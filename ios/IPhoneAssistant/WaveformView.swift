import SwiftUI
import AVFoundation

/// 真波形：从音频文件里按桶取峰值。
///
/// 上一版那个波形是按文件名哈希生成的——看着像波形，其实和声音一点关系都没有。
/// 现在读真样本，代价是 IO + 遍历几十万帧，所以：
///   - 只在后台队列算；
///   - 按「路径 + 修改时间 + 柱数」缓存，同一个文件只算一次；
///   - 界面先画占位（一条矮线），算完再长出来，不跳版。
final class WaveformCache {

    static let shared = WaveformCache()

    private var peaks: [String: [Float]] = [:]
    private let queue = DispatchQueue(label: "waveform.peaks", qos: .utility)

    private init() {}

    func cached(url: URL, bars: Int) -> [Float]? {
        peaks[key(url: url, bars: bars)]
    }

    /// 回调一定在主线程
    func peaks(url: URL, bars: Int, completion: @escaping ([Float]?) -> Void) {
        let key = self.key(url: url, bars: bars)
        queue.async {
            if let hit = self.peaks[key] {
                DispatchQueue.main.async { completion(hit) }
                return
            }
            let result = Self.compute(url: url, bars: bars)
            if let result { self.peaks[key] = result }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func key(url: URL, bars: Int) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(Int(stamp))|\(bars)"
    }

    /// 分块读，每块只更新对应桶的峰值——不把整个文件读进内存。
    private static func compute(url: URL, bars: Int) -> [Float]? {
        guard bars > 0, FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let total = file.length
        guard total > 0 else { return nil }

        let framesPerBar = max(1, Int(total) / bars)
        let chunk: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: chunk) else { return nil }

        var out = [Float](repeating: 0, count: bars)
        var index = 0
        while true {
            buffer.frameLength = 0
            do { try file.read(into: buffer) } catch { break }
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard let channel = buffer.floatChannelData?[0] else { break }
            for i in 0..<count {
                let bar = min(bars - 1, (index + i) / framesPerBar)
                let value = abs(channel[i])
                if value > out[bar] { out[bar] = value }
            }
            index += count
        }
        guard index > 0 else { return nil }
        return out
    }
}

/// 一段音频的波形。传文件 URL，算不出来就画一条矮线（不报错、不留空）。
///
/// 波形是装饰：段落卡上已经写了「第 N 段」和时长，所以这里对 VoiceOver 隐藏，
/// 免得读屏时多念一串没用的东西。
struct WaveformView: View {

    var url: URL?
    var bars: Int = 32
    var tint: Color = Color(uiColor: .secondaryLabel)
    var height: CGFloat = 24

    @State private var peaks: [Float] = []

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let spacing: CGFloat = 2
            let barWidth = max(1.5, (width - CGFloat(bars - 1) * spacing) / CGFloat(bars))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<bars, id: \.self) { index in
                    Capsule()
                        .fill(tint.opacity(peaks.isEmpty ? 0.3 : 1))
                        .frame(width: barWidth, height: barHeight(index))
                }
            }
            .frame(width: width, height: height)
        }
        .frame(height: height)
        .task(id: taskKey) { await load() }
        .accessibilityHidden(true)
    }

    private var taskKey: String {
        "\(url?.path ?? "none")|\(bars)"
    }

    private func barHeight(_ index: Int) -> CGFloat {
        guard peaks.count == bars else { return max(2, height * 0.22) }
        // 开个方根把轻声部分托起来，不然整条看起来都是平的
        let value = CGFloat(pow(max(0, min(1, peaks[index])), 0.6))
        return max(2, min(height, value * height))
    }

    private func load() async {
        guard let url else {
            peaks = []
            return
        }
        if let hit = WaveformCache.shared.cached(url: url, bars: bars) {
            peaks = hit
            return
        }
        let result: [Float]? = await withCheckedContinuation { continuation in
            WaveformCache.shared.peaks(url: url, bars: bars) { continuation.resume(returning: $0) }
        }
        if let result { peaks = result }
    }
}
