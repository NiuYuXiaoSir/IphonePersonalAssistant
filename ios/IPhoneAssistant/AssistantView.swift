import SwiftUI

/// 速记页：输入一段话 → AI 拆成可执行条目 → 你确认 → 写入提醒事项 / 日历。
///
/// 这是 PRD 4.4 的 M4-3 闭环。之所以先做它而不是先做会议录音：
/// EventKit 写入路径已经在 E1 里实测可用，而 LLM 层刚建好，两者接上就是完整闭环，
/// 而且不依赖尚未验证的录音能力。
struct AssistantView: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var input = ""
    @State private var items: [ParsedItem] = []
    @State private var status = ""
    @State private var busy = false

    private let example = "明天下午三点跟老王过一下堵盖的方案，提前半小时提醒我；另外这周五之前把报价单发给采购"

    var body: some View {
        NavigationStack {
            List {
                setupSection
                inputSection
                if !items.isEmpty { reviewSection }
                if !status.isEmpty { statusSection }
            }
            .navigationTitle("速记")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !items.isEmpty {
                        Button("清空") { items.removeAll(); status = "" }
                    }
                }
            }
        }
    }

    // MARK: - 各区块

    private var setupSection: some View {
        Section {
            if settings.hasKey {
                Label("凭证已就绪 · \(settings.model)", systemImage: "checkmark.seal")
                    .font(.footnote)
                    .foregroundStyle(.green)
            } else {
                Label("还没配置 API Key，去「设置」页填一个", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var inputSection: some View {
        Section {
            TextField("说一句话，比如：\(example)", text: $input, axis: .vertical)
                .lineLimit(3...8)
            HStack {
                Button(busy ? "处理中…" : "解析") { parse() }
                    .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Button("填个例子") { input = example }
                    .font(.footnote)
                    .disabled(busy)
            }
        } header: {
            Text("输入")
        } footer: {
            Text("可以是一句口头交办，也可以直接粘一整段会议记录。AI 会拆成待办、日程、备忘三类，下一步你逐条确认。")
        }
    }

    private var reviewSection: some View {
        Section {
            ForEach($items) { $item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Toggle("", isOn: $item.include)
                            .labelsHidden()
                        Image(systemName: item.kind.symbol)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        TextField("标题", text: $item.title)
                            .font(.headline)
                    }
                    HStack(spacing: 10) {
                        TextField("时间（可留空）", text: $item.dueDate)
                            .font(.caption)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if item.kind == .event {
                            TextField("分钟", value: $item.durationMinutes, format: .number)
                                .font(.caption)
                                .keyboardType(.numberPad)
                                .frame(width: 56)
                        }
                        Text(item.kind.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !item.notes.isEmpty {
                        TextField("备注", text: $item.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .onDelete { offsets in items.remove(atOffsets: offsets) }

            Button(busy ? "写入中…" : "写入系统（\(items.filter { $0.include }.count) 条）") { writeAll() }
                .disabled(busy || items.filter { $0.include }.isEmpty)
        } header: {
            Text("确认")
        } footer: {
            Text("只有勾选的条目会被写入。待办进提醒事项的「AI助理」列表，日程进日历的「AI助理」，备忘暂不写入（备忘录需要经快捷指令中转，下一轮做）。")
        }
    }

    private var statusSection: some View {
        Section("结果") {
            Text(status)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    // MARK: - 动作

    private func parse() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
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
        status = "正在解析…"

        Task {
            do {
                let parsed = try await AIStructurer.parse(text: text, config: config)
                await MainActor.run {
                    self.busy = false
                    if parsed.isEmpty {
                        self.status = "没能从这段内容里抽出可执行的条目。\n如果内容确实包含待办，把原文和这个结果一并告诉我，我改 prompt。"
                    } else {
                        self.items.append(contentsOf: parsed)
                        self.input = ""
                        self.status = "解析出 \(parsed.count) 条，确认后点「写入系统」。"
                    }
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.status = "解析失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func writeAll() {
        let selected = items.filter { $0.include }
        guard !selected.isEmpty else {
            status = "没有勾选任何条目"
            return
        }
        busy = true
        status = "正在写入 \(selected.count) 条…"

        Task {
            var succeeded: [String] = []
            var failures: [String] = []

            for item in selected {
                do {
                    switch item.kind {
                    case .todo:
                        try await SystemWriter.writeReminder(
                            title: item.title,
                            notes: item.notes,
                            dueDate: item.dueDate,
                            priority: item.priority
                        )
                        succeeded.append("待办 · \(item.title)")
                    case .event:
                        try await SystemWriter.writeEvent(
                            title: item.title,
                            notes: item.notes,
                            dueDate: item.dueDate,
                            durationMinutes: item.durationMinutes
                        )
                        succeeded.append("日程 · \(item.title)")
                    case .note:
                        AppLog.info("Writer", "备忘未写入系统（待做快捷指令桥接）：\(item.title)")
                        succeeded.append("备忘（仅记录）· \(item.title)")
                    }
                } catch {
                    failures.append("\(item.title)：\(error.localizedDescription)")
                }
            }

            let ok = succeeded
            let bad = failures
            await MainActor.run {
                self.busy = false
                var lines: [String] = []
                lines.append("成功 \(ok.count) 条")
                lines.append(contentsOf: ok.map { "  ✅ " + $0 })
                if !bad.isEmpty {
                    lines.append("失败 \(bad.count) 条")
                    lines.append(contentsOf: bad.map { "  ❌ " + $0 })
                }
                self.status = lines.joined(separator: "\n")
                self.items.removeAll { $0.include }
            }
        }
    }
}

#Preview {
    AssistantView().environmentObject(SettingsStore())
}
