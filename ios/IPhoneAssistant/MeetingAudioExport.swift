import Foundation
import AVFoundation

/// 把一场会议的多个录音段拼成一个 m4a。
///
/// 为什么要现拼而不是干脆录成一个文件：分段是防「App 被系统杀掉、整段录音报废」的保险，
/// 这个保险不能丢。但听、发、存档时想要的是一个整文件，所以两者都留着——
/// 需要的时候用 AVMutableComposition 把各段首尾相接，再导出一个 .m4a 落到 Documents 里。
///
/// 中断漏掉的那段没有音频，合并时不会伪造静音补时长，直接跳过——
/// 时间轴会短一点，但听到的都是当时真实录到的。
enum MeetingAudioExport {

    enum ExportError: LocalizedError {
        case noSegment
        case trackFailed
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSegment:
                return "这场会议没有可用的音频段"
            case .trackFailed:
                return "拼不出音轨（可能是某一段文件已损坏）"
            case .exportFailed(let reason):
                return "合并失败：\(reason)"
            }
        }
    }

    /// 返回合并后的文件 URL（在 Documents 根目录，文件名带「完整录音」）。
    static func merge(meeting: Meeting) async throws -> URL {
        let dir = MeetingStore.recordingsDirectory()
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.trackFailed
        }

        var cursor = CMTime.zero
        var used = 0
        for segment in meeting.segments {
            let url = dir.appendingPathComponent(segment.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)

            let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            guard let source = tracks.first else {
                AppLog.warn("Export", "\(segment.fileName) 里没有音轨，跳过")
                continue
            }
            guard let duration = try? await asset.load(.duration) else { continue }

            do {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                          of: source,
                                          at: cursor)
            } catch {
                AppLog.warn("Export", "合并时跳过 \(segment.fileName)：\(error.localizedDescription)")
                continue
            }
            cursor = CMTimeAdd(cursor, duration)
            used += 1
        }
        guard used > 0, cursor > .zero else { throw ExportError.noSegment }

        let name = "\(safeName(meeting.title))-完整录音.m4a"
        let out = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        try? FileManager.default.removeItem(at: out)

        guard let session = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.exportFailed("创建导出会话失败")
        }
        session.outputURL = out
        session.outputFileType = .m4a
        session.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                cont.resume()
            }
        }
        // 导出期间 session 必须活着：这里的 withExtendedLifetime 就是拦住编译器
        // 提前把它释放掉（后面不再用 session，ARC 有权这么做，那样导出会被取消）
        withExtendedLifetime(session) {}

        // 不去读 session.status / session.error：那两个属性在新版 SDK 里已经标了废弃。
        // 导出成没成，看文件本身最实在。
        let attrs = try? FileManager.default.attributesOfItem(atPath: out.path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        guard bytes > 1024 else {
            AppLog.error("Export", "合并没产出可用文件（\(cursor.seconds) 秒，\(used) 段）")
            throw ExportError.exportFailed("导出没有产出可用的音频文件，可能是某一段录音已损坏")
        }

        AppLog.info("Export", "合并完成：\(name)（\(used) 段，\(String(format: "%.1f", cursor.seconds)) 秒，\(bytes / 1024) KB）")
        return out
    }

    /// 文件名里不能有路径分隔符，标题里却经常有
    static func safeName(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "会议" : cleaned
    }
}
