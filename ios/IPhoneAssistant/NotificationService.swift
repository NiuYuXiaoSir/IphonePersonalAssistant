import Foundation
import UserNotifications

/// 本地通知：App 的**唯一**提醒通道。
///
/// 「10 分钟后提醒我」「明天三点开会」「周五前把报价单发出去」——这些全部排成本地通知，
/// 内容和时刻来自 `ItemStore` 里的那一条（通知是数据的影子，数据才是事实）。
/// 通知上带两个按钮：完成 / 延后 10 分钟——HIG 的 Notifications 页就是拿日历通知
/// 带的那个 Snooze 按钮举例的（「a Calendar event notification provides a Snooze button」），
/// 而且「Prefer actions that let people perform common, time-saving tasks that
/// eliminate the need to open your app」。
enum NotificationService {

    /// 通知上的动作
    enum Action {
        static let complete = "assistant-action-complete"
        static let snooze = "assistant-action-snooze"
    }

    enum ScheduleError: LocalizedError {
        case denied
        case tooSoon
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .denied:
                return "通知权限被拒绝了。去 设置 → 通知 → 私人助理 里把「允许通知」打开。"
            case .tooSoon:
                return "这个时间已经过去了，没法安排通知"
            case .failed(let s):
                return "安排通知失败：\(s)"
            }
        }
    }

    // MARK: - 权限

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func statusText(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized:     return "已允许"
        case .denied:         return "已拒绝"
        case .notDetermined:  return "还没问过"
        case .provisional:    return "安静推送"
        case .ephemeral:      return "临时允许"
        @unknown default:     return "未知状态"
        }
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            break
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            AppLog.info("Notice", "请求通知权限 granted=\(granted)")
            return granted
        } catch {
            AppLog.error("Notice", "请求通知权限失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 注册通知分类（两个按钮）。启动时调用一次，不然通知上不会出现按钮。
    static func registerCategories() {
        let complete = UNNotificationAction(identifier: Action.complete,
                                            title: "完成",
                                            options: [])
        let snooze = UNNotificationAction(identifier: Action.snooze,
                                          title: "延后 10 分钟",
                                          options: [])
        let category = UNNotificationCategory(identifier: ItemStore.categoryIdentifier,
                                              actions: [complete, snooze],
                                              intentIdentifiers: [],
                                              options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - 排通知

    /// 排一条通知。标识符由调用方给（按条目的 id 算），这样同一条改时间就是覆盖，
    /// 不会在通知队列里留下两条。
    @discardableResult
    static func schedule(identifier: String,
                         title: String,
                         body: String,
                         at date: Date,
                         category: String? = nil) async throws -> String {
        let interval = date.timeIntervalSinceNow
        guard interval > 1 else { throw ScheduleError.tooSoon }

        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        content.sound = .default
        if let category { content.categoryIdentifier = category }

        // 用时间间隔触发而不是日历触发：算出来的绝对时间已经带本机时区，
        // 再交给日历组件反而容易被时区/夏令时绕进去
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
            return identifier
        } catch {
            AppLog.error("Notice", "安排通知失败：\(error.localizedDescription)")
            throw ScheduleError.failed(error.localizedDescription)
        }
    }

    // MARK: - 查看与取消

    /// 撤销一条（条目删掉、或者改了时间要重排）
    static func cancel(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// 撤掉某一类自己排的通知。整批重排之前先清干净，不然改过时间的条目会残留旧的那条。
    static func removeAll(withPrefix prefix: String) async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
