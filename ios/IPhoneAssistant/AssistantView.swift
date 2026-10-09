import SwiftUI
import UIKit

/// 速记页：手动新建待办 / 日程 / 备忘 / 提醒。
///
/// 这一页不经过 AI，也不该出现「解析」这种词——自己清楚要记什么的时候，
/// 一项项填完保存，比说一句话再回头改更快也更准。
/// 想让助理从一段话里替你拆出来，去「对话」页。
///
/// 版式用系统 Form：分段选择、开关、日期选择、行、页脚说明都是系统给的。
/// 已记下的东西不在这里列——它们在「今日 → 安排」，那一页能改能排序。
struct AssistantView: View {

    /// 从「＋」面板选「语音速记」进来时，话筒直接开着
    var autoStartVoice: Bool = false

    @ObservedObject private var items = ItemStore.shared
    @StateObject private var liveASR = LiveSpeechRecognizer()

    @State private var kind: ParsedItem.Kind = .todo
    @State private var title = ""
    @State private var notes = ""
    @State private var hasDueDate = false
    @State private var dueDate = Date().addingTimeInterval(3600)
    @State private var durationMinutes = 60
    @State private var remindBeforeMinutes = 0

    @State private var busy = false
    @State private var message = ""
    @State private var messageIsError = false
    @State private var toast = ""
    @State private var voicePrefix = ""

    private let durationOptions = [15, 30, 45, 60, 90, 120, 180]
    /// 提前提醒的档位。0 = 到点
    private let remindOptions = [0, 5, 10, 15, 30, 60]

    var body: some View {
        Form {
            kindSection
            contentSection
            if kind == .todo { todoTimeSection }
            if kind == .event { eventTimeSection }
            if kind == .notification { noticeTimeSection }
            notesFieldSection
            saveSection
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
        .onChange(of: liveASR.transcript) { _, text in
            guard !text.isEmpty else { return }
            title = voicePrefix + text
            voicePrefix = ""
        }
        .onDisappear { if liveASR.isRunning { liveASR.stop() } }
        .onAppear {
            if autoStartVoice && !liveASR.isRunning { toggleVoice() }
        }
        .toast($toast)
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
            ? "到点会弹一条通知。想提前一点提醒，用下面的「提前提醒」。"
            : "不设时间就是一条没有截止时间的待办，不会提醒。"
    }

    private var kindHint: String {
        switch kind {
        case .todo:         return "写一件要做的事。设了时间到点会提醒，办完可以在「安排」里打勾，也可以直接在通知上点「完成」。"
        case .event:        return "写一件要占用一段时间的事（会议、约人），到点会提醒你。"
        case .note:         return "记一条信息，不提醒、不用打勾。存在 App 里，可以整条复制走。"
        case .notification: return "到点弹一条通知就完事，不用回来打勾。适合几分钟到几小时后要响一下的事。"
        }
    }

    private var contentSection: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                TextField(titlePlaceholder, text: $title, axis: .vertical)
                    .lineLimit(1...4)
                Button {
                    toggleVoice()
                } label: {
                    Image(systemName: liveASR.isRunning ? "waveform.circle.fill" : "mic.fill")
                        .font(.title3)
                        .foregroundStyle(liveASR.isRunning ? Color.red : Color.accentColor)
                        .symbolEffect(.variableColor, isActive: liveASR.isRunning)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(liveASR.isRunning ? "停止语音输入" : "开始语音输入")
            }
            if liveASR.isRunning {
                Label("在听…说完点一下话筒停止", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !liveASR.message.isEmpty && liveASR.message != "已停止" {
                Text(liveASR.message)
                    .font(.caption)
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
                remindPicker
            }
        } header: {
            Text("提醒")
        } footer: {
            Text(dueHint)
        }
    }

    /// 提前多久提醒。以前只有对话里能说「提前半小时」，手填的没有这个选项。
    private var remindPicker: some View {
        Picker("提前提醒", selection: $remindBeforeMinutes) {
            ForEach(remindOptions, id: \.self) { minutes in
                Text(minutes == 0 ? "到点" : "提前 \(minutes) 分钟").tag(minutes)
            }
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
            remindPicker
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
            Text("到点弹一条系统通知，通知上可以直接点「完成」或「延后 10 分钟」。不想让它响了，来「今日 → 安排」里删掉。")
        }
    }

    private var notesFieldSection: some View {
        Section {
            TextField(bodyPlaceholder, text: $notes, axis: .vertical)
                .lineLimit(2...6)
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
                    if busy { ProgressView() }
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
            Text("记下的东西都存在本机，不碰系统里的提醒事项和日历，也就不需要那些权限。这一页不联网，没配密钥也能用。")
        }
    }

    private var saveButtonTitle: String {
        switch kind {
        case .todo:         return "存下这条待办"
        case .event:        return "存下这个日程"
        case .note:         return "记下这条备忘"
        case .notification: return "安排这条提醒"
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

        // 只有需要时间的类型才带时间；备忘和「不设时间」的待办给空串，
        // 空串在 ItemWriter 那边等于「不设时刻、不会提醒」。
        let dueString = needsTime ? Self.dueFormatter.string(from: dueDate) : ""
        let body = notes
        let itemKind = kind
        let itemDuration = durationMinutes
        let itemRemind = kind == .notification ? 0 : remindBeforeMinutes
        let displayTime = dueDate.formatted(date: .abbreviated, time: .shortened)

        // 存的是本机数据库里的一行，不需要网络也不需要系统权限，同步做完
        do {
            let parsed = ParsedItem(kind: itemKind,
                                    title: trimmed,
                                    notes: body,
                                    dueDate: dueString,
                                    durationMinutes: itemKind == .event ? itemDuration : 0,
                                    remindBeforeMinutes: itemRemind)
            try ItemWriter.save(parsed, source: "quickadd")

            busy = false
            message = ""
            switch itemKind {
            case .todo:
                toast = dueString.isEmpty ? "已记下：\(trimmed)（没有设时间）" : "到点会提醒你：\(trimmed) · \(displayTime)"
            case .event:
                toast = "已存下：\(trimmed) · \(displayTime)，\(Self.durationLabel(itemDuration))"
            case .note:
                toast = "已记下备忘：\(trimmed)"
            case .notification:
                toast = "到点会弹一下：\(trimmed) · \(displayTime)"
            }
            AppLog.info("QuickAdd", toast)
            title = ""
            notes = ""
            // 手记的东西也进每日流水：不然「明天要做什么」只算对话里说过的那些。
            // 时间取条目上的日期，没设时间的算今天。
            let day = Self.dayString(from: dueString)
            let logKind: MemoryKind = itemKind == .note ? .note : .plan
            MemoryStore.shared.logManual(kind: logKind,
                                         content: Self.logContent(title: trimmed, kind: itemKind, notes: body),
                                         day: day,
                                         source: "quickadd")
        } catch {
            busy = false
            message = error.localizedDescription
            messageIsError = true
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

    /// 条目日期（yyyy-MM-dd HH:mm 或空）→ 这一条算在哪天的流水里
    private static func dayString(from dueString: String) -> String? {
        let trimmed = dueString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let date = ItemTime.date(from: trimmed, defaultHour: 9) else { return nil }
        return MemoryStore.dayString(date)
    }

    /// 流水里那句要写得能脱离上下文看懂，所以带上类型前缀和备注
    private static func logContent(title: String, kind: ParsedItem.Kind, notes: String) -> String {
        var text = "\(kind.label)：\(title)"
        let extra = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { text += "（\(extra)）" }
        return text
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
