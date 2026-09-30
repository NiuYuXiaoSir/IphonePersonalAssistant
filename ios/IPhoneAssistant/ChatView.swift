import SwiftUI
import UIKit
import PhotosUI

/// 一段对话：和助理说话，它把话里的待办、日程、备忘、提醒直接建出来。
///
/// 这个页面的重点是没有「解析」这一步——发出去的消息本身就是操作，
/// 助手回过来的卡片就是要建的东西，确认一下就能写进系统。
/// 需要自己一项项填的时候去「速记」页，那是给人用手填的。
///
/// 版式照元宝：用户消息是右边的灰色气泡，助手的话是不带气泡的正文，
/// 下面跟一排方形小按钮（复制 / 朗读 / 删除）；底部是一条圆角胶囊，
/// 相机、输入框、语音、发送都在胶囊里面，不再是几个分开的圆按钮。
///
/// 它是被「对话」列表推进来的（外面已经有 NavigationStack），所以这里不再套一层。
struct ChatView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var chats: ChatStore
    /// 余额是全局一份：这里花掉 token 之后，别的页面看到的数字也跟着变
    @ObservedObject private var balance = BalanceStore.shared

    /// 看的是哪一段对话
    let threadID: String

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
        Group {
            if entries.isEmpty {
                welcome
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                conversation
            }
        }
        .background(YBColor.bg)
        .navigationTitle(threadTitle)
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
        .onAppear { balance.refreshIfStale(settings: settings) }
        .onChange(of: liveASR.liveText) { _, text in
            if liveASR.isRunning { draft = voicePrefix + text }
        }
        .onDisappear {
            if liveASR.isRunning { liveASR.stop() }
            YBSpeech.stop()
        }
        .confirmationDialog("清空这段对话？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空", role: .destructive) { chats.clearThread(id: threadID) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这段对话的消息和图片都会被删掉，会话本身留着。已经写进提醒事项、日历、备忘的东西不受影响。")
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

    // MARK: - 会话读写

    private var entries: [ChatEntry] { chats.thread(id: threadID)?.entries ?? [] }

    private var threadTitle: String { chats.thread(id: threadID)?.title ?? "对话" }

    private func entry(_ id: String) -> ChatEntry? {
        entries.first { $0.id == id }
    }

    private func updateEntry(_ id: String, _ mutate: (inout ChatEntry) -> Void) {
        chats.updateThread(id: threadID) { thread in
            guard let index = thread.entries.firstIndex(where: { $0.id == id }) else { return }
            mutate(&thread.entries[index])
        }
    }

    private func removeEntry(_ id: String) {
        chats.updateThread(id: threadID) { thread in
            thread.entries.removeAll { $0.id == id }
        }
        chats.saveNow()
    }

    // MARK: - 空对话的问候
    //
    // 元宝首页中间就是一句大字问候，这里照搬：整块内容在可用区域里居中，
    // 下面跟几个能直接点开的引子——第一次用的人往往不知道该说多具体。

    private var welcome: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Text("Hi，有什么要办的？")
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)

                Text("说一句就把待办、日程、备忘、提醒建出来，\n核对一下直接进提醒事项和日历。")
                    .font(.system(size: 15))
                    .foregroundStyle(YBColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            keyStatus

            VStack(spacing: 8) {
                ForEach(examples, id: \.self) { text in
                    Button {
                        draft = text
                    } label: {
                        Text(text)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(YBColor.surface,
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(YBPressStyle())
                }
            }
        }
        .padding(.horizontal, 28)
    }

    @ViewBuilder
    private var keyStatus: some View {
        if settings.hasKey {
            Label("凭证已就绪 · \(settings.model)", systemImage: "checkmark.seal")
                .font(.system(size: 13))
                .foregroundStyle(YBColor.success)
        } else {
            Label("还没配置密钥，先去「设置」页填一个", systemImage: "exclamationmark.triangle")
                .font(.system(size: 13))
                .foregroundStyle(YBColor.warning)
        }
    }

    // MARK: - 对话流

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(entries) { entry in
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
            .onAppear {
                DispatchQueue.main.async { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: entries.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: entries.last?.state) { _, _ in scrollToBottom(proxy) }
            .onChange(of: entries.last?.items?.count) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: ChatEntry) -> some View {
        if entry.role == .user {
            userRow(entry)
        } else {
            assistantRow(entry)
        }
    }

    // MARK: - 用户消息

    private func userRow(_ entry: ChatEntry) -> some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 8) {
                if !entry.images.isEmpty { imageStrip(entry.images) }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .font(YBFont.chatBody)
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(YBColor.surfaceHi,
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .contextMenu {
                Button(role: .destructive) {
                    removeEntry(entry.id)
                } label: {
                    Label("删除这条", systemImage: "trash")
                }
            }
        }
    }

    private func imageStrip(_ names: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(names, id: \.self) { name in
                if let image = chats.thumbnail(named: name) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(YBColor.surface)
                        .frame(width: 88, height: 88)
                        .overlay(Image(systemName: "photo").foregroundStyle(YBColor.textSecondary))
                }
            }
        }
    }

    // MARK: - 助手消息

    private func assistantRow(_ entry: ChatEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if entry.state == .thinking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(entry.text.isEmpty ? "正在整理…" : entry.text)
                        .font(YBFont.chatBody)
                        .foregroundStyle(YBColor.textSecondary)
                }
                .padding(.vertical, 2)
            } else if !entry.text.isEmpty {
                Text(entry.text)
                    .font(YBFont.chatBody)
                    .foregroundStyle(entry.state == .failed ? YBColor.warning : Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let items = entry.items, !items.isEmpty {
                ItemsCard(items: itemsBinding(entry.id), busy: entry.busy) {
                    write(entry.id)
                }
            }

            if let result = entry.result {
                resultCard(entry, result: result)
            }

            if entry.state != .thinking && !entry.text.isEmpty {
                actionRow(entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultCard(_ entry: ChatEntry, result: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(YBColor.success)
                    .padding(.top, 2)
                Text(result)
                    .font(.system(size: 14))
                    .foregroundStyle(YBColor.textSecondary)
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
        .background(YBColor.surface,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 助手消息下面那排方形小按钮。元宝是五个（复制/赞/踩/朗读/转发），
    /// 这里只留真的能用的三个：复制、朗读、删除。
    private func actionRow(_ entry: ChatEntry) -> some View {
        HStack(spacing: 8) {
            YBSquareButton(icon: "doc.on.doc") {
                UIPasteboard.general.string = entry.text
                toast = "已复制这条回复"
            }
            YBSquareButton(icon: "speaker.wave.2") {
                YBSpeech.toggle(entry.text)
            }
            YBSquareButton(icon: "trash", tint: YBColor.danger) {
                removeEntry(entry.id)
            }
        }
    }

    // MARK: - 输入栏

    private var composer: some View {
        VStack(spacing: 8) {
            if !liveASR.message.isEmpty && !liveASR.isRunning && liveASR.message != "已停止" {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(liveASR.message)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(YBColor.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }

            if !attachments.isEmpty { attachmentStrip }

            HStack(alignment: .bottom, spacing: 4) {
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
                        .font(.system(size: 20))
                        .foregroundStyle(YBColor.textSecondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .disabled(busy)

                TextField(composerPlaceholder, text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(YBFont.chatBody)
                    .padding(.vertical, 8)
                    .frame(minHeight: 36)

                Button {
                    toggleVoice()
                } label: {
                    Image(systemName: liveASR.isRunning ? "waveform.circle.fill" : "waveform")
                        .font(.system(size: 21))
                        .foregroundStyle(liveASR.isRunning ? YBColor.danger : YBColor.textSecondary)
                        .frame(width: 34, height: 36)
                        .contentShape(Rectangle())
                        .symbolEffect(.variableColor, isActive: liveASR.isRunning)
                }
                .disabled(busy)

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(canSend ? YBColor.accent : YBColor.textTertiary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(YBColor.surface,
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
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
        ToolbarItemGroup(placement: .topBarTrailing) {
            // 这一页每发一次消息都要花 token，余额摆在能看见的地方
            if balance.supports(settings) { balanceChip }
            if !entries.isEmpty {
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

    /// 顶上的余额胶囊：点一下重新查
    private var balanceChip: some View {
        YBBalanceChip(text: balance.chipText,
                      icon: balance.chipIcon,
                      tint: balanceTint,
                      busy: balance.isRefreshing) {
            balance.refresh(settings: settings)
        }
    }

    private var balanceTint: Color {
        if balance.isLow { return YBColor.warning }
        if balance.isUnavailable { return YBColor.textSecondary }
        return Color.primary
    }

    // MARK: - 状态与工具

    private var busy: Bool {
        entries.contains { $0.busy || $0.state == .thinking }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var composerPlaceholder: String {
        liveASR.isRunning ? "在听…" : "发消息或按住说话…"
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    private func itemsBinding(_ id: String) -> Binding<[ParsedItem]> {
        Binding(
            get: { entry(id)?.items ?? [] },
            set: { newValue in updateEntry(id) { $0.items = newValue } }
        )
    }

    private func openAppButton(_ title: String, scheme: String) -> some View {
        Button {
            guard let url = URL(string: scheme) else { return }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        } label: {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 13))
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10))
            }
        }
        .buttonStyle(YBSoftButtonStyle())
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
        user.images = attachments.compactMap { chats.saveImage($0.data) }
        draft = ""
        attachments = []
        chats.append(user, to: threadID)

        let thinking = ChatEntry(role: .assistant, text: "", state: .thinking)
        chats.append(thinking, to: threadID)
        let history = chats.historyText(threadID: threadID)

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
        updateEntry(id) { entry in
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
        // 模型刚回来的东西立刻落盘，别等那 0.8 秒的合并窗口
        chats.saveNow()
        // 这一趟已经花掉 token 了，余额重新查一次，胶囊上的数字才是真的
        balance.refresh(settings: settings)
    }

    private func write(_ id: String) {
        guard let entry = entry(id), let items = entry.items else { return }
        let selected = items.filter { $0.include }
        guard !selected.isEmpty else {
            updateEntry(id) { $0.result = "没有勾选任何条目。" }
            return
        }

        // 先按目标分好组：写完之后要能明确说出「哪几条去了哪里」，
        // 不然用户回到提醒事项里找不到东西，也没法判断是没写进去还是看错了列表。
        let selectedTodos = selected.filter { $0.kind == .todo }
        let selectedEvents = selected.filter { $0.kind == .event }
        let selectedNotes = selected.filter { $0.kind == .note }
        let selectedNotices = selected.filter { $0.kind == .notification }
        AppLog.info("Chat", "开始写入：待办 \(selectedTodos.count)、日程 \(selectedEvents.count)、备忘 \(selectedNotes.count)、通知 \(selectedNotices.count)")

        updateEntry(id) { $0.busy = true }

        Task {
            let result = await SystemWriter.writeAll(selected)
            await MainActor.run {
                var summary: [String] = []
                if !selectedTodos.isEmpty { summary.append("提醒事项 \(selectedTodos.count) 条") }
                if !selectedEvents.isEmpty { summary.append("日历 \(selectedEvents.count) 条") }
                if !selectedNotices.isEmpty { summary.append("通知 \(selectedNotices.count) 条") }
                if !selectedNotes.isEmpty { summary.append("备忘 \(selectedNotes.count) 条") }
                AppLog.info("Chat", "写入结束：成功 \(result.succeeded.count)，失败 \(result.failed.count)")

                updateEntry(id) { entry in
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
                chats.saveNow()
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
                    Rectangle().fill(YBColor.line).frame(height: 1).padding(.leading, 44)
                }
            }
            Rectangle().fill(YBColor.line).frame(height: 1)
            footer
        }
        .background(YBColor.surface,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .disabled(busy)
    }

    private func itemRow(_ item: Binding<ParsedItem>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                item.wrappedValue.include.toggle()
            } label: {
                Image(systemName: item.wrappedValue.include ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(item.wrappedValue.include ? YBColor.accent : YBColor.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: item.wrappedValue.kind.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(YBColor.textSecondary)
                    TextField("标题", text: item.title, axis: .vertical)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1...3)
                    destinationMenu(item)
                }

                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(YBColor.textSecondary)
                    TextField("时间（可留空）", text: item.dueDate)
                        .font(.system(size: 13))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if item.wrappedValue.kind == .event {
                        TextField("分钟", value: item.durationMinutes, format: .number)
                            .font(.system(size: 13))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 42)
                        Text("分钟")
                            .font(.system(size: 12))
                            .foregroundStyle(YBColor.textSecondary)
                    }
                }

                if !item.wrappedValue.notes.isEmpty {
                    Text(item.wrappedValue.notes)
                        .font(.system(size: 12))
                        .foregroundStyle(YBColor.textSecondary)
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
            .background(YBColor.accent.opacity(0.16), in: Capsule())
            .foregroundStyle(YBColor.accent)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(allSelected ? "全不选" : "全选") {
                let target = !allSelected
                for index in items.indices { items[index].include = target }
            }
            .font(.system(size: 13))
            .buttonStyle(.plain)
            .foregroundStyle(YBColor.accent)

            Text("\(items.filter { $0.include }.count)/\(items.count) 条")
                .font(.system(size: 12))
                .foregroundStyle(YBColor.textSecondary)

            Spacer()

            Button(action: onWrite) {
                HStack(spacing: 6) {
                    if busy {
                        ProgressView().controlSize(.mini)
                    }
                    Text(writeTitle)
                }
            }
            .buttonStyle(YBPrimaryButtonStyle())
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
    NavigationStack {
        ChatListView()
    }
    .environmentObject(ChatStore())
    .environmentObject(SettingsStore())
}
