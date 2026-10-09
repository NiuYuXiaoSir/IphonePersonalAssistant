import SwiftUI
import UIKit

/// 会议纪要面板。
///
/// 它是会议详情里「纪要」那一页的内容，所以整块按文档排版：
/// 摘要是一段话，后面按「议题 / 待办 / 日程 / 决议 / 要点 / 未决问题」一节节往下走，
/// 不是六张各带标题的卡片——看长文字，一段段读比一张张点舒服。
///
/// 抬头（标题 + 时间 + 改名）由外面传进来，因为它要跟着会议标题一起变。
struct MeetingSummaryPanel<Header: View>: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var settings: SettingsStore
    /// 生成纪要要花 token，所以这一块也把余额摆出来
    @ObservedObject private var balance = BalanceStore.shared

    let meetingID: String
    @ViewBuilder var header: () -> Header

    @State private var summary = MeetingSummary()
    @State private var hasSummary = false
    @State private var busy = false
    @State private var status = ""
    @State private var toast = ""
    @State private var loaded = false
    /// 正在跑的那次生成。要有它才能「停止」。
    @State private var generateTask: Task<Void, Never>?

    private var meeting: Meeting? { store.meeting(id: meetingID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header()

                VStack(alignment: .leading, spacing: 18) {
                    if let m = meeting {
                        if m.transcript.isEmpty {
                            notice("还没有会议文字。先去「转写」页把文字准备好，再回来生成纪要。",
                                   icon: "exclamationmark.triangle")
                        } else {
                            generateBlock(m)
                        }

                        if hasSummary {
                            document
                            writeBlock
                        }
                    } else {
                        notice("记录不存在，可能已经被删了", icon: "questionmark.folder")
                    }

                    if !status.isEmpty {
                        Text(status)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 28)
        }
        .onAppear(perform: loadExisting)
        .toast($toast)
    }

    // MARK: - 文档

    @ViewBuilder
    private var document: some View {
        if !summary.titleDraft.isEmpty { titleSuggestion }
        if !summary.summaryText.isEmpty { paragraph(summary.summaryText) }

        if !summary.topics.isEmpty || !summary.actionItems.isEmpty || !summary.events.isEmpty
            || !summary.decisions.isEmpty || !summary.keyPoints.isEmpty || !summary.unresolved.isEmpty {
            Text("小结")
                .font(.title3.bold())
                .padding(.top, 2)
        }

        if !summary.topics.isEmpty { topicsSection }
        if !summary.actionItems.isEmpty { actionSection }
        if !summary.events.isEmpty { eventSection }
        if !summary.decisions.isEmpty {
            bulletSection("决议", lines: summary.decisions)
        }
        if !summary.keyPoints.isEmpty {
            bulletSection("要点", lines: summary.keyPoints)
        }
        if !summary.unresolved.isEmpty {
            bulletSection("未决问题", lines: summary.unresolved, tint: .orange)
        }
    }

    private var titleSuggestion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("标题建议")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(summary.titleDraft)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Button("用它作为会议标题") { applyTitle() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 摘要和议题都按正文排版：不套卡片，靠字号和留白分层
    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(summary.topics.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(index + 1). \(summary.topics[index].topic)")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(summary.topics[index].conclusion)
                        .font(.body)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bulletSection(_ title: String, lines: [String], tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(lines.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Text(lines[index])
                            .font(.body)
                            .foregroundStyle(tint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("待办", note: "\(summary.actionItems.filter { $0.include }.count)/\(summary.actionItems.count) 条会存下来，到时提醒")
            ForEach($summary.actionItems) { item in
                reviewRow(item)
            }
        }
    }

    private var eventSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("日程", note: "\(summary.events.filter { $0.include }.count)/\(summary.events.count) 条会存下来，到点提醒")
            ForEach($summary.events) { item in
                reviewRow(item)
            }
        }
    }

    private func sectionTitle(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reviewRow(_ item: Binding<ParsedItem>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    item.wrappedValue.include.toggle()
                } label: {
                    Image(systemName: item.wrappedValue.include ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(item.wrappedValue.include ? Color.accentColor : Color.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.wrappedValue.include ? "不存这条" : "存这条")

                TextField("标题", text: item.title, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...3)
            }

            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("时间（可留空）", text: item.dueDate)
                    .font(.footnote)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if item.wrappedValue.kind == .event {
                    TextField("分钟", value: item.durationMinutes, format: .number)
                        .font(.footnote)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 42)
                    Text("分钟")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 27)

            if !item.wrappedValue.notes.isEmpty {
                Text(item.wrappedValue.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 27)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func generateBlock(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 三小段信息：横排放不下（大字号）就改成竖排，不许把字压弯
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    transcriptChip(m)
                    modelChip
                    if balance.supports(settings) { balanceButton }
                }
                VStack(alignment: .leading, spacing: 4) {
                    transcriptChip(m)
                    modelChip
                    if balance.supports(settings) { balanceButton }
                }
            }

            HStack(spacing: 10) {
                Button {
                    generate(m)
                } label: {
                    Label(busy ? "生成中…" : (hasSummary ? "重新生成纪要" : "生成 AI 纪要"),
                          systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)

                // HIG 的 Progress indicators 页：能中断的流程要给一个「停」的出口
                if busy {
                    Button("停止") { stopGenerating() }
                        .buttonStyle(.bordered)
                }
            }

            Text("会真的向模型发一次请求。每条待办都被要求附上原文句子，方便你核对是不是模型编的。长会议可能要等半分钟，等不下去可以点「停止」。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func transcriptChip(_ m: Meeting) -> some View {
        Text("会议文字 \(m.transcript.count) 字")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var modelChip: some View {
        Text("模型 \(settings.model)")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var balanceButton: some View {
        Button {
            balance.refresh(settings: settings)
        } label: {
            Text(balance.isLow ? "余额偏低：" : "余额 \(balance.chipText)")
                .font(.footnote)
                .foregroundStyle(balance.isLow ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var writeBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                writeSelected()
            } label: {
                Label(busy ? "存下中…" : "把勾选的条目存下来", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)

            Button {
                UIPasteboard.general.string = meeting?.summaryJSON ?? ""
                toast = "已复制纪要原文"
            } label: {
                Label("复制纪要原文", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)

            Text("待办和日程都存进 App 自己这里，到时弹通知提醒。只有勾选的会被存下，存完能在「今日 → 安排」里改时间和备注。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func notice(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        var config = settings.makeConfig()
        guard config.chatCompletionsURL != nil else {
            status = "接口地址无效，去「设置」里看一下"
            return
        }
        guard !config.apiKey.isEmpty else {
            status = "还没有保存密钥，去「设置」里填一个"
            return
        }
        // 这一场会议自己的 id，OpenCode 的网关按它做路由与缓存
        config.sessionID = m.id

        busy = true
        status = "正在请求模型…"

        generateTask?.cancel()
        generateTask = Task {
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
                    // 刚花掉一次 token，余额跟着更新
                    self.balance.refresh(settings: self.settings)
                }
            } catch {
                let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled
                await MainActor.run {
                    self.busy = false
                    self.status = cancelled
                        ? "已停止。上一份纪要（如果有）还在，会议文字没有丢。"
                        : "生成失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func stopGenerating() {
        generateTask?.cancel()
        generateTask = nil
        busy = false
        status = "已停止。"
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
        status = "正在存 \(selected.count) 条…"

        // 存本机数据库：同步、毫秒级
        let result = ItemWriter.saveAll(selected, source: meetingID)
        busy = false
        var lines = ["成功 \(result.succeeded.count) 条"]
        lines.append(contentsOf: result.succeeded.map { "  ✅ " + $0 })
        if !result.failed.isEmpty {
            lines.append("没成 \(result.failed.count) 条")
            lines.append(contentsOf: result.failed.map { "  ❌ " + $0 })
        }
        status = lines.joined(separator: "\n")
        summary.actionItems.removeAll { $0.include }
        summary.events.removeAll { $0.include }
    }
}

#Preview {
    MeetingSummaryPanel(meetingID: "none") {
        Text("抬头")
    }
    .environmentObject(MeetingStore())
    .environmentObject(SettingsStore())
}
