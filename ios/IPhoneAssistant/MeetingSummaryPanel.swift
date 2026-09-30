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
                                            priority: item.priority,
                                            remindBeforeMinutes: item.remindBeforeMinutes)
                    ok.append("待办 · \(item.title)")
                case .event:
                    try await writeEvent(title: item.title,
                                         notes: item.notes,
                                         dueDate: item.dueDate,
                                         durationMinutes: item.durationMinutes)
                    ok.append("日程 · \(item.title)")
                case .note:
                    // 备忘录没有公开的写入 API，存进 App 自己的备忘列表
                    NoteStore.shared.add(title: item.title, body: item.notes)
                    ok.append("备忘 · \(item.title)")
                case .notification:
                    try await writeNotification(title: item.title,
                                                body: item.notes,
                                                dueDate: item.dueDate)
                    ok.append("提醒 · \(item.title)")
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
/// 它是会议详情里那张「纸」上的内容之一，所以整块按文档排版：
/// 摘要是一段话，后面按「议题 / 待办 / 日程 / 决议 / 要点 / 未决问题」一节节往下走，
/// 不再是六张各带标题的卡片——那样看长文字很累，也不像一份纪要。
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
    @State private var loaded = false

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
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(YBColor.paperInkSoft)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(YBColor.paperHi,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 28)
        }
        .onAppear(perform: loadExisting)
    }

    // MARK: - 文档

    @ViewBuilder
    private var document: some View {
        if !summary.titleDraft.isEmpty { titleSuggestion }
        if !summary.summaryText.isEmpty { paragraph(summary.summaryText) }

        if !summary.topics.isEmpty || !summary.actionItems.isEmpty || !summary.events.isEmpty
            || !summary.decisions.isEmpty || !summary.keyPoints.isEmpty || !summary.unresolved.isEmpty {
            Text("小结")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(YBColor.paperInk)
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
            bulletSection("未决问题", lines: summary.unresolved, tint: YBColor.warning)
        }
    }

    private var titleSuggestion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("标题建议")
                .font(.system(size: 13))
                .foregroundStyle(YBColor.paperInkSoft)
            Text(summary.titleDraft)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(YBColor.paperInk)
                .fixedSize(horizontal: false, vertical: true)
            Button("用它作为会议标题") { applyTitle() }
                .buttonStyle(YBPaperButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(YBColor.paperHi,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 摘要和议题都按正文排版：不套卡片，靠字号和留白分层
    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15.5))
            .foregroundStyle(YBColor.paperInk)
            .lineSpacing(6)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(summary.topics.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(index + 1). \(summary.topics[index].topic)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(YBColor.paperInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(summary.topics[index].conclusion)
                        .font(.system(size: 15.5))
                        .foregroundStyle(YBColor.paperInk)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bulletSection(_ title: String, lines: [String], tint: Color = YBColor.paperInk) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(YBColor.paperInk)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(lines.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.system(size: 15.5))
                            .foregroundStyle(YBColor.paperInkSoft)
                        Text(lines[index])
                            .font(.system(size: 15.5))
                            .foregroundStyle(tint)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("待办", note: "\(summary.actionItems.filter { $0.include }.count)/\(summary.actionItems.count) 条会写进提醒事项")
            ForEach($summary.actionItems) { $item in
                reviewRow($item)
            }
        }
    }

    private var eventSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("日程", note: "\(summary.events.filter { $0.include }.count)/\(summary.events.count) 条会写进日历")
            ForEach($summary.events) { $item in
                reviewRow($item)
            }
        }
    }

    private func sectionTitle(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(YBColor.paperInk)
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(YBColor.paperInkSoft)
        }
    }

    private func reviewRow(_ item: Binding<ParsedItem>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    item.wrappedValue.include.toggle()
                } label: {
                    Image(systemName: item.wrappedValue.include ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(item.wrappedValue.include ? YBColor.accent : YBColor.paperInkSoft)
                }
                .buttonStyle(.plain)

                TextField("标题", text: item.title, axis: .vertical)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(YBColor.paperInk)
                    .lineLimit(1...3)
            }

            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(YBColor.paperInkSoft)
                TextField("时间（可留空）", text: item.dueDate)
                    .font(.system(size: 13))
                    .foregroundStyle(YBColor.paperInk)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if item.wrappedValue.kind == .event {
                    TextField("分钟", value: item.durationMinutes, format: .number)
                        .font(.system(size: 13))
                        .foregroundStyle(YBColor.paperInk)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 42)
                    Text("分钟")
                        .font(.system(size: 12))
                        .foregroundStyle(YBColor.paperInkSoft)
                }
            }
            .padding(.leading, 27)

            if !item.wrappedValue.notes.isEmpty {
                Text(item.wrappedValue.notes)
                    .font(.system(size: 12))
                    .foregroundStyle(YBColor.paperInkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 27)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(YBColor.paperHi,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func generateBlock(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("会议文字 \(m.transcript.count) 字")
                    .font(.system(size: 13))
                    .foregroundStyle(YBColor.paperInkSoft)
                Text("模型 \(settings.model)")
                    .font(.system(size: 13))
                    .foregroundStyle(YBColor.paperInkSoft)
                if balance.supports(settings) {
                    Button {
                        balance.refresh(settings: settings)
                    } label: {
                        Text("余额 \(balance.chipText)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(balance.isLow ? YBColor.danger : YBColor.paperInkSoft)
                    }
                    .buttonStyle(YBPressStyle())
                }
                Spacer(minLength: 0)
            }

            Button {
                generate(m)
            } label: {
                Label(busy ? "生成中…（长会议可能要等半分钟）" : (hasSummary ? "重新生成纪要" : "生成 AI 纪要"),
                      systemImage: "sparkles")
            }
            .buttonStyle(YBPaperPrimaryButtonStyle())
            .disabled(busy)

            Text("会真的向模型发一次请求。每条待办都被要求附上原文句子，方便你核对是不是模型编的。")
                .font(.system(size: 12))
                .foregroundStyle(YBColor.paperInkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(YBColor.paperHi,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var writeBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                writeSelected()
            } label: {
                Label(busy ? "写入中…" : "把勾选的条目写入系统", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(YBPaperPrimaryButtonStyle())
            .disabled(busy)

            Button {
                UIPasteboard.general.string = meeting?.summaryJSON ?? ""
                status = "已复制纪要原文"
            } label: {
                Label("复制纪要原文", systemImage: "doc.on.doc")
            }
            .buttonStyle(YBPaperButtonStyle())

            Text("待办进提醒事项的「AI助理」列表，日程进日历的「AI助理」。只有勾选的会被写入。")
                .font(.system(size: 12))
                .foregroundStyle(YBColor.paperInkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(YBColor.paperHi,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func notice(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 14))
        .foregroundStyle(YBColor.paperInkSoft)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(YBColor.paperHi,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            status = "还没有保存密钥，去「设置」里填一个"
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
                    // 刚花掉一次 token，余额跟着更新
                    self.balance.refresh(settings: self.settings)
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
    MeetingSummaryPanel(meetingID: "none") {
        Text("抬头")
    }
    .environmentObject(MeetingStore())
    .environmentObject(SettingsStore())
}
