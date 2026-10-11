import Foundation

/// 查「未完成的事项」时能选的时间范围。
///
/// 五档都在「过去」这一侧：这个功能是**回头看落了什么**，不是查未来
/// （未来的那些在「安排 → 待弹的通知」里）。
/// 档位数量和标签按 HIG 的 Segmented controls 页来：iPhone 上
/// 「Aim for no more than… about five segments on iPhone」，而且标签要用
/// 「nouns or noun phrases」、各段长短尽量一致——所以是五个短词，不是五句话。
enum UnfinishedRange: String, CaseIterable, Identifiable {
    case yesterday
    case threeDays
    case week
    case month
    case threeMonths

    var id: String { rawValue }

    /// 分段控件上的标签（短、长度接近）
    var label: String {
        switch self {
        case .yesterday:   return "昨天"
        case .threeDays:   return "三天内"
        case .week:        return "一周内"
        case .month:       return "一个月"
        case .threeMonths: return "三个月"
        }
    }

    /// 这个范围到底是哪一段。返回的是**开区间上界**（`end` 那一刻不算在内）。
    ///
    /// 「三天内」这种说法各人有各人的理解，所以界面上会把算出来的日期摊开写出来
    /// （见 `text()`），而不是只写「三天内」让人猜。
    func interval(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .yesterday:
            // 昨天那一整天：今天零点就是它的上界
            let start = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            return (start, today)
        case .threeDays:
            // 今天 + 前两天
            let start = calendar.date(byAdding: .day, value: -2, to: today) ?? today
            return (start, now)
        case .week:
            let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            return (start, now)
        case .month:
            // 按日历月算（9月11日 起），不是「30 天」——「一个月」就是一个月
            let start = calendar.date(byAdding: .month, value: -1, to: today) ?? today
            return (start, now)
        case .threeMonths:
            let start = calendar.date(byAdding: .month, value: -3, to: today) ?? today
            return (start, now)
        }
    }

    /// 「昨天（10月10日）」「10月5日 – 今天」这种说法
    func text(now: Date = Date(), calendar: Calendar = .current) -> String {
        let (start, _) = interval(now: now, calendar: calendar)
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        switch self {
        case .yesterday: return "昨天（\(f.string(from: start))）"
        default:         return "\(f.string(from: start)) – 今天"
        }
    }
}

/// 本地筛出来的「还没完成」的东西。
///
/// 三类分开装，界面上也分开显示——它们的性质不一样：
/// 逾期的要处理、没时间的是一直挂着的、计划里的要先确认到底做没做。
struct UnfinishedDigest {

    /// 安排里到点了还没打勾的（按到点时刻从早到晚）
    var overdue: [AssistantItem] = []
    /// 安排里没设时间的（备忘不算，那本来就不用做）
    var timeless: [AssistantItem] = []
    /// 记忆流水里写着「打算做」、但看不出做完的
    var plans: [MemoryLog] = []

    var isEmpty: Bool { overdue.isEmpty && timeless.isEmpty && plans.isEmpty }

    var total: Int { overdue.count + timeless.count + plans.count }

    /// 这份清单的「签名」：只取每条的身份和它自己的状态，**不含**「已过几小时」这种
    /// 随时间变的文字。整理结果就是拿它判断要不要重新问模型的——过了一个钟头
    /// 材料里的时长会变，但清单其实没变，不该为此再花一次 token。
    var signature: String {
        let a = overdue.map { "\($0.id)#\($0.updatedAt.timeIntervalSince1970)" }
        let b = timeless.map { "\($0.id)#\($0.updatedAt.timeIntervalSince1970)" }
        let c = plans.map { "\($0.id)#\($0.day)" }
        return (a + b + c).joined(separator: "|")
    }

    /// 给模型看的那份材料：一行一条，带原定时间、「已过多久」和类型。
    /// 有时间差它才能按「最该先办的排前面」重排（这段格式 HIG 没有规定，是工程判断）。
    func material(now: Date = Date()) -> String {
        var sections: [String] = []

        if !overdue.isEmpty {
            let lines = overdue.map { item -> String in
                var parts = ["- \(item.title)"]
                if let due = item.dueAt { parts.append("原定 \(ItemTimeText.when(due))") }
                if let fire = item.fireDate, fire < now { parts.append(ItemTimeText.relative(fire)) }
                parts.append(item.kind.label)
                if !item.notes.isEmpty { parts.append("备注：\(String(item.notes.prefix(60)))") }
                return parts.joined(separator: "｜")
            }
            sections.append("【安排：到点了还没打勾】\n" + lines.joined(separator: "\n"))
        }

        if !timeless.isEmpty {
            let lines = timeless.map { item -> String in
                var parts = ["- \(item.title)"]
                parts.append(item.kind.label)
                if !item.notes.isEmpty { parts.append("备注：\(String(item.notes.prefix(60)))") }
                return parts.joined(separator: "｜")
            }
            sections.append("【安排：没设时间、一直挂着的】\n" + lines.joined(separator: "\n"))
        }

        if !plans.isEmpty {
            let lines = plans.map { log -> String in
                "- \(MemoryStore.dayLabel(log.day, now: now))：\(log.content)"
            }
            sections.append("【记忆里写着「打算做」的】\n" + lines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }
}

/// 「未完成」的本地查询。
///
/// 先在本地筛一遍、再让模型整理**这一份筛出来的文本**——顺序反过来的话，
/// 模型既不知道库里有什么、也不该拿到整库数据。本地这一步不联网、不花 token，
/// 所以没配密钥、断网的时候这张原始清单照样能看（这是这个功能的下限）。
enum UnfinishedQuery {

    static func run(range: UnfinishedRange,
                    now: Date = Date(),
                    items: [AssistantItem] = ItemStore.shared.items,
                    logs: [MemoryLog] = MemoryStore.shared.logs) -> UnfinishedDigest {
        let (start, end) = range.interval(now: now)
        var digest = UnfinishedDigest()

        for item in items {
            // 备忘不用做、重复提醒是常设的（不是「这一次没做完」），都不算
            guard !item.isDone, item.kind != .note, !item.isRepeating else { continue }

            guard let due = item.dueAt else {
                digest.timeless.append(item)
                continue
            }
            guard due >= start, due < end else { continue }
            // 过了点才算「没做完」：今晚才到点的，现在还谈不上没做
            if let fire = item.fireDate, fire < now {
                digest.overdue.append(item)
            }
        }
        digest.overdue.sort { ($0.fireDate ?? .distantPast) < ($1.fireDate ?? .distantPast) }
        digest.timeless.sort { $0.createdAt < $1.createdAt }

        // 流水按天存的是 "yyyy-MM-dd"，直接当字符串比大小；上界是开区间，减一秒落回所属的那天
        let startDay = MemoryStore.dayString(start)
        let endDay = MemoryStore.dayString(end.addingTimeInterval(-1))
        let dones = logs.filter { $0.kind == .done }.map { (day: $0.day, content: $0.content) }
        digest.plans = logs.filter { log in
            guard log.kind == .plan, log.day >= startDay, log.day <= endDay else { return false }
            // 那一天或之后说过「做了」的，就不再算没完成（内容一样才算同一条）
            return !dones.contains { $0.day >= log.day && $0.content == log.content }
        }.sorted { lhs, rhs in
            lhs.day == rhs.day ? lhs.at < rhs.at : lhs.day < rhs.day
        }

        return digest
    }
}

/// 整理结果的小缓存（存在 UserDefaults 里，退出 App 也在）。
///
/// 为什么要缓存：这个功能可能一天开好几次（随手翻一下），每次都问一遍模型是在烧钱。
/// 缓存里连同**当时那份清单的签名**一起存着——它和现在筛出来的一样，
/// 就说明本地清单没变（没打勾、没加新条目、没改时间），那次整理的话还能用；
/// 变了就重新问，不拿一份过期的话骗人。
struct UnfinishedReportCache: Codable {
    var report: String
    var signature: String
    var askedAt: Date

    private static func key(_ range: UnfinishedRange) -> String {
        "unfinished.report.\(range.rawValue)"
    }

    static func load(_ range: UnfinishedRange) -> UnfinishedReportCache? {
        guard let data = UserDefaults.standard.data(forKey: key(range)) else { return nil }
        return try? JSONDecoder().decode(UnfinishedReportCache.self, from: data)
    }

    func save(for range: UnfinishedRange) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(range))
    }
}

