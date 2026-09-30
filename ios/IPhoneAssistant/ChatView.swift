import SwiftUI
import UIKit
import PhotosUI

/// 对话页：和助理说话，它把话里的待办、日程、备忘直接建出来。
///
/// 这个页面的重点是没有「解析」这一步——发出去的消息本身就是操作，
/// 助手回过来的卡片就是要建的东西，确认一下就能写进系统。
/// 需要自己一项项填的时候去「速记」页，那是给人用手填的。
struct ChatView: View {
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var chat = ChatStore()
    @StateObject private var liveASR = LiveSpeechRecognizer()

    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @State private var libraryItems: [PhotosPickerItem] = []
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var showClearConfirm = false
    @State private var toast = ""
    /// 语音输入是「接着已经打的字往下说」，不是把输入框清空重来
    @State private var voicePrefix = ""

    /// 还没发出去的照片：先留在内存里，点发送时才落盘
    private struct Attachment: Identifiable {
        let id = UUID()
        let data: Data
        let image: UIImage
    }

    private let bottomAnchor = "chat-bottom"

    private let examples = [
        "10 分钟后提醒我给供应商打个电话",
        "明天下午三点跟老王过一下方案，提前半小时提醒我",
        "这周五之前把报价单发给采购"
    ]

    var body: some View {
        NavigationStack {
            conversation
                .background(Color(.systemBackground))
                .navigationTitle("对话")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .toolbar { toolbarContent }
                .fullScreenCover(isPresented: $showCamera) {
                    CameraPicker(isPresented: $showCamera) { attach($0) }
                        .ignoresSafeArea()
                }
                .photosPicker(isPresented: $showLibrary,
                              selection: $libraryItems,
                              maxSelectionCount: 4,
                              matching: .images)
                .onChange(of: libraryItems) { _, items in loadLibrary(items) }
                .onChange(of: liveASR.liveText) { _, text in
                    if liveASR.isRunning { draft = voicePrefix + text }
                }
                .onDisappear { if liveASR.isRunning { liveASR.stop() } }
                .confirmationDialog("清空这段对话？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                    Button("清空", role: .destructive) { chat.clear() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("对话记录和里面的图片都会被删掉。已经写进提醒事项和日历的条目不受影响。")
                }
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

    // MARK: - 对话流

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if chat.entries.isEmpty { welcome }
                    ForEach(chat.entries) { entry in
                        row(entry).id(entry.id)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 点消息之间的空白处收键盘。手势只挂在背景层上：
                // 挂在 ScrollView 上会连卡片里的输入框一起抢，一点就失焦。
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { hideKeyboard() }
                )
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.entries.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: chat.entries.last?.state) { _, _ in scrollToBottom(proxy) }
            .onChange(of: chat.entries.last?.items?.count) { _, _ in scrollToBottom(proxy) }
            .onAppear {
                DispatchQueue.main.async { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    /// 空对话时的开场白。顺手把几个例子做成可直接点开的引子——
    /// 第一次用的人往往不知道该说多具体。
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("直接说要做的事")
                    .font(.title3.weight(.semibold))
                Text("说一句话，我就把里面的待办、日程、备忘建出来，你确认后直接进提醒事项和日历。不用自己填表，也不用先选类型。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settings.hasKey {
                Label("凭证已就绪 · \(settings.model)", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label("还没配置密钥，先去「设置」页填一个", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("试一句")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ForEach(examples, id: \.self) { text in
                    Button {
                        draft = text
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10))
                            Text(text)
                                .font(.footnote)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("也可以拍白板、纸质笔记、聊天截图，图里的待办和时间我会一起读出来。说完还能接着改：「第二条改成周五下午」。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func row(_ entry: ChatEntry) -> some View {
        if entry.role == .user {
            userRow(entry)
        } else {
            assistantRow(entry)
        }
    }

    private func userRow(_ entry: ChatEntry) -> some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 8) {
                if !entry.images.isEmpty { imageStrip(entry.images) }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor,
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .contextMenu {
                Button(role: .destructive) {
                    chat.remove(id: entry.id)
                } label: {
                    Label("删除这条", systemImage: "trash")
                }
            }
        }
    }

    private func imageStrip(_ names: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(names, id: \.self) { name in
                if let image = chat.thumbnail(named: name) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 88, height: 88)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
            }
        }
    }

    private func assistantRow(_ entry: ChatEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if entry.state == .thinking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(entry.text.isEmpty ? "正在整理…" : entry.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } else if !entry.text.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                    Text(entry.text)
                        .font(.callout)
                        .foregroundStyle(entry.state == .failed ? Color.orange : Color.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let items = entry.items, !items.isEmpty {
                ItemsCard(items: itemsBinding(entry.id), busy: entry.busy) {
                    write(entry.id)
                }
            }

            if let result = entry.result {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .padding(.top, 2)
                        Text(result)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // 写进的是「AI助理」这个列表/日历，不是默认那个。
                    // 用户去提醒事项里翻不到是常事，给个直达入口省得到处找。
                    if !entry.writtenKinds.isEmpty {
                        HStack(spacing: 8) {
                            if entry.writtenKinds.contains("todo") {
                                openAppButton("打开提醒事项", scheme: "x-apple-reminder://")
                            }
                            if entry.writtenKinds.contains("event") {
                                openAppButton("打开日历", scheme: "calshow://")
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 输入栏

    private var composer: some View {
        VStack(spacing: 8) {
            if !liveASR.message.isEmpty && !liveASR.isRunning && liveASR.message != "已停止" {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text(liveASR.message)
                        .font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !attachments.isEmpty { attachmentStrip }

            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button {
                        openCamera()
                    } label: {
                        Label("拍照", systemImage: "camera")
                    }
                    Button {
                        showLibrary = true
                    } label: {
                        Label("从相册选择", systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 19))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .disabled(busy)

                TextField(composerPlaceholder, text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Button {
                    toggleVoice()
                } label: {
                    Image(systemName: liveASR.isRunning ? "waveform.circle.fill" : "waveform")
                        .font(.system(size: 21))
                        .foregroundStyle(liveASR.isRunning ? Color.red : Color.secondary)
                        .frame(width: 32, height: 34)
                        .contentShape(Rectangle())
                        .symbolEffect(.variableColor, isActive: liveASR.isRunning)
                }
                .disabled(busy)

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 27))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .disabled(!canSend)
            }
            .padding(.bottom, liveASR.isRunning ? 2 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { item in
                    Image(uiImage: item.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                attachments.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 17))
                                    .foregroundStyle(.white, .black.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .padding(3)
                        }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("收起键盘") { hideKeyboard() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if !chat.entries.isEmpty {
                Menu {
                    Button {
                        showClearConfirm = true
                    } label: {
                        Label("清空对话", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - 状态与工具

    private var busy: Bool {
        chat.entries.contains { $0.busy || $0.state == .thinking }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var composerPlaceholder: String {
        liveASR.isRunning ? "在听…" : "说一句要做的事…"
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    private func itemsBinding(_ id: String) -> Binding<[ParsedItem]> {
        Binding(
            get: { chat.entry(id: id)?.items ?? [] },
            set: { newValue in chat.update(id: id) { $0.items = newValue } }
        )
    }

    private func openAppButton(_ title: String, scheme: String) -> some View {
        Button {
            guard let url = URL(string: scheme) else { return }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        } label: {
            HStack(spacing: 4) {
                Text(title).font(.caption)
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func openCamera() {
        guard CameraPicker.isAvailable else {
            toast = "这台设备没有可用的相机（模拟器上也没有）。用「从相册选择」吧。"
            return
        }
        hideKeyboard()
        showCamera = true
    }

    private func attach(_ image: UIImage) {
        guard let data = image.compressedForLLM() else {
            toast = "这张照片读不出来（格式不支持）。"
            return
        }
        attachments.append(Attachment(data: data, image: image))
    }

    private func loadLibrary(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        libraryItems = []
        Task {
            for item in items {
                guard let raw = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: raw) else { continue }
                await MainActor.run { attach(image) }
            }
        }
    }

    private func toggleVoice() {
        if liveASR.isRunning {
            liveASR.stop()
            voicePrefix = ""
            return
        }
        hideKeyboard()
        voicePrefix = draft
        liveASR.start()
    }

    // MARK: - 动作

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }

        let config = settings.makeConfig()
        guard config.chatCompletionsURL != nil, !config.apiKey.isEmpty else {
            toast = "还没有可用的密钥，去「设置」页填一个再发。"
            return
        }

        if liveASR.isRunning { liveASR.stop() }
        voicePrefix = ""
        hideKeyboard()

        // 图片先落盘，消息里只留文件名；发给模型时才读回来转 base64
        let dataURLs = attachments.map { "data:image/jpeg;base64,\($0.data.base64EncodedString())" }
        var user = ChatEntry(role: .user, text: text)
        user.images = attachments.compactMap { chat.saveImage($0.data) }
        draft = ""
        attachments = []
        chat.append(user)

        let thinking = ChatEntry(role: .assistant, text: "", state: .thinking)
        chat.append(thinking)
        let history = chat.historyText()

        Task {
            do {
                let items = try await AIStructurer.parse(text: text,
                                                         images: dataURLs,
                                                         history: history,
                                                         config: config)
                await MainActor.run { apply(items, to: thinking.id, error: nil) }
            } catch {
                await MainActor.run { apply([], to: thinking.id, error: error.localizedDescription) }
            }
        }
    }

    private func apply(_ items: [ParsedItem], to id: String, error: String?) {
        chat.update(id: id) { entry in
            if let error {
                entry.state = .failed
                entry.text = "这条没处理成功：\(error)"
                return
            }
            entry.state = .ok
            if items.isEmpty {
                entry.text = """
                这段里没有找到可以执行的事。\
                如果是想让我记下一件事，可以说得更具体一点，比如「明天下午三点跟老王过方案」。
                """
            } else {
                entry.text = "整理出 \(items.count) 条，核对一下，没问题就写进系统。"
                entry.items = items
            }
        }
    }

    private func write(_ id: String) {
        guard let entry = chat.entry(id: id), let items = entry.items else { return }
        let selected = items.filter { $0.include }
        guard !selected.isEmpty else {
            chat.update(id: id) { $0.result = "没有勾选任何条目。" }
            return
        }

        // 先按目标分好组：写完之后要能明确说出「哪几条去了哪里」，
        // 不然用户回到提醒事项里找不到东西，也没法判断是没写进去还是看错了列表。
        let selectedTodos = selected.filter { $0.kind == .todo }
        let selectedEvents = selected.filter { $0.kind == .event }
        let selectedNotes = selected.filter { $0.kind == .note }
        let selectedNotices = selected.filter { $0.kind == .notification }
        AppLog.info("Chat", "开始写入：待办 \(selectedTodos.count)、日程 \(selectedEvents.count)、备忘 \(selectedNotes.count)、通知 \(selectedNotices.count)")

        chat.update(id: id) { $0.busy = true }

        Task {
            let result = await SystemWriter.writeAll(selected)
            await MainActor.run {
                var summary: [String] = []
                if !selectedTodos.isEmpty { summary.append("提醒事项 \(selectedTodos.count) 条") }
                if !selectedEvents.isEmpty { summary.append("日历 \(selectedEvents.count) 条") }
                if !selectedNotices.isEmpty { summary.append("通知 \(selectedNotices.count) 条") }
                if !selectedNotes.isEmpty { summary.append("备忘 \(selectedNotes.count) 条") }
                AppLog.info("Chat", "写入结束：成功 \(result.succeeded.count)，失败 \(result.failed.count)")

                chat.update(id: id) { entry in
                    entry.busy = false
                    entry.items = nil
                    entry.writtenKinds = selected.map { $0.kind.rawValue }
                    var lines: [String] = []
                    if !result.succeeded.isEmpty {
                        lines.append("已写入：" + summary.joined(separator: "、"))
                        lines.append(contentsOf: result.succeeded.map { "· " + $0 })
                    }
                    if !result.failed.isEmpty {
                        lines.append("失败 \(result.failed.count) 条：")
                        lines.append(contentsOf: result.failed.map { "· " + $0 })
                    }
                    entry.result = lines.joined(separator: "\n")

                    if result.failed.isEmpty {
                        var text = "已写入 " + summary.joined(separator: "、") + "。"
                        if !selectedTodos.isEmpty {
                            text += "待办在提醒事项的「\(SystemWriter.reminderListName)」列表里。"
                        }
                        if !selectedEvents.isEmpty {
                            text += "日程在日历的「\(SystemWriter.calendarName)」里。"
                        }
                        if !selectedNotices.isEmpty {
                            text += "通知到点会弹出来，不用它了可以在「速记」页取消。"
                        }
                        if !selectedNotes.isEmpty {
                            text += "备忘存在 App 里，在「速记」页能看到。"
                        }
                        entry.text = text
                    } else {
                        entry.text = "写入完成：成功 \(result.succeeded.count) 条，失败 \(result.failed.count) 条。"
                    }
                }
            }
        }
    }
}

// MARK: - 条目卡片

/// 助手消息里的那张卡片：勾选 / 改标题 / 改时间 / 写进系统。
/// 它直接绑定到 ChatStore 里的那条消息，所以改完切页面再回来还在。
private struct ItemsCard: View {

    @Binding var items: [ParsedItem]
    let busy: Bool
    let onWrite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach($items) { $item in
                itemRow($item)
                if $item.wrappedValue.id != items.last?.id {
                    Divider().padding(.leading, 44)
                }
            }
            Divider()
            footer
        }
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .disabled(busy)
    }

    private func itemRow(_ item: Binding<ParsedItem>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                item.wrappedValue.include.toggle()
            } label: {
                Image(systemName: item.wrappedValue.include ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(item.wrappedValue.include ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: item.wrappedValue.kind.symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("标题", text: item.title, axis: .vertical)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1...3)
                    destinationMenu(item)
                }

                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                        Text("分钟")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if !item.wrappedValue.notes.isEmpty {
                    Text(item.wrappedValue.notes)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// 这一条会存到哪儿——顺手也能改。
    ///
    /// 模型把照片里的东西判成「备忘」是常见的事，而备忘不会进提醒事项。
    /// 与其让用户回到对话里重新说一遍，不如在这里点一下就改过去。
    private func destinationMenu(_ item: Binding<ParsedItem>) -> some View {
        Menu {
            ForEach(ParsedItem.Kind.allCases, id: \.self) { candidate in
                Button {
                    item.wrappedValue.kind = candidate
                } label: {
                    Label("\(candidate.label) → \(destination(of: candidate))", systemImage: candidate.symbol)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(destination(of: item.wrappedValue.kind))
                    .font(.system(size: 10))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
            .foregroundStyle(Color.accentColor)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(allSelected ? "全不选" : "全选") {
                let target = !allSelected
                for index in items.indices { items[index].include = target }
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Text("\(items.filter { $0.include }.count)/\(items.count) 条")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: onWrite) {
                HStack(spacing: 6) {
                    if busy {
                        ProgressView().controlSize(.mini)
                    }
                    Text(writeTitle)
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(busy || items.allSatisfy { !$0.include })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var allSelected: Bool {
        !items.isEmpty && items.allSatisfy { $0.include }
    }

    /// 按钮上直接说清这批东西会落到哪儿
    private var writeTitle: String {
        if busy { return "写入中…" }
        let selected = items.filter { $0.include }
        guard !selected.isEmpty else { return "写入系统" }
        let kinds = Set(selected.map { $0.kind })
        if kinds.count == 1, let only = kinds.first {
            return "存入\(destination(of: only))（\(selected.count) 条）"
        }
        return "写入系统（\(selected.count) 条）"
    }

    private func destination(of kind: ParsedItem.Kind) -> String { kind.destination }
}

// MARK: - 图片压缩

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
    ChatView().environmentObject(SettingsStore())
}
