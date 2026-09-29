import SwiftUI
import UIKit

// 批量写入的公共实现。放在这里而不是 SystemWriter 里，
// 是为了不改动已经稳定工作的那个文件。
extension SystemWriter {
    /// 逐条写入，一条失败不拖垮整批。返回成功与失败的描述列表。
    static func writeAll(_ items: [ParsedItem]) async -> (succeeded: [String], failed: [String]) {
        var ok: [String] = []
        var bad: [String] = []
        for item in items {
            do {
                switch item.kind {
                case .todo:
                    try await writeReminder(title: item.title,
                                            notes: item.notes,
                                            dueDate: item.dueDate,
                                            priority: item.priority)
                    ok.append("待办 · \(item.title)")
                case .event:
                    try await writeEvent(title: item.title,
                                         notes: item.notes,
                                         dueDate: item.dueDate,
                                         durationMinutes: item.durationMinutes)
                    ok.append("日程 · \(item.title)")
                case .note:
                    AppLog.info("Writer", "备忘未写入系统（待做快捷指令桥接）：\(item.title)")
                    ok.append("备忘（仅记录）· \(item.title)")
                }
            } catch {
                bad.append("\(item.title)：\(error.localizedDescription)")
            }
        }
        return (ok, bad)
    }
}

struct MeetingSummaryView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var settings: SettingsStore
    let meetingID: String

    @State private var summary = MeetingSummary()
    @State private var hasSummary = false
    @State private var busy = false
    @State private var status = ""
    @State private var loaded = false

    private var meeting: Meeting? { store.meeting(id: meetingID) }

    var body: some View {
        List {
            guard let m = meeting else {
                Text("记录不存在，可能已被删除").foregroundStyle(.secondary)
                return
            }

            if m.transcript.isEmpty {
                Section {
                    Label("先去上一页把会议文字粘进去", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } else {
                generateSection(m)
            }

            if hasSummary {
                headerSection
                if !summary.summaryText.isEmpty { abstractSection }
                if !summary.topics.isEmpty { topicsSection }
                if !summary.decisions.isEmpty { decisionsSection }
                if !summary.actionItems.isEmpty { actionSection }
                if !summary.events.isEmpty { eventsSection }
                if !summary.keyPoints.isEmpty { keyPointsSection }
                if !summary.unresolved.isEmpty { unresolvedSection }
                writeSection
            }

            if !status.isEmpty {
                Section("结果") {
                    Text(status)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("AI 纪要")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadExisting)
    }

    // MARK: - 区块

    private func generateSection(_ m: Meeting) -> some View {
        Section {
            LabeledContent("会议文字", value: "\(m.transcript.count) 字")
            LabeledContent("模型", value: settings.model)
            Button(busy ? "生成中…（长会议可能要等 30 秒）" : (hasSummary ? "重新生成纪要" : "生成 AI 纪要")) {
                generate(m)
            }
            .disabled(busy)
        } header: {
            Text("生成")
        } footer: {
            Text("会真的向模型发一次请求。提醒：待办必须能在原文里找到依据，模型被要求在每条待办里附上原文句子，方便你核对。")
        }
    }

    private var headerSection: some View {
        Section("标题建议") {
            Text(summary.titleDraft.isEmpty ? "（模型没给建议）" : summary.titleDraft)
                .font(.headline)
            Button("用它作为会议标题") {
                applyTitle()
            }
            .disabled(summary.titleDraft.isEmpty)
        }
    }

    private var abstractSection: some View {
        Section("摘要") {
            Text(summary.summaryText).font(.footnote)
        }
    }

    private var topicsSection: some View {
        Section("议题与结论") {
            ForEach(summary.topics) { t in
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.topic).font(.subheadline).bold()
                    Text(t.conclusion).font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var decisionsSection: some View {
        Section("决议") {
            ForEach(summary.decisions, id: \.self) { d in
                Label(d, systemImage: "checkmark.circle")
                    .font(.footnote)
            }
        }
    }

    private var actionSection: some View {
        Section {
            ForEach($summary.actionItems) { $item in
                reviewRow($item)
            }
        } header: {
            Text("待办（\(summary.actionItems.filter { $0.include }.count) / \(summary.actionItems.count) 条写入提醒事项）")
        } footer: {
            Text("每条都附了原文依据，可以核对一下是不是模型自己编的。")
        }
    }

    private var eventsSection: some View {
        Section {
            ForEach($summary.events) { $item in
                reviewRow($item)
            }
        } header: {
            Text("日程（\(summary.events.filter { $0.include }.count) / \(summary.events.count) 条写入日历）")
        }
    }

    private func reviewRow(_ item: Binding<ParsedItem>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: item.include).labelsHidden()
                TextField("标题", text: item.title).font(.subheadline)
            }
            HStack(spacing: 10) {
                TextField("时间（可留空）", text: item.dueDate)
                    .font(.caption)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if item.wrappedValue.kind == .event {
                    TextField("分钟", value: item.durationMinutes, format: .number)
                        .font(.caption)
                        .keyboardType(.numberPad)
                        .frame(width: 54)
                }
            }
            if !item.wrappedValue.notes.isEmpty {
                Text(item.wrappedValue.notes)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var keyPointsSection: some View {
        Section("要点") {
            ForEach(summary.keyPoints, id: \.self) { p in
                Text("· " + p).font(.footnote)
            }
        }
    }

    private var unresolvedSection: some View {
        Section("未决问题") {
            ForEach(summary.unresolved, id: \.self) { u in
                Text("· " + u).font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private var writeSection: some View {
        Section {
            Button(busy ? "写入中…" : "把勾选的条目写入系统") { writeSelected() }
                .disabled(busy)
            Button("复制纪要 JSON 到剪贴板") {
                UIPasteboard.general.string = meeting?.summaryJSON ?? ""
                status = "已复制"
            }
        } header: {
            Text("写入")
        } footer: {
            Text("待办进提醒事项的「AI助理」列表，日程进日历的「AI助理」。只有勾选的会被写入。")
        }
    }

    // MARK: - 动作

    private func loadExisting() {
        guard !loaded, let m = meeting else { return }
        loaded = true
        guard !m.summaryJSON.isEmpty else { return }
        do {
            summary = try MeetingSummarizer.decode(m.summaryJSON)
            hasSummary = true
            AppLog.info("Summary", "载入已有纪要")
        } catch {
            status = "已有纪要读不出来（可能是旧格式），可以重新生成：\(error.localizedDescription)"
        }
    }

    private func generate(_ m: Meeting) {
        let config = settings.makeConfig()
        guard config.chatCompletionsURL != nil else {
            status = "接口地址无效，去「设置」里看一下"
            return
        }
        guard !config.apiKey.isEmpty else {
            status = "还没有保存 API Key，去「设置」里填一个"
            return
        }

        busy = true
        status = "正在请求模型…"

        Task {
            do {
                let raw = try await MeetingSummarizer.generate(transcript: m.transcript, config: config)
                let parsed = try MeetingSummarizer.decode(raw)
                await MainActor.run {
                    self.busy = false
                    guard var updated = self.store.meeting(id: self.meetingID) else { return }
                    updated.summaryJSON = raw
                    if updated.status == "recorded" || updated.status == "transcribed" {
                        updated.status = "summarized"
                    }
                    self.store.update(updated)
                    self.summary = parsed
                    self.hasSummary = true
                    self.status = "生成完成：待办 \(parsed.actionItems.count) 条，日程 \(parsed.events.count) 条，决议 \(parsed.decisions.count) 条"
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.status = "生成失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func applyTitle() {
        guard var m = meeting else { return }
        let trimmed = summary.titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        m.title = trimmed
        store.update(m)
        status = "标题已改为「\(trimmed)」"
    }

    private func writeSelected() {
        let selected = summary.actionItems.filter { $0.include } + summary.events.filter { $0.include }
        guard !selected.isEmpty else {
            status = "没有勾选任何条目"
            return
        }
        busy = true
        status = "正在写入 \(selected.count) 条…"

        Task {
            let result = await SystemWriter.writeAll(selected)
            await MainActor.run {
                self.busy = false
                var lines = ["成功 \(result.succeeded.count) 条"]
                lines.append(contentsOf: result.succeeded.map { "  ✅ " + $0 })
                if !result.failed.isEmpty {
                    lines.append("失败 \(result.failed.count) 条")
                    lines.append(contentsOf: result.failed.map { "  ❌ " + $0 })
                }
                self.status = lines.joined(separator: "\n")
                self.summary.actionItems.removeAll { $0.include }
                self.summary.events.removeAll { $0.include }
            }
        }
    }
}

#Preview {
    NavigationStack {
        MeetingSummaryView(meetingID: "none")
    }
    .environmentObject(MeetingStore())
    .environmentObject(SettingsStore())
}
