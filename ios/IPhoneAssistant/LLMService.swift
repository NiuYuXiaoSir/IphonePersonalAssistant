import Foundation

struct ChatMessage: Codable {
    let role: String
    let content: String

    static func system(_ c: String) -> ChatMessage { ChatMessage(role: "system", content: c) }
    static func user(_ c: String) -> ChatMessage { ChatMessage(role: "user", content: c) }
    static func assistant(_ c: String) -> ChatMessage { ChatMessage(role: "assistant", content: c) }
}

enum LLMError: LocalizedError {
    case badURL(String)
    case http(Int, String)
    case emptyReply
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let u):
            return "接口地址无效：\(u)"
        case .http(let code, let body):
            return "HTTP \(code)：\(body.prefix(500))"
        case .emptyReply:
            return "服务端返回了空内容"
        case .decoding(let d):
            return "解析响应失败：\(d)"
        }
    }
}

/// LLM 调用层。按 PRD 6.2 的设计，上层只依赖这个协议，
/// 换供应商、换模型都只换实现。
protocol LLMService {
    func chat(_ messages: [ChatMessage], jsonMode: Bool) async throws -> String
}

/// OpenAI 兼容实现。DeepSeek 官方和 OpenCode Zen 都是这个协议的实现。
final class OpenAICompatibleClient: LLMService {

    let config: LLMConfig
    private let session: URLSession

    init(config: LLMConfig) {
        self.config = config
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 90
        c.timeoutIntervalForResource = 180
        c.waitsForConnectivity = true
        self.session = URLSession(configuration: c)
    }

    func chat(_ messages: [ChatMessage], jsonMode: Bool = false) async throws -> String {
        guard let url = config.chatCompletionsURL else {
            throw LLMError.badURL(config.baseURL)
        }
        guard !config.apiKey.isEmpty else {
            throw LLMError.http(0, "还没有填写 API Key")
        }

        var body: [String: Any] = [
            "model": config.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": false
        ]
        if jsonMode {
            body["response_format"] = ["type": "json_object"]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decoding("没有收到 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.extractContent(from: data)
    }

    /// 从响应里取出 choices[0].message.content。
    /// 手动解析而不是用 Codable，是因为各家网关的响应字段经常有增减，
    /// 手解能容忍缺字段，报错信息也更直接。
    static func extractContent(from data: Data) throws -> String {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any] else {
            let preview = String(data: data, encoding: .utf8).map { String($0.prefix(400)) } ?? "(非文本)"
            throw LLMError.decoding(preview)
        }

        if let choices = obj["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { throw LLMError.emptyReply }
            return trimmed
        }

        // 有些网关出错时返回 200 但在 body 里放 error
        if let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            throw LLMError.http(200, msg)
        }

        throw LLMError.decoding("响应里找不到 choices[0].message.content")
    }
}
