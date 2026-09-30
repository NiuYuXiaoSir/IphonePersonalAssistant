import Foundation
import UserNotifications

/// 本地通知。
///
/// 「10 分钟后提醒我」这类短时、一次性的提醒走这里：弹出来就完事，
/// 不需要在提醒事项里留一条要跟踪完成状态的任务。
/// 需要跟踪的、时间远的，才写进提醒事项——这个判断交给模型做。
enum NotificationService {

    /// 我们排的通知，标识符都带这个前缀，方便把自己的和探针的区分开
    static let identifierPrefix = "assistant-"

    struct Pending: Identifiable {
        let id: String
        let title: String
        let body: String
        let fireDate: Date
    }

    enum ScheduleError: LocalizedError {
        case denied
        case noDate
        case tooSoon
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .denied:
                return "通知权限被拒绝了。去 设置 → 通知 → 私人助理 里把「允许通知」打开。"
            case .noDate:
                return "通知必须有明确的触发时间"
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
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            AppLog.info("Notice", "请求通知权限 granted=\(granted)")
            return granted
        } catch {
            AppLog.error("Notice", "请求通知权限失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 排通知

    /// 排一条在 date 弹出的本地通知
    @discardableResult
    static func schedule(title: String, body: String, at date: Date) async throws -> String {
        guard await requestAuthorization() else { throw ScheduleError.denied }

        let interval = date.timeIntervalSinceNow
        guard interval > 1 else { throw ScheduleError.tooSoon }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let identifier = identifierPrefix + UUID().uuidString
        // 用时间间隔触发而不是日历触发：算出来的绝对时间已经是本地时区，
        // 再交给日历组件反而容易被时区/夏令时绕进去
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
            AppLog.info("Notice", "已安排通知「\(title)」，\(Int(interval)) 秒后弹出")
            return identifier
        } catch {
            AppLog.error("Notice", "安排通知失败：\(error.localizedDescription)")
            throw ScheduleError.failed(error.localizedDescription)
        }
    }

    // MARK: - 查看与取消

    /// 已经排上、还没弹出的通知（只列本 App 通过这里排的，不含探针那条）
    static func pending() async -> [Pending] {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return requests.compactMap { request -> Pending? in
            guard request.identifier.hasPrefix(identifierPrefix),
                  let trigger = request.trigger as? UNTimeIntervalNotificationTrigger,
                  let fireDate = trigger.nextTriggerDate() else { return nil }
            return Pending(id: request.identifier,
                           title: request.content.title,
                           body: request.content.body,
                           fireDate: fireDate)
        }
        .sorted { $0.fireDate < $1.fireDate }
    }

    static func cancel(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        AppLog.info("Notice", "已取消通知 \(id)")
    }
}
