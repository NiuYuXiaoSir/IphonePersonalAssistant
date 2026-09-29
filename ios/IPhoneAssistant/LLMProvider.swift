import Foundation

/// 模型服务预设。本项目只依赖 OpenAI 兼容的 /chat/completions 这一个接口，
/// 所以 DeepSeek 官方和 OpenCode Zen 用同一套客户端，差别只在 base URL 和模型名。
enum LLMProviderPreset: String, CaseIterable, Identifiable {
    case deepseek
    case opencode
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek 官方"
        case .opencode: return "OpenCode Zen"
        case .custom: return "自定义"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com"
        case .opencode: return "https://opencode.ai/zen/v1"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-flash"
        case .opencode: return "deepseek-v4.1-flash"
        case .custom: return ""
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .deepseek: return ["deepseek-flash", "deepseek-v4-pro"]
        case .opencode: return ["deepseek-v4.1-flash", "deepseek-v4-pro"]
        case .custom: return []
        }
    }

    var note: String {
        switch self {
        case .deepseek:
            return "官方直连，国内可访问。deepseek-flash 支持 1M 上下文和 JSON 输出。高峰时段（工作日 9-12 点、14-18 点）单价是非高峰的两倍，其余时间及周末半价。"
        case .opencode:
            return "OpenCode Zen 网关，OpenAI 兼容。若你的套餐给的地址不同，直接改上面的输入框即可。"
        case .custom:
            return "任何 OpenAI 兼容服务都能接：填 base URL（填到 /v1 为止）、模型名和 API Key。"
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
    var chatCompletionsURL: URL? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty, s.lowercased().hasPrefix("http") else { return nil }
        return URL(string: s + "/chat/completions")
    }
}
