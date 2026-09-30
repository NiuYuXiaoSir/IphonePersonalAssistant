import SwiftUI

/// 会议列表：按「年 → 月 → 日」三层折叠，默认只展开离现在最近的那一天。
///
/// 一天最多一两场会，一层层压下去比平铺一长条好找：找上个月的会先点开月份，
/// 找去年的会先点开年份，不用一路往下滚。
struct MeetingsView: View {
    @EnvironmentObject private var store: MeetingStore

    @State private var showRecorder = false
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var didPrimeExpansion = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showRecorder = true
                    } label: {
                        Label("开始记录会议", systemImage: "record.circle")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 6)
                    }
                } footer: {
                    Text("点一下就开始录音，然后可以把手机锁屏放桌上。每分钟自动存一段，即使 App 被系统回收也只会丢最后一段。")
                }

                if filtered.isEmpty {
                    emptySection
                } else {
                    ForEach(tree) { year in
                        yearSection(year)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("会议")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索标题或会议文字")
            .navigationDestination(for: String.self) { id in
                MeetingDetailView(meetingID: id)
            }
            .fullScreenCover(isPresented: $showRecorder) {
                RecordView()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !tree.isEmpty {
                        Menu {
                            Button("全部展开") { expandAll() }
                            Button("全部收起") { expanded.removeAll() }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                    }
                }
            }
            .onAppear(perform: primeExpansion)
        }
    }

    // MARK: - 区块

    @ViewBuilder
    private var emptySection: some View {
        Section {
            if query.isEmpty {
                Text("还没有会议记录")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("没有匹配「\(query)」的记录")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("历史记录")
        } footer: {
            if !query.isEmpty {
                Text("搜索会同时匹配标题和会议文字。")
            } else if !store.meetings.isEmpty {
                Text("音频占用 \(formatBytes(store.storageBytes()))。")
            }
        }
    }

    private func yearSection(_ year: YearNode) -> some View {
        DisclosureGroup(isExpanded: expansion(year.id)) {
            ForEach(year.months) { month in
                monthSection(month)
            }
        } label: {
            groupLabel(title: "\(year.year) 年",
                       detail: "\(year.count) 场 · \(RecordingService.durationText(year.duration))",
                       bold: true)
        }
    }

    private func monthSection(_ month: MonthNode) -> some View {
        DisclosureGroup(isExpanded: expansion(month.id)) {
            ForEach(month.days) { day in
                daySection(day)
            }
        } label: {
            groupLabel(title: "\(month.month) 月",
                       detail: "\(month.count) 场",
                       bold: false)
        }
    }

    private func daySection(_ day: DayNode) -> some View {
        DisclosureGroup(isExpanded: expansion(day.id)) {
            ForEach(day.meetings) { meeting in
                NavigationLink(value: meeting.id) {
                    meetingRow(meeting)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        store.delete(meeting)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        } label: {
            groupLabel(title: dayLabel(day.date),
                       detail: "\(day.meetings.count) 场 · \(RecordingService.durationText(day.duration))",
                       bold: false)
        }
    }

    private func groupLabel(title: String, detail: String, bold: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(bold ? .subheadline.weight(.semibold) : .subheadline)
            Spacer()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func meetingRow(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(m.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            HStack(spacing: 6) {
                chip(RecordingService.durationText(m.durationSeconds), icon: "clock")
                chip("\(m.segments.count) 段", icon: "waveform")
                if !m.transcript.isEmpty {
                    chip("\(m.transcript.count) 字", icon: "text.alignleft")
                }
                if !m.summaryJSON.isEmpty {
                    chip("纪要", icon: "wand.and.stars")
                }
            }

            HStack(spacing: 6) {
                Text(timeText(m.startedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if m.status == "recovered" {
                    Text("意外中断，已恢复")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func chip(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 11))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .foregroundStyle(.secondary)
    }

    // MARK: - 展开状态

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { searchActive || expanded.contains(id) },
            set: { newValue in
                // 搜索时强制全展开，免得搜索结果藏在折叠节点里
                guard !searchActive else { return }
                if newValue { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    /// 首次显示时展开离现在最近的那一天，让列表一打开就有内容可看
    private func primeExpansion() {
        guard !didPrimeExpansion, let newest = store.meetings.first else { return }
        didPrimeExpansion = true
        expanded = [yearID(newest.startedAt), monthID(newest.startedAt), dayID(newest.startedAt)]
    }

    private func expandAll() {
        var ids: Set<String> = []
        for year in tree {
            ids.insert(year.id)
            for month in year.months {
                ids.insert(month.id)
                for day in month.days { ids.insert(day.id) }
            }
        }
        expanded = ids
    }

    // MARK: - 数据

    private var searchActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filtered: [Meeting] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let meetings = filtered
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
