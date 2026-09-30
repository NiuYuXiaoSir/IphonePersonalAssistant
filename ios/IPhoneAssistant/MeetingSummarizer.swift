import Foundation

/// 会议纪要的结构化结果
struct MeetingSummary {

    struct Topic: Identifiable {
        let id = UUID()
        var topic: String
        var conclusion: String

        init(topic: String, conclusion: String) {
            self.topic = topic
            self.conclusion = conclusion
        }
    }

    var titleDraft: String = ""
    var summaryText: String = ""
    var topics: [Topic] = []
    var decisions: [String] = []
    /// 拆成待办，可直接走 SystemWriter 写进提醒事项
    var actionItems: [ParsedItem] = []
    /// 拆成日程，可直接走 SystemWriter 写进日历
    var events: [ParsedItem] = []
    var keyPoints: [String] = []
    var unresolved: [String] = []

    var isEmpty: Bool {
        summaryText.isEmpty && topics.isEmpty && decisions.isEmpty
            && actionItems.isEmpty && events.isEmpty && keyPoints.isEmpty && unresolved.isEmpty
    }
}

/// 会议文字 → 结构化纪要。
///
/// prompt 里最要紧的一条是 source_quote：要求每条待办都能引用到原文片段。
/// 这是对 AI 编造待办的最直接的制约，而且让用户能一眼核对。
enum MeetingSummarizer {

    static let systemPrompt = """
    你是一个中文会议纪要引擎。用户会给你一场会议的完整文字记录（可能是语音转写，有错别字和口语赘述）。

    只输出 JSON，不要任何解释，不要 markdown 代码块，不要前后缀文字。格式：
    {
      "title": "给这场会议起一个不超过 15 字的标题",
      "summary": "3-5 句话的摘要",
      "topics": [{"topic": "议题", "conclusion": "结论"}],
      "decisions": ["已达成一致的决议"],
      "action_items": [
        {"task": "待办事项，写成动作句",
         "owner": "负责人，没提到就空字符串",
         "due_date": "yyyy-MM-dd HH:mm 或 yyyy-MM-dd，没提到就空字符串",
         "priority": "high 或 normal 或 low",
         "source_quote": "原文中支持这条待办的原句"}
      ],
      "calendar_events": [
        {"title": "事件名", "start": "yyyy-MM-dd HH:mm", "duration_minutes": 60}
      ],
      "key_points": ["值得单独记下的要点、数字、背景"],
      "unresolved": ["讨论了但没定下来的问题"]
    }

    规则：
    1. action_items 每一条都必须在原文里有依据，source_quote 要引用原句。找不到依据的不要写。
    2. 绝不编造原文没有的负责人、时间、金额、数字。
    3. 相对时间（“下周三”“月底前”“后天上午”）一律以用户在消息里给出的【现在】为基准换算成绝对日期，那是带时刻的真实当前时间。不要凭空给时刻。
    4. 原文有错别字或同音字时，结合上下文纠正后写入，但不要改变原意。
    5. 只写进 calendar_events 的是“会上确定的、以后要发生的事”（如“下周一开评审会”）。待办自己的截止时间不算事件。
    6. 没有内容的字段返回空数组或空字符串，**不要省略字段**。
    """

    /// 调模型生成纪要，返回经过校验的 JSON 文本（校验不过就抛错，不存）
    static func generate(transcript: String, config: LLMConfig) async throws -> String {
        let user = """
        现在是 \(AIStructurer.nowDescription())。
        会议文字记录如下：
        ---
        \(transcript)
        ---
        """

        AppLog.info("Summary", "开始生成纪要，输入 \(transcript.count) 字，模型 \(config.model)")
        let client = OpenAICompatibleClient(config: config)
        let raw = try await client.chat([.system(systemPrompt), .user(user)], jsonMode: true)
        AppLog.info("Summary", "模型返回 \(raw.count) 字")

        // 先试解码，解不出来就不要存到会议里，免得留下一个坏 JSON
        let parsed = try decode(raw)
        AppLog.info("Summary", "解析成功：议题 \(parsed.topics.count)、决议 \(parsed.decisions.count)、待办 \(parsed.actionItems.count)、日程 \(parsed.events.count)")
        return AIStructurer.stripCodeFence(raw)
    }

    /// 手解 JSON，容忍缺字段
    static func decode(_ raw: String) throws -> MeetingSummary {
        let cleaned = AIStructurer.stripCodeFence(raw)
        guard let obj = AIStructurer.jsonObject(from: cleaned) else {
            AppLog.error("Summary", "返回的不是 JSON：\(cleaned.prefix(400))")
            throw LLMError.decoding("纪要返回的不是合法 JSON，原文开头：\(cleaned.prefix(200))")
        }

        var s = MeetingSummary()
        s.titleDraft = (obj["title"] as? String) ?? ""
        s.summaryText = (obj["summary"] as? String) ?? ""
        s.decisions = (obj["decisions"] as? [String]) ?? []
        s.keyPoints = (obj["key_points"] as? [String]) ?? []
        s.unresolved = (obj["unresolved"] as? [String]) ?? []

        if let topics = obj["topics"] as? [[String: Any]] {
            s.topics = topics.compactMap { d in
                let topic = (d["topic"] as? String) ?? ""
                let conclusion = (d["conclusion"] as? String) ?? ""
                guard !topic.isEmpty || !conclusion.isEmpty else { return nil }
                return MeetingSummary.Topic(topic: topic, conclusion: conclusion)
            }
        }

        if let items = obj["action_items"] as? [[String: Any]] {
            s.actionItems = items.compactMap { d in
                let task = (d["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !task.isEmpty else { return nil }
                let owner = (d["owner"] as? String) ?? ""
                let quote = (d["source_quote"] as? String) ?? ""
                var noteLines: [String] = []
                if !owner.isEmpty { noteLines.append("负责人：\(owner)") }
                if !quote.isEmpty { noteLines.append("原文：\(quote)") }
                return ParsedItem(
                    kind: .todo,
                    title: task,
                    notes: noteLines.joined(separator: "\n"),
                    dueDate: ((d["due_date"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    priority: ((d["priority"] as? String) ?? "normal").lowercased()
                )
            }
        }

        if let events = obj["calendar_events"] as? [[String: Any]] {
            s.events = events.compactMap { d in
                let title = (d["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !title.isEmpty else { return nil }
                let duration = (d["duration_minutes"] as? Int) ?? (d["duration_minutes"] as? NSNumber)?.intValue ?? 60
                return ParsedItem(
                    kind: .event,
                    title: title,
                    dueDate: ((d["start"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    durationMinutes: duration
                )
            }
        }

        if s.isEmpty {
            AppLog.warn("Summary", "纪要字段全空，原始返回：\(cleaned.prefix(400))")
        }
        return s
    }
}
