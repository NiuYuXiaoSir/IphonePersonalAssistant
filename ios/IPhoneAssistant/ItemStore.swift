import Foundation
import UserNotifications

/// App 自己安排的一条事。
///
/// 待办、日程、备忘、提醒这四类现在**都存在本机**（`assistant.sqlite3` 的 `items` 表），
/// 区别只剩两件对用户有意义的事：到点提不提醒、要不要事后打勾。
/// 以前待办写系统提醒事项、日程写系统日历、提醒走通知、备忘存 JSON——四个地方四套规矩，
/// 而且改一条要过系统接口。现在都是 App 自己的数据，改时间、改备注、调顺序都是改自己的一行。
struct AssistantItem: Identifiable, Equatable {

    var id: String = UUID().uuidString
    var kind: ParsedItem.Kind = .todo
    var title: String = ""
    var notes: String = ""
    /// 到点（日程是开始）时间。备忘和不设时间的待办是 nil。
    var dueAt: Date?
    /// 日程占用的时长；其余类型是 0
    var durationMinutes: Int = 0
    /// high / normal / low
    var priority: String = "normal"
    /// 提前几分钟提醒：0 = 到点提醒
    var remindBeforeMinutes: Int = 0
    var isDone: Bool = false
    /// 手动排序用的位置（越大越靠后）。按时间排时不用它。
    var sortIndex: Double = 0
    /// 从哪来的：对话 id、会议 id、quickadd
    var source: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// 真正弹通知的时刻
    var fireDate: Date? {
        guard let dueAt else { return nil }
        return dueAt.addingTimeInterval(-Double(max(0, remindBeforeMinutes)) * 60)
    }

    var hasTime: Bool { dueAt != nil }

    /// 会弹通知吗（备忘不弹）
    var notifies: Bool { kind != .note && fireDate != nil }

    var isOverdue: Bool {
        guard let fireDate else { return false }
        return !isDone && fireDate < Date()
    }

    /// 通知里那句话。没写备注就给一句能看懂的话，而不是空白。
    var notificationBody: String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch kind {
        case .event:        return "日程开始了"
        case .todo:         return "到点了，办完记得打勾"
        default:            return "到点了"
        }
    }

    /// `yyyy-MM-dd HH:mm`，没有时间就是空串。界面上的时间输入框用它。
    var dueText: String {
        guard let dueAt else { return "" }
        return Self.textFormatter.string(from: dueAt)
    }

    static let textFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

/// 「安排」列表的排序方式
enum ItemSortMode: String, CaseIterable {
    /// 按弹出/开始时间：这是通知本来的语义
    case byTime
    /// 按手动顺序：拖出来的次序，只影响这个列表怎么显示
    case manual

    var label: String {
        switch self {
        case .byTime: return "按时间"
        case .manual: return "手动排序"
        }
    }
}

/// 本机所有安排的仓库：一张表、一套增删改查、一份通知计划。
///
/// 通知只是这张表的**影子**：真正的事实存在库里，弹出来的通知由 `rescheduleNotifications()`
/// 按最近的一批重新排。这样才有「改时间、改备注、删掉」可言——系统通知队列本身不能改，
/// 只能撤了重排；而 iOS 对每个 App 的待弹通知有条数上限，所以永远只排最近的那些。
final class ItemStore: ObservableObject {

    static let shared = ItemStore()

    @Published private(set) var items: [AssistantItem] = []

    /// 通知标识符前缀：只动自己排的，不碰别的
    static let notificationPrefix = "assistant-item-"
    /// 通知分类（带「完成 / 延后 10 分钟」两个动作）
    static let categoryIdentifier = "assistant-item-actions"
    /// 一次性最多排多少条。iOS 每个 App 只保留最近 64 条待弹通知，
    /// 留一点余量给探针那条和系统自己的东西。
    private static let maxScheduled = 56

    private let db = AppDatabase.shared
    private let sortModeKey = "items.sortMode"

    /// 手动排序只在这次会话里临时改的顺序（拖完立刻落盘）
    @Published var sortMode: ItemSortMode {
        didSet { UserDefaults.standard.set(sortMode.rawValue, forKey: sortModeKey) }
    }

    private init() {
        sortMode = ItemSortMode(rawValue: UserDefaults.standard.string(forKey: sortModeKey) ?? "") ?? .byTime
        load()
        importLegacyNotes()
    }

    // MARK: - 读

    func load() {
        items = db.query("""
            SELECT id, kind, title, notes, due_at, duration_minutes, priority,
                   remind_before, is_done, sort_index, source, created_at, updated_at
            FROM items ORDER BY created_at DESC
            """).compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            var item = AssistantItem(id: id)
            item.kind = ParsedItem.Kind(rawValue: (row["kind"] as? String) ?? "") ?? .todo
            item.title = (row["title"] as? String) ?? ""
            item.notes = (row["notes"] as? String) ?? ""
            if let stamp = row["due_at"] as? Double {
                item.dueAt = Date(timeIntervalSince1970: stamp)
            }
            item.durationMinutes = (row["duration_minutes"] as? Int) ?? 0
            item.priority = (row["priority"] as? String) ?? "normal"
            item.remindBeforeMinutes = (row["remind_before"] as? Int) ?? 0
            item.isDone = ((row["is_done"] as? Int) ?? 0) != 0
            item.sortIndex = (row["sort_index"] as? Double) ?? 0
            item.source = (row["source"] as? String) ?? ""
            item.createdAt = Date(timeIntervalSince1970: (row["created_at"] as? Double) ?? 0)
            item.updatedAt = Date(timeIntervalSince1970: (row["updated_at"] as? Double) ?? 0)
            return item
        }
        AppLog.info("Item", "载入 \(items.count) 条安排")
    }

    // MARK: - 分组视图

    var openItems: [AssistantItem] { items.filter { !$0.isDone } }

    var doneItems: [AssistantItem] { items.filter { $0.isDone } }

    /// 还没弹出来的：有时间、没打勾、时刻还没到
    var upcomingItems: [AssistantItem] {
        let now = Date()
        return openItems
            .filter { $0.notifies && ($0.fireDate ?? .distantPast) > now }
            .sorted { ($0.fireDate ?? .distantPast) < ($1.fireDate ?? .distantPast) }
    }

    /// 时间已经过了、但还没处理的
    var overdueItems: [AssistantItem] {
        openItems.filter { $0.isOverdue }
            .sorted { ($0.fireDate ?? .distantPast) < ($1.fireDate ?? .distantPast) }
    }

    /// 没有时间的（备忘、以及不设时间的待办）
    var timelessItems: [AssistantItem] {
        openItems.filter { !$0.notifies && !$0.isOverdue }
    }

    /// 按当前排序方式排好的清单：给「安排」页和「今日」用
    func sorted(_ list: [AssistantItem]) -> [AssistantItem] {
        switch sortMode {
        case .byTime:
            return list.sorted { lhs, rhs in
                let l = lhs.fireDate ?? lhs.createdAt
                let r = rhs.fireDate ?? rhs.createdAt
                if l != r { return l < r }
                return lhs.createdAt < rhs.createdAt
            }
        case .manual:
            return list.sorted { lhs, rhs in
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.createdAt > rhs.createdAt
            }
        }
    }

    func item(id: String) -> AssistantItem? { items.first { $0.id == id } }

    // MARK: - 写

    @discardableResult
    func add(_ draft: AssistantItem) -> AssistantItem {
        var item = draft
        // 新条目排到最后：手动顺序里「刚加的」不应该插到老条目中间
        item.sortIndex = (items.map(\.sortIndex).max() ?? 0) + 1
        item.createdAt = item.createdAt.timeIntervalSince1970 > 0 ? item.createdAt : Date()
        item.updatedAt = Date()
        write(item)
        items.insert(item, at: 0)
        rescheduleNotifications()
        AppLog.info("Item", "新增\(item.kind.label)「\(item.title)」时间=\(item.dueText.isEmpty ? "无" : item.dueText)")
        return item
    }

    func update(_ item: AssistantItem) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        var copy = item
        copy.updatedAt = Date()
        write(copy)
        if let index = items.firstIndex(where: { $0.id == copy.id }) { items[index] = copy }
        rescheduleNotifications()
    }

    func delete(_ item: AssistantItem) {
        db.run("DELETE FROM items WHERE id = ?", [item.id])
        items.removeAll { $0.id == item.id }
        NotificationService.cancel(id: Self.notificationPrefix + item.id)
        rescheduleNotifications()
        AppLog.info("Item", "删除\(item.kind.label)「\(item.title)」")
    }

    func toggleDone(_ item: AssistantItem) {
        var copy = item
        copy.isDone.toggle()
        update(copy)
    }

    /// 打勾 / 取消打勾之后，已完成的条目就不再占通知名额了
    func setDone(id: String, done: Bool) {
        guard var item = item(id: id) else { return }
        item.isDone = done
        update(item)
    }

    /// 把通知往后推：通知上的「延后 10 分钟」按钮走这里
    func snooze(id: String, minutes: Int) {
        guard var item = item(id: id) else { return }
        let base = item.dueAt ?? Date()
        let from = max(base, Date())
        item.dueAt = from.addingTimeInterval(TimeInterval(minutes) * 60)
        item.remindBeforeMinutes = 0
        update(item)
        AppLog.info("Item", "延后「\(item.title)」到 \(item.dueText)")
    }

    /// 手动排序：把一段行从一个位置挪到另一个位置，整段重排 sort_index。
    /// （自己写这段而不是用 SwiftUI 那个 `move(fromOffsets:toOffset:)`：这个文件不依赖 SwiftUI。）
    func move(_ list: [AssistantItem], from offsets: IndexSet, to destination: Int) {
        var ordered = list
        let moving = offsets.sorted().map { ordered[$0] }
        for index in offsets.sorted(by: >) { ordered.remove(at: index) }
        let insertAt = max(0, min(ordered.count, destination - offsets.filter { $0 < destination }.count))
        ordered.insert(contentsOf: moving, at: insertAt)
        for (index, item) in ordered.enumerated() {
            var copy = item
            copy.sortIndex = Double(index)
            write(copy)
            if let i = items.firstIndex(where: { $0.id == copy.id }) { items[i] = copy }
        }
        sortMode = .manual
    }

    private func write(_ item: AssistantItem) {
        db.run("""
            INSERT OR REPLACE INTO items(id, kind, title, notes, due_at, duration_minutes,
                                         priority, remind_before, is_done, sort_index,
                                         source, created_at, updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
               [item.id, item.kind.rawValue, item.title, item.notes,
                item.dueAt?.timeIntervalSince1970, item.durationMinutes,
                item.priority, item.remindBeforeMinutes, item.isDone ? 1 : 0,
                item.sortIndex, item.source,
                item.createdAt.timeIntervalSince1970, item.updatedAt.timeIntervalSince1970])
    }

    // MARK: - 通知

    /// 通知计划：按时间从近到远取出最多 `maxScheduled` 条。
    /// 单独拎出来是为了能在主线程算完再交给后台去排（`items` 只能在主线程读）。
    private func notificationPlan() -> [(item: AssistantItem, fire: Date)] {
        let now = Date()
        return openItems
            .compactMap { item -> (AssistantItem, Date)? in
                guard item.notifies, let fire = item.fireDate, fire > now.addingTimeInterval(1) else { return nil }
                return (item, fire)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(Self.maxScheduled)
            .map { ($0.0, $0.1) }
    }

    /// 整批重排通知。打开 App、改过任何一条、启动时都会走一遍。
    func rescheduleNotifications() {
        let plan = notificationPlan()
        let skipped = openItems.filter { $0.notifies }.count - plan.count
        Task {
            await NotificationService.removeAll(withPrefix: Self.notificationPrefix)
            guard !plan.isEmpty else { return }
            guard await NotificationService.requestAuthorization() else {
                AppLog.warn("Item", "通知权限没给，\(plan.count) 条安排只在 App 里看得到")
                return
            }
            for entry in plan {
                try? await NotificationService.schedule(identifier: Self.notificationPrefix + entry.item.id,
                                                        title: entry.item.title,
                                                        body: entry.item.notificationBody,
                                                        at: entry.fire,
                                                        category: Self.categoryIdentifier)
            }
            AppLog.info("Item", "重排通知 \(plan.count) 条" + (skipped > 0 ? "（还有 \(skipped) 条超出系统的待弹上限，等前面弹完再排）" : ""))
        }
    }

    // MARK: - 老数据

    /// 把上一版存在 notes.json 里的备忘搬进 items 表（搬完把文件改名留个底）
    private func importLegacyNotes() {
        // 库里已经有备忘就说明搬过了，别再搬一次
        guard db.query("SELECT 1 FROM items WHERE kind = 'note' LIMIT 1").isEmpty else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("notes.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return }

        struct LegacyNote: Codable {
            var id: String
            var title: String
            var body: String
            var createdAt: Date
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let notes = try? decoder.decode([LegacyNote].self, from: data), !notes.isEmpty else { return }

        db.transaction {
            for note in notes {
                let item = AssistantItem(id: note.id,
                                         kind: .note,
                                         title: note.title,
                                         notes: note.body,
                                         dueAt: nil,
                                         source: "notes.json",
                                         createdAt: note.createdAt,
                                         updatedAt: note.createdAt)
                write(item)
            }
        }
        load()
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("imported"))
        AppLog.info("Item", "把老的 notes.json 导入数据库：\(notes.count) 条备忘")
    }
}
