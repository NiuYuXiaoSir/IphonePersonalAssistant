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
/// 想要一个整文件：会议详情 → 导出 →「合并成一个音频文件」，会现拼一个出来。
///
/// 中断处理是这里最容易出事的地方，规则是：
///   1. 中断一开始就立刻收尾当前段——把已经录到的部分封口保存，不等重连；
///   2. 之后每 3 秒试一次重新激活音频会话，来电打多久就试多久，不设上限；
///   3. 界面上显示的是**实际录到的时长**，中断漏掉的时间单独算。
///      上一版把墙上的钟当录音时长，于是出现过「5 段、总时长 59 分钟」这种账：
///      中间 55 分钟其实一点音频都没有。
final class RecordingService: ObservableObject {

    static let segmentDuration: Double = 60

    @Published private(set) var isRecording = false
    /// 实际录到的秒数（各已完成段之和 + 当前正在录的这段）
    @Published private(set) var elapsed: Double = 0
    /// 因为中断没录到的秒数
    @Published private(set) var lostSeconds: Double = 0
    /// 中断中、还没接上：录音器是停的
    @Published private(set) var isWaitingForAudio = false
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
    /// 已完成各段的时长之和
    private var finishedSeconds: Double = 0
    /// 已经结算过的漏录时长
    private var lostBefore: Double = 0
    /// 本次中断开始的时刻；非 nil 表示「这一段没在录」
    private var gapStart: Date?
    private var resumeAttempts = 0
    private var lastResumeAttempt = Date.distantPast
    private var markers: [Double] = []
    private var interruptionObserver: NSObjectProtocol?

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
        finishedSeconds = 0
        lostBefore = 0
        gapStart = nil
        resumeAttempts = 0
        lastResumeAttempt = .distantPast
        markers = []
        elapsed = 0
        lostSeconds = 0
        segmentCount = 0
        markerCount = 0
        currentFileKB = 0
        isWaitingForAudio = false
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
        guard startedAt != nil else { return nil }

        finishCurrentSegment()
        settleGap()
        timer?.invalidate()
        timer = nil
        isRecording = false
        isWaitingForAudio = false
        removeInterruptionObserver()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard !finishedSegments.isEmpty else {
            message = "结束，但没有产生可用的音频段"
            AppLog.error("Rec", "录音结束，无可用段")
            return nil
        }

        let duration = finishedSeconds
        let meeting = Meeting(
            id: meetingID,
            title: Self.defaultTitle(for: startedAt ?? Date()),
            startedAt: startedAt ?? Date(),
            endedAt: Date(),
            durationSeconds: duration,
            gapSeconds: lostBefore > 0.5 ? lostBefore : nil,
            segments: finishedSegments,
            markers: markers,
            transcript: "",
            summaryJSON: "",
            status: "recorded"
        )
        segmentCount = finishedSegments.count
        AppLog.info("Rec", "结束录音：\(finishedSegments.count) 段，录到 \(Int(duration)) 秒，中断漏录 \(Int(lostBefore)) 秒")
        message = "已保存 \(finishedSegments.count) 段，共 \(Self.durationText(duration))"
            + (lostBefore > 0.5 ? "（另有 \(Self.durationText(lostBefore)) 因中断没录到）" : "")
        startedAt = nil
        return meeting
    }

    func addMarker() {
        guard isRecording else { return }
        // 标记点是「录音时间轴上的第几秒」，和分段偏移、播放器用同一把尺子，
        // 所以用 elapsed（录到的时长）而不是墙上时间——中断漏掉的那段不占时间轴。
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
            // 偏移用「已经录到的秒数」而不是墙上时间：中断漏掉的那段没有音频，
            // 不该在时间轴上占位置。这样分段偏移、播放器的连续时间轴、标记点三者对得上。
            let offset = finishedSeconds
            currentSegment = Meeting.AudioSegment(id: UUID().uuidString,
                                                  fileName: name,
                                                  startOffset: offset,
                                                  durationSeconds: 0)
            lastResumeAttempt = Date()
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
        finishedSeconds += duration
        segmentCount = finishedSegments.count
        elapsed = finishedSeconds
        AppLog.info("Rec", "收尾第 \(finishedSegments.count) 段，时长 \(String(format: "%.1f", duration)) 秒")

        // 段已经完整落盘，交给边录边转
        onSegmentFinished?(finalized)
    }

    private func tick() {
        guard isRecording, startedAt != nil else { return }

        // 计的是「录到多少」，不是「过了多久」
        elapsed = finishedSeconds + max(0, recorder?.currentTime ?? 0)
        if let gap = gapStart {
            lostSeconds = lostBefore + Date().timeIntervalSince(gap)
        }
        updateCurrentFileSize()

        if let rec = recorder {
            if rec.isRecording {
                if rec.currentTime >= Self.segmentDuration {
                    finishCurrentSegment()
                    if !startSegment(index: finishedSegments.count) {
                        // 起不来新段就退到「等音频」状态，由下面的重试逻辑接着试，
                        // 已经录到的部分已经安全落盘，不会丢
                        beginWaiting(reason: "下一段启动失败")
                    }
                }
            } else {
                // 录音器已经不工作了（中断、被别的 App 抢走麦克风、系统重置音频）。
                // 先把这一段收尾封口，再进入重连状态——不能像以前那样干等，
                // 那样这一段会一直开着，用户不点结束就一直不落盘。
                AppLog.warn("Rec", "录音器已停止工作，收尾当前段")
                finishCurrentSegment()
                beginWaiting(reason: "音频被中断")
            }
        } else if isWaitingForAudio {
            // 每 3 秒试一次重连。来电可能很久，所以不设次数上限，只把日志压低。
            if Date().timeIntervalSince(lastResumeAttempt) >= 3 {
                attemptResume()
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
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            AppLog.warn("Rec", "音频被系统中断（来电/闹钟/其他 App 抢音频）")
            // 立刻封口：把已经录到的部分存下来，文件是完整可播的
            finishCurrentSegment()
            beginWaiting(reason: "音频被系统中断（来电/闹钟）")
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            AppLog.info("Rec", "中断结束，shouldResume=\(options.contains(.shouldResume))")
            // 不等下一个 tick，立刻试一次；失败就交给 tick 的 3 秒重试
            lastResumeAttempt = .distantPast
            attemptResume()
        @unknown default:
            break
        }
    }

    /// 进入「没有在录」的状态。gapStart 只记第一次，漏录时长按整段中断算。
    private func beginWaiting(reason: String) {
        if gapStart == nil {
            gapStart = Date()
            resumeAttempts = 0
        }
        isWaitingForAudio = true
        message = "\(reason)，正在自动重连…"
    }

    /// 把这段中断的时长结算掉
    private func settleGap() {
        guard let gap = gapStart else { return }
        lostBefore += Date().timeIntervalSince(gap)
        lostSeconds = lostBefore
        gapStart = nil
    }

    private func attemptResume() {
        guard isRecording, isWaitingForAudio else { return }
        lastResumeAttempt = Date()
        do {
            try activateSession()
        } catch {
            resumeAttempts += 1
            // 一整通电话里会有几十次失败，只留第一次和每 10 次一条
            if resumeAttempts == 1 || resumeAttempts % 10 == 0 {
                AppLog.warn("Rec", "重连失败第 \(resumeAttempts) 次：\(error.localizedDescription)")
            }
            message = "音频被中断，正在自动重连…（已试 \(resumeAttempts) 次）"
            return
        }

        resumeAttempts = 0
        guard startSegment(index: finishedSegments.count) else {
            message = "恢复录音失败，正在重试…"
            return
        }
        settleGap()
        isWaitingForAudio = false
        AppLog.info("Rec", "中断后恢复成功，这段中断漏录 \(Int(lostBefore)) 秒")
        message = "已接上录音（中断期间漏掉的内容没法补录）"
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
