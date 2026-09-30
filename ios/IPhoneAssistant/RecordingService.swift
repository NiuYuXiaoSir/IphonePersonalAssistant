import Foundation
import AVFoundation

/// 长会议录音。
///
/// 核心设计：**分段录制**，每 `segmentDuration` 秒换一个新文件。
///
/// 为什么必须分段：m4a(AAC) 的元数据是停止录制时才写入文件的，如果 App 在会议中途
/// 被系统杀掉（内存压力下完全可能），单文件录制的整段音频会变成打不开的废文件。
/// 分段后最多丢最后一段，之前的都是完整可播放的。这也是为什么不需要“定期 flush”——
/// 每段文件本身就是一次完整的落盘。
final class RecordingService: ObservableObject {

    static let segmentDuration: Double = 60

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var segmentCount: Int = 0
    @Published private(set) var markerCount: Int = 0
    @Published private(set) var currentFileKB: Int = 0
    @Published private(set) var message: String = "准备就绪"

    /// 每完成一段就回调一次。调用方拿它做“边录边转”——
    /// 回调里读的是已经落盘完成的文件，不会干扰录音。
    var onSegmentFinished: ((Meeting.AudioSegment) -> Void)?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private var meetingID = ""
    private var currentSegment: Meeting.AudioSegment?
    private var finishedSegments: [Meeting.AudioSegment] = []
    private var markers: [Double] = []
    private var interruptionObserver: NSObjectProtocol?
    private var resumeWorkItem: DispatchWorkItem?

    // MARK: - 开始 / 结束

    func start() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.message = "麦克风权限被拒绝，去 设置 → 隐私与安全性 → 麦克风 里打开"
                    AppLog.error("Rec", "麦克风权限被拒绝")
                    return
                }
                self.beginSession()
            }
        }
    }

    private func beginSession() {
        do {
            try activateSession()
        } catch {
            message = "音频会话配置失败：\(error.localizedDescription)"
            AppLog.error("Rec", message)
            return
        }

        startedAt = Date()
        meetingID = UUID().uuidString
        finishedSegments = []
        markers = []
        elapsed = 0
        segmentCount = 0
        markerCount = 0
        currentFileKB = 0
        isRecording = true
        observeInterruptions()

        guard startSegment(index: 0) else {
            isRecording = false
            removeInterruptionObserver()
            return
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        message = "录音中。现在可以锁屏，录音会继续。"
        AppLog.info("Rec", "开始录音，会议 id=\(meetingID)")
    }

    /// 用户点结束。返回 nil 表示没录到任何可用音频。
    func stop() -> Meeting? {
        guard isRecording else { return nil }

        finishCurrentSegment()
        timer?.invalidate()
        timer = nil
        isRecording = false
        removeInterruptionObserver()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed

        guard !finishedSegments.isEmpty else {
            message = "结束，但没有产生可用的音频段"
            AppLog.error("Rec", "录音结束，无可用段")
            return nil
        }

        let meeting = Meeting(
            id: meetingID,
            title: Self.defaultTitle(for: startedAt ?? Date()),
            startedAt: startedAt ?? Date(),
            endedAt: Date(),
            durationSeconds: duration,
            segments: finishedSegments,
            markers: markers,
            transcript: "",
            summaryJSON: "",
            status: "recorded"
        )
        AppLog.info("Rec", "结束录音：\(finishedSegments.count) 段，总时长 \(Int(duration)) 秒")
        message = "已保存 \(finishedSegments.count) 段，共 \(Self.durationText(duration))"
        return meeting
    }

    func addMarker() {
        guard isRecording else { return }
        markers.append(elapsed)
        markerCount = markers.count
        AppLog.info("Rec", "标记点 \(Int(elapsed)) 秒")
    }

    // MARK: - 分段

    private func startSegment(index: Int) -> Bool {
        let name = "\(meetingID)-seg\(String(format: "%03d", index)).m4a"
        let url = MeetingStore.recordingsDirectory().appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            guard rec.record() else {
                message = "第 \(index + 1) 段录音启动失败"
                AppLog.error("Rec", message)
                return false
            }
            recorder = rec
            let offset = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            currentSegment = Meeting.AudioSegment(id: UUID().uuidString,
                                                  fileName: name,
                                                  startOffset: offset,
                                                  durationSeconds: 0)
            AppLog.info("Rec", "开始第 \(index + 1) 段：\(name)")
            return true
        } catch {
            message = "创建录音文件失败：\(error.localizedDescription)"
            AppLog.error("Rec", message)
            return false
        }
    }

    /// 收尾当前段。文件长度以磁盘上的音频为准，而不是界面计时器。
    private func finishCurrentSegment() {
        guard let seg = currentSegment else { return }
        let url = MeetingStore.recordingsDirectory().appendingPathComponent(seg.fileName)
        recorder?.stop()
        recorder = nil
        currentSegment = nil

        let duration = MeetingStore.fileDuration(url)
        guard duration > 0.1 else {
            AppLog.warn("Rec", "第 \(finishedSegments.count + 1) 段时长≈0，丢弃")
            try? FileManager.default.removeItem(at: url)
            return
        }
        var finalized = seg
        finalized.durationSeconds = duration
        finishedSegments.append(finalized)
        segmentCount = finishedSegments.count
        AppLog.info("Rec", "收尾第 \(finishedSegments.count) 段，时长 \(String(format: "%.1f", duration)) 秒")

        // 段已经完整落盘，交给边录边转
        onSegmentFinished?(finalized)
    }

    private func tick() {
        guard let started = startedAt else { return }
        elapsed = Date().timeIntervalSince(started)
        updateCurrentFileSize()

        if let rec = recorder, rec.currentTime >= Self.segmentDuration {
            finishCurrentSegment()
            if !startSegment(index: finishedSegments.count) {
                AppLog.error("Rec", "分段失败，主动停止录音以免悄悄丢内容")
                message = "分段失败，已停止录音"
                isRecording = false
                timer?.invalidate()
                timer = nil
            }
        }
    }

    private func updateCurrentFileSize() {
        guard let seg = currentSegment else { return }
        let url = MeetingStore.recordingsDirectory().appendingPathComponent(seg.fileName)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let bytes = attrs[.size] as? Int {
            currentFileKB = bytes / 1024
        }
    }

    // MARK: - 音频会话与中断

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
    }

    private func observeInterruptions() {
        removeInterruptionObserver()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
    }

    private func removeInterruptionObserver() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        resumeWorkItem?.cancel()
        resumeWorkItem = nil
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            AppLog.warn("Rec", "音频被系统中断（来电/闹钟/其他 App 抢音频）")
            message = "音频被中断，正在等待自动恢复…"
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            AppLog.info("Rec", "中断结束，shouldResume=\(options.contains(.shouldResume))")
            scheduleResume()
        @unknown default:
            break
        }
    }

    /// 中断结束后自动接上。
    /// 当前段在中断时已经停了，所以先收尾再起一段新的——宁可多一个文件，不要出现静默的空洞。
    private func scheduleResume() {
        resumeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            do {
                try self.activateSession()
            } catch {
                self.message = "中断后恢复音频会话失败：\(error.localizedDescription)"
                AppLog.error("Rec", self.message)
                return
            }
            self.finishCurrentSegment()
            if self.startSegment(index: self.finishedSegments.count) {
                self.message = "已在中断后自动恢复录音"
                AppLog.info("Rec", "中断后恢复成功")
            } else {
                self.message = "中断后无法恢复录音"
            }
        }
        resumeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    // MARK: - 工具

    static func defaultTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm 的会议"
        return f.string(from: date)
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        if m >= 60 {
            return "\(m / 60) 小时 \(m % 60) 分"
        }
        return "\(m) 分 \(s) 秒"
    }
}
