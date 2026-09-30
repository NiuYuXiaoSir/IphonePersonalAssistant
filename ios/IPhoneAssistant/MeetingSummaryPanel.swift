import SwiftUI
import UIKit

// 批量写入的公共实现。速记页的条目卡片和这里的纪要面板都走它。
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

/// 会议纪要面板。
///
/// 做成可内嵌的面板（而不是一个独立页面），因为它现在是会议详情里的一页——
/// 听录音、看转写、生成纪要本来就是同一件事的三个动作，来回 push 太绕。
struct MeetingSummaryPanel: View {
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let m = meeting {
                    if m.transcript.isEmpty {
                        notice("还没有会议文字。先去「转写」页把文字准备好，再回来生成纪要。",
                               icon: "exclamationmark.triangle",
                               tint: .orange)
                    } else {
                        generateCard(m)
                    }

                    if hasSummary {
                        if !summary.titleDraft.isEmpty { titleCard }
                        if !summary.summaryText.isEmpty { textCard("摘要", "text.alignleft", summary.summaryText, .primary) }
                        if !summary.topics.isEmpty { topicsCard }
                        if !summary.decisions.isEmpty { listCard("决议", "checkmark.circle", summary.decisions, .primary) }
                        if !summary.actionItems.isEmpty { actionCard }
                        if !summary.events.isEmpty { eventCard }
                        if !summary.keyPoints.isEmpty { listCard("要点", "list.bullet", summary.keyPoints, .primary) }
                        if !summary.unresolved.isEmpty { listCard("未决问题", "questionmark.circle", summary.unresolved, .orange) }
                        writeCard
                    }
                } else {
                    notice("记录不存在，可能已经被删了", icon: "questionmark.folder", tint: .secondary)
                }

                if !status.isEmpty {
                    Text(status)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .onAppear(perform: loadExisting)
    }

    // MARK: - 卡片

    private func generateCard(_ m: Meeting) -> some View {
        card("生成", icon: "wand.and.stars") {
            HStack(spacing: 12) {
                infoChip("会议文字", "\(m.transcript.count) 字")
                infoChip("模型", settings.model)
            }
            Button {
                generate(m)
            } label: {
                Label(busy ? "生成中…（长会议可能要等半分钟）" : (hasSummary ? "重新生成纪要" : "生成 AI 纪要"),
                      systemImage: "sparkles")
                    .font(.footnote)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)

            Text("会真的向模型发一次请求。每条待办都被要求附上原文句子，方便你核对是不是模型编的。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var titleCard: some View {
        card("标题建议", icon: "textformat") {
            Text(summary.titleDraft)
                .font(.headline)
            Button("用它作为会议标题") { applyTitle() }
                .font(.footnote)
                .buttonStyle(.bordered)
        }
    }

    private func textCard(_ title: String, _ icon: String, _ text: String, _ tint: Color) -> some View {
        card(title, icon: icon) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func listCard(_ title: String, _ icon: String, _ lines: [String], _ tint: Color) -> some View {
        card(title, icon: icon) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 6) {
                        Text("·").font(.footnote).foregroundStyle(.secondary)
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(tint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var topicsCard: some View {
        card("议题与结论", icon: "bubble.left.and.bubble.right") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(summary.topics) { topic in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(topic.topic).font(.subheadline.weight(.semibold))
                        Text(topic.conclusion).font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var actionCard: some View {
        card("待办（\(summary.actionItems.filter { $0.include }.count)/\(summary.actionItems.count) 条会写入提醒事项）",
             icon: "checklist") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach($summary.actionItems) { $item in
                    reviewRow($item)
                }
            }
        }
    }

    private var eventCard: some View {
        card("日程（\(summary.events.filter { $0.include }.count)/\(summary.events.count) 条会写入日历）",
             icon: "calendar") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach($summary.events) { $item in
                    reviewRow($item)
                }
            }
        }
    }

    private var writeCard: some View {
        card("写入", icon: "tray.and.arrow.down") {
            Button {
                writeSelected()
            } label: {
                Label(busy ? "写入中…" : "把勾选的条目写入系统", systemImage: "square.and.arrow.down")
                    .font(.footnote)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)

            Button {
                UIPasteboard.general.string = meeting?.summaryJSON ?? ""
                status = "已复制纪要 JSON"
            } label: {
                Label("复制纪要 JSON", systemImage: "doc.on.doc")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)

            Text("待办进提醒事项的「AI助理」列表，日程进日历的「AI助理」。只有勾选的会被写入。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func notice(_ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func infoChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium))
        }
    }

    private func card<Content: View>(_ title: String,
                                     icon: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func reviewRow(_ item: Binding<ParsedItem>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    item.wrappedValue.include.toggle()
                } label: {
                    Image(systemName: item.wrappedValue.include ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(item.wrappedValue.include ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)

                TextField("标题", text: item.title, axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(1...3)
            }

            HStack(spacing: 10) {
                Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
                TextField("时间（可留空）", text: item.dueDate)
                    .font(.caption)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if item.wrappedValue.kind == .event {
                    TextField("分钟", value: item.durationMinutes, format: .number)
                        .font(.caption)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 42)
                    Text("分钟").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 27)

            if !item.wrappedValue.notes.isEmpty {
                Text(item.wrappedValue.notes)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 27)
            }
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
                    if var updated = self.store.meeting(id: self.meetingID) {
                        updated.summaryJSON = raw
                        if updated.status == "recorded" || updated.status == "transcribed" {
                            updated.status = "summarized"
                        }
                        self.store.update(updated)
                    }
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
    MeetingSummaryPanel(meetingID: "none")
        .environmentObject(MeetingStore())
        .environmentObject(SettingsStore())
}
