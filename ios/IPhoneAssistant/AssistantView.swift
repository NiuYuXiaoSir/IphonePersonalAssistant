import SwiftUI
import UIKit

/// 速记页：手动新建待办 / 日程 / 备忘。
///
/// 这一页不经过 AI，也不该出现「解析」这种词——自己清楚要记什么的时候，
/// 一项项填完保存，比说一句话再回头改更快也更准。
/// 想让助理从一段话里替你拆出来，去「对话」页。
struct AssistantView: View {

    @ObservedObject private var noteStore = NoteStore.shared
    @StateObject private var liveASR = LiveSpeechRecognizer()

    @State private var kind: ParsedItem.Kind = .todo
    @State private var title = ""
    @State private var notes = ""
    @State private var hasDueDate = false
    @State private var dueDate = Date().addingTimeInterval(3600)
    @State private var durationMinutes = 60
    @State private var priority = "normal"

    @State private var busy = false
    @State private var message = ""
    @State private var messageIsError = false
    @State private var toast = ""
    @State private var voicePrefix = ""
    /// 已经排上、还没弹出的通知
    @State private var pendingNotices: [NotificationService.Pending] = []

    private let durationOptions = [15, 30, 45, 60, 90, 120, 180]

    var body: some View {
        NavigationStack {
            List {
                kindSection
                contentSection
                if kind == .todo { todoTimeSection }
                if kind == .event { eventTimeSection }
                if kind == .notification { noticeTimeSection }
                notesFieldSection
                saveSection
                if hasNotes { savedNotesSection }
                if hasPendingNotices { pendingNoticeSection }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("速记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { hideKeyboard() }
                }
            }
            .onChange(of: kind) { _, newKind in
                if newKind == .event {
                    hasDueDate = true
                    dueDate = Self.nextRoundHour()
                }
            }
            .onChange(of: liveASR.liveText) { _, text in
                if liveASR.isRunning { title = voicePrefix + text }
            }
            .onDisappear { if liveASR.isRunning { liveASR.stop() } }
            .onAppear { Task { await refreshNotices() } }
            .alert("提示", isPresented: Binding(
                get: { !toast.isEmpty },
                set: { if !$0 { toast = "" } }
            )) {
                Button("知道了") { toast = "" }
            } message: {
                Text(toast)
            }
        }
    }

    // MARK: - 表单

    private var kindSection: some View {
        Section {
            Picker("类型", selection: $kind) {
                ForEach(ParsedItem.Kind.allCases, id: \.self) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } footer: {
            Text(kindHint)
        }
    }

    // 这几处写成 String 属性而不是往 Text/TextField 里塞字面量三元：
    // SwiftUI 对 LocalizedStringKey 和 String 各有一套重载，字面量三元容易撞在重载解析上。
    private var titlePlaceholder: String { kind == .note ? "记什么" : "要做什么" }
    private var bodyPlaceholder: String { kind == .note ? "补充（可留空）" : "备注（可留空）" }
    private var bodyHeader: String { kind == .note ? "正文" : "备注" }
    private var dueHint: String {
        hasDueDate
            ? "到点会弹一条通知。要提前提醒的话，在「对话」页直说，比如「提前半小时提醒我」。"
            : "不设时间就是一条没有截止时间的待办，不会提醒。"
    }

    private var kindHint: String {
        switch kind {
        case .todo:         return "写一件要做的事，可以设个提醒时间。保存后进提醒事项的「AI助理」列表。"
        case .event:        return "写一件要占用一段时间的事（会议、约人），保存后进日历的「AI助理」。"
        case .note:         return "记一条信息，不需要行动、也不提醒。存在 App 里，可以复制走。"
        case .notification: return "到点弹一条通知就完事，不写进提醒事项。适合几分钟到几小时后要响一下的事。"
        }
    }

    private var contentSection: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                TextField(titlePlaceholder, text: $title, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.body)
                Button {
                    toggleVoice()
                } label: {
                    Image(systemName: liveASR.isRunning ? "waveform.circle.fill" : "mic.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(liveASR.isRunning ? Color.red : Color.accentColor)
                        .symbolEffect(.variableColor, isActive: liveASR.isRunning)
                }
                .buttonStyle(.plain)
            }
            if liveASR.isRunning {
                Label("在听…说完点一下话筒停止", systemImage: "waveform")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !liveASR.message.isEmpty && liveASR.message != "已停止" {
                Text(liveASR.message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("内容")
        }
    }

    private var todoTimeSection: some View {
        Section {
            Toggle("设个提醒时间", isOn: $hasDueDate)
            if hasDueDate {
                DatePicker("提醒时间", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
            }
            Picker("优先级", selection: $priority) {
                Text("低").tag("low")
                Text("中").tag("normal")
                Text("高").tag("high")
            }
            .pickerStyle(.segmented)
        } header: {
            Text("提醒")
        } footer: {
            Text(dueHint)
        }
    }

    private var eventTimeSection: some View {
        Section {
            DatePicker("开始", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
            Picker("时长", selection: $durationMinutes) {
                ForEach(durationOptions, id: \.self) { minutes in
                    Text(Self.durationLabel(minutes)).tag(minutes)
                }
            }
        } header: {
            Text("时间")
        }
    }

    private var noticeTimeSection: some View {
        Section {
            DatePicker("弹出时间", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
        } header: {
            Text("时间")
        } footer: {
            Text("到点弹一条系统通知。这条不会出现在提醒事项里——想让事情留下来打勾，选「待办」。")
        }
    }

    private var notesFieldSection: some View {
        Section {
            TextField(bodyPlaceholder, text: $notes, axis: .vertical)
                .lineLimit(2...6)
                .font(.footnote)
        } header: {
            Text(bodyHeader)
        }
    }

    private var saveSection: some View {
        Section {
            Button {
                save()
            } label: {
                HStack {
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Text(busy ? "保存中…" : saveButtonTitle)
                        .font(.headline)
                    Spacer()
                }
            }
            .disabled(busy)

            if !message.isEmpty {
                Label(message, systemImage: messageIsError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(messageIsError ? Color.orange : Color.green)
            }
        } footer: {
            Text("待办进提醒事项的「AI助理」列表，日程进日历的「AI助理」。这一页不联网，没配密钥也能用。")
        }
    }

    private var saveButtonTitle: String {
        switch kind {
        case .todo:         return "保存到提醒事项"
        case .event:        return "保存到日历"
        case .note:         return "记下这条备忘"
        case .notification: return "安排这条通知"
        }
    }

    private var hasNotes: Bool {
        !noteStore.notes.isEmpty
    }

    private var hasPendingNotices: Bool {
        !pendingNotices.isEmpty
    }

    /// 还没弹出来的通知。iOS 自己不给用户看这个队列，所以在这里列出来，
    /// 不然「10 分钟后提醒我」排下去之后就没法撤了。
    private var pendingNoticeSection: some View {
        Section {
            ForEach(pendingNotices) { notice in
                VStack(alignment: .leading, spacing: 4) {
                    Text(notice.title)
                        .font(.subheadline.weight(.medium))
                    Text(notice.fireDate.formatted(date: .abbreviated, time: .shortened) + " 弹出")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .swipeActions {
                    Button(role: .destructive) {
                        NotificationService.cancel(id: notice.id)
                        pendingNotices.removeAll { $0.id == notice.id }
                    } label: {
                        Label("取消", systemImage: "bell.slash")
                    }
                }
            }
        } header: {
            HStack {
                Text("已安排的通知（\(pendingNotices.count) 条）")
                Spacer()
                Button("刷新") { Task { await refreshNotices() } }
                    .font(.caption)
            }
        } footer: {
            Text("这些通知还没弹出来，左滑可以取消。它们只在手机的通知队列里，不在提醒事项里。")
        }
    }

    private var savedNotesSection: some View {
        Section {
            ForEach(noteStore.notes) { note in
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.title)
                        .font(.subheadline.weight(.medium))
                    if !note.body.isEmpty {
                        Text(note.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                .swipeActions {
                    Button(role: .destructive) {
                        noteStore.delete(note)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    Button {
                        UIPasteboard.general.string = note.body.isEmpty ? note.title : "\(note.title)\n\(note.body)"
                        toast = "已复制到剪贴板"
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .tint(.blue)
                }
            }
        } header: {
            Text("备忘（\(noteStore.notes.count) 条）")
        } footer: {
            Text("iOS 的「备忘录」没有对外写入的接口，所以备忘存在 App 里，在「文件」App 的 私人助理 目录下能看到 notes.json，也可以在这里左滑复制走。")
        }
    }

    // MARK: - 动作

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    private func toggleVoice() {
        if liveASR.isRunning {
            liveASR.stop()
            voicePrefix = ""
            return
        }
        hideKeyboard()
        voicePrefix = title
        liveASR.start()
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = kind == .note ? "先写点要记的内容" : "先写一句要做什么"
            messageIsError = true
            return
        }
        if liveASR.isRunning { liveASR.stop() }
        hideKeyboard()
        busy = true

        // 只有需要时间的类型才带时间；备忘和「不设时间」的待办一律空串，
        // 空串在 SystemWriter 那边等于「不设截止时间、也不提醒」。
        let dueString = needsTime ? Self.dueFormatter.string(from: dueDate) : ""
        let body = notes
        let itemKind = kind
        let itemPriority = priority
        let itemDuration = durationMinutes
        let displayTime = dueDate.formatted(date: .abbreviated, time: .shortened)

        Task {
            do {
                // 每条分支都赋值一次，赋值完再交给主线程使用，
                // 免得跨线程去改一个可变的捕获变量
                let done: String
                switch itemKind {
                case .todo:
                    try await SystemWriter.writeReminder(title: trimmed,
                                                         notes: body,
                                                         dueDate: dueString,
                                                         priority: itemPriority,
                                                         remindBeforeMinutes: 0)
                    done = dueString.isEmpty
                        ? "已存进提醒事项：\(trimmed)（没有设时间）"
                        : "已存进提醒事项：\(trimmed) · \(displayTime)"
                case .event:
                    try await SystemWriter.writeEvent(title: trimmed,
                                                      notes: body,
                                                      dueDate: dueString,
                                                      durationMinutes: itemDuration)
                    done = "已存进日历：\(trimmed) · \(displayTime)，\(Self.durationLabel(itemDuration))"
                case .note:
                    NoteStore.shared.add(title: trimmed, body: body)
                    done = "已记下备忘：\(trimmed)"
                case .notification:
                    try await SystemWriter.writeNotification(title: trimmed,
                                                             body: body,
                                                             dueDate: dueString)
                    done = "已安排通知：\(trimmed) · \(displayTime)"
                }
                await MainActor.run {
                    self.busy = false
                    self.message = done
                    self.messageIsError = false
                    self.title = ""
                    self.notes = ""
                    AppLog.info("QuickAdd", done)
                }
                if itemKind == .notification { await refreshNotices() }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.message = error.localizedDescription
                    self.messageIsError = true
                }
            }
        }
    }

    private var needsTime: Bool {
        switch kind {
        case .todo:         return hasDueDate
        case .event:        return true
        case .note:         return false
        case .notification: return true
        }
    }

    private func refreshNotices() async {
        let list = await NotificationService.pending()
        await MainActor.run { self.pendingNotices = list }
    }

    // MARK: - 小工具

    private static let dueFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()

    private static func durationLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
    }

    /// 默认时间取下一个整点，比「现在」更像人挑的时间。
    /// 先把分秒截掉再 +1 小时——`date(bySetting:)` 会往后找下一个匹配时刻，不是把当前值改小。
    private static func nextRoundHour(from date: Date = Date()) -> Date {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        let truncated = calendar.date(from: comps) ?? date
        return calendar.date(byAdding: .hour, value: 1, to: truncated) ?? date.addingTimeInterval(3600)
    }
}

#Preview {
    AssistantView()
}
