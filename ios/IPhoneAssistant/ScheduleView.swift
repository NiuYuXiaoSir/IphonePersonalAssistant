import SwiftUI
import UIKit
import UserNotifications

/// 「安排」：App 自己排下来的每一条都在这里——待办、日程、提醒、备忘。
///
/// 上一版这些东西分在四处（系统提醒事项、系统日历、App 里的备忘文件、通知队列），
/// 每个地方能改的都不一样，App 里能看全的只有「还没弹的通知」那一小截。
/// 现在事实只有一份：`items` 表。所以这一页能做的事也直白——
/// 改标题、改备注、改时间、提前多久提醒、打勾、拖动排序、删掉，
/// 以及看清「这条到底会不会响、什么时候响」。
struct ScheduleView: View {

    @ObservedObject private var store = ItemStore.shared

    @State private var editing: AssistantItem?
    @State private var toast = ""
    @State private var undoTarget: AssistantItem?
    @State private var notificationDenied = false

    var body: some View {
        List {
            if notificationDenied { deniedSection }

            if store.items.isEmpty {
                emptyState
            } else {
                upcomingSection
                overdueSection
                timelessSection
                doneSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("安排")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                sortMenu
                if !store.items.isEmpty { EditButton() }
            }
        }
        .sheet(item: $editing) { item in
            ItemEditSheet(item: item) { message in
                toast = message
            }
        }
        .task { await refreshPermission() }
        .toast($toast,
               actionTitle: "撤销",
               duration: 5,
               onExpire: { commitDelete() },
               action: { undoDelete() })
    }

    // MARK: - 空态

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有安排", systemImage: "checklist")
        } description: {
            Text("在「对话」里说一句话，或在「＋」里记一条，就会出现在这里——到点弹通知提醒你。")
        }
    }

    /// 通知权限是这个 App 唯一的提醒通道，被拒了要在这里明说
    private var deniedSection: some View {
        Section {
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            } label: {
                Label("去打开通知", systemImage: "bell.slash")
            }
        } header: {
            Text("通知被关掉了")
        } footer: {
            Text("这些安排还在，但到点不会弹出来——通知权限现在是关的。去系统设置里把「通知 → 私人助理」打开，回来就自动重排。")
        }
    }

    // MARK: - 分区

    @ViewBuilder
    private var upcomingSection: some View {
        let list = store.sorted(store.upcomingItems)
        if !list.isEmpty {
            Section {
                rows(list, draggable: true)
            } header: {
                Text("待弹的通知（\(list.count) 条）")
            } footer: {
                if store.sortMode == .manual {
                    Text("现在是手动顺序：按住右边的把手可以拖动。手动顺序只改这个列表怎么排，弹出时刻不变。")
                } else {
                    Text("按弹出时刻排。想自己排，用右上的「排序」切成手动。")
                }
            }
        }
    }

    @ViewBuilder
    private var overdueSection: some View {
        let list = store.sorted(store.overdueItems)
        if !list.isEmpty {
            Section {
                rows(list, draggable: false)
            } header: {
                Text("时间已经过了（\(list.count) 条）")
            } footer: {
                Text("这些的时间已经过了。办完了打个勾，还想要就点开改个时间。")
            }
        }
    }

    @ViewBuilder
    private var timelessSection: some View {
        let list = store.sorted(store.timelessItems)
        if !list.isEmpty {
            Section {
                rows(list, draggable: false)
            } header: {
                Text("没有时间的（\(list.count) 条）")
            } footer: {
                Text("没设时间就不会提醒，只是一张清单。点开可以补一个时间。")
            }
        }
    }

    @ViewBuilder
    private var doneSection: some View {
        let list = store.doneItems.sorted { $0.updatedAt > $1.updatedAt }
        if !list.isEmpty {
            Section {
                rows(Array(list.prefix(12)), draggable: false)
                if list.count > 12 {
                    Text("还有 \(list.count - 12) 条更早完成的")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("已完成的（\(list.count) 条）")
            }
        }
    }

    /// 分区里的行。`draggable` 只给「待弹的通知」——按时间排的清单拖动没有意义
    private func rows(_ list: [AssistantItem], draggable: Bool) -> some View {
        ForEach(list) { item in
            row(item)
                .swipeActions(edge: .leading) {
                    if item.kind != .note {
                        Button {
                            store.setDone(id: item.id, done: !item.isDone)
                        } label: {
                            Label(item.isDone ? "取消完成" : "完成",
                                  systemImage: item.isDone ? "arrow.uturn.backward" : "checkmark")
                        }
                        .tint(item.isDone ? Color.secondary : Color.green)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        delete(item)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button {
                        editing = item
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    if item.kind != .note {
                        Button {
                            store.setDone(id: item.id, done: !item.isDone)
                        } label: {
                            Label(item.isDone ? "取消完成" : "完成",
                                  systemImage: item.isDone ? "arrow.uturn.backward" : "checkmark")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        delete(item)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
        }
        .onMove { offsets, destination in
            store.move(list, from: offsets, to: destination)
        }
        .moveDisabled(!draggable)
        .deleteDisabled(true)
    }

    private func row(_ item: AssistantItem) -> some View {
        Button {
            editing = item
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.kind.symbol)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.body)
                        .foregroundStyle(item.isDone ? Color.secondary : Color.primary)
                        .strikethrough(item.isDone, color: .secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if !item.notes.isEmpty {
                        Text(item.notes)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    Text(metaLine(item))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.kind.label)：\(item.title)。\(metaLine(item))。点按编辑")
    }

    /// 时间那行：说清「什么时候」和「还有多久」，不靠颜色
    private func metaLine(_ item: AssistantItem) -> String {
        var parts: [String] = []
        if let due = item.dueAt {
            parts.append(ItemTimeText.when(due))
            if item.isDone {
                parts.append("已完成")
            } else if let fire = item.fireDate {
                parts.append(fire < Date() ? "时间已过" : ItemTimeText.relative(fire))
            }
        } else {
            parts.append("没有时间")
        }
        if item.remindBeforeMinutes > 0 { parts.append("提前 \(item.remindBeforeMinutes) 分钟提醒") }
        if item.kind == .event && item.durationMinutes > 0 {
            parts.append("\(item.durationMinutes) 分钟")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 排序

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: Binding(
                get: { store.sortMode },
                set: { store.sortMode = $0 }
            )) {
                ForEach(ItemSortMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("排序方式：\(store.sortMode.label)")
    }

    // MARK: - 删除与撤销

    /// 先撤下、给 5 秒撤销，再真删——和其它列表一个规矩（有撤销就不弹确认框）
    private func delete(_ item: AssistantItem) {
        if let previous = undoTarget, previous.id != item.id { commitDelete() }
        undoTarget = item
        store.delete(item)
        toast = "已删除「\(item.title)」"
    }

    private func undoDelete() {
        guard let item = undoTarget else { return }
        undoTarget = nil
        store.add(item)
        toast = "已恢复「\(item.title)」"
    }

    private func commitDelete() {
        undoTarget = nil
    }

    private func refreshPermission() async {
        let status = await NotificationService.authorizationStatus()
        await MainActor.run { notificationDenied = (status == .denied) }
    }
}

// MARK: - 编辑一条

/// 点开一条安排：改标题、改备注、改时间、改提前多久、打勾、复制、删除。
///
/// 改完在关掉这张表单时一次性落盘（不是每敲一个字写一次库、重排一次通知）。
private struct ItemEditSheet: View {

    let original: AssistantItem
    /// 回一句话给上层显示（复制成功、删除……）
    let onMessage: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: AssistantItem
    @State private var hasTime: Bool
    @State private var dueDate: Date

    private let durationOptions = [15, 30, 45, 60, 90, 120, 180]
    private let remindOptions = [0, 5, 10, 15, 30, 60]

    init(item: AssistantItem, onMessage: @escaping (String) -> Void) {
        self.original = item
        self.onMessage = onMessage
        _draft = State(initialValue: item)
        _hasTime = State(initialValue: item.dueAt != nil)
        _dueDate = State(initialValue: item.dueAt ?? Date().addingTimeInterval(3600))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("类型", selection: $draft.kind) {
                        ForEach(ParsedItem.Kind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } footer: {
                    Text(draft.kind.behavior + "。" + kindHint)
                }

                Section("内容") {
                    TextField("标题", text: $draft.title, axis: .vertical)
                        .lineLimit(1...4)
                    TextField("备注（可留空）", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                if draft.kind != .note {
                    Section {
                        Toggle("设个时间", isOn: $hasTime)
                        if hasTime {
                            DatePicker("时间", selection: $dueDate,
                                       displayedComponents: [.date, .hourAndMinute])
                            Picker("提前提醒", selection: $draft.remindBeforeMinutes) {
                                ForEach(remindOptions, id: \.self) { minutes in
                                    Text(minutes == 0 ? "到点" : "提前 \(minutes) 分钟").tag(minutes)
                                }
                            }
                            if draft.kind == .event {
                                Picker("时长", selection: $draft.durationMinutes) {
                                    ForEach(durationOptions, id: \.self) { minutes in
                                        Text(minutes < 60 ? "\(minutes) 分钟"
                                             : (minutes % 60 == 0 ? "\(minutes / 60) 小时"
                                                : "\(minutes / 60) 小时 \(minutes % 60) 分"))
                                            .tag(minutes)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("提醒")
                    } footer: {
                        Text(hasTime
                             ? "到点会弹一条通知，上面能直接点「完成」或「延后 10 分钟」。"
                             : "不设时间就不会提醒。")
                    }
                }

                Section {
                    if draft.kind != .note {
                        Toggle("已完成", isOn: $draft.isDone)
                    }
                    Button {
                        UIPasteboard.general.string = copyText
                        onMessage("已复制")
                    } label: {
                        Label("复制这条", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        ItemStore.shared.delete(original)
                        onMessage("已删除「\(original.title)」")
                        dismiss()
                    } label: {
                        Label("删除这条", systemImage: "trash")
                    }
                } footer: {
                    if let due = effectiveDue {
                        Text("离开这一页时会存下改动，通知也跟着重排。这条会在 \(ItemTimeText.when(due)) 提醒。")
                    } else {
                        Text("离开这一页时会存下改动。")
                    }
                }
            }
            .navigationTitle(original.title.isEmpty ? "编辑" : original.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onDisappear(perform: commit)
    }

    private var kindHint: String {
        switch draft.kind {
        case .todo:         return "办完打个勾，通知上也能直接点「完成」。"
        case .event:        return "要占一段时间的安排。"
        case .note:         return "只记着，不提醒。"
        case .notification: return "响一下就完，不用回来打勾。"
        }
    }

    private var copyText: String {
        var text = draft.title
        if !draft.notes.isEmpty { text += "\n\(draft.notes)" }
        if let due = effectiveDue { text += "\n\(ItemTimeText.when(due))" }
        return text
    }

    private var effectiveDue: Date? {
        draft.kind == .note ? nil : (hasTime ? dueDate : nil)
    }

    private func commit() {
        // 关表单时一次性落盘；期间没动过就不写
        var item = draft
        item.dueAt = effectiveDue
        guard item != original else { return }
        ItemStore.shared.update(item)
    }
}

// MARK: - 时间怎么说

enum ItemTimeText {

    /// 「今天 15:00」「明天 09:00」「10月12日 15:00」
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = DateFormatter()
        time.locale = Locale(identifier: "zh_CN")
        time.dateFormat = "HH:mm"
        let clock = time.string(from: date)

        if calendar.isDateInToday(date) { return "今天 \(clock)" }
        if calendar.isDateInTomorrow(date) { return "明天 \(clock)" }
        if calendar.isDateInYesterday(date) { return "昨天 \(clock)" }
        let day = DateFormatter()
        day.locale = Locale(identifier: "zh_CN")
        day.dateFormat = "M月d日"
        return "\(day.string(from: date)) \(clock)"
    }

    /// 「还有 2 小时」「已过 3 小时」。不写「即将」这种含糊词，说清差多少。
    static func relative(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        let past = seconds < 0
        let total = Int(abs(seconds))
        let text: String
        if total < 60 {
            text = "不到 1 分钟"
        } else if total < 3600 {
            text = "\(total / 60) 分钟"
        } else if total < 86400 {
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            text = minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分"
        } else {
            text = "\(total / 86400) 天"
        }
        return past ? "已过 \(text)" : "还有 \(text)"
    }
}

#Preview {
    NavigationStack {
        ScheduleView()
    }
}
