import Foundation
import AVFoundation

/// 会议音频播放器。
///
/// 录音是每 60 秒一个文件的，直接一段段放很别扭，所以这里把若干段当成一整条来放：
/// 一段放完自动接下一段，进度条上是一条连续的时间轴，点进度条也能跨段定位。
final class MeetingPlayer: NSObject, ObservableObject {

    @Published private(set) var isPlaying = false
    /// 当前播到第几段（从 0 开始）
    @Published private(set) var currentIndex = 0
    /// 整条录音上的已播放秒数
    @Published private(set) var elapsedTotal: Double = 0
    /// 是否已经装进音频。没装的时候界面上不该出现可点的播放按钮
    @Published private(set) var loaded = false

    /// 全部段加起来的总时长
    private(set) var totalDuration: Double = 0
    private(set) var segmentCount = 0

    private var urls: [URL] = []
    /// 每段在整条时间轴上的起点
    private var offsets: [Double] = []
    private var player: AVAudioPlayer?
    private var timer: Timer?

    // MARK: - 装载

    func load(urls: [URL], durations: [Double]) {
        stop()
        self.urls = urls
        var offsets: [Double] = []
        var acc = 0.0
        for duration in durations {
            offsets.append(acc)
            acc += max(duration, 0)
        }
        self.offsets = offsets
        totalDuration = acc
        segmentCount = urls.count
        currentIndex = 0
        elapsedTotal = 0
        loaded = !urls.isEmpty
    }

    // MARK: - 播放控制

    func togglePlay() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard !urls.isEmpty else { return }
        if let player {
            activateSession()
            player.play()
            isPlaying = true
            startTimer()
            return
        }
        // 放完最后一段之后再点播放，从头开始
        if elapsedTotal >= totalDuration - 0.2 {
            start(index: 0, at: 0, autoplay: true)
        } else {
            let target = segmentIndex(for: elapsedTotal)
            start(index: target, at: elapsedTotal - offsets[target], autoplay: true)
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    /// 从某一段开始播（点录音段列表里的某一项）
    func play(from index: Int) {
        guard index >= 0, index < urls.count else { return }
        start(index: index, at: 0, autoplay: true)
    }

    func stop() {
        stopTimer()
        player?.stop()
        player = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 拖动进度条：拖的过程中先停掉定时器，松手再继续，
    /// 否则定时器会把进度往回顶，手感会很别扭。
    func setScrubbing(_ scrubbing: Bool) {
        if scrubbing {
            stopTimer()
        } else if isPlaying {
            startTimer()
        }
    }

    func seek(to time: Double) {
        guard !urls.isEmpty, !offsets.isEmpty else { return }
        let clamped = max(0, min(time, totalDuration))
        let target = segmentIndex(for: clamped)

        // 还在同一段里就只挪播放头。重新建一个 AVAudioPlayer 很贵，
        // 拖进度条时每一帧都建一次会卡。
        if let player, target == currentIndex {
            player.currentTime = min(max(clamped - offsets[target], 0), max(player.duration - 0.05, 0))
            updateElapsed()
            return
        }
        start(index: target, at: clamped - offsets[target], autoplay: isPlaying)
    }

    // MARK: - 内部

    private func start(index: Int, at local: Double, autoplay: Bool) {
        stopTimer()
        player?.stop()
        do {
            activateSession()
            let next = try AVAudioPlayer(contentsOf: urls[index])
            next.delegate = self
            next.prepareToPlay()
            if local > 0 {
                next.currentTime = min(local, max(next.duration - 0.05, 0))
            }
            player = next
            currentIndex = index
            if autoplay {
                next.play()
                isPlaying = true
                startTimer()
            } else {
                isPlaying = false
            }
            updateElapsed()
        } catch {
            isPlaying = false
            player = nil
            AppLog.error("Player", "播放 \(urls[index].lastPathComponent) 失败：\(error.localizedDescription)")
        }
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }

    /// 整条时间轴上的某一秒落在第几段
    private func segmentIndex(for time: Double) -> Int {
        var result = 0
        for (index, offset) in offsets.enumerated() where offset <= time + 0.001 {
            result = index
        }
        return result
    }

    private func updateElapsed() {
        guard let player, currentIndex < offsets.count else { return }
        elapsedTotal = offsets[currentIndex] + player.currentTime
    }

    private func startTimer() {
        stopTimer()
        // 用 common 模式：拖动滑块时 runloop 会切到 tracking 模式，default 模式下的定时器会停
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.updateElapsed()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension MeetingPlayer: AVAudioPlayerDelegate {

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // 这个回调的线程没有保证，统一回主线程再动状态
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let next = self.currentIndex + 1
            if next < self.urls.count {
                self.start(index: next, at: 0, autoplay: true)
            } else {
                self.stopTimer()
                self.player = nil
                self.isPlaying = false
                self.elapsedTotal = self.totalDuration
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                AppLog.info("Player", "整场录音播放完毕")
            }
        }
    }
}
