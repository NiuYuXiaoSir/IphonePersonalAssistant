import Foundation
import AVFoundation
import Speech

/// 逐字实时语音识别，用于速记和对话的语音输入。
///
/// 两种引擎，按设置里的选择走：
///   - **系统（端上）**：边说边出字，文字直接进输入框；识别率一般
///   - **第三方**：录音时只显示「正在听…」，说完把整段音频传上去（`CloudSpeechService`），
///     回来的文字通过 `transcript` 交给调用方——准确率高得多，代价是要等几秒、且要联网
///
/// 与会议录音的转写仍是两套东西：会议是录完再逐段转（不碰麦克风、后台也能跑），
/// 这里是边说边听（独占麦克风）。速记不需要同时录音，所以可以放心独占。
final class LiveSpeechRecognizer: ObservableObject {

    @Published private(set) var isRunning = false
    /// 边说边出的预览文字（只有系统引擎有）
    @Published private(set) var liveText = ""
    /// 这一轮的最终文字。第三方引擎是说完才拿到，所以调用方要监听它。
    @Published private(set) var transcript = ""
    /// 音频已经录完、正在上传/识别
    @Published private(set) var isTranscribing = false
    @Published private(set) var message = ""

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var onDevice = true

    /// 第三方引擎那条路：用录音机存文件（比手写音频文件流省事，格式也是各家都吃的 m4a）
    private var recorder: AVAudioRecorder?
    private var cloudFileURL: URL?
    private var cloudConfig: SpeechConfig?
    private var useCloud = false

    // MARK: - 开始 / 停止

    func start(onDevice: Bool = true) {
        guard !isRunning else { return }
        self.onDevice = onDevice
        liveText = ""
        transcript = ""
        message = ""

        let config = SpeechSettings.shared.makeConfig()
        useCloud = config.isCloud
        if useCloud {
            cloudConfig = config
            guard !config.apiKey.isEmpty else {
                message = "第三方语音识别还没配密钥：去「我的 → 语音识别」填一个，或把引擎切回「系统（端上）」。"
                AppLog.warn("LiveASR", message)
                return
            }
        } else {
            let status = SFSpeechRecognizer.authorizationStatus()
            guard status == .authorized else {
                message = "语音识别未授权（当前：\(TranscriptionService.statusText(status))）。去 设置 → 隐私与安全性 → 语音识别 打开。"
                AppLog.warn("LiveASR", message)
                return
            }
        }

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.message = "麦克风未授权"
                    AppLog.warn("LiveASR", "麦克风未授权")
                    return
                }
                do {
                    if self.useCloud {
                        try self.beginCloudSession()
                    } else {
                        try self.beginSystemSession()
                    }
                } catch {
                    self.message = "启动失败：\(error.localizedDescription)"
                    AppLog.error("LiveASR", self.message)
                    self.teardown()
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        if useCloud {
            isRunning = false
            finishCloud()
        } else {
            request?.endAudio()
            let final = liveText
            teardown()
            transcript = final
            message = "已停止"
            AppLog.info("LiveASR", "停止实时识别，共 \(final.count) 字")
        }
    }

    // MARK: - 系统端上识别

    private func beginSystemSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)

        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.reset()

        try beginRecognitionTask()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw TranscriptionError.failed("麦克风没有可用的音频格式（采样率 0）")
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()

        isRunning = true
        message = "正在听…"
        AppLog.info("LiveASR", "开始端上识别，采样率=\(Int(format.sampleRate))")
    }

    private func beginRecognitionTask() throws {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) else {
            throw TranscriptionError.noRecognizer
        }
        guard rec.isAvailable else {
            throw TranscriptionError.failed("识别器当前不可用（系统忙或需要网络）")
        }
        if onDevice && !rec.supportsOnDeviceRecognition {
            throw TranscriptionError.onDeviceUnsupported
        }
        recognizer = rec

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = onDevice
        req.addsPunctuation = true
        request = req

        task = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async { self.liveText = text }
                if result.isFinal {
                    AppLog.info("LiveASR", "识别定稿：\(text.count) 字")
                }
            }
            if let error {
                AppLog.warn("LiveASR", "识别任务报错：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 第三方整段识别

    private func beginCloudSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        guard rec.record() else {
            throw TranscriptionError.failed("录音没能启动（可能是麦克风被别的 App 占着）")
        }
        recorder = rec
        cloudFileURL = url
        isRunning = true
        message = "正在听…说完点一下停止"
        AppLog.info("LiveASR", "开始第三方录音，引擎=\(cloudConfig?.engine.rawValue ?? "-")")
    }

    private func finishCloud() {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let url = cloudFileURL, let config = cloudConfig else {
            message = "已停止"
            return
        }
        cloudFileURL = nil
        isTranscribing = true
        message = "正在识别…"

        Task {
            do {
                let text = try await CloudSpeechService.transcribe(url: url, config: config)
                await MainActor.run {
                    self.isTranscribing = false
                    self.transcript = text
                    self.message = text.isEmpty ? "没听出内容，再说一遍试试" : "已识别 \(text.count) 字"
                }
            } catch {
                await MainActor.run {
                    self.isTranscribing = false
                    self.message = "识别失败：\(error.localizedDescription)"
                }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 收尾

    private func teardown() {
        isRunning = false
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
