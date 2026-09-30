import Foundation

/// 模型服务预设。本项目只依赖 OpenAI 兼容的 /chat/completions 这一个接口，
/// 所以 DeepSeek 官方和 OpenCode Zen 用同一套客户端，差别只在 base URL 和模型名。
enum LLMProviderPreset: String, CaseIterable, Identifiable {
    case deepseek
    case opencodeGo
    case opencode
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepseek:   return "DeepSeek 官方"
        case .opencodeGo: return "OpenCode Go（订阅）"
        case .opencode:   return "OpenCode Zen"
        case .custom:     return "自定义"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepseek:   return "https://api.deepseek.com"
        case .opencodeGo: return "https://opencode.ai/zen/go/v1"
        case .opencode:   return "https://opencode.ai/zen/v1"
        case .custom:     return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek:   return "deepseek-flash"
        case .opencodeGo: return "deepseek-v4.1-flash"
        case .opencode:   return "deepseek-v4.1-flash"
        case .custom:     return ""
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .deepseek:   return ["deepseek-flash", "deepseek-v4-pro"]
        // Go 套餐里的模型名以服务端为准，拿不准就点「拉取模型列表」看实际返回
        case .opencodeGo: return ["deepseek-v4.1-flash", "deepseek-v4-pro"]
        case .opencode:   return ["deepseek-v4.1-flash", "deepseek-v4-pro"]
        case .custom:     return []
        }
    }

    var note: String {
        switch self {
        case .deepseek:
            return "官方直连，国内可访问。deepseek-flash 支持长上下文和 JSON 输出。高峰时段（工作日 9 点到 12 点、14 点到 18 点）单价是非高峰的两倍，其余时间及周末半价。"
        case .opencodeGo:
            return "OpenCode 的订阅套餐，走 zen/go 这条网关。可用模型和套餐绑在一起，准确的模型名以服务端为准——点下面的「拉取模型列表」看实际有哪些，再挑一个填进「模型名」。"
        case .opencode:
            return "OpenCode Zen 网关，接口格式和上面一样，只是地址不同。若你的套餐给的地址不一样，直接改上面的输入框。"
        case .custom:
            return "任何兼容接口的服务都能接：填接口地址（填到 v1 那一层为止）、模型名和密钥。"
        }
    }
}

/// 一次调用需要的全部参数。
/// 刻意不做 Codable——避免密钥被顺手编进磁盘文件。
struct LLMConfig {
    var presetID: String
    var baseURL: String
    var model: String
    var apiKey: String
    /// 这一段对话的稳定标识。OpenCode 的网关要求每个请求都带（x-opencode-session），
    /// 它据此做路由和 prompt 缓存，缺了直接 400 MissingSessionID。
    /// 调用方填对话/会议自己的 id；不填就退回设备级的那一个。
    var sessionID: String = ""

    /// 把 base URL 拼成 chat completions 端点
    var chatCompletionsURL: URL? { endpoint("chat/completions") }

    /// 模型清单端点。OpenAI 兼容服务一般都有 /models，
    /// 用来确认套餐里到底给了哪些模型名。
    var modelsURL: URL? { endpoint("models") }

    /// 是不是 OpenCode 的网关（zen/go 与 zen）。只有它要上面那个会话头。
    var isOpenCodeHost: Bool {
        baseURL.lowercased().contains("opencode.ai")
    }

    /// 真正发出去的会话 id
    var effectiveSessionID: String {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? SessionIdentity.current : trimmed
    }

    /// 客户端自己的标识。这类网关按它区分调用方，不接受 SDK 或 HTTP 库的默认 UA。
    static let userAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "IPhoneAssistant/\(version)"
    }()

    private func endpoint(_ path: String) -> URL? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty, s.lowercased().hasPrefix("http") else { return nil }
        return URL(string: s + "/" + path)
    }
}

/// OpenCode 网关要的那个会话 id。
///
/// 一台设备一份，第一次用到时生成并存进偏好里，之后一直不变——
/// 它只是给服务端做路由亲和与缓存用的不透明字符串，不含任何用户信息。
/// 有对话的请求应该用 LLMConfig.sessionID 传更准的那个 id，这里兜底
/// 那些没有「对话」概念的请求（模型列表、余额查询、连接测试）。
enum SessionIdentity {
    private static let key = "llm.opencodeSessionID"

    static var current: String {
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return saved
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}
