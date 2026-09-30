import Foundation
import AVFoundation
import Speech

/// 逐字实时语音识别，用于速记的语音输入。
///
/// 与会议录音的转写是两套东西，这是刻意的：
/// - 会议那边：每段录完再转（不碰麦克风，零冲突，后台也能跑）
/// - 这里：边说边出字（独占麦克风）
/// 速记不需要同时录音，所以可以放心独占麦克风。
///
/// 不做周期性重启识别任务：速记一次最多说一两句话，碰不到端上识别的单次时长限制，
/// 而重启会带来文字重叠或截断的问题。
final class LiveSpeechRecognizer: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var liveText = ""
    @Published private(set) var message = ""

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var onDevice = true

    func start(onDevice: Bool = true) {
        guard !isRunning else { return }
        self.onDevice = onDevice
        liveText = ""

        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else {
            message = "语音识别未授权（当前：\(TranscriptionService.statusText(status))）。去 设置 → 隐私与安全性 → 语音识别 打开。"
            AppLog.warn("LiveASR", message)
            return
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
                    try self.beginSession()
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
        request?.endAudio()
        teardown()
        message = "已停止"
        AppLog.info("LiveASR", "停止实时识别，共 \(liveText.count) 字")
    }

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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func beginSession() throws {
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
        AppLog.info("LiveASR", "开始实时识别，端上=\(onDevice)，采样率=\(Int(format.sampleRate))")
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
}
