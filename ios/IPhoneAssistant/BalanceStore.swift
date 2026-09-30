import Foundation
import SwiftUI

/// 余额 / 套餐用量。
///
/// 两家的接口形状完全不同，这里统一成一份报告：
///   - DeepSeek 官方：`GET /user/balance` → 金额（充值 + 赠送），返回 CNY 或 USD
///   - OpenCode Go：`GET /zen/go/v1/usage` → rolling / weekly / monthly
///     三个窗口的「已用百分比」，订阅制没有金额，只有还能用多少
///
/// 其他供应商（Zen 同网关、自定义）没试过或没有公开接口，报告里直说查不到，
/// 不假装有数。字段解析一律宽容：JSON 里数字可能是字符串，时间戳可能是
/// 秒、毫秒或 ISO 字符串，缺字段不能整个失败。
struct BalanceReport {

    enum Kind {
        case money      // 充值余额（DeepSeek 这类按量付费）
        case plan       // 订阅窗口用量（OpenCode Go）
        case unknown    // 查不到
    }

    var kind: Kind = .unknown
    var icon: String = "questionmark.circle"
    /// 胶囊上的短字：「¥110.00」「剩 88%」
    var headline: String = "余额未知"
    /// 明细，多行，设置页里展开看
    var detail: String = ""
    /// 剩余偏低，界面上要变色
    var low: Bool = false
    var capturedAt: Date = Date()
}

enum BalanceService {

    /// 这家供应商查余额的相对路径；nil = 没有公开接口
    static func path(for preset: LLMProviderPreset) -> String? {
        switch preset {
        case .deepseek:   return "user/balance"
        case .opencodeGo: return "usage"
        // Zen 是同一家的另一个网关，接口名一样，能不能用要看套餐给不给
        case .opencode:   return "usage"
        case .custom:     return nil
        }
    }

    static func fetch(config: LLMConfig, preset: LLMProviderPreset) async throws -> BalanceReport {
        guard let path = path(for: preset) else {
            var report = BalanceReport()
            report.detail = "「\(preset.displayName)」没有公开的余额接口，只能去它的控制台看。"
            return report
        }
        guard let url = endpoint(config.baseURL, path) else {
            throw LLMError.badURL(config.baseURL)
        }
        guard !config.apiKey.isEmpty else {
            throw LLMError.http(0, "还没有保存密钥，查不了余额")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        // OpenCode 的网关对每个请求都要那个会话头，余额查询也一样
        OpenAICompatibleClient.applyOpenCodeHeaders(to: &request, config: config)

        // 日志里只写地址，不写密钥
        AppLog.info("Balance", "查余额 GET \(url.absoluteString)")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decoding("没有收到 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "(非文本响应)"
            throw LLMError.http(http.statusCode, text)
        }

        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any] else {
            throw LLMError.decoding("余额响应不是 JSON 对象")
        }

        AppLog.info("Balance", "余额返回 \(data.count) 字节")

        switch preset {
        case .deepseek:
            return parseDeepSeek(obj)
        case .opencodeGo, .opencode:
            return parsePlan(obj, preset: preset)
        case .custom:
            return BalanceReport()
        }
    }

    // MARK: - DeepSeek：金额

    private static func parseDeepSeek(_ obj: [String: Any]) -> BalanceReport {
        var report = BalanceReport()
        report.kind = .money
        report.icon = "yensign.circle"
        report.capturedAt = Date()

        let infos = obj["balance_infos"] as? [[String: Any]] ?? []
        guard let first = infos.first else {
            report.detail = "接口没返回余额明细：\(preview(obj))"
            return report
        }

        let currency = text(first["currency"]) ?? "CNY"
        let total = text(first["total_balance"]) ?? "0"
        let granted = text(first["granted_balance"])
        let topped = text(first["topped_up_balance"])
        let available = bool(obj["is_available"]) ?? true

        let mark = symbol(currency)
        report.icon = currency.uppercased() == "USD" ? "dollarsign.circle" : "yensign.circle"
        report.headline = mark + total

        var lines = ["可用余额 \(mark)\(total)"]
        if let topped { lines.append("其中充值 \(mark)\(topped)") }
        if let granted { lines.append("其中赠送 \(mark)\(granted)") }
        if !available { lines.append("账户当前不可用（余额不足），接口会直接拒绝") }
        report.detail = lines.joined(separator: "\n")

        // 低于 5 块就提醒一下，免得正用着突然被拒
        report.low = !available || (number(total) ?? 0) < 5
        return report
    }

    // MARK: - OpenCode Go：订阅窗口用量

    private static func parsePlan(_ obj: [String: Any], preset: LLMProviderPreset) -> BalanceReport {
        var report = BalanceReport()
        report.kind = .plan
        report.icon = "calendar.badge.clock"
        report.capturedAt = Date()

        // 有的网关包一层 usage，有的直接就给了
        let usage = (obj["usage"] as? [String: Any]) ?? obj
        var windows: [(name: String, used: Double, reset: Date?)] = []
        for (key, name) in [("rolling", "5 小时窗口"), ("weekly", "本周"), ("monthly", "本月")] {
            guard let row = usage[key] as? [String: Any],
                  let used = number(row["percent"]) else { continue }
            windows.append((name, min(max(used, 0), 100), date(row["resetsAt"])))
        }

        guard !windows.isEmpty else {
            report.headline = "用量未知"
            report.detail = "\(preset.displayName) 没返回窗口用量：\(preview(obj))"
            return report
        }

        // 胶囊上只说最紧的那个窗口：订阅制关心的是「还能不能接着用」
        let tightest = windows.max { $0.used < $1.used } ?? windows[0]
        let remaining = Int((100 - tightest.used).rounded())
        report.headline = "剩 \(remaining)%"
        report.low = remaining <= 10
        report.detail = windows.map { window in
            var line = "\(window.name)：已用 \(Int(window.used.rounded()))%"
            if let reset = window.reset { line += "，重置于 \(resetText(reset))" }
            return line
        }.joined(separator: "\n")
        return report
    }

    // MARK: - 解析小工具

    private static func endpoint(_ baseURL: String, _ path: String) -> URL? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty, s.lowercased().hasPrefix("http") else { return nil }
        return URL(string: s + "/" + path)
    }

    private static func text(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    /// 重置时间可能是秒、毫秒或 ISO 字符串，都认
    private static func date(_ value: Any?) -> Date? {
        if let n = number(value) {
            let seconds = n > 1_000_000_000_000 ? n / 1000 : n
            guard seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        guard let s = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    private static func symbol(_ currency: String) -> String {
        switch currency.uppercased() {
        case "USD": return "$"
        case "CNY": return "¥"
        default:    return ""
        }
    }

    private static func preview(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return "(读不出来)" }
        return String(text.prefix(200))
    }

    private static let resetFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日 HH:mm"
        return df
    }()

    private static let resetTimeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "HH:mm"
        return df
    }()

    private static func resetText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "今天 " + resetTimeFormatter.string(from: date)
        }
        return resetFormatter.string(from: date)
    }
}

/// 余额的缓存与刷新。所有会产生 token 的页面共用这一份。
///
/// 省钱的方式是「别乱查」：显示前先看缓存，两分钟内不重复请求；
/// 但每花掉一次 token（对话整理完、纪要生成完）就强制刷一次，
/// 这样数字始终跟着花费走。
final class BalanceStore: ObservableObject {

    static let shared = BalanceStore()

    @Published private(set) var report: BalanceReport?
    @Published private(set) var isRefreshing = false
    /// 「更新于 12:03」或者出错原因
    @Published private(set) var message = ""

    private var lastAttempt: Date?
    /// 供应商 + 地址，换一家就得重新查
    private var lastSignature = ""

    private init() {}

    // MARK: - 给界面看的几个短属性

    var chipText: String {
        if isRefreshing && report == nil { return "查询中" }
        guard let report else { return message.isEmpty ? "查余额" : "余额未知" }
        return report.headline
    }

    var chipIcon: String { report?.icon ?? "questionmark.circle" }

    /// 查过但没成功过
    var isUnavailable: Bool { report == nil }

    var isLow: Bool { report?.low == true }

    func supports(_ settings: SettingsStore) -> Bool {
        BalanceService.path(for: settings.preset) != nil
    }

    // MARK: - 刷新

    /// 显示前调用：两分钟内查过就不重复查
    func refreshIfStale(settings: SettingsStore, maxAge: TimeInterval = 120) {
        let signature = settings.preset.rawValue + "|" + settings.baseURL
        if signature == lastSignature,
           let last = lastAttempt,
           Date().timeIntervalSince(last) < maxAge {
            return
        }
        refresh(settings: settings)
    }

    /// 强制查一次。花掉 token 之后调它，数字跟着花费走。
    func refresh(settings: SettingsStore) {
        let preset = settings.preset
        let config = settings.makeConfig()

        lastSignature = preset.rawValue + "|" + settings.baseURL
        lastAttempt = Date()

        guard BalanceService.path(for: preset) != nil else {
            report = nil
            message = "「\(preset.displayName)」没有公开的余额接口"
            return
        }
        guard !config.apiKey.isEmpty else {
            report = nil
            message = "还没有保存「\(preset.displayName)」的密钥，查不了余额"
            return
        }

        isRefreshing = true
        message = "正在查询…"

        Task {
            do {
                let next = try await BalanceService.fetch(config: config, preset: preset)
                await MainActor.run {
                    self.report = next
                    self.isRefreshing = false
                    self.message = "更新于 " + Self.clock(next.capturedAt)
                }
            } catch {
                // 查失败时保留上一次的数字——它仍是手上最好的信息；
                // 这里把失败原因和上次查询时间一起留着，设置页会说清这是旧的。
                let reason = error.localizedDescription
                await MainActor.run {
                    self.isRefreshing = false
                    var line = "查不到：\(reason)"
                    if let last = self.report?.capturedAt {
                        line += "\n上面显示的还是 \(Self.clock(last)) 查到的数字"
                    }
                    self.message = line
                }
                AppLog.warn("Balance", "查询失败：\(reason)")
            }
        }
    }

    private static func clock(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "HH:mm"
        return df.string(from: date)
    }
}
