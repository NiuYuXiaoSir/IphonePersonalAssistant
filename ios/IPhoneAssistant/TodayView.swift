import SwiftUI

/// 今日：打开 App 的第一屏。
///
/// 它回答四个问题，都是零点击就能看到的：今天要做什么、今天做了什么、
/// 有没有会要料理、有什么通知还没弹。
/// 数据全在本机（记忆库的 plan/done/note、会议列表、安排表），不申请新权限。
struct TodayView: View {
    @EnvironmentObject private var meetings: MeetingStore
    @EnvironmentObject private var chats: ChatStore
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var memory = MemoryStore.shared
    @ObservedObject private var items = ItemStore.shared
    @ObservedObject private var balance = BalanceStore.shared

    @State private var path = NavigationPath()
    @State private var showRecorder = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                greetingSection
                if let recovered = recentlyRecovered { recoveredSection(recovered) }
                planSection
                doneSection
                meetingSection
                noticeSection
                noteSection
            }
            .navigationTitle("今日")
            .navigationDestination(for: TodayMeetingRoute.self) { route in
                MeetingDetailView(meetingID: route.id)
            }
            .navigationDestination(for: TodayChatRoute.self) { route in
                ChatView(threadID: route.id)
            }
            .navigationDestination(for: TodayScheduleRoute.self) { _ in
                ScheduleView()
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if balance.supports(settings) { balanceChip }
                    Button {
                        router.showQuickAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("记一条")
                }
            }
            .fullScreenCover(isPresented: $showRecorder) { RecordView() }
            .onAppear {
                memory.reload()
                balance.refreshIfStale(settings: settings)
                openScheduleIfRequested()
            }
            .onChange(of: router.showSchedule) { _, _ in openScheduleIfRequested() }
        }
    }

    /// 别处（对话里存下东西之后、点通知本体）请求看「安排」：把请求消费掉并推进去
    private func openScheduleIfRequested() {
        guard router.showSchedule else { return }
        router.showSchedule = false
        path.append(TodayScheduleRoute())
    }

    // MARK: - 问候与主操作

    private var greetingSection: some View {
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

            quickActions
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            Text(greeting)
        }
    }

    private func openChat() {
        let thread = chats.createThread()
        path.append(TodayChatRoute(id: thread.id))
    }

    /// 三个快捷动作。
    ///
    /// `ViewThatFits` 兜底：横排放不下（比如系统字号调到最大）就自动改竖排。
    /// 上一版直接给 Label 加 maxWidth 平分宽度，结果宽度不够时文字被挤成一列竖着排——
    /// 所以每个 Label 都要 `fixedSize()`：宁可让它撑开容器，也不许把字压弯。
    @ViewBuilder
    private var quickActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                quickAction("说一句话", icon: "bubble.left.and.bubble.right", wide: false) { openChat() }
                quickAction("速记", icon: "square.and.pencil", wide: false) { router.showQuickAdd = true }
                quickAction("拍照", icon: "camera", wide: false) { openChat() }
            }
            VStack(alignment: .leading, spacing: 8) {
                quickAction("说一句话", icon: "bubble.left.and.bubble.right", wide: true) { openChat() }
                quickAction("速记", icon: "square.and.pencil", wide: true) { router.showQuickAdd = true }
                quickAction("拍照", icon: "camera", wide: true) { openChat() }
            }
        }
    }

    private func quickAction(_ title: String, icon: String, wide: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: wide ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part: String
        switch hour {
        case 5..<11:  part = "上午好"
        case 11..<14: part = "中午好"
        case 14..<18: part = "下午好"
        default:      part = "晚上好"
        }
        let count = plans.count
        if count == 0 { return "\(part)，今天还没有安排" }
        return "\(part)，今天有 \(count) 件要做"
    }

    // MARK: - 上次的录音找回来了

    private var recentlyRecovered: Meeting? {
        meetings.meetings.first { meeting in
            meeting.status == "recovered"
                && Calendar.current.isDateInToday(meeting.startedAt)
        }
    }

    private func recoveredSection(_ meeting: Meeting) -> some View {
        Section {
            Button {
                path.append(TodayMeetingRoute(id: meeting.id))
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("上次的录音已找回", systemImage: "arrow.clockwise.circle")
                        .foregroundStyle(.orange)
                    Text("\(meeting.title) · 录到 \(RecordingService.durationText(meeting.durationSeconds))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            Text("录音中途被系统回收了，已经录到的部分都还在，去确认一下内容和标题。")
        }
    }

    // MARK: - 今天要做

    @ViewBuilder
    private var planSection: some View {
        if !plans.isEmpty {
            Section("今天要做") {
                ForEach(plans) { log in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(log.content)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                            if log.at > Date() {
                                Text(log.at.formatted(date: .omitted, time: .shortened))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - 今天的流水

    @ViewBuilder
    private var doneSection: some View {
        if !doneLogs.isEmpty {
            Section("今天的流水") {
                ForEach(doneLogs) { log in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: log.kind.symbol)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                            .padding(.top, 3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(log.content)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(log.at.formatted(date: .omitted, time: .shortened))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - 今天的会

    @ViewBuilder
    private var meetingSection: some View {
        if !todayMeetings.isEmpty {
            Section("今天的会") {
                ForEach(todayMeetings) { meeting in
                    Button {
                        path.append(TodayMeetingRoute(id: meeting.id))
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(meeting.title)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Spacer(minLength: 4)
                                Text(Self.statusText(meeting))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(meeting.startedAt.formatted(date: .omitted, time: .shortened)) · 录到 \(RecordingService.durationText(meeting.durationSeconds))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - 待弹通知

    /// 今天要弹的，加上已经过点但还没处理的（说明手机刚醒，或者 App 刚回来）
    private var todayNotices: [AssistantItem] {
        items.sorted(items.upcomingItems)
            .filter { item in
                guard let fire = item.fireDate else { return false }
                return Calendar.current.isDateInToday(fire) || fire < Date()
            }
    }

    @ViewBuilder
    private var noticeSection: some View {
        if !items.items.isEmpty {
            Section {
                ForEach(todayNotices.prefix(5)) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.body)
                        Text(noticeLine(item))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                NavigationLink {
                    ScheduleView()
                } label: {
                    Text(todayNotices.isEmpty ? "看全部安排" : "看全部安排（今天 \(todayNotices.count) 条要弹）")
                        .font(.footnote)
                }
            } header: {
                Text("待弹的通知")
            } footer: {
                if todayNotices.isEmpty {
                    Text("今天没有要到点的提醒。所有安排——能改时间、改备注、拖动排序——都在「安排」里。")
                }
            }
        }
    }

    private func noticeLine(_ item: AssistantItem) -> String {
        guard let fire = item.fireDate else { return item.kind.label }
        let when = ItemTimeText.when(fire)
        guard fire > Date() else { return "\(when) · 时间已过" }
        return "\(when) · \(ItemTimeText.relative(fire))"
    }

    // MARK: - 备忘

    @ViewBuilder
    private var noteSection: some View {
        let notes = items.sorted(items.timelessItems).filter { $0.kind == .note }
        if !notes.isEmpty {
            Section("备忘") {
                ForEach(notes.prefix(5)) { note in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.title)
                            .font(.body)
                        if !note.notes.isEmpty {
                            Text(note.notes)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - 余额

    private var balanceChip: some View {
        Button {
            balance.refresh(settings: settings)
        } label: {
            HStack(spacing: 5) {
                if balance.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: balance.isLow ? "exclamationmark.triangle.fill" : balance.chipIcon).font(.caption)
                }
                Text(balance.chipText).font(.footnote)
            }
            .foregroundStyle(balance.isLow ? Color.orange : Color.primary)
        }
        .disabled(balance.isRefreshing)
        .accessibilityLabel("余额：\(balance.chipText)，点击刷新")
    }

    // MARK: - 数据

    private var todayLogs: [MemoryLog] {
        let today = MemoryStore.dayString(Date())
        return memory.logs.filter { $0.day == today }
    }

    private var plans: [MemoryLog] {
        todayLogs.filter { $0.kind == .plan }.sorted { $0.at < $1.at }
    }

    private var doneLogs: [MemoryLog] {
        todayLogs.filter { $0.kind != .plan }.sorted { $0.at < $1.at }
    }

    private var todayMeetings: [Meeting] {
        meetings.meetings
            .filter { Calendar.current.isDateInToday($0.startedAt) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private static func statusText(_ m: Meeting) -> String {
        if m.status == "recovered" { return "意外中断，已恢复" }
        if m.transcript.isEmpty { return "未转写" }
        if m.summaryJSON.isEmpty { return "未纪要" }
        return "已纪要"
    }
}

/// 今日页的跳转标识。会议 id 和会话 id 都是字符串，用不同类型分开，
/// 免得两个 navigationDestination(for: String.self) 撞在一起。
struct TodayMeetingRoute: Hashable { let id: String }
struct TodayChatRoute: Hashable { let id: String }
struct TodayScheduleRoute: Hashable {}

#Preview {
    TodayView()
        .environmentObject(MeetingStore())
        .environmentObject(ChatStore())
        .environmentObject(SettingsStore())
}
