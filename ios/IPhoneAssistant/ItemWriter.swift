import Foundation

/// 时间字符串 → Date。
///
/// 格式放宽是有意的：模型有时给 ISO8601（带 T、带时区），有时顺手写成「2026年9月30日 21:05」，
/// 解析失败会变成「这条没有时间」，比时间差一点更难看出来。
/// 注意格式数组的顺序——越具体的越靠前，否则 `yyyy-M-d` 会把「2026-09-30 21:15」只解析出日期部分。
enum ItemTime {

    /// 只有日期没有时刻时，补一个默认小时（日程和待办都默认 9 点）
    static func date(from string: String, defaultHour: Int) -> Date? {
        let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        if t.contains("T") || t.hasSuffix("Z") {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: t) { return d }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: t) { return d }
        }

        let normalized = t
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "年", with: "-")
            .replacingOccurrences(of: "月", with: "-")
            .replacingOccurrences(of: "日", with: " ")
            .replacingOccurrences(of: "时", with: ":")
            .replacingOccurrences(of: "分", with: "")
            .replacingOccurrences(of: "T", with: " ")
            .trimmingCharacters(in: .whitespaces)

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current

        for fmt in ["yyyy-M-d H:mm:ss", "yyyy-M-d H:mm", "yyyy-M-d H", "yyyy-M-d"] {
            df.dateFormat = fmt
            guard let d = df.date(from: normalized) else { continue }
            if fmt == "yyyy-M-d" {
                return Calendar.current.date(bySettingHour: defaultHour, minute: 0, second: 0, of: d)
            }
            return d
        }
        AppLog.warn("Item", "时间解析失败：「\(t)」")
        return nil
    }

    /// 「yyyy-MM-dd HH:mm」；空串表示没有时间
    static func text(from date: Date?) -> String {
        guard let date else { return "" }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df.string(from: date)
    }
}

/// 把 AI 拆出的条目、速记表单填的条目存进本机数据库，并按需排通知。
///
/// 上一版这里叫 `SystemWriter`：待办写系统「提醒事项」、日程写系统「日历」。
/// 现在**不再碰系统里的其他 App**——不申请日历/提醒事项权限，也就没有「找不到列表」
/// 「权限被拒」这些和用户要做的事无关的失败。写自己的一张表几乎不会失败，
/// 唯一会失败的是时间认不出来（那就明确说认不出，让用户改一个）。
enum ItemWriter {

    enum WriteError: LocalizedError {
        case emptyTitle
        case needTime(String)
        case badTime(String)

        var errorDescription: String? {
            switch self {
            case .emptyTitle:
                return "这条没有标题"
            case .needTime(let title):
                return "「\(title)」要有个时间才会提醒。在卡片上的时间框里填一个，或者把类型改成「备忘」。"
            case .badTime(let text):
                return "认不出时间「\(text)」。写成 2026-10-08 15:00 这样就行。"
            }
        }
    }

    /// 存一条并（如果有时间）排上通知
    @discardableResult
    static func save(_ parsed: ParsedItem, source: String) throws -> AssistantItem {
        let title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw WriteError.emptyTitle }

        var due: Date?
        let text = parsed.dueDate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            guard let date = ItemTime.date(from: text, defaultHour: 9) else {
                throw WriteError.badTime(text)
            }
            due = date
        }
        // 日程和提醒没时间就失去了意义（不会响、也不知道占哪一段），这两种必须给时间
        if due == nil && (parsed.kind == .event || parsed.kind == .notification) {
            throw WriteError.needTime(title)
        }

        let item = AssistantItem(kind: parsed.kind,
                                 title: title,
                                 notes: parsed.notes,
                                 dueAt: due,
                                 durationMinutes: parsed.durationMinutes,
                                 priority: parsed.priority,
                                 remindBeforeMinutes: parsed.remindBeforeMinutes,
                                 source: source)
        return ItemStore.shared.add(item)
    }

    /// 逐条存，一条失败不拖垮整批
    static func saveAll(_ items: [ParsedItem], source: String) -> (succeeded: [String], failed: [String]) {
        var ok: [String] = []
        var bad: [String] = []
        for item in items {
            do {
                let saved = try save(item, source: source)
                ok.append("\(saved.kind.label) · \(saved.title)")
            } catch {
                bad.append("\(item.title)：\(error.localizedDescription)")
            }
        }
        return (ok, bad)
    }

    /// 存完之后给用户的那句话：说清存到哪儿了、到点会怎样
    static func summary(for items: [ParsedItem]) -> String {
        guard !items.isEmpty else { return "" }
        let kinds = Set(items.map { $0.kind })
        let notifying = items.filter { $0.kind != .note && !$0.dueDate.isEmpty }.count
        var text = kinds.count == 1
            ? "已存下 \(items.count) 条\(kinds.first?.label ?? "")"
            : "已存下 \(items.count) 条"
        if notifying > 0 { text += "，到点会弹通知" }
        text += "。在「今日 → 安排」里能改时间和备注。"
        return text
    }
}
