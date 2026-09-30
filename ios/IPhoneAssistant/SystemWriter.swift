import Foundation
import EventKit

/// 把 AI 解析出的条目写进系统：待办 → 提醒事项，日程 → 日历。
///
/// 只写入自己创建的「AI助理」列表和日历，不碰用户已有的数据——这是 PRD 4.4/4.5 的约束。
/// EventKit 的全部读写都记日志，因为没有调试器时这是唯一的事后线索。
enum SystemWriter {

    static let reminderListName = "AI助理"
    static let calendarName = "AI助理"

    enum WriteError: LocalizedError {
        case noSource
        case denied(String)
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSource:
                return "找不到可用的提醒事项/日历来源（source）"
            case .denied(let what):
                return "\(what)权限被拒绝。去 设置 → 隐私与安全性 → \(what) 里打开「私人助理」的开关"
            case .saveFailed(let s):
                return "写入失败：\(s)"
            }
        }
    }

    // MARK: - 提醒事项

    /// remindBeforeMinutes：提前几分钟提醒。0 表示到点提醒（也就是用户说「提醒我」时最自然的那种）。
    static func writeReminder(title: String,
                              notes: String,
                              dueDate: String,
                              priority: String,
                              remindBeforeMinutes: Int = 0) async throws {
        let store = EKEventStore()
        guard try await ensureRemindersAccess(store) else {
            throw WriteError.denied("提醒事项")
        }
        guard let source = store.defaultCalendarForNewReminders()?.source ?? store.sources.first else {
            throw WriteError.noSource
        }
        let list = try ensureReminderList(store, source: source)

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        reminder.notes = notes
        switch priority {
        case "high": reminder.priority = 1
        case "low":  reminder.priority = 9
        default:     reminder.priority = 5
        }
        if let comps = dateComponents(from: dueDate, defaultHour: 9) {
            reminder.dueDateComponents = comps
            // 之前固定写死「提前 5 分钟」，于是「10 分钟后提醒我」会在 5 分钟后弹出来。
            // 现在默认到点提醒，只有用户明说了「提前半小时」才提前。
            reminder.addAlarm(EKAlarm(relativeOffset: TimeInterval(-60 * max(0, remindBeforeMinutes))))
        }

        do {
            try store.save(reminder, commit: true)
            AppLog.info("EventKit", "已写入待办「\(title)」截止=\(dueDate.isEmpty ? "无" : dueDate)，提前 \(max(0, remindBeforeMinutes)) 分钟提醒")
        } catch {
            AppLog.error("EventKit", "写待办失败：\(error.localizedDescription)")
            throw WriteError.saveFailed(error.localizedDescription)
        }
    }

    // MARK: - 本地通知

    /// 排一条本地通知。这条不进提醒事项，也不需要 EventKit 权限。
    /// 用于「10 分钟后提醒我」这类弹一次就够、不用回来打勾的短时提醒。
    static func writeNotification(title: String, body: String, dueDate: String) async throws {
        let trimmed = dueDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let fireDate = date(from: trimmed, defaultHour: 9) else {
            throw WriteError.saveFailed("提醒必须有明确的时间，但没能从「\(trimmed)」里认出时间")
        }
        try await NotificationService.schedule(title: title, body: body, at: fireDate)
    }

    private static func ensureReminderList(_ store: EKEventStore, source: EKSource) throws -> EKCalendar {
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == reminderListName }) {
            return existing
        }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = reminderListName
        cal.source = source
        try store.saveCalendar(cal, commit: true)
        AppLog.info("EventKit", "新建提醒列表「\(reminderListName)」")
        return cal
    }

    // MARK: - 日历

    static func writeEvent(title: String,
                           notes: String,
                           dueDate: String,
                           durationMinutes: Int) async throws {
        let store = EKEventStore()
        guard try await ensureEventsAccess(store) else {
            throw WriteError.denied("日历")
        }
        guard let source = store.defaultCalendarForNewEvents?.source ?? store.sources.first else {
            throw WriteError.noSource
        }
        let calendar = try ensureCalendar(store, source: source)

        guard let start = date(from: dueDate, defaultHour: 9) else {
            throw WriteError.saveFailed("日程必须有个开始时间，但没能从「\(dueDate)」里认出时间。请写成 2026-10-08 15:00 这样的格式")
        }
        let minutes = durationMinutes > 0 ? durationMinutes : 60

        let event = EKEvent(eventStore: store)
        event.title = title
        event.notes = notes
        event.calendar = calendar
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval(minutes * 60))

        do {
            try store.save(event, span: .thisEvent, commit: true)
            AppLog.info("EventKit", "已写入日程「\(title)」开始=\(start)")
        } catch {
            AppLog.error("EventKit", "写日程失败：\(error.localizedDescription)")
            throw WriteError.saveFailed(error.localizedDescription)
        }
    }

    private static func ensureCalendar(_ store: EKEventStore, source: EKSource) throws -> EKCalendar {
        if let existing = store.calendars(for: .event).first(where: { $0.title == calendarName }) {
            return existing
        }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = calendarName
        cal.source = source
        try store.saveCalendar(cal, commit: true)
        AppLog.info("EventKit", "新建日历「\(calendarName)」")
        return cal
    }

    // MARK: - 时间解析

    /// 把模型给的日期字符串变成 Date。
    /// 只有日期没有时刻时，补一个默认小时（日程默认 9 点，待办默认 9 点）。
    ///
    /// 格式放宽是有意的：模型有时给 ISO8601（带 T、带时区），有时顺手写成「2026年9月30日 21:05」，
    /// 解析失败会变成「这条没有时间」，比时间差一点更难看出来。
    /// 注意格式数组的顺序——越具体的越靠前，否则 `yyyy-M-d` 会把「2026-09-30 21:15」只解析出日期部分。
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
        AppLog.warn("EventKit", "时间解析失败：「\(t)」")
        return nil
    }

    static func dateComponents(from string: String, defaultHour: Int) -> DateComponents? {
        guard let d = date(from: string, defaultHour: defaultHour) else { return nil }
        return Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
    }

    // MARK: - 授权

    private static func ensureRemindersAccess(_ store: EKEventStore) async throws -> Bool {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            store.requestFullAccessToReminders { granted, error in
                if let error {
                    AppLog.error("EventKit", "提醒事项授权出错：\(error.localizedDescription)")
                    cont.resume(throwing: error)
                } else {
                    AppLog.info("EventKit", "提醒事项授权 granted=\(granted)")
                    cont.resume(returning: granted)
                }
            }
        }
    }

    private static func ensureEventsAccess(_ store: EKEventStore) async throws -> Bool {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    AppLog.error("EventKit", "日历授权出错：\(error.localizedDescription)")
                    cont.resume(throwing: error)
                } else {
                    AppLog.info("EventKit", "日历授权 granted=\(granted)")
                    cont.resume(returning: granted)
                }
            }
        }
    }
}
