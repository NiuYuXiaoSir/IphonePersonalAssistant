import SwiftUI

/// 会议列表。
///
/// 版式照元宝的列表页：大标题 → 搜索框 → 一整块「开始记录会议」的蓝字卡片 →
/// 一行灰色说明 → 「历史记录」分组。分组内部是 年 → 月 → 日 三级折叠，
/// 一天最多一两场会，平铺一长条不好找；默认只展开离现在最近的那一天。
struct MeetingsView: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var history = YBSearchHistory.meetings

    @State private var path: [String] = []
    @State private var showRecorder = false
    @State private var query = ""
    @State private var showingSearch = false
    @FocusState private var searchFocused: Bool
    @State private var expanded: Set<String> = []
    @State private var didPrimeExpansion = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                searchRow
                if searchActive {
                    searchResultsContent
                } else {
                    homeContent
                }
            }
            .ybPageList()
            .navigationTitle("会议")
            .navigationDestination(for: String.self) { id in
                MeetingDetailView(meetingID: id)
            }
            .fullScreenCover(isPresented: $showRecorder) {
                RecordView()
            }
            .onChange(of: searchFocused) { _, focused in
                if focused { showingSearch = true }
            }
            .onAppear {
                primeExpansion()
                consumeShortcut()
            }
            .onChange(of: router.pending) { _, _ in consumeShortcut() }
        }
    }

    /// 长按图标点了「开始录音」：直接把这个页面的录音页拉起来
    private func consumeShortcut() {
        guard router.pending == .record else { return }
        router.pending = nil
        DispatchQueue.main.async { showRecorder = true }
    }

    // MARK: - 搜索

    private var searchActive: Bool {
        showingSearch || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchRow: some View {
        HStack(spacing: 12) {
            YBSearchField(placeholder: "搜索标题或会议文字",
                          text: $query,
                          focused: $searchFocused,
                          onSubmit: { history.add(trimmedQuery) })
            if searchActive {
                Button("取消") { cancelSearch() }
                    .font(.system(size: 16))
                    .foregroundStyle(YBColor.accent)
            }
        }
        .padding(.top, 4)
        .ybRow()
    }

    private func cancelSearch() {
        searchFocused = false
        showingSearch = false
        query = ""
    }

    @ViewBuilder
    private var searchResultsContent: some View {
        if trimmedQuery.isEmpty {
            if !history.items.isEmpty {
                Section {
                    historyChips
                } header: {
                    YBPinnedHeader("历史记录") {
                        Button {
                            history.clear()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15))
                                .foregroundStyle(YBColor.textSecondary)
                        }
                        .buttonStyle(YBPressStyle())
                    }
                }
            }
        } else {
            if searchResults.isEmpty {
                Section {
                    YBHint(text: "没有匹配「\(trimmedQuery)」的记录。搜索会同时匹配标题和会议文字。",
                           icon: "magnifyingglass")
                        .padding(.top, 12)
                        .ybRow(horizontal: 0)
                }
            } else {
                // 搜索时 displayRows 给的就是搜索结果，用它而不是 searchResults——
                // 前者已经摊平成 DisplayRow（带首尾圆角），直接就能画
                let rows = displayRows
                Section {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                } header: {
                    YBPinnedHeader("找到 \(rows.count) 场")
                }
            }
        }
    }

    private var historyChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(history.items, id: \.self) { keyword in
                    YBTag(text: keyword) {
                        query = keyword
                        history.add(keyword)
                    }
                }
            }
            .padding(.horizontal, YBMetric.pagePad)
            .padding(.bottom, YBMetric.rowGap)
        }
        .ybRow(horizontal: 0)
    }

    // MARK: - 正常态

    @ViewBuilder
    private var homeContent: some View {
        Section {
            YBActionCard(title: "开始记录会议", icon: "record.circle") {
                showRecorder = true
            }
            .padding(.top, 4)
            .ybRow()

            YBHint(text: "点一下就开始录音，然后可以把手机锁屏放桌上。每分钟自动存一段，即使本应用被系统回收也只会丢最后一段。")
                .ybRow(horizontal: 0)
        }

        Section {
            if displayRows.isEmpty {
                YBRow(title: "还没有会议记录",
                      subtitle: "点上面的「开始记录会议」录第一场。",
                      position: .only)
                    .ybRow(bottom: YBMetric.rowGap)
            } else {
                ForEach(displayRows) { row in
                    rowView(row)
                }
            }

            YBHint(text: historyFooter)
                .ybRow(horizontal: 0)
                .padding(.bottom, 24)
        } header: {
            // 滚动时钉在顶上，和「对话」列表里的今天/本月一个行为
            YBPinnedHeader("历史记录")
        }
    }

    private var historyFooter: String {
        var text = "音频占用 \(formatBytes(store.storageBytes()))。左滑一条记录可以连同音频一起删掉。"
        if !displayRows.isEmpty { text += "点年份、月份可以一层层展开或收起。" }
        return text
    }

    // MARK: - 行的组装
    //
    // 折叠状态下哪些行出现是会变的，所以先把要显示的行摊平成一个数组，
    // 再回头给首尾两行标上圆角。这样卡片的分隔线和圆角永远是对的。

    private struct DisplayRow: Identifiable {
        var id: String
        var title: String
        var subtitle: String?
        var detail: String?
        var icon: String?
        var indent: CGFloat
        var chevron: String?
        var position: YBRowPosition = .middle
        var groupID: String?
        var meetingID: String?

        init(groupID: String, title: String, detail: String, icon: String,
             indent: CGFloat, chevron: String) {
            self.id = groupID
            self.groupID = groupID
            self.title = title
            self.detail = detail
            self.icon = icon
            self.indent = indent
            self.chevron = chevron
            self.subtitle = nil
            self.meetingID = nil
        }

        init(meetingID: String, title: String, subtitle: String, indent: CGFloat) {
            self.id = meetingID
            self.meetingID = meetingID
            self.title = title
            self.subtitle = subtitle
            self.detail = nil
            self.icon = nil
            self.indent = indent
            self.chevron = "chevron.right"
            self.groupID = nil
        }
    }

    private var displayRows: [DisplayRow] {
        var rows: [DisplayRow] = []

        if searchActive {
            for meeting in searchResults {
                rows.append(DisplayRow(meetingID: meeting.id,
                                       title: meeting.title,
                                       subtitle: metaLine(meeting),
                                       indent: 0))
            }
        } else if !tree.isEmpty {
            for year in tree {
                rows.append(DisplayRow(groupID: year.id,
                                       title: "\(year.year) 年",
                                       detail: "\(year.count) 场 · \(RecordingService.durationText(year.duration))",
                                       icon: "calendar",
                                       indent: 0,
                                       chevron: isExpanded(year.id) ? "chevron.up" : "chevron.down"))
                if isExpanded(year.id) {
                    for month in year.months {
                        rows.append(DisplayRow(groupID: month.id,
                                               title: "\(month.month) 月",
                                               detail: "\(month.count) 场",
                                               icon: "folder",
                                               indent: 16,
                                               chevron: isExpanded(month.id) ? "chevron.up" : "chevron.down"))
                        if isExpanded(month.id) {
                            for day in month.days {
                                rows.append(DisplayRow(groupID: day.id,
                                                       title: dayLabel(day.date),
                                                       detail: "\(day.meetings.count) 场 · \(RecordingService.durationText(day.duration))",
                                                       icon: "clock",
                                                       indent: 32,
                                                       chevron: isExpanded(day.id) ? "chevron.up" : "chevron.down"))
                                if isExpanded(day.id) {
                                    for meeting in day.meetings {
                                        rows.append(DisplayRow(meetingID: meeting.id,
                                                               title: meeting.title,
                                                               subtitle: metaLine(meeting),
                                                               indent: 46))
                                    }
                                }
                            }
                        }
                    }
                }
            }

            rows.append(DisplayRow(groupID: Self.collapseID,
                                   title: allExpanded ? "收起分组" : "展开分组",
                                   detail: "",
                                   icon: "folder",
                                   indent: 0,
                                   chevron: allExpanded ? "chevron.up" : "chevron.down"))
        }

        let count = rows.count
        for index in rows.indices {
            rows[index].position = Self.position(index: index, count: count)
        }
        return rows
    }

    @ViewBuilder
    private func rowView(_ row: DisplayRow) -> some View {
        if let meetingID = row.meetingID {
            YBRow(title: row.title,
                  subtitle: row.subtitle,
                  indent: row.indent,
                  chevron: row.chevron,
                  position: row.position) {
                path.append(meetingID)
            }
            .swipeActions {
                Button(role: .destructive) {
                    if let meeting = store.meeting(id: meetingID) { store.delete(meeting) }
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .ybRow(bottom: row.position == .last ? YBMetric.rowGap : 0)
        } else {
            YBRow(title: row.title,
                  detail: row.detail,
                  icon: row.icon,
                  indent: row.indent,
                  chevron: row.chevron,
                  position: row.position) {
                if row.groupID == Self.collapseID {
                    if allExpanded { expanded.removeAll() } else { expanded = allGroupIDs }
                } else if let groupID = row.groupID {
                    toggle(groupID)
                }
            }
            .ybRow(bottom: row.position == .last ? YBMetric.rowGap : 0)
        }
    }

    private static let collapseID = "__collapse__"

    private static func position(index: Int, count: Int) -> YBRowPosition {
        if count <= 1 { return .only }
        if index == 0 { return .first }
        if index == count - 1 { return .last }
        return .middle
    }

    /// 一行灰字说清这场会的关键信息，比挂一排彩色小标签安静得多
    private func metaLine(_ m: Meeting) -> String {
        var parts = [timeText(m.startedAt), "录到 " + RecordingService.durationText(m.durationSeconds)]
        if let gap = m.gapSeconds, gap > 0.5 {
            parts.append("漏录 " + RecordingService.durationText(gap))
        }
        if !m.segments.isEmpty { parts.append("\(m.segments.count) 段") }
        if !m.transcript.isEmpty { parts.append("\(m.transcript.count) 字") }
        if !m.summaryJSON.isEmpty { parts.append("有纪要") }
        if m.status == "recovered" { parts.append("意外中断，已恢复") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 展开状态

    private func isExpanded(_ id: String) -> Bool {
        searchActive || expanded.contains(id)
    }

    private func toggle(_ id: String) {
        // 搜索时强制全展开，免得搜索结果藏在折叠节点里
        guard !searchActive else { return }
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    private var allGroupIDs: Set<String> {
        var ids: Set<String> = []
        for year in tree {
            ids.insert(year.id)
            for month in year.months {
                ids.insert(month.id)
                for day in month.days { ids.insert(day.id) }
            }
        }
        return ids
    }

    private var allExpanded: Bool {
        let ids = allGroupIDs
        return !ids.isEmpty && ids.isSubset(of: expanded)
    }

    /// 首次显示时展开离现在最近的那一天，让列表一打开就有内容可看
    private func primeExpansion() {
        guard !didPrimeExpansion, let newest = store.meetings.first else { return }
        didPrimeExpansion = true
        expanded = [yearID(newest.startedAt), monthID(newest.startedAt), dayID(newest.startedAt)]
    }

    // MARK: - 数据

    private var searchResults: [Meeting] {
        let keyword = trimmedQuery
        guard !keyword.isEmpty else { return store.meetings }
        return store.meetings.filter {
            $0.title.localizedCaseInsensitiveContains(keyword)
                || $0.transcript.localizedCaseInsensitiveContains(keyword)
        }
    }

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
        let meetings = searchActive ? searchResults : store.meetings
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

    // MARK: - 日期文案

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

    private static let idFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return Self.dayFormatter.string(from: date)
    }

    private func timeText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天 " + Self.timeFormatter.string(from: date) }
        if calendar.isDateInYesterday(date) { return "昨天 " + Self.timeFormatter.string(from: date) }
        return Self.dayFormatter.string(from: date) + " " + Self.timeFormatter.string(from: date)
    }

    private func dayID(_ date: Date) -> String { Self.idFormatter.string(from: date) }
    private func monthID(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        return "y\(comps.year ?? 0)-m\(comps.month ?? 0)"
    }
    private func yearID(_ date: Date) -> String {
        "y\(Calendar.current.component(.year, from: date))"
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}

#Preview {
    MeetingsView().environmentObject(MeetingStore())
}
