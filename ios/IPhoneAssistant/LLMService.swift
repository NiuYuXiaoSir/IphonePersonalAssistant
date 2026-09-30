import Foundation

struct ChatMessage: Codable {
    let role: String
    let content: String
    /// 附图，以 data URL 形式附加（data:image/jpeg;base64,xxxx）
    var images: [String] = []

    static func system(_ c: String) -> ChatMessage { ChatMessage(role: "system", content: c) }
    static func user(_ c: String) -> ChatMessage { ChatMessage(role: "user", content: c) }
    static func assistant(_ c: String) -> ChatMessage { ChatMessage(role: "assistant", content: c) }

    /// 转成 API 需要的形状。
    /// 没有图片时 content 是普通字符串；有图片时是 OpenAI 风格的多模态数组——
    /// DeepSeek 的 flash 模型支持这种视觉输入（v4-pro 不支持）。
    var payload: [String: Any] {
        guard !images.isEmpty else {
            return ["role": role, "content": content]
        }
        var parts: [[String: Any]] = [["type": "text", "text": content]]
        for dataURL in images {
            parts.append(["type": "image_url", "image_url": ["url": dataURL]])
        }
        return ["role": role, "content": parts]
    }
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

        let imageCount = messages.reduce(0) { $0 + $1.images.count }
        var body: [String: Any] = [
            "model": config.model,
            "messages": messages.map { $0.payload },
            "stream": false
        ]
        if jsonMode {
            // JSON 模式和视觉输入不能同时用，有些网关会直接报错，所以带图时关掉
            body["response_format"] = ["type": "json_object"]
            if imageCount > 0 {
                AppLog.warn("LLM", "本次带图 \(imageCount) 张，但仍要求 JSON 输出，如果服务端报错就取消勾选图片重试")
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // 日志里绝不写 API Key，只写地址、模型、体积和耗时
        AppLog.info("LLM", "POST \(url.absoluteString) model=\(config.model) json=\(jsonMode) 图=\(imageCount) 请求体=\(request.httpBody?.count ?? 0) 字节")
        let started = Date()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AppLog.error("LLM", "网络请求失败：\(error.localizedDescription)")
            throw error
        }

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        guard let http = response as? HTTPURLResponse else {
            AppLog.error("LLM", "没有收到 HTTP 响应")
            throw LLMError.decoding("没有收到 HTTP 响应")
        }
        AppLog.info("LLM", "HTTP \(http.statusCode)，\(ms)ms，\(data.count) 字节")

        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "(非文本响应)"
            AppLog.error("LLM", "HTTP \(http.statusCode)：\(text.prefix(500))")
            throw LLMError.http(http.statusCode, text)
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
