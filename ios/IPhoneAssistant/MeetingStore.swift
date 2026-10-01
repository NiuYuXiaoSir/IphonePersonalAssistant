import Foundation
import AVFoundation

/// 一场会议的全部元数据。音频本身存在 Documents/recordings/ 下，这里只记文件名。
struct Meeting: Codable, Identifiable {

    struct AudioSegment: Codable, Identifiable {
        var id: String
        var fileName: String
        /// 相对会议开始的偏移秒数
        var startOffset: Double
        var durationSeconds: Double
    }

    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    /// 实际录到的音频总长（不是从开始到结束过了多久）
    var durationSeconds: Double
    /// 中途因中断（来电/闹钟）漏掉的秒数。老的记录里没有这个字段，所以是可选的。
    var gapSeconds: Double?
    var segments: [AudioSegment]
    /// 录制中用户打的标记点，秒
    var markers: [Double]
    var transcript: String
    var summaryJSON: String
    /// recording / recorded / transcribed / summarized / recovered / failed
    var status: String
}

/// 会议记录的本地存储。用单个 JSON 文件存元数据，音频单独放目录。
///
/// 为什么不用 SwiftData：这个 App 的数据量很小（一天 1-2 场会），
/// JSON 文件的好处是自己完全可控、能直接看懂、能直接从「文件」App 导出。
/// 后续如果要全文搜索再换。
final class MeetingStore: ObservableObject {

    @Published private(set) var meetings: [Meeting] = []

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("meetings.json")
    }

    init() {
        load()
        let recovered = recoverOrphans()
        if !recovered.isEmpty {
            AppLog.warn("Store", "启动时恢复了 \(recovered.count) 场被意外中断的录音")
        }
    }

    // MARK: - 目录与文件

    static func recordingsDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func fileDuration(_ url: URL) -> Double {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return 0 }
        return player.duration
    }

    static func fileCreationDate(_ url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.creationDate] as? Date
    }

    // MARK: - 读写

    func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([Meeting].self, from: data) else {
            meetings = []
            return
        }
        meetings = decoded.sorted { $0.startedAt > $1.startedAt }
        AppLog.info("Store", "载入 \(meetings.count) 场会议记录")
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        do {
            let data = try encoder.encode(meetings)
            try data.write(to: fileURL, options: .atomic)
            AppLog.debug("Store", "已保存 \(meetings.count) 场记录")
        } catch {
            AppLog.error("Store", "保存失败：\(error.localizedDescription)")
        }
    }

    func add(_ meeting: Meeting) {
        meetings.insert(meeting, at: 0)
        save()
    }

    func update(_ meeting: Meeting) {
        guard let i = meetings.firstIndex(where: { $0.id == meeting.id }) else { return }
        meetings[i] = meeting
        save()
    }

    func delete(_ meeting: Meeting) {
        for seg in meeting.segments {
            let url = Self.recordingsDirectory().appendingPathComponent(seg.fileName)
            try? FileManager.default.removeItem(at: url)
        }
        meetings.removeAll { $0.id == meeting.id }
        save()
        AppLog.info("Store", "删除会议「\(meeting.title)」及其 \(meeting.segments.count) 个音频段")
    }

    func meeting(id: String) -> Meeting? {
        meetings.first { $0.id == id }
    }

    /// 磁盘占用
    func storageBytes() -> Int {
        let dir = Self.recordingsDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var total = 0
        for f in files {
            total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    // MARK: - 意外中断恢复

    /// 找回被系统杀掉时留下的录音段：音频文件还在，但 meetings.json 里没有对应记录。
    ///
    /// 这是分段录制带来的直接好处——即使 App 在会议中途被系统回收，
    /// 已经写完的那些段文件都是完整可播放的，不会像单文件那样整段报废。
    @discardableResult
    func recoverOrphans() -> [Meeting] {
        let dir = Self.recordingsDirectory()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".m4a") }
        guard !names.isEmpty else { return [] }

        // 文件名格式：<meetingID>-segNNN.m4a
        var grouped: [String: [String]] = [:]
        for name in names {
            guard let r = name.range(of: "-seg", options: .backwards) else { continue }
            let meetingID = String(name[name.startIndex..<r.lowerBound])
            grouped[meetingID, default: []].append(name)
        }

        var recovered: [Meeting] = []
        for (meetingID, group) in grouped {
            if meetings.contains(where: { $0.id == meetingID }) { continue }

            var segments: [Meeting.AudioSegment] = []
            var offset = 0.0
            for name in group.sorted() {
                let url = dir.appendingPathComponent(name)
                let duration = Self.fileDuration(url)
                guard duration > 0.1 else {
                    // 最后一段可能因为 App 被杀而没写完，直接清掉
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                segments.append(Meeting.AudioSegment(id: UUID().uuidString,
                                                     fileName: name,
                                                     startOffset: offset,
                                                     durationSeconds: duration))
                offset += duration
            }
            guard !segments.isEmpty else { continue }

            let firstURL = dir.appendingPathComponent(group.sorted()[0])
            let meeting = Meeting(
                id: meetingID,
                title: "（意外中断，已恢复）",
                startedAt: Self.fileCreationDate(firstURL) ?? Date(),
                endedAt: nil,
                durationSeconds: offset,
                segments: segments,
                markers: [],
                transcript: "",
                summaryJSON: "",
                status: "recovered"
            )
            recovered.append(meeting)
            AppLog.warn("Store", "恢复被中断的录音：\(meetingID)，\(segments.count) 段，\(Int(offset)) 秒")
        }

        if !recovered.isEmpty {
            meetings.insert(contentsOf: recovered, at: 0)
            save()
        }
        return recovered
    }
}
