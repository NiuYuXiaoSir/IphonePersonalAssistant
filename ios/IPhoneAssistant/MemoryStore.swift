import Foundation

/// 记忆的种类。
///
/// 前三种是「流水」——挂在某一天上，用来回答「我今天做了什么」「明天要做什么」；
/// 后四种是「长期事实」——不按天，用来让助理知道你是谁、在做什么、有什么习惯。
enum MemoryKind: String, CaseIterable {
    case done
    case plan
    case note
    case fact
    case preference
    case person
    case project

    var label: String {
        switch self {
        case .done:       return "做了"
        case .plan:       return "计划"
        case .note:       return "记下"
        case .fact:       return "事实"
        case .preference: return "偏好"
        case .person:     return "人物"
        case .project:    return "项目"
        }
    }

    var symbol: String {
        switch self {
        case .done:       return "checkmark.circle"
        case .plan:       return "calendar.badge.clock"
        case .note:       return "note.text"
        case .fact:       return "info.circle"
        case .preference: return "heart"
        case .person:     return "person"
        case .project:    return "hammer"
        }
    }

    /// 流水类：挂在天上；其余是长期记忆，不分天
    var isTimeline: Bool {
        self == .done || self == .plan || self == .note
    }
}

/// 模型在一轮对话里要求记住的一条东西。字段名对齐 prompt 里的 JSON。
struct MemoryDraft {
    var kind: String = "fact"
    var content: String = ""
    /// yyyy-MM-dd；空表示按今天算
    var day: String = ""
}

struct MemoryFact: Identifiable, Equatable {
    var id: String
    var kind: MemoryKind
    var content: String
    var keywords: String
    var createdAt: Date
    var updatedAt: Date
}

struct MemoryLog: Identifiable, Equatable {
    var id: String
    var day: String
    var at: Date
    var kind: MemoryKind
    var content: String
}

/// 记忆页里按天分好的一组流水
struct MemoryDayGroup: Identifiable {
    var id: String { day }
    var day: String
    var title: String
    var logs: [MemoryLog]
}

/// 记忆库：长期记忆 + 每日流水，都落在 SQLite 里（Documents/assistant.sqlite3）。
///
/// 它解决的是上一版对话最大的短板：每句话都是孤立的。现在每轮对话都会
/// 把「和这句话相关的长期记忆 + 最近几天做了什么、打算做什么」塞进 prompt，
/// 模型每次也把新的事实和流水写回来，于是「我这一天都干了啥」「明天要做什么」
/// 这类问题才有东西可答。
final class MemoryStore: ObservableObject {

    static let shared = MemoryStore()

    @Published private(set) var facts: [MemoryFact] = []
    @Published private(set) var logs: [MemoryLog] = []

    private let db = AppDatabase.shared

    private init() {
        reload()
    }

    // MARK: - 读

    func reload() {
        facts = db.query("""
            SELECT id, kind, content, keywords, created_at, updated_at
            FROM memories ORDER BY updated_at DESC
            """).compactMap { row in
            guard let id = row["id"] as? String, let content = row["content"] as? String else { return nil }
            return MemoryFact(id: id,
                              kind: MemoryKind(rawValue: (row["kind"] as? String) ?? "") ?? .fact,
                              content: content,
                              keywords: (row["keywords"] as? String) ?? "",
                              createdAt: Date(timeIntervalSince1970: (row["created_at"] as? Double) ?? 0),
                              updatedAt: Date(timeIntervalSince1970: (row["updated_at"] as? Double) ?? 0))
        }

        logs = db.query("""
            SELECT id, day, at, kind, content
            FROM timeline ORDER BY day DESC, at ASC
            """).compactMap { row in
            guard let id = row["id"] as? String, let content = row["content"] as? String else { return nil }
            return MemoryLog(id: id,
                             day: (row["day"] as? String) ?? "",
                             at: Date(timeIntervalSince1970: (row["at"] as? Double) ?? 0),
                             kind: MemoryKind(rawValue: (row["kind"] as? String) ?? "") ?? .note,
                             content: content)
        }
    }

    /// 记忆页按天倒序分组。今天的在最上面。
    var dayGroups: [MemoryDayGroup] {
        let grouped = Dictionary(grouping: logs, by: { $0.day })
        return grouped.keys.sorted(by: >).map { day in
            MemoryDayGroup(day: day,
                           title: Self.dayLabel(day),
                           logs: (grouped[day] ?? []).sorted { $0.at < $1.at })
        }
    }

    // MARK: - 写

    /// 把模型要求记住的东西落库。
    /// 流水按「天 + 种类 + 内容」去重，长期事实按内容去重——同一件事说两遍不会记两条。
    @discardableResult
    func remember(_ drafts: [MemoryDraft], source: String = "") -> (facts: Int, logs: Int) {
        guard !drafts.isEmpty else { return (0, 0) }
        let now = Date()
        let stamp = now.timeIntervalSince1970
        var factCount = 0
        var logCount = 0

        db.transaction {
            for draft in drafts {
                let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard content.count >= 2 else { continue }
                let kind = MemoryKind(rawValue: draft.kind.lowercased()) ?? .fact
                if kind.isTimeline {
                    let day = Self.day(fromText: draft.day) ?? Self.dayString(now)
                    if db.run("""
                        INSERT OR IGNORE INTO timeline(id, day, at, kind, content, thread_id, created_at)
                        VALUES(?,?,?,?,?,?,?)
                        """, [UUID().uuidString, day, stamp, kind.rawValue, content, source, stamp]) {
                        logCount += 1
                    }
                } else {
                    if db.run("""
                        INSERT OR IGNORE INTO memories(id, kind, content, keywords, importance, source, created_at, updated_at)
                        VALUES(?,?,?,?,?,?,?,?)
                        """, [UUID().uuidString, kind.rawValue, content, Self.keywords(content), 1, source, stamp, stamp]) {
                        factCount += 1
                    }
                }
            }
        }

        if factCount > 0 || logCount > 0 {
            AppLog.info("Memory", "记下长期 \(factCount) 条、流水 \(logCount) 条（来源 \(source.isEmpty ? "手动" : source)）")
            reload()
        }
        return (factCount, logCount)
    }

    /// 手动速记（不走模型）也记一笔流水，免得「这一天做了什么」只有对话里说过的那部分。
    func logManual(kind: MemoryKind, content: String, day: String? = nil, source: String = "manual") {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        remember([MemoryDraft(kind: kind.rawValue, content: trimmed, day: day ?? "")], source: source)
    }

    func delete(fact: MemoryFact) {
        db.run("DELETE FROM memories WHERE id = ?", [fact.id])
        reload()
    }

    func delete(log: MemoryLog) {
        db.run("DELETE FROM timeline WHERE id = ?", [log.id])
        reload()
    }

    enum Scope {
        case facts
        case timeline
        case all
    }

    func clear(_ scope: Scope) {
        switch scope {
        case .facts:
            db.exec("DELETE FROM memories")
        case .timeline:
            db.exec("DELETE FROM timeline")
        case .all:
            db.exec("DELETE FROM memories; DELETE FROM timeline;")
        }
        reload()
        AppLog.info("Memory", "清空记忆：\(scope)")
    }

    // MARK: - 给模型看的上下文

    /// 拼出这次请求要带的记忆：和这句话相关的长期记忆 + 最近几天的流水。
    /// 返回空串表示还没有任何记忆，prompt 里就不放这两段。
    func digest(for query: String, now: Date = Date()) -> String {
        var sections: [String] = []

        let picked = relevantFacts(for: query, limit: 24)
        if !picked.isEmpty {
            let lines = picked.map { "- [\($0.kind.label)] \($0.content)" }
            sections.append("【长期记忆】（以前记下的，用得上才参考，别硬套）\n" + lines.joined(separator: "\n"))
        }

        let timeline = timelineText(fromDayOffset: -7, toDayOffset: 3, now: now)
        if !timeline.isEmpty {
            sections.append("【最近几天】（做了什么、打算做什么）\n" + timeline)
        }

        return sections.joined(separator: "\n\n")
    }

    /// 挑和这句话相关的长期记忆。中文没有词边界，用二元组重叠算相关性，
    /// 再补一点「越新越靠前」的权重；相关的太少时拿最近的几条补齐，
    /// 让模型至少知道「你是谁、在做什么」。
    func relevantFacts(for query: String, limit: Int = 24) -> [MemoryFact] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(facts.prefix(limit)) }

        let now = Date()
        var scored: [(fact: MemoryFact, score: Double)] = facts.map { fact in
            var score = Double(Self.matchScore(query: trimmed, text: fact.content + " " + fact.keywords))
            let age = now.timeIntervalSince(fact.updatedAt)
            if age < 3 * 86400 {
                score += 2
            } else if age < 14 * 86400 {
                score += 1
            }
            return (fact, score)
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.fact.updatedAt > rhs.fact.updatedAt
        }

        var picked = scored.filter { $0.score > 0 }.prefix(limit).map { $0.fact }
        if picked.count < 8 {
            for fact in facts where picked.count < 8 {
                if !picked.contains(where: { $0.id == fact.id }) { picked.append(fact) }
            }
        }
        return picked
    }

    /// 把几天的流水拼成文本，按天分组，标注今天/昨天/明天。
    func timelineText(fromDayOffset: Int, toDayOffset: Int, now: Date = Date()) -> String {
        let calendar = Calendar.current
        guard let start = calendar.date(byAdding: .day, value: fromDayOffset, to: now),
              let end = calendar.date(byAdding: .day, value: toDayOffset, to: now) else { return "" }
        let from = Self.dayString(start)
        let to = Self.dayString(end)

        let rows = logs.filter { $0.day >= from && $0.day <= to }
        guard !rows.isEmpty else { return "" }

        let grouped = Dictionary(grouping: rows, by: { $0.day })
        var out: [String] = []
        for day in grouped.keys.sorted() {
            let items = (grouped[day] ?? []).sorted { $0.at < $1.at }
            let lines = items.prefix(12).map { "· \($0.kind.label)：\($0.content)" }
            out.append(Self.dayLabel(day, now: now) + "\n" + lines.joined(separator: "\n"))
        }
        return out.joined(separator: "\n")
    }

    // MARK: - 日期与文本工具

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func date(fromDay day: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }

    /// 模型给的日期字符串（可能写成 2026/10/1、2026年10月1日）尽量认出来，认不出返回 nil。
    static func day(fromText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = SystemWriter.date(from: trimmed, defaultHour: 9) {
            return dayString(date)
        }
        return nil
    }

    static func dayLabel(_ day: String, now: Date = Date()) -> String {
        guard let date = date(fromDay: day) else { return day }
        let calendar = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        var label = f.string(from: date)

        if calendar.isDateInToday(date) {
            label += "（今天）"
        } else if calendar.isDateInYesterday(date) {
            label += "（昨天）"
        } else if calendar.isDateInTomorrow(date) {
            label += "（明天）"
        } else {
            let weekday = DateFormatter()
            weekday.locale = Locale(identifier: "zh_CN")
            weekday.dateFormat = "EEEE"
            label += "（\(weekday.string(from: date))）"
        }
        return label
    }

    /// 中文的「相关性」用二元组重叠来近似
    static func matchScore(query: String, text: String) -> Int {
        let q = query.lowercased()
        let t = text.lowercased()
        guard !q.isEmpty, !t.isEmpty else { return 0 }
        let chars = Array(q)
        guard chars.count >= 2 else { return t.contains(q) ? 2 : 0 }
        var hits = 0
        var index = 0
        while index < chars.count - 1 {
            if t.contains(String(chars[index...index + 1])) { hits += 1 }
            index += 1
        }
        return hits
    }

    private static func keywords(_ content: String) -> String {
        let chars = Array(content)
        guard chars.count >= 2 else { return content }
        var grams: [String] = []
        var index = 0
        while index < chars.count - 1 {
            grams.append(String(chars[index...index + 1]))
            index += 1
        }
        return grams.joined(separator: " ")
    }
}
