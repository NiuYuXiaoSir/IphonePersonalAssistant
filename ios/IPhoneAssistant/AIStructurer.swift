import Foundation

/// AI 从一段自由文本里抽出来的一个可执行条目。
/// 会随速记对话一起存进 chat.json，所以是 Codable。
struct ParsedItem: Identifiable, Codable {

    enum Kind: String, Codable, CaseIterable {
        case todo
        case event
        case note
        /// 短时、一次性的提醒，弹完就完，不写进提醒事项
        case notification

        var label: String {
            switch self {
            case .todo:         return "待办"
            case .event:        return "日程"
            case .note:         return "备忘"
            case .notification: return "提醒"
            }
        }

        /// 这条东西最终会落到哪儿
        var destination: String {
            switch self {
            case .todo:         return "提醒事项"
            case .event:        return "日历"
            case .note:         return "备忘"
            case .notification: return "通知"
            }
        }

        var symbol: String {
            switch self {
            case .todo:         return "checklist"
            case .event:        return "calendar"
            case .note:         return "note.text"
            case .notification: return "bell"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var notes: String
    /// "yyyy-MM-dd HH:mm" 或 "yyyy-MM-dd"，没有时间就空串
    var dueDate: String
    var durationMinutes: Int
    /// high / normal / low
    var priority: String
    /// 提前几分钟提醒。0 = 到点就提醒；负数 = 没提，按到点算
    var remindBeforeMinutes: Int
    /// 用户在确认界面上的勾选状态
    var include: Bool

    init(kind: Kind,
         title: String,
         notes: String = "",
         dueDate: String = "",
         durationMinutes: Int = 0,
         priority: String = "normal",
         remindBeforeMinutes: Int = 0,
         include: Bool = true) {
        self.kind = kind
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.durationMinutes = durationMinutes
        self.priority = priority
        self.remindBeforeMinutes = remindBeforeMinutes
        self.include = include
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, notes, dueDate, durationMinutes, priority, remindBeforeMinutes, include
    }

    /// 手写解码：合成的解码器遇到缺字段会直接抛错，
    /// 而这个结构体会被写进 chat.json 长期存着，以后加字段时旧数据必须还能读出来。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = Kind(rawValue: (try? c.decode(String.self, forKey: .kind)) ?? "") ?? .todo
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
        dueDate = (try? c.decode(String.self, forKey: .dueDate)) ?? ""
        durationMinutes = (try? c.decode(Int.self, forKey: .durationMinutes)) ?? 0
        priority = (try? c.decode(String.self, forKey: .priority)) ?? "normal"
        remindBeforeMinutes = (try? c.decode(Int.self, forKey: .remindBeforeMinutes)) ?? 0
        include = (try? c.decode(Bool.self, forKey: .include)) ?? true
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
          "kind": "todo 或 event 或 note 或 notification",
          "title": "条目标题，不超过 30 字",
          "notes": "补充说明，没有就空字符串",
          "due_date": "yyyy-MM-dd HH:mm 或 yyyy-MM-dd，没有就空字符串",
          "due_in_minutes": 如果用户说的是相对当前时刻的时间（“10分钟后”“半小时后”“两小时后”），这里填相对分钟数；否则填 -1,
          "duration_minutes": 事件的时长分钟数，不是事件就填 0,
          "priority": "high 或 normal 或 low",
          "remind_before_minutes": 用户明确说了提前多久提醒就填分钟数（“提前半小时提醒我”填 30），没提就填 0
        }
      ]
    }

    规则：
    1. kind 决定这条东西最后存到哪儿，判错了用户就找不到它，所以按下面的分工来选：
       - notification → 只是在某个时刻响一下，不写进提醒事项。用在「短时间内的、一次性的提醒」：几分钟到几小时后弹一次就够，不需要事后回来打勾。像「10 分钟后提醒我给供应商打电话」「一小时后叫我」「下午三点提醒我打个电话」。这类**必须**有明确时刻，没有时刻的不要判成 notification。
       - todo → 写进提醒事项。需要跟踪完成状态的事，或者时间比较远的事（「这周五之前把报价单发给采购」）。没写时间的也归这里。
       - event → 写进日历。要占用一段时间的事（会议、约人、饭局、出差），有开始时间和时长。
       - note → 只是信息，不需要行动（账号、地址、名言、别人的话）。
       拿不准时问自己：用户事后会回来打勾吗？会的话是 todo；只是想让它在某刻响一下，就是 notification。
       照片（白板、便签、纸质笔记）里的内容通常是要做的事，除非明确只是信息，否则判成 todo，不要判成 note——用户拍照基本是想让自己记得去做。
    2. 一切时间换算都以用户在消息里给出的【现在】为准，那是带时刻的真实当前时间，不是随便挑的。相对表达必须算出绝对时间：“明天下午三点”“下周三”“月底前”都要变成具体日期，不要保留原文。
    3. “10分钟后”“半小时后”这类相对当前时刻的表达，除了在 due_date 里算出绝对时间，还要在 due_in_minutes 里填上那个分钟数。两个都要对得上。
    4. 一句话里包含多件事就拆成多条；同一件事不要拆开。
    5. title 要写成动作句（如“把方案改完发给老王”），不要只写名词。
    6. 绝不编造原文里没有的时间、人名、优先级。不确定就把对应字段留空。时间一律基于【现在】推算，不要凭空给一个时刻。
    7. 如果整段内容里没有任何可执行的事，返回 {"items": []}。
    8. 如果带了图片，先把图里的内容读出来（可能是白板照片、纸质笔记、聊天截图、名片、手写便签），把其中提到的待办、时间、人名一并抽取。用户只发一张图、没配文字时，图里的内容就是全部输入，不要因为用户没打字就返回空数组：图里哪怕只有一句“明天交周报”，也要抽成一条待办。图里的字看不清就不要猜，宁可不抽。
    9. 如果用户是在改上一条结果（比如“第二条改成周五下午”“不要第一条了”），要结合【最近的对话】里已经列出的条目，把改完之后的完整清单重新输出一遍，不要只输出改动的那一条，也不要漏掉没被改动的条目。
    """

    /// 调一次模型，把 text（可附图）拆成条目。
    /// history 是最近的对话摘要，用来让“第二条改成周五”这类追问能接上上文。
    static func parse(text: String,
                      images: [String] = [],
                      history: String = "",
                      config: LLMConfig) async throws -> [ParsedItem] {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections = ["现在是 \(nowDescription())。"]
        if !history.isEmpty {
            sections.append("【最近的对话】\n\(history)")
        }
        sections.append("需要抽取的内容：\n\(body.isEmpty ? "（内容见附图）" : body)")
        let user = sections.joined(separator: "\n\n")

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

    /// 给模型的“现在”。
    ///
    /// 必须带上时刻和时区，只给日期是过去那个版本最大的坑：
    /// 「10 分钟后提醒我」没有基准时刻可算，模型只能自己编一个时间出来。
    static func nowDescription() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        let zone = TimeZone.current
        let hours = zone.secondsFromGMT() / 3600
        let sign = hours >= 0 ? "+" : "-"
        return "\(df.string(from: Date()))（\(zone.identifier)，UTC\(sign)\(abs(hours))）"
    }

    /// 相对当前时刻的分钟数 → "yyyy-MM-dd HH:mm"。
    /// 这条路径不经过模型，是「10 分钟后」这类表达的最后一道保险：
    /// 模型的算术能力靠不住，但客户端取当前时间做加法是准的。
    static func absoluteDate(afterMinutes minutes: Int, from base: Date = Date()) -> String {
        let target = base.addingTimeInterval(TimeInterval(minutes) * 60)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df.string(from: target)
    }

    // MARK: - 解析

    /// 手解 JSON 而不是用 Codable：
    /// 各家网关的返回字段经常有增减，手解能容忍缺字段，报错也能直接带出原文。
    static func decode(_ raw: String) throws -> [ParsedItem] {
        let cleaned = stripCodeFence(raw)
        guard let obj = jsonObject(from: cleaned) else {
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

            var dueDate = ((dict["due_date"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let relative = (dict["due_in_minutes"] as? Int) ?? (dict["due_in_minutes"] as? NSNumber)?.intValue ?? -1
            // 只认正数：字段缺省是 -1，但模型也可能随手填 0（「没有相对时间」写成 0 很常见）。
            // 要是把 0 当成「0 分钟后」，一条写着「10月8日交报告」的待办会被改成「现在」，
            // 比不换算还糟——这是之前覆盖得最狠的一处。
            if relative > 0 {
                // “10 分钟后”这种不采信模型算出来的绝对值，本地按当前时刻重算一遍。
                // 模型的时间算术错得很有规律（常常是拿日期当零点），错的又正好是最要紧的那条。
                let fixed = absoluteDate(afterMinutes: relative)
                if fixed != dueDate {
                    AppLog.info("AI", "相对时间本地重算：模型给「\(dueDate)」→ 实为「\(fixed)」（\(relative) 分钟后）")
                }
                dueDate = fixed
            }

            let remindBefore = (dict["remind_before_minutes"] as? Int) ?? (dict["remind_before_minutes"] as? NSNumber)?.intValue ?? 0

            return ParsedItem(
                kind: kind,
                title: title,
                notes: (dict["notes"] as? String) ?? "",
                dueDate: dueDate,
                durationMinutes: duration,
                priority: ((dict["priority"] as? String) ?? "normal").lowercased(),
                remindBeforeMinutes: max(0, remindBefore)
            )
        }
        for item in items {
            AppLog.info("AI", "条目 \(item.kind.rawValue)「\(item.title)」时间=\(item.dueDate.isEmpty ? "无" : item.dueDate) 提前提醒=\(item.remindBeforeMinutes)分")
        }
        return items
    }

    /// 从模型返回里挖出那个 JSON 对象。
    ///
    /// 先按整段解析；不行就退一步找第一个 `{` 到最后一个 `}`。
    /// 带图的时候不会发 response_format（有些网关不接受它和多模态同时出现），
    /// 模型偶尔会在 JSON 前面加一句「好的，图里是这些：」，那种情况下这层兜底就是必需的。
    static func jsonObject(from text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return obj
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
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
