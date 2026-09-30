import Foundation

/// 边录边转的执行者。
///
/// 为什么不是“边说边逐字识别”：那样要让识别器和录音器同时占麦克风，
/// 两者共存不可靠，而录音是不允许失败的关键路径。
/// 这里的做法是：每段录完（磁盘上已经是完整文件）再送去转写，
/// 完全不碰麦克风，录音零风险，而且后台也能继续。代价是延迟最多一段（60 秒）。
///
/// 单独写成一个类而不是把闭包挂在 RecordingService 上，是为了避开引用环：
/// recorder → 闭包 → weak transcriber，两边都不持有对方。
final class RealtimeTranscriber: ObservableObject {

    /// 开关可以直接在录音中切换（类是引用类型，读到的总是当前值）
    @Published var isEnabled = true
    @Published private(set) var text = ""
    @Published private(set) var completedSegments = 0
    @Published private(set) var failedSegments = 0

    private var chain: Task<Void, Never>?
    private var onDevice = true

    func configure(onDevice: Bool) {
        self.onDevice = onDevice
    }

    /// 把一段录音排进转写队列。串行执行，不会并发压堆。
    func enqueue(_ segment: Meeting.AudioSegment) {
        guard isEnabled else {
            AppLog.info("RealtimeASR", "边录边转已关闭，跳过 \(segment.fileName)")
            return
        }

        let previous = chain
        let useOnDevice = onDevice

        chain = Task { [weak self] in
            // 串行化：等上一段转完，避免多段识别同时跑
            await previous?.value
            guard let self else { return }

            let url = MeetingStore.recordingsDirectory().appendingPathComponent(segment.fileName)
            do {
                let piece = try await TranscriptionService.recognize(url: url, onDevice: useOnDevice)
                await MainActor.run {
                    if !piece.isEmpty {
                        self.text = self.text.isEmpty ? piece : self.text + "\n" + piece
                    }
                    self.completedSegments += 1
                    AppLog.info("RealtimeASR", "已完成 \(self.completedSegments) 段，累计 \(self.text.count) 字")
                }
            } catch {
                await MainActor.run {
                    self.failedSegments += 1
                    AppLog.warn("RealtimeASR", "\(segment.fileName) 失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 录音结束时调用：等所有在途段转完再返回，宁可多等几秒也不丢文字
    func finish() async {
        await chain?.value
    }

    func reset() {
        chain?.cancel()
        chain = nil
        text = ""
        completedSegments = 0
        failedSegments = 0
    }
}
