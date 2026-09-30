import Foundation

/// AI 从一段自由文本里抽出来的一个可执行条目
struct ParsedItem: Identifiable {

    enum Kind: String {
        case todo
        case event
        case note

        var label: String {
            switch self {
            case .todo:  return "待办"
            case .event: return "日程"
            case .note:  return "备忘"
            }
        }

        var symbol: String {
            switch self {
            case .todo:  return "checklist"
            case .event: return "calendar"
            case .note:  return "note.text"
            }
        }
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var notes: String
    /// "yyyy-MM-dd HH:mm" 或 "yyyy-MM-dd"，没有时间就空串
    var dueDate: String
    var durationMinutes: Int
    /// high / normal / low
    var priority: String
    /// 用户在确认界面上的勾选状态
    var include: Bool

    init(kind: Kind,
         title: String,
         notes: String = "",
         dueDate: String = "",
         durationMinutes: Int = 0,
         priority: String = "normal",
         include: Bool = true) {
        self.kind = kind
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.durationMinutes = durationMinutes
        self.priority = priority
        self.include = include
    }
}

/// 把中文自然语言（可带图）拆成结构化条目。
/// 这是整个 App 里最需要反复调的部分，所以 prompt 写成常量集中放，方便单独改。
enum AIStructurer {

    /// 抽取用的系统提示词。改这里就能调整抽取行为，不用碰界面代码。
    static let systemPrompt = """
    你是一个中文工作助理的信息抽取引擎。用户会给你一句话、一段文字（可能是会议记录、口头交办、聊天记录），也可能带一张图片。你要把它拆成可执行条目。

    只输出 JSON，不要任何解释，不要 markdown 代码块，不要前后缀文字。格式：
    {
      "items": [
        {
          "kind": "todo 或 event 或 note",
          "title": "条目标题，不超过 30 字",
          "notes": "补充说明，没有就空字符串",
          "due_date": "yyyy-MM-dd HH:mm 或 yyyy-MM-dd，没有就空字符串",
          "duration_minutes": 事件的时长分钟数，不是事件就填 0,
          "priority": "high 或 normal 或 low"
        }
      ]
    }

    规则：
    1. kind 判断：有明确时间点、要占用一段时间的 → event；要做但没定具体时段 → todo；只是信息、不需要行动 → note。
    2. 相对时间必须换算成绝对日期，以用户在消息里给出的【今天】为基准。“下周三”“月底前”“明天下午三点”都要变成具体日期，不要保留原文。
    3. 一句话里包含多件事就拆成多条；同一件事不要拆开。
    4. title 要写成动作句（如“把方案改完发给老王”），不要只写名词。
    5. 绝不编造原文里没有的时间、人名、优先级。不确定就把对应字段留空。
    6. 如果整段内容里没有任何可执行的事，返回 {"items": []}。
    7. 如果带了图片，先把图里的内容读出来（可能是白板照片、纸质笔记、聊天截图、名片、手写便签），把其中提到的待办、时间、人名一并抽取。图里的字看不清就不要猜，宁可不抽。
    """

    /// 调一次模型，把 text（可附图）拆成条目
    static func parse(text: String,
                      images: [String] = [],
                      config: LLMConfig) async throws -> [ParsedItem] {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = """
        今天是 \(todayDescription())。
        需要抽取的内容：
        \(body.isEmpty ? "（内容见附图）" : body)
        """

        AppLog.info("AI", "开始解析，输入 \(body.count) 字，附图 \(images.count) 张")
        let client = OpenAICompatibleClient(config: config)
        var userMessage = ChatMessage.user(user)
        userMessage.images = images
        let raw = try await client.chat([.system(systemPrompt), userMessage], jsonMode: true)
        AppLog.info("AI", "模型返回 \(raw.count) 字")

        let items = try decode(raw)
        AppLog.info("AI", "解析出 \(items.count) 条")
        if items.isEmpty {
            // 抽不出东西时必须把原文记下来，否则无法判断是模型没抽还是内容确实没有
            AppLog.warn("AI", "未抽出条目，模型原文：\(raw.prefix(600))")
        }
        return items
    }

    static func todayDescription() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy-MM-dd EEEE"
        return df.string(from: Date())
    }

    // MARK: - 解析

    /// 手解 JSON 而不是用 Codable：
    /// 各家网关的返回字段经常有增减，手解能容忍缺字段，报错也能直接带出原文。
    static func decode(_ raw: String) throws -> [ParsedItem] {
        let cleaned = stripCodeFence(raw)
        guard let data = cleaned.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            AppLog.error("AI", "返回的不是 JSON：\(cleaned.prefix(400))")
            throw LLMError.decoding("模型没有返回合法 JSON，原文：\(cleaned.prefix(200))")
        }

        guard let rawItems = obj["items"] as? [[String: Any]] else {
            AppLog.warn("AI", "响应里没有 items 数组：\(cleaned.prefix(400))")
            return []
        }

        let items: [ParsedItem] = rawItems.compactMap { dict in
            let title = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            let kindRaw = ((dict["kind"] as? String) ?? "todo").lowercased()
            let kind = ParsedItem.Kind(rawValue: kindRaw) ?? .todo
            let duration = (dict["duration_minutes"] as? Int) ?? (dict["duration_minutes"] as? NSNumber)?.intValue ?? 0
            return ParsedItem(
                kind: kind,
                title: title,
                notes: (dict["notes"] as? String) ?? "",
                dueDate: ((dict["due_date"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                durationMinutes: duration,
                priority: ((dict["priority"] as? String) ?? "normal").lowercased()
            )
        }
        return items
    }

    /// 有些模型会把 JSON 包在 ```json ... ``` 里，即使开了 JSON 模式也会。
    static func stripCodeFence(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        if let newline = t.firstIndex(of: "\n") {
            t = String(t[t.index(after: newline)...])
        }
        if let closing = t.range(of: "```", options: .backwards) {
            t = String(t[t.startIndex..<closing.lowerBound])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
