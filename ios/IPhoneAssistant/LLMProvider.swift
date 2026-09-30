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

    /// 把 base URL 拼成 chat completions 端点
    var chatCompletionsURL: URL? { endpoint("chat/completions") }

    /// 模型清单端点。OpenAI 兼容服务一般都有 /models，
    /// 用来确认套餐里到底给了哪些模型名。
    var modelsURL: URL? { endpoint("models") }

    private func endpoint(_ path: String) -> URL? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty, s.lowercased().hasPrefix("http") else { return nil }
        return URL(string: s + "/" + path)
    }
}
