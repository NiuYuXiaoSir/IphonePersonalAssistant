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

    static func writeReminder(title: String,
                              notes: String,
                              dueDate: String,
                              priority: String) async throws {
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
            reminder.addAlarm(EKAlarm(relativeOffset: -300))
        }

        do {
            try store.save(reminder, commit: true)
            AppLog.info("EventKit", "已写入待办「\(title)」截止=\(dueDate.isEmpty ? "无" : dueDate)")
        } catch {
            AppLog.error("EventKit", "写待办失败：\(error.localizedDescription)")
            throw WriteError.saveFailed(error.localizedDescription)
        }
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
            throw WriteError.saveFailed("日程必须有明确时间，但没能从「\(dueDate)」里解析出来。请把时间补成 2026-10-08 15:00 这种格式")
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
    static func date(from string: String, defaultHour: Int) -> Date? {
        let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current

        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            guard let d = df.date(from: t) else { continue }
            if fmt == "yyyy-MM-dd" {
                return Calendar.current.date(bySettingHour: defaultHour, minute: 0, second: 0, of: d)
            }
            return d
        }
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
