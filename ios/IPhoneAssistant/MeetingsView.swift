import SwiftUI

/// 会议列表。
///
/// 默认是**时间轴**（今天 / 昨天 / 本周 / 更早）：会议这个量级，「打开最近那场」是高频动作，
/// 年月日那棵树留在「归档」视图里（右上角切），要按时间考古的时候再进去。
///
/// 版式用系统 List + 系统搜索：分组、吸顶、取消按钮、键盘收起、无障碍都是系统给的。
/// 删除是「撤下 + 撤销」，不再弹确认框——有了撤销，确认只是白打断一次。
struct MeetingsView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var history = SearchHistory.meetings

    @State private var path: [String] = []
    @State private var showRecorder = false
    @State private var query = ""
    @State private var mode: ViewMode = .timeline
    @State private var expanded: Set<String> = []
    @State private var undoMessage = ""

    private enum ViewMode: String, CaseIterable, Identifiable {
        case timeline, archive

        var id: String { rawValue }
        var title: String { self == .timeline ? "时间轴" : "按年月归档" }
    }

    var body: some View {
        NavigationStack(path: $path) {
            listContent
            .navigationTitle("会议")
            // 搜索历史走系统的搜索建议：点一下直接填进搜索框
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "搜索标题或会议文字")
            .searchSuggestions {
                if query.isEmpty {
                    ForEach(history.items, id: \.self) { keyword in
                        Label(keyword, systemImage: "clock.arrow.circlepath")
                            .searchCompletion(keyword)
                    }
                }
            }
            .onSubmit(of: .search) { history.add(query) }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        router.showQuickAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("记一条")

                    Menu {
                        Picker("视图", selection: $mode) {
                            ForEach(ViewMode.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("切换列表视图")
                }
            }
            .navigationDestination(for: String.self) { id in
                MeetingDetailView(meetingID: id)
            }
            .fullScreenCover(isPresented: $showRecorder) {
                RecordView()
            }
            .onAppear(perform: consumeShortcut)
            .onChange(of: router.pending) { _, _ in consumeShortcut() }
            .onChange(of: store.recentlyDetached?.id) { _, _ in
                if let meeting = store.recentlyDetached {
                    undoMessage = "已删除「\(meeting.title)」"
                }
            }
            .toast($undoMessage,
                   actionTitle: "撤销",
                   duration: 4,
                   onExpire: { store.commitDetach() },
                   action: { store.undoDetach() })
            .sensoryFeedback(.warning, trigger: store.recentlyDetached?.id) { _, _ in settings.hapticsEnabled }
        }
    }

    /// 列表内容单独拎出来：body 里那一大坨表达式会让编译器算不动
    /// （报错原文：unable to type-check this expression in reasonable time）
    @ViewBuilder
    private var listContent: some View {
        List {
            if !searching { recordSection }
            if searching {
                searchSection
            } else if mode == .timeline {
                timelineSections
            } else {
                archiveSection
            }
            infoSection
        }
    }

    /// 长按图标点了「开始录音」：直接把这个页面的录音页拉起来
    private func consumeShortcut() {
        guard router.pending == .record else { return }
        router.pending = nil
        DispatchQueue.main.async { showRecorder = true }
    }

    // MARK: - 主操作

    private var recordSection: some View {
        Section {
            Button {
                showRecorder = true
            } label: {
                Label("开始记录会议", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
        } footer: {
            Text("点一下就开始录音，锁屏也能录。每分钟自动存一段，即使本应用被系统回收也只会丢最后一段。")
        }
    }

    // MARK: - 搜索

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchResults: [Meeting] {
        let keyword = trimmedQuery
        guard !keyword.isEmpty else { return store.meetings }
        return store.meetings.filter {
            $0.title.localizedCaseInsensitiveContains(keyword)
                || $0.transcript.localizedCaseInsensitiveContains(keyword)
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        let results = searchResults
        if results.isEmpty {
            ContentUnavailableView.search(text: trimmedQuery)
                .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(results) { meeting in
                    row(meeting)
                }
            } header: {
                Text("找到 \(results.count) 场")
            } footer: {
                Text("搜索会同时匹配标题和会议文字。")
            }
        }
    }

    // MARK: - 时间轴

    @ViewBuilder
    private var timelineSections: some View {
        if store.meetings.isEmpty {
            ContentUnavailableView {
                Label("还没有会议记录", systemImage: "waveform")
            } description: {
                Text("点上面的「开始记录会议」录第一场。")
            }
            .listRowBackground(Color.clear)
        } else {
            ForEach(Bucket.allCases) { bucket in
                let list = store.meetings.filter { bucket.contains($0.startedAt) }
                if !list.isEmpty {
                    Section(bucket.title) {
                        ForEach(list) { meeting in
                            row(meeting, showDate: bucket.showsFullDate)
                        }
                    }
                }
            }
        }
    }

    /// 时间分段：本周和更早都是相对「今天」算的，不和月份挂钩
    private enum Bucket: String, CaseIterable, Identifiable {
        case today, yesterday, thisWeek, thisMonth, earlier

        var id: String { rawValue }

        var title: String {
            switch self {
            case .today:     return "今天"
            case .yesterday: return "昨天"
            case .thisWeek:  return "本周"
            case .thisMonth: return "本月"
            case .earlier:   return "更早"
            }
        }

        /// 分组标题已经把日子说清楚了（今天/昨天），行里就不用再报一遍日期
        var showsFullDate: Bool {
            self != .today && self != .yesterday
        }

        func contains(_ date: Date) -> Bool {
            let calendar = Calendar.current
            let inThisWeek: Bool = {
                guard let week = calendar.dateInterval(of: .weekOfYear, for: Date()) else { return false }
                return week.contains(date)
            }()
            switch self {
            case .today:
                return calendar.isDateInToday(date)
            case .yesterday:
                return calendar.isDateInYesterday(date)
            case .thisWeek:
                return inThisWeek && !calendar.isDateInToday(date) && !calendar.isDateInYesterday(date)
            case .thisMonth:
                // 本周之外的、本月的：光有「本周」不够——周日的手机上看，周四那场会
                // 掉进「更早」显得很怪（其实才三天前）
                return calendar.isDate(date, equalTo: Date(), toGranularity: .month) && !inThisWeek
            case .earlier:
                return !calendar.isDate(date, equalTo: Date(), toGranularity: .month)
            }
        }
    }

    // MARK: - 归档（年 → 月 → 日）

    @ViewBuilder
    private var archiveSection: some View {
        if tree.isEmpty {
            ContentUnavailableView {
                Label("还没有会议记录", systemImage: "calendar")
            }
            .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(tree) { year in
                    DisclosureGroup(isExpanded: expansion(year.id)) {
                        ForEach(year.months) { month in
                            DisclosureGroup(isExpanded: expansion(month.id)) {
                                ForEach(month.days) { day in
                                    DisclosureGroup(isExpanded: expansion(day.id)) {
                                        ForEach(day.meetings) { meeting in
                                            // 归档视图里分组标题已经写了日期
                                            row(meeting, showDate: false)
                                        }
                                    } label: {
                                        groupLabel(dayLabel(day.date),
                                                   detail: "\(day.meetings.count) 场 · \(RecordingService.durationText(day.duration))")
                                    }
                                }
                            } label: {
                                groupLabel("\(month.month) 月",
                                           detail: "\(month.count) 场 · \(RecordingService.durationText(month.duration))")
                            }
                        }
                    } label: {
                        groupLabel("\(year.year) 年",
                                   detail: "\(year.count) 场 · \(RecordingService.durationText(year.duration))")
                    }
                }
            } header: {
                Text("按年月")
            } footer: {
                Text("一层层展开或收起。平常看「时间轴」就够，这里是为翻旧账准备的。")
            }
        }
    }

    private func groupLabel(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// DisclosureGroup 要 Binding<Bool>，展开状态自己存一份集合
    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOpen in
                if isOpen { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    // MARK: - 一行

    private func row(_ meeting: Meeting, showDate: Bool = true) -> some View {
        NavigationLink(value: meeting.id) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(meeting.title)
                        .font(.body)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text(Self.statusText(meeting))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
                Text(Self.metaLine(meeting, showDate: showDate))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.vertical, 2)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.detach(meeting)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 底部说明

    private var infoSection: some View {
        Section {
            EmptyView()
        } footer: {
            Text("音频占用 \(formatBytes(store.storageBytes()))。左滑一条记录可以删掉，删完有 4 秒可以撤销。")
        }
    }

    // MARK: - 文案

    /// 一行里只说一件事：这场会现在卡在哪一步
    private static func statusText(_ m: Meeting) -> String {
        if m.status == "recovered" { return "意外中断，已恢复" }
        if m.transcript.isEmpty { return "未转写" }
        if m.summaryJSON.isEmpty { return "未纪要" }
        return "已纪要"
    }

    /// 一行灰字说清这场会的关键信息，比挂一排彩色小标签安静得多
    private static func metaLine(_ m: Meeting, showDate: Bool = true) -> String {
        var parts = [showDate ? timeText(m.startedAt) : timeFormatter.string(from: m.startedAt),
                     "录到 " + RecordingService.durationText(m.durationSeconds)]
        if let gap = m.gapSeconds, gap > 0.5 {
            parts.append("漏录 " + RecordingService.durationText(gap))
        }
        if !m.segments.isEmpty { parts.append("\(m.segments.count) 段") }
        if !m.transcript.isEmpty { parts.append("\(m.transcript.count) 字") }
        return parts.joined(separator: " · ")
    }

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日 EEEE"
        return df
    }()

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "HH:mm"
        return df
    }()


    private static func timeText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天 " + timeFormatter.string(from: date) }
        if calendar.isDateInYesterday(date) { return "昨天 " + timeFormatter.string(from: date) }
        return dayFormatter.string(from: date) + " " + timeFormatter.string(from: date)
    }

    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return Self.dayFormatter.string(from: date)
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    // MARK: - 归档分组树

    private struct DayNode: Identifiable {
        let id: String
        let date: Date
        let meetings: [Meeting]
        var duration: Double { meetings.reduce(0) { $0 + $1.durationSeconds } }
    }

    private struct MonthNode: Identifiable {
        let id: String
        let month: Int
        let days: [DayNode]
        var count: Int { days.reduce(0) { $0 + $1.meetings.count } }
        var duration: Double { days.reduce(0) { $0 + $1.duration } }
    }

    private struct YearNode: Identifiable {
        let id: String
        let year: Int
        let months: [MonthNode]
        var count: Int { months.reduce(0) { $0 + $1.count } }
        var duration: Double { months.reduce(0) { $0 + $1.duration } }
    }

    private struct MonthKey: Hashable {
        let year: Int
        let month: Int
    }

    private var tree: [YearNode] {
        let meetings = store.meetings
        guard !meetings.isEmpty else { return [] }
        let calendar = Calendar.current

        // 先把同一天的会议聚在一起，再按 年 → 月 往上卷
        let byDay = Dictionary(grouping: meetings) { calendar.startOfDay(for: $0.startedAt) }

        var months: [MonthKey: [Date: [Meeting]]] = [:]
        for (day, list) in byDay {
            let comps = calendar.dateComponents([.year, .month], from: day)
            let key = MonthKey(year: comps.year ?? 0, month: comps.month ?? 0)
            months[key, default: [:]][day] = list
        }

        var byYear: [Int: [MonthNode]] = [:]
        for (key, dayMap) in months {
            let days = dayMap.keys.sorted(by: >).map { day in
                DayNode(id: dayID(day),
                        date: day,
                        meetings: (dayMap[day] ?? []).sorted { $0.startedAt > $1.startedAt })
            }
            let node = MonthNode(id: "y\(key.year)-m\(key.month)", month: key.month, days: days)
            byYear[key.year, default: []].append(node)
        }

        return byYear.keys.sorted(by: >).map { year in
            YearNode(id: "y\(year)",
                     year: year,
                     months: (byYear[year] ?? []).sorted { $0.month > $1.month })
        }
    }

    private func dayID(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }
}

#Preview {
    MeetingsView()
        .environmentObject(MeetingStore())
        .environmentObject(SettingsStore())
}
