import SwiftUI
import UIKit
import PhotosUI

/// 速记页：输入一段话（打字 / 说话 / 拍张照）→ AI 拆成可执行条目 → 你确认 → 写入提醒事项 / 日历。
struct AssistantView: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var input = ""
    @State private var items: [ParsedItem] = []
    @State private var status = ""
    @State private var busy = false

    @StateObject private var liveASR = LiveSpeechRecognizer()
    @State private var pickerItem: PhotosPickerItem?
    @State private var imageData: Data?

    private let example = "明天下午三点跟老王过一下堵盖的方案，提前半小时提醒我；另外这周五之前把报价单发给采购"

    var body: some View {
        NavigationStack {
            List {
                setupSection
                inputSection
                if let data = imageData, let ui = UIImage(data: data) {
                    attachedSection(data: data, image: ui)
                }
                if !items.isEmpty { reviewSection }
                if !status.isEmpty { statusSection }
            }
            .navigationTitle("速记")
            // 滑动列表即收起键盘。iOS 上没有“点空白收键盘”的惯例，滚动收起 + 键盘上方的按钮才是
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { hideKeyboard() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !items.isEmpty {
                        Button("清空") {
                            items.removeAll()
                            status = ""
                        }
                    }
                }
            }
            .onChange(of: liveASR.liveText) { _, newValue in
                // 语音进行中时，识别结果实时回填到输入框，用户可以边看边改
                if liveASR.isRunning { input = newValue }
            }
            .onChange(of: pickerItem) { _, newItem in
                loadPicked(newItem)
            }
            .onDisappear {
                if liveASR.isRunning { liveASR.stop() }
            }
        }
    }

    // MARK: - 区块

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

            HStack(spacing: 10) {
                Button {
                    toggleVoice()
                } label: {
                    Label(liveASR.isRunning ? "停止" : "说话",
                          systemImage: liveASR.isRunning ? "stop.circle.fill" : "mic.fill")
                }
                .buttonStyle(.bordered)
                .tint(liveASR.isRunning ? Color.red : Color.accentColor)

                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("贴照片", systemImage: "photo")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(busy ? "处理中…" : "解析") { parse() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !canParse)
            }

            if liveASR.isRunning {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.red)
                        .symbolEffect(.variableColor)
                    Text(input.isEmpty ? "在听…直接说话" : input)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !liveASR.message.isEmpty && liveASR.message != "已停止" {
                Text(liveASR.message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("输入")
        } footer: {
            Text("可以打字、可以说话、也可以贴一张照片（白板、纸质笔记、聊天截图都行）。滑动列表或点键盘上方的「收起键盘」即可关掉键盘。")
        }
    }

    private func attachedSection(data: Data, image: UIImage) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                        .font(.caption)
                    Text("\(data.count / 1024) KB")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    imageData = nil
                    pickerItem = nil
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }
        } header: {
            Text("附图")
        } footer: {
            Text("图片会被压到长边 1568 像素后发给模型。用 DeepSeek 时要选支持视觉的 deepseek-flash，deepseek-v4-pro 不支持图片。")
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
            Text("只有勾选的条目会被写入。待办进提醒事项的「AI助理」列表，日程进日历的「AI助理」，备忘暂不写入。")
        }
    }

    private var statusSection: some View {
        Section("结果") {
            Text(status)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    // MARK: - 状态与工具

    private var canParse: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageData != nil
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    private func toggleVoice() {
        if liveASR.isRunning {
            liveASR.stop()
            hideKeyboard()
            return
        }
        hideKeyboard()
        // 语音输入是“新增一句”，不是替换——保留已经打的字
        let existing = input
        input = existing
        liveASR.start()
        // 识别结果会通过 onChange 覆盖 input；这里先把已有内容记下来，避免被清掉
        if !existing.isEmpty {
            status = "语音输入会直接覆盖输入框内容。如果要追加，先把手打的字剪贴走。"
        }
    }

    private func loadPicked(_ newItem: PhotosPickerItem?) {
        guard let newItem else { return }
        Task {
            do {
                guard let raw = try await newItem.loadTransferable(type: Data.self) else {
                    await MainActor.run { self.status = "读取图片失败（拿不到数据）" }
                    return
                }
                await MainActor.run {
                    if let ui = UIImage(data: raw), let compressed = ui.compressedForLLM() {
                        self.imageData = compressed
                        AppLog.info("Vision", "已选图：原始 \(raw.count / 1024) KB，压缩后 \(compressed.count / 1024) KB")
                    } else {
                        self.status = "这张图片读不出来（格式不支持）"
                    }
                }
            } catch {
                await MainActor.run { self.status = "读取图片出错：\(error.localizedDescription)" }
            }
        }
    }

    // MARK: - 动作

    private func parse() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var images: [String] = []
        if let data = imageData {
            images = ["data:image/jpeg;base64,\(data.base64EncodedString())"]
        }
        guard !text.isEmpty || !images.isEmpty else { return }
        if liveASR.isRunning { liveASR.stop() }

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
                let parsed = try await AIStructurer.parse(text: text, images: images, config: config)
                await MainActor.run {
                    self.busy = false
                    if parsed.isEmpty {
                        self.status = "没能从这段内容里抽出可执行的条目。\n如果内容确实包含待办，把原文和诊断页的日志一并告诉我，我改 prompt。"
                    } else {
                        self.items.append(contentsOf: parsed)
                        self.input = ""
                        self.imageData = nil
                        self.pickerItem = nil
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
                self.items.removeAll { $0.include }
            }
        }
    }
}

extension UIImage {
    /// 压到适合发给模型的尺寸。
    /// 不压的话原图 base64 后轻松过 MB，请求体会很大且慢。
    func compressedForLLM(maxSide: CGFloat = 1568, quality: CGFloat = 0.7) -> Data? {
        let longest = max(size.width, size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        guard target.width > 0, target.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}

#Preview {
    AssistantView().environmentObject(SettingsStore())
}
