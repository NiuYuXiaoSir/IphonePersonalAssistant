import Foundation
import UIKit

/// 对话里的一条消息。
///
/// 速记对话整个就是一段和助手的对话：用户说的话、助手整理出的条目卡片、
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
    /// 实际写到过哪些地方（todo / event / note / notification），决定结果下面显示哪个「打开…」按钮
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

/// 一段对话。一个会话一个话题，免得所有东西都堆在一条时间线上找不到。
struct ChatThread: Codable, Identifiable {
    var id: String = UUID().uuidString
    var title: String = "新对话"
    /// 属于哪个分组；空表示没分组
    var folderID: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var entries: [ChatEntry] = []

    /// 列表里显示的最后一句
    var preview: String {
        for entry in entries.reversed() where !entry.text.isEmpty {
            return entry.text
        }
        return entries.contains { !$0.images.isEmpty } ? "（一张图片）" : ""
    }
}

/// 对话分组，就是一个文件夹。
struct ChatFolder: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String = ""
    var createdAt: Date = Date()
}

/// 对话的本地存储：会话、分组、消息都在 chat.json 里，图片按文件存在 chatImages/。
///
/// 和会议记录一样用 JSON 文件而不是数据库：数据量小、能直接看懂、
/// 能直接从「文件」App 导出来看。
final class ChatStore: ObservableObject {

    @Published private(set) var folders: [ChatFolder] = []
    @Published private(set) var threads: [ChatThread] = []

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("chat.json")
    }

    /// 缩略图内存缓存：列表重绘很频繁，每次都读盘会卡
    private var thumbCache: [String: UIImage] = [:]
    private var pendingSave: DispatchWorkItem?

    private struct Snapshot: Codable {
        var folders: [ChatFolder]
        var threads: [ChatThread]
    }

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

        guard let data = try? Data(contentsOf: fileURL) else {
            threads = []
            folders = []
            return
        }

        if let snapshot = try? decoder.decode(Snapshot.self, from: data) {
            folders = snapshot.folders.sorted { $0.createdAt < $1.createdAt }
            // 空的会话不进列表，顺手在这里清掉——启动时没有正在看的会话，删了最安全
            threads = snapshot.threads
                .filter { !$0.entries.isEmpty }
                .sorted { $0.updatedAt > $1.updatedAt }
            AppLog.info("Chat", "载入 \(threads.count) 个对话、\(folders.count) 个分组")
            return
        }

        // 旧版本存的是一个扁平的 [ChatEntry]，迁移成一个会话，别让历史消息丢了
        if let legacy = try? decoder.decode([ChatEntry].self, from: data), !legacy.isEmpty {
            var thread = ChatThread()
            thread.title = "升级前的对话"
            thread.createdAt = legacy.first?.createdAt ?? Date()
            thread.updatedAt = legacy.last?.createdAt ?? Date()
            thread.entries = legacy
            threads = [thread]
            folders = []
            writeNow()
            AppLog.info("Chat", "把旧格式的 \(legacy.count) 条消息迁移成 1 个会话")
            return
        }

        AppLog.warn("Chat", "chat.json 读不出来，按空对话处理")
        threads = []
        folders = []
    }

    /// 打字是连续动作，每次编辑都整份写盘太浪费，所以合并一下。
    /// 真正要紧的节点（发出消息、建会话、删东西）走 writeNow，立刻落盘。
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
            let snapshot = Snapshot(folders: folders, threads: threads)
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.error("Chat", "保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 会话

    func thread(id: String) -> ChatThread? {
        threads.first { $0.id == id }
    }

    @discardableResult
    func createThread(folderID: String? = nil) -> ChatThread {
        var thread = ChatThread()
        thread.folderID = folderID
        threads.insert(thread, at: 0)
        writeNow()
        return thread
    }

    /// 关键节点（模型回来了、写进系统了）手动催一次落盘，
    /// 不用等那 0.8 秒的合并窗口
    func saveNow() {
        writeNow()
    }

    func updateThread(id: String, _ mutate: (inout ChatThread) -> Void) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        var copy = threads[index]
        mutate(&copy)
        threads[index] = copy
        scheduleSave()
    }

    /// 追加一条消息。第一句话会顺手变成会话标题——列表里全是「新对话」没法用。
    func append(_ entry: ChatEntry, to threadID: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].entries.append(entry)
        threads[index].updatedAt = entry.createdAt
        if entry.role == .user && threads[index].title == "新对话" {
            threads[index].title = Self.title(from: entry)
        }
        writeNow()
    }

    func deleteThread(id: String) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        for entry in threads[index].entries {
            for name in entry.images {
                try? FileManager.default.removeItem(at: Self.imageURL(named: name))
            }
        }
        threads.remove(at: index)
        writeNow()
    }

    func clearThread(id: String) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        for entry in threads[index].entries {
            for name in entry.images {
                try? FileManager.default.removeItem(at: Self.imageURL(named: name))
            }
        }
        threads[index].entries = []
        writeNow()
    }

    func moveThread(id: String, to folderID: String?) {
        updateThread(id: id) { $0.folderID = folderID }
        writeNow()
    }

    static func title(from entry: ChatEntry) -> String {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return entry.images.isEmpty ? "新对话" : "照片"
        }
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
        return cleaned.count <= 16 ? cleaned : String(cleaned.prefix(16)) + "…"
    }

    // MARK: - 分组

    func folder(id: String?) -> ChatFolder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    func folderName(_ id: String?) -> String {
        folder(id: id)?.name ?? "未分组"
    }

    @discardableResult
    func createFolder(name: String) -> ChatFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var folder = ChatFolder()
        folder.name = trimmed.isEmpty ? "新分组" : trimmed
        folders.append(folder)
        writeNow()
        return folder
    }

    func renameFolder(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = trimmed
        writeNow()
    }

    /// 删分组不删对话：里面的会话回到未分组
    func deleteFolder(id: String) {
        folders.removeAll { $0.id == id }
        for index in threads.indices where threads[index].folderID == id {
            threads[index].folderID = nil
        }
        writeNow()
    }

    func threadCount(inFolder id: String) -> Int {
        threads.filter { $0.folderID == id }.count
    }

    /// 按最近更新分组：今天 / 昨天 / 本月 / 更早
    func threads(inFolder id: String?) -> [ChatThread] {
        threads.filter { $0.folderID == id }
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
    func historyText(threadID: String, limit: Int = 8) -> String {
        guard let thread = thread(id: threadID) else { return "" }
        let recent = thread.entries.suffix(limit).filter { $0.state != .thinking }
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
