import Foundation
import UIKit

/// 一条消息引用的另一条消息（微信那种「引用」）。
///
/// 存的是**快照**而不是只存 id：被引用的那条删掉之后，引用块还得看得见，
/// 不然屏幕上会出现一个点不开、也读不懂的空框。
/// id 也留着，点引用块能跳回原消息。
struct ChatQuote: Codable, Equatable {
    var entryID: String = ""
    /// 「你」或「助理」
    var author: String = ""
    var text: String = ""
    /// 引用的是一条只有图片/视频的消息
    var isImage: Bool = false

    /// 引用块里显示的那一行
    var displayText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return isImage ? "[图片]" : "（空消息）"
    }

    private enum CodingKeys: String, CodingKey {
        case entryID, author, text, isImage
    }

    init(entryID: String = "", author: String = "", text: String = "", isImage: Bool = false) {
        self.entryID = entryID
        self.author = author
        self.text = text
        self.isImage = isImage
    }

    /// 和 ChatEntry 一样手写解码：旧数据里没有这个字段，不能让它把整条消息读崩
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entryID = (try? c.decode(String.self, forKey: .entryID)) ?? ""
        author = (try? c.decode(String.self, forKey: .author)) ?? ""
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        isImage = (try? c.decode(Bool.self, forKey: .isImage)) ?? false
    }
}

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
    /// 这条消息引用（回复）了哪一条
    var quote: ChatQuote?
    /// 助手整理出来的条目卡片；写进系统之后置空
    var items: [ParsedItem]?
    /// 写回系统后的结果摘要
    var result: String?
    /// 这一轮写进记忆库的内容，回复下面显示一行「已记下」
    var remembered: [String] = []
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
        case id, role, text, images, quote, items, result, remembered, writtenKinds, state, busy, createdAt
    }

    /// 手写解码，理由和 ParsedItem 一样：这份 JSON 要长期留在手机上，
    /// 以后加字段时旧记录必须还能读出来，而不是整份对话直接消失。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        role = (try? c.decode(Role.self, forKey: .role)) ?? .assistant
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        images = (try? c.decode([String].self, forKey: .images)) ?? []
        quote = try? c.decodeIfPresent(ChatQuote.self, forKey: .quote)
        items = try? c.decodeIfPresent([ParsedItem].self, forKey: .items)
        result = try? c.decodeIfPresent(String.self, forKey: .result)
        remembered = (try? c.decode([String].self, forKey: .remembered)) ?? []
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

/// 对话的本地存储：会话、分组、消息都在 SQLite 里（Documents/assistant.sqlite3），
/// 图片还是按文件存在 chatImages/。
///
/// 上一版把整份对话写在 chat.json 里。换成数据库是为了让对话和记忆库能互相查
/// （比如「上周关于桥杆都说了什么」要跨会话翻），也免得每次改动都整份重写。
/// 老的 chat.json 在第一次启动时会被导入进来，导入完改名留个备份。
final class ChatStore: ObservableObject {

    @Published private(set) var folders: [ChatFolder] = []
    @Published private(set) var threads: [ChatThread] = []

    private let db = AppDatabase.shared

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private var legacyFileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("chat.json")
    }

    /// 缩略图内存缓存：列表重绘很频繁，每次都读盘会卡
    private var thumbCache: [String: UIImage] = [:]
    private var pendingSave: DispatchWorkItem?

    /// 只用来读老版本留下的 chat.json
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
        let threadRows = db.query("""
            SELECT id, title, folder_id, created_at, updated_at
            FROM chat_threads ORDER BY updated_at DESC
            """)

        guard !threadRows.isEmpty else {
            importLegacyJSON()
            return
        }

        folders = db.query("SELECT id, name, created_at FROM chat_folders ORDER BY created_at ASC").compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            var folder = ChatFolder()
            folder.id = id
            folder.name = (row["name"] as? String) ?? ""
            folder.createdAt = Date(timeIntervalSince1970: (row["created_at"] as? Double) ?? 0)
            return folder
        }

        var loaded: [ChatThread] = []
        for row in threadRows {
            guard let id = row["id"] as? String else { continue }
            var thread = ChatThread()
            thread.id = id
            thread.title = (row["title"] as? String) ?? "新对话"
            thread.folderID = row["folder_id"] as? String
            thread.createdAt = Date(timeIntervalSince1970: (row["created_at"] as? Double) ?? 0)
            thread.updatedAt = Date(timeIntervalSince1970: (row["updated_at"] as? Double) ?? 0)
            thread.entries = entries(threadID: id)
            loaded.append(thread)
        }

        // 空的会话不进列表，顺手在这里清掉——启动时没有正在看的会话，删了最安全
        threads = loaded.filter { !$0.entries.isEmpty }
        AppLog.info("Chat", "从数据库载入 \(threads.count) 个对话、\(folders.count) 个分组")
    }

    private func entries(threadID: String) -> [ChatEntry] {
        db.query("SELECT payload FROM chat_entries WHERE thread_id = ? ORDER BY rowid", [threadID])
            .compactMap { row in
                guard let payload = row["payload"] as? String,
                      let data = payload.data(using: .utf8) else { return nil }
                return try? Self.decoder.decode(ChatEntry.self, from: data)
            }
    }

    /// 数据库里还什么都没有的时候，把老版本写在 chat.json 里的对话导进来。
    /// 导入后把文件改名成 chat.json.imported 留着——万一导错了，数据还在。
    private func importLegacyJSON() {
        guard let data = try? Data(contentsOf: legacyFileURL) else {
            threads = []
            folders = []
            return
        }

        var imported: Snapshot?
        if let snapshot = try? Self.decoder.decode(Snapshot.self, from: data) {
            imported = snapshot
        } else if let legacy = try? Self.decoder.decode([ChatEntry].self, from: data), !legacy.isEmpty {
            // 更早的版本存的是一个扁平的 [ChatEntry]
            var thread = ChatThread()
            thread.title = "升级前的对话"
            thread.createdAt = legacy.first?.createdAt ?? Date()
            thread.updatedAt = legacy.last?.createdAt ?? Date()
            thread.entries = legacy
            imported = Snapshot(folders: [], threads: [thread])
        }

        guard let snapshot = imported else {
            AppLog.warn("Chat", "chat.json 读不出来，按空对话处理")
            threads = []
            folders = []
            return
        }

        folders = snapshot.folders.sorted { $0.createdAt < $1.createdAt }
        threads = snapshot.threads
            .filter { !$0.entries.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
        writeNow()

        let backup = legacyFileURL.appendingPathExtension("imported")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: legacyFileURL, to: backup)
        AppLog.info("Chat", "把老的 chat.json 导入数据库：\(threads.count) 个对话、\(folders.count) 个分组")
    }

    /// 打字是连续动作，每次编辑都整份写盘太浪费，所以合并一下。
    /// 真正要紧的节点（发出消息、建会话、删东西）走 writeNow，立刻落盘。
    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeNow() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    /// 整份快照写回数据库，一个事务里完成，中途失败不会留下半份数据。
    /// 会话和分组只有几十条、消息几百条，整份重写的开销远小于维护增量同步的复杂度。
    private func writeNow() {
        pendingSave?.cancel()
        pendingSave = nil
        db.transaction {
            db.exec("DELETE FROM chat_entries; DELETE FROM chat_threads; DELETE FROM chat_folders;")
            for folder in folders {
                db.run("INSERT INTO chat_folders(id, name, created_at) VALUES(?,?,?)",
                       [folder.id, folder.name, folder.createdAt.timeIntervalSince1970])
            }
            for thread in threads {
                db.run("""
                    INSERT INTO chat_threads(id, title, folder_id, created_at, updated_at)
                    VALUES(?,?,?,?,?)
                    """, [thread.id, thread.title, thread.folderID,
                          thread.createdAt.timeIntervalSince1970,
                          thread.updatedAt.timeIntervalSince1970])
                for entry in thread.entries {
                    guard let data = try? Self.encoder.encode(entry),
                          let payload = String(data: data, encoding: .utf8) else { continue }
                    db.run("INSERT INTO chat_entries(id, thread_id, payload, created_at) VALUES(?,?,?,?)",
                           [entry.id, thread.id, payload, entry.createdAt.timeIntervalSince1970])
                }
            }
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
        let thread = threads[index]
        threads.remove(at: index)
        purgeThread(thread)
        writeNow()
    }

    // MARK: - 删除与撤销
    //
    // 和会议一样的三段式：先撤下（图片留着），撤销窗口过了才真删。
    // 有撤销就不该再弹确认框——HIG 的 Alerts 页：「Avoid displaying alerts for common, undoable actions」。

    /// 刚撤下、还在撤销窗口里的会话
    @Published private(set) var recentlyDetachedThread: ChatThread?

    func detachThread(id: String) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        // 上一笔还没撤销完就删下一笔：先把上一笔落定
        if let previous = recentlyDetachedThread, previous.id != id {
            purgeThread(previous)
        }
        let thread = threads.remove(at: index)
        recentlyDetachedThread = thread
        writeNow()
    }

    @discardableResult
    func undoDetachThread() -> ChatThread? {
        guard let thread = recentlyDetachedThread else { return nil }
        recentlyDetachedThread = nil
        if !threads.contains(where: { $0.id == thread.id }) {
            threads.append(thread)
            threads.sort { $0.updatedAt > $1.updatedAt }
            writeNow()
        }
        AppLog.info("Chat", "撤销删除会话「\(thread.title)」")
        return thread
    }

    /// 撤销窗口过了：落定，真删图片
    func commitDetachThread() {
        guard let thread = recentlyDetachedThread else { return }
        recentlyDetachedThread = nil
        purgeThread(thread)
    }

    private func purgeThread(_ thread: ChatThread) {
        for entry in thread.entries {
            for name in entry.images {
                try? FileManager.default.removeItem(at: Self.imageURL(named: name))
            }
        }
        AppLog.info("Chat", "删除会话「\(thread.title)」及其 \(thread.entries.count) 条消息")
    }

    /// 重发 / 重试时要把原图读回来
    func imageData(named name: String) -> Data? {
        try? Data(contentsOf: Self.imageURL(named: name))
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

    /// 把一条消息拍成引用块
    static func quote(from entry: ChatEntry) -> ChatQuote {
        ChatQuote(entryID: entry.id,
                  author: entry.role == .user ? "你" : "助理",
                  text: entry.text,
                  isImage: !entry.images.isEmpty)
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
    ///
    /// 留 20 条：对话现在是有上下文的（接着上一条改、接着上次聊的事问），
    /// 只给 8 条经常正好把「上次那件事」挤出窗口。
    func historyText(threadID: String, limit: Int = 20) -> String {
        guard let thread = thread(id: threadID) else { return "" }
        let recent = thread.entries.suffix(limit).filter { $0.state != .thinking }
        var lines: [String] = []
        for entry in recent {
            var body = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty && !entry.images.isEmpty {
                body = "（发了一张图片，内容已经抽取过）"
            }
            // 引用要带进上下文：用户是在对着那句回话，「第二条改成周五」指的就是它
            if let quote = entry.quote {
                body = "（引用\(quote.author)说的「\(String(quote.displayText.prefix(120)))」）" + body
            }
            if let items = entry.items, !items.isEmpty {
                let list = items.map { item -> String in
                    var s = "\(item.kind.label)「\(item.title)」"
                    if !item.dueDate.isEmpty { s += "，时间 \(item.dueDate)" }
                    return s
                }.joined(separator: "；")
                body += "（已列出条目：\(list)）"
            }
            if let result = entry.result, !result.isEmpty {
                body += "（写入结果：\(String(result.prefix(120)))）"
            }
            guard !body.isEmpty else { continue }
            lines.append("\(entry.role == .user ? "用户" : "助手")：\(String(body.prefix(400)))")
        }
        return lines.joined(separator: "\n")
    }
}
