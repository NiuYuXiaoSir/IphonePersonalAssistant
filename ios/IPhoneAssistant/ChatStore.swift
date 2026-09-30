import Foundation
import UIKit

/// 速记对话里的一条消息。
///
/// 速记页整个就是一段和助手的对话：用户说的话、助手整理出的条目卡片、
/// 写回系统后的结果，都落在这条时间线上。所以消息本体要能存图、存卡片、存结果。
struct ChatEntry: Codable, Identifiable {

    enum Role: String, Codable {
        case user
        case assistant
    }

    /// thinking = 已经占了位置，结果还没回来
    enum State: String, Codable {
        case ok
        case thinking
        case failed
    }

    var id: String = UUID().uuidString
    var role: Role = .user
    var text: String = ""
    /// 附图文件名，图片实体存在 Documents/chatImages/ 下
    var images: [String] = []
    /// 助手整理出来的条目卡片；写进系统之后置空
    var items: [ParsedItem]?
    /// 写回系统后的结果摘要
    var result: String?
    /// 实际写到过哪些地方（todo / event / note），决定结果下面显示哪个「打开…」按钮
    var writtenKinds: [String] = []
    var state: State = .ok
    /// 正在请求模型或正在写入系统
    var busy: Bool = false
    var createdAt: Date = Date()

    init(role: Role, text: String = "", state: State = .ok) {
        self.role = role
        self.text = text
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, images, items, result, writtenKinds, state, busy, createdAt
    }

    /// 手写解码，理由和 ParsedItem 一样：这份 JSON 要长期留在手机上，
    /// 以后加字段时旧记录必须还能读出来，而不是整份对话直接消失。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        role = (try? c.decode(Role.self, forKey: .role)) ?? .assistant
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        images = (try? c.decode([String].self, forKey: .images)) ?? []
        items = try? c.decodeIfPresent([ParsedItem].self, forKey: .items)
        result = try? c.decodeIfPresent(String.self, forKey: .result)
        writtenKinds = (try? c.decode([String].self, forKey: .writtenKinds)) ?? []
        state = (try? c.decode(State.self, forKey: .state)) ?? .ok
        busy = (try? c.decode(Bool.self, forKey: .busy)) ?? false
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
    }
}

/// 速记对话的本地存储。文字和时间线存 chat.json，图片按文件存在 chatImages/。
///
/// 和会议记录一样用 JSON 文件而不是数据库：数据量小、能直接看懂、
/// 能直接从「文件」App 导出来看。
final class ChatStore: ObservableObject {

    @Published private(set) var entries: [ChatEntry] = []

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("chat.json")
    }

    /// 缩略图内存缓存：列表重绘很频繁，每次都读盘会卡
    private var thumbCache: [String: UIImage] = [:]
    private var pendingSave: DispatchWorkItem?

    init() {
        load()
    }

    // MARK: - 目录

    static func imagesDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("chatImages", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func imageURL(named name: String) -> URL {
        imagesDirectory().appendingPathComponent(name)
    }

    // MARK: - 读写

    func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([ChatEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
        AppLog.info("Chat", "载入 \(entries.count) 条速记对话")
    }

    /// 打字是连续动作，每次编辑都整份写盘太浪费，所以合并一下。
    /// 真正要紧的节点（发出消息、清空）走 writeNow，立刻落盘。
    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeNow() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    private func writeNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.error("Chat", "保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 增删改

    func append(_ entry: ChatEntry) {
        entries.append(entry)
        writeNow()
    }

    func update(id: String, _ mutate: (inout ChatEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var copy = entries[index]
        mutate(&copy)
        entries[index] = copy
        scheduleSave()
    }

    func entry(id: String) -> ChatEntry? {
        entries.first { $0.id == id }
    }

    func remove(id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        for name in entries[index].images {
            try? FileManager.default.removeItem(at: Self.imageURL(named: name))
        }
        entries.remove(at: index)
        writeNow()
    }

    func clear() {
        for entry in entries {
            for name in entry.images {
                try? FileManager.default.removeItem(at: Self.imageURL(named: name))
            }
        }
        entries = []
        thumbCache.removeAll()
        writeNow()
        AppLog.info("Chat", "已清空速记对话")
    }

    // MARK: - 图片

    @discardableResult
    func saveImage(_ data: Data) -> String? {
        let name = UUID().uuidString + ".jpg"
        do {
            try data.write(to: Self.imageURL(named: name), options: .atomic)
            return name
        } catch {
            AppLog.error("Chat", "保存附图失败：\(error.localizedDescription)")
            return nil
        }
    }

    func thumbnail(named name: String) -> UIImage? {
        if let hit = thumbCache[name] { return hit }
        guard let image = UIImage(contentsOfFile: Self.imageURL(named: name).path) else { return nil }
        thumbCache[name] = image
        return image
    }

    // MARK: - 给模型看的上下文

    /// 最近的对话，纯文本。不重发历史图片——又贵又没必要，
    /// 之前抽出来的条目已经写在文本里了。
    func historyText(limit: Int = 8) -> String {
        let recent = entries.suffix(limit).filter { $0.state != .thinking }
        var lines: [String] = []
        for entry in recent {
            var body = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty && !entry.images.isEmpty {
                body = "（发了一张图片，内容已经抽取过）"
            }
            if let items = entry.items, !items.isEmpty {
                let list = items.map { item -> String in
                    var s = "\(item.kind.label)「\(item.title)」"
                    if !item.dueDate.isEmpty { s += "，时间 \(item.dueDate)" }
                    return s
                }.joined(separator: "；")
                body += "（已列出条目：\(list)）"
            }
            guard !body.isEmpty else { continue }
            lines.append("\(entry.role == .user ? "用户" : "助手")：\(String(body.prefix(300)))")
        }
        return lines.joined(separator: "\n")
    }
}
