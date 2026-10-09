import Foundation

/// 第三方语音识别（OpenAI 兼容的 `/audio/transcriptions`）。
///
/// 走的是最通行的那个约定：multipart/form-data 传 `file`、`model`，可带 `language`，
/// 回来一个 `{"text": "..."}`。Groq、硅基流动、以及自建的 whisper 服务都是这个形状。
///
/// 为什么不流式：这些免费额度主要给的是**整段批量**接口，逐字回传要另开 WebSocket，
/// 各家协议还不一样。整段上传换来的是准确率——按整句上下文解码，比端上逐字识别准得多，
/// 代价是「说完才出字」。听写场景可以接受。
enum CloudSpeechService {

    /// 一次请求的大小上限。超过就明确报错，别让用户看着进度条转半天。
    static let maxBytes = 24 * 1024 * 1024

    /// 上传一个音频文件，拿回文字
    static func transcribe(url: URL, config: SpeechConfig) async throws -> String {
        guard let endpoint = config.transcriptionURL else {
            throw LLMError.badURL(config.baseURL)
        }
        guard !config.apiKey.isEmpty else {
            throw LLMError.http(0, "还没填语音识别的密钥：去「我的 → 语音识别」填一个，或者把引擎切回「系统（端上）」")
        }
        guard let audio = try? Data(contentsOf: url) else {
            throw LLMError.decoding("读不出这个音频文件：\(url.lastPathComponent)")
        }
        guard !audio.isEmpty else {
            throw LLMError.decoding("这个音频文件是空的（\(url.lastPathComponent)）")
        }
        guard audio.count <= maxBytes else {
            throw LLMError.decoding("这一段音频 \(audio.count / 1024 / 1024) MB，超过上传上限。会议录音是按 60 秒分段的，如果每段都这么大，检查一下录音格式。")
        }

        let body = multipartBody(fields: ["model": config.model,
                                          "language": "zh",
                                          "response_format": "json"],
                                 fileField: "file",
                                 fileName: url.lastPathComponent,
                                 mimeType: mimeType(for: url),
                                 fileData: audio)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(LLMConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        let started = Date()
        AppLog.info("ASR", "上传 \(url.lastPathComponent)（\(audio.count / 1024) KB）到 \(endpoint.absoluteString) model=\(config.model)")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let ms = Int(Date().timeIntervalSince(started) * 1000)

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decoding("没有收到 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "(非文本响应)"
            AppLog.error("ASR", "HTTP \(http.statusCode)：\(text.prefix(400))")
            throw LLMError.http(http.statusCode, text)
        }

        let text = try extractText(from: data)
        AppLog.info("ASR", "\(url.lastPathComponent) 识别完成：\(text.count) 字，\(ms)ms")
        return text
    }

    /// 端点自检：传一段静音过去，只验证「地址、密钥、模型名」这三件事。
    /// 返回服务端给的空结果（静音识别出来当然是空的）——不报错就说明配置可用。
    static func selfTest(config: SpeechConfig) async throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-\(UUID().uuidString).wav")
        try silentWAV(seconds: 0.4).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await transcribe(url: url, config: config)
    }

    // MARK: - 解析

    /// 回来的是 `{"text": "..."}`。也见过把结果放在 `segments` 里的实现，一并兼容。
    static func extractText(from data: Data) throws -> String {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            let preview = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? "(非文本)"
            throw LLMError.decoding("响应不是 JSON：\(preview)")
        }
        if let obj = raw as? [String: Any] {
            if let text = obj["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let segments = obj["segments"] as? [[String: Any]] {
                let joined = segments.compactMap { $0["text"] as? String }.joined()
                return joined.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let error = obj["error"] as? [String: Any], let message = error["message"] as? String {
                throw LLMError.http(200, message)
            }
        }
        let preview = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? "(非文本)"
        throw LLMError.decoding("响应里找不到 text 字段：\(preview)")
    }

    // MARK: - multipart

    private static let boundary = "----assistantASR\(UUID().uuidString)"

    private static func multipartBody(fields: [String: String],
                                      fileField: String,
                                      fileName: String,
                                      mimeType: String,
                                      fileData: Data) -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav":  return "audio/wav"
        case "mp3":  return "audio/mpeg"
        case "m4a":  return "audio/m4a"
        case "mp4":  return "audio/mp4"
        case "caf":  return "audio/x-caf"
        case "ogg":  return "audio/ogg"
        case "webm": return "audio/webm"
        default:     return "application/octet-stream"
        }
    }

    // MARK: - 自检用的静音 WAV

    /// 生成一段 16 kHz 单声道 16 bit 的静音 WAV（44 字节头 + 全 0 采样）。
    /// 用来验证端点：不需要麦克风、不花时间，服务端认了就是配置对了。
    static func silentWAV(seconds: Double, sampleRate: Int = 16000) -> Data {
        let frames = max(1, Int(Double(sampleRate) * seconds))
        let dataBytes = frames * 2
        var data = Data()

        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                       // fmt 块长度
        append(UInt16(1))                        // PCM
        append(UInt16(1))                        // 单声道
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))           // 字节率
        append(UInt16(2))                        // 块对齐
        append(UInt16(16))                       // 位深
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        data.append(Data(count: dataBytes))      // 静音
        return data
    }
}
