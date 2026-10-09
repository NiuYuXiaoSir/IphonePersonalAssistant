import SwiftUI
import UIKit
import PhotosUI

/// 一段对话：和助理说话，它把话里的待办、日程、备忘、提醒直接建出来。
///
/// 这个页面的重点是没有「解析」这一步——发出去的消息本身就是操作，
/// 助手回过来的卡片就是要建的东西，确认一下就能写进系统。
/// 需要自己一项项填的时候去「速记」页，那是给人用手填的。
///
/// 版式全是系统件：用户消息是右边的灰色气泡，助手的话直接排（不套气泡），
/// 底部一条输入胶囊。模型回来的话按 Markdown 轻渲染——问「今天做了什么」时它常带列表和粗体，
/// 不渲染就会露出 ** 和 - 这些符号。
///
/// 消息上的动作（引用 / 复制 / 朗读 / 删除）走**长按菜单**，不再常驻一排小图标：
/// 那排按钮会一直占着正文下面的位置，看着像工具面板，不像在跟人说话。
/// 长按看一条消息能做什么，是和微信、信息一致的照做（HIG 的 Menus 页：
/// context menu「lets people access a small number of frequently used actions
/// relevant to their current view or task」；Gestures 页把 touch and hold 定义为
/// 「Reveal additional controls or functionality」）。
///
/// 它是被「对话」列表推进来的（外面已经有 NavigationStack），所以这里不再套一层。
struct ChatView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var chats: ChatStore
    /// 余额是全局一份：这里花掉 token 之后，别的页面看到的数字也跟着变
    @ObservedObject private var balance = BalanceStore.shared

    /// 看的是哪一段对话
    let threadID: String
    /// 从「＋ → 拍照」进来时，相机直接打开
    var openCameraOnAppear: Bool = false

    @StateObject private var liveASR = LiveSpeechRecognizer()

    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @State private var libraryItems: [PhotosPickerItem] = []
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var showClearConfirm = false
    @State private var toast = ""
    /// 正在引用（回复）哪一条。引用块挂在输入框上方，发出去或点叉就没了。
    @State private var quoting: ChatQuote?
    /// 点了引用块要跳到的那条消息。ScrollViewReader 的代理在 conversation 里，
    /// 所以这里只放个「要去哪」，由那边负责滚。
    @State private var scrollTarget: String?
    /// 语音输入是「接着已经打的字往下说」，不是把输入框清空重来
    @State private var voicePrefix = ""
    /// 正在跑的请求。用来支持「停止」。
    @State private var sendTask: Task<Void, Never>?
    /// 触觉触发器：写入成功一次、删除一次
    @State private var hapticSuccess = 0
    @State private var hapticWarning = 0

    /// 还没发出去的照片：先留在内存里，点发送时才落盘
    private struct Attachment: Identifiable {
        let id = UUID()
        let data: Data
        let image: UIImage
    }

    /// 一组消息 + 它上面要不要加日期分隔
    private struct DisplayEntry: Identifiable {
        let id: String
        let entry: ChatEntry
        let separator: String?
    }

    private let bottomAnchor = "chat-bottom"

    private let examples = [
        "10 分钟后提醒我给供应商打个电话",
        "明天下午三点跟老王过一下方案，提前半小时提醒我",
        "我今天做了什么？明天要做什么？"
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
        .background(Color(uiColor: .systemBackground))
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
        .onAppear {
            balance.refreshIfStale(settings: settings)
            if openCameraOnAppear { openCamera() }
        }
        .onChange(of: liveASR.liveText) { _, text in
            if liveASR.isRunning { draft = voicePrefix + text }
        }
        .onDisappear {
            if liveASR.isRunning { liveASR.stop() }
            sendTask?.cancel()
            SpeechPlayer.stop()
        }
        .confirmationDialog("清空这段对话？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空", role: .destructive) { chats.clearThread(id: threadID) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这段对话的消息和图片都会被删掉，会话本身留着。已经存下的条目和备忘不受影响——它们在本机的数据库里，去「今日 → 安排」还能看到。")
        }
        .toast($toast)
        .sensoryFeedback(.success, trigger: hapticSuccess) { _, _ in settings.hapticsEnabled }
        .sensoryFeedback(.warning, trigger: hapticWarning) { _, _ in settings.hapticsEnabled }
    }

    // MARK: - 会话读写

    private var entries: [ChatEntry] { chats.thread(id: threadID)?.entries ?? [] }

    private var threadTitle: String { chats.thread(id: threadID)?.title ?? "对话" }

    /// 跨天的地方插一条日期分隔
    private var displayEntries: [DisplayEntry] {
        var out: [DisplayEntry] = []
        var lastDay: Date?
        for entry in entries {
            let day = Calendar.current.startOfDay(for: entry.createdAt)
            let separator = (lastDay == nil || lastDay != day) ? Self.dayLabel(entry.createdAt) : nil
            out.append(DisplayEntry(id: entry.id, entry: entry, separator: separator))
            lastDay = day
        }
        return out
    }

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

    private var welcome: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Text("Hi，有什么要办的？")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                Text("说一句就把待办、日程、备忘、提醒记下来，\n到点它会弹通知提醒你。\n它记得你说过的事——做了什么、要做什么都记着。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color(uiColor: .secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 28)
    }

    @ViewBuilder
    private var keyStatus: some View {
        if settings.hasKey {
            Label("凭证已就绪 · \(settings.model)", systemImage: "checkmark.seal")
                .font(.footnote)
                .foregroundStyle(.green)
        } else {
            Label("还没配置密钥，先去「设置」页填一个", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - 对话流

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(displayEntries) { item in
                        if let separator = item.separator {
                            Text(separator)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 2)
                        }
                        row(item.entry).id(item.entry.id)
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
            // 点了引用块：滚到被引用的那条，停一下再松开目标
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(target, anchor: .center)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { scrollTarget = nil }
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
                if !entry.text.isEmpty || entry.quote != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        if let quote = entry.quote { quotedBlock(quote) }
                        if !entry.text.isEmpty {
                            Text(entry.text)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .contextMenu { messageMenu(entry) }
        }
    }

    /// 气泡里那块引用（微信里的样子）：左边一条竖线，上面是被引用的人，下面是那句话。
    /// 点一下跳回原消息；原消息删了就说一声，不做无声失败。
    private func quotedBlock(_ quote: ChatQuote) -> some View {
        Button {
            guard entries.contains(where: { $0.id == quote.entryID }) else {
                toast = "引用的那条消息已经不在了"
                return
            }
            scrollTarget = quote.entryID
        } label: {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(quote.author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(quote.displayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .padding(.vertical, 5)
                .padding(.leading, 8)
                .padding(.trailing, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("引用\(quote.author)说的：\(quote.displayText)。点按跳到那条消息")
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
                        .fill(Color(uiColor: .secondarySystemBackground))
                        .frame(width: 88, height: 88)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
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
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("停止") { stopGenerating() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.vertical, 2)
            } else if !entry.text.isEmpty {
                rendered(entry.text)
                    .font(.body)
                    .foregroundStyle(entry.state == .failed ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if entry.state == .failed {
                Button {
                    retry(assistantEntryID: entry.id)
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let items = entry.items, !items.isEmpty {
                ItemsCard(items: itemsBinding(entry.id), busy: entry.busy) {
                    write(entry.id)
                }
            }

            if !entry.remembered.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entry.remembered, id: \.self) { line in
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "brain")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let result = entry.result {
                resultCard(entry, result: result)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 助手这条也一样长按出菜单。正文不再开「选择文字」——开了之后长按会被
        // 文字选择的系统菜单接管，长按菜单就出不来，两个手势会互相盖住。
        .contextMenu { messageMenu(entry) }
    }

    /// 一条消息能做的事。长按出菜单，不再常驻一排图标。
    ///
    /// 顺序按 HIG 的 Menus 页来：常用的放前面（引用 → 复制 → 朗读），
    /// 破坏性的「删除」用分隔线隔开单独一组、并标成 destructive。
    @ViewBuilder
    private func messageMenu(_ entry: ChatEntry) -> some View {
        Button {
            quoting = ChatStore.quote(from: entry)
        } label: {
            Label("引用", systemImage: "quote.opening")
        }

        if !entry.text.isEmpty {
            Button {
                UIPasteboard.general.string = entry.text
                toast = "已复制"
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }

            if entry.role == .assistant {
                Button {
                    SpeechPlayer.toggle(entry.text)
                } label: {
                    Label("朗读", systemImage: "speaker.wave.2")
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            hapticWarning += 1
            removeEntry(entry.id)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    /// 受控的 Markdown：粗体、行内代码、列表、引用这些会正常显示；
    /// 解析不了就当纯文本画出来，绝不吞内容。
    private func rendered(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func resultCard(_ entry: ChatEntry, result: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .padding(.top, 2)
                Text(result)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 条目都存在 App 自己这里，写完之后去哪儿看要说明白
            if !entry.writtenKinds.isEmpty {
                Button {
                    AppRouter.shared.showSchedule = true
                } label: {
                    HStack(spacing: 4) {
                        Text("去看安排").font(.footnote)
                        Image(systemName: "arrow.up.forward.app")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 助手消息下面那排小按钮（复制、朗读、删除）已经撤掉，动作改走长按菜单。
    /// 这一页里凡是「一条消息能做什么」，去 messageMenu 里找。

    // MARK: - 输入栏

    private var composer: some View {
        VStack(spacing: 8) {
            if !liveASR.message.isEmpty && !liveASR.isRunning && liveASR.message != "已停止" {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text(liveASR.message)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }

            if let quote = quoting { quotingBar(quote) }

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
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(busy)
                .accessibilityLabel("添加照片")

                TextField(composerPlaceholder, text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.body)
                    .padding(.vertical, 10)

                Button {
                    toggleVoice()
                } label: {
                    Image(systemName: liveASR.isRunning ? "waveform.circle.fill" : "waveform")
                        .font(.title2)
                        .foregroundStyle(liveASR.isRunning ? Color.red : Color.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .symbolEffect(.variableColor, isActive: liveASR.isRunning)
                }
                .disabled(busy)
                .accessibilityLabel(liveASR.isRunning ? "停止语音输入" : "开始语音输入")

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(canSend ? Color.accentColor : Color(uiColor: .tertiaryLabel))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    /// 输入框上面的「正在引用谁」条，发出去或点叉就收掉
    private func quotingBar(_ quote: ChatQuote) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "quote.opening")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("回复\(quote.author)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(quote.displayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                quoting = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary, Color(uiColor: .tertiarySystemFill))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消引用")
        }
        .padding(.leading, 8)
        .background(Color(uiColor: .tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                                    .font(.body)
                                    .foregroundStyle(.white, .black.opacity(0.5))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(-6)
                            .accessibilityLabel("移除这张照片")
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
                .accessibilityLabel("更多操作")
            }
        }
    }

    /// 顶上的余额：点一下重新查
    private var balanceChip: some View {
        Button {
            balance.refresh(settings: settings)
        } label: {
            HStack(spacing: 5) {
                if balance.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: balance.chipIcon).font(.caption)
                }
                Text(balance.chipText).font(.footnote)
            }
            .foregroundStyle(balanceTint)
        }
        .disabled(balance.isRefreshing)
        .accessibilityLabel("余额：\(balance.chipText)，点击刷新")
    }

    private var balanceTint: Color {
        if balance.isLow { return .orange }
        if balance.isUnavailable { return .secondary }
        return .primary
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

    private func config() -> LLMConfig? {
        var config = settings.makeConfig()
        guard config.chatCompletionsURL != nil, !config.apiKey.isEmpty else {
            toast = "还没有可用的密钥，去「设置」页填一个再发。"
            return nil
        }
        // 这一段对话自己的 id，OpenCode 的网关按它做路由和缓存
        config.sessionID = threadID
        return config
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        guard config() != nil else { return }

        if liveASR.isRunning { liveASR.stop() }
        voicePrefix = ""
        hideKeyboard()

        // 图片先落盘，消息里只留文件名；发给模型时才读回来转 base64
        let dataURLs = attachments.map { "data:image/jpeg;base64,\($0.data.base64EncodedString())" }
        var user = ChatEntry(role: .user, text: text)
        user.images = attachments.compactMap { chats.saveImage($0.data) }
        user.quote = quoting
        let quote = quoting
        quoting = nil
        draft = ""
        attachments = []
        chats.append(user, to: threadID)

        dispatch(text: text, dataURLs: dataURLs, quote: quote)
    }

    /// 失败重试：把上一条用户消息原样再发一次（图片从磁盘读回来，不丢图）
    private func retry(assistantEntryID: String) {
        guard let index = entries.firstIndex(where: { $0.id == assistantEntryID }),
              index > 0 else { return }
        let userEntry = entries[index - 1]
        guard userEntry.role == .user else { return }

        let dataURLs: [String] = userEntry.images.compactMap { name in
            guard let data = chats.imageData(named: name) else { return nil }
            return "data:image/jpeg;base64,\(data.base64EncodedString())"
        }
        removeEntry(assistantEntryID)
        dispatch(text: userEntry.text, dataURLs: dataURLs, quote: userEntry.quote)
    }

    /// 真正发请求的那一段。send 和 retry 都走这里。
    private func dispatch(text: String, dataURLs: [String], quote: ChatQuote? = nil) {
        guard let config = config() else { return }

        let thinking = ChatEntry(role: .assistant, text: "", state: .thinking)
        chats.append(thinking, to: threadID)
        let history = chats.historyText(threadID: threadID)
        // 记忆库给的相关上下文：长期记忆 + 最近几天的流水。
        // 「昨天说的那事」「明天要做什么」能接上，全靠它和上面的对话历史。
        let memory = MemoryStore.shared.digest(for: text)

        sendTask?.cancel()
        sendTask = Task {
            do {
                let result = try await AIStructurer.parse(text: text,
                                                          images: dataURLs,
                                                          history: history,
                                                          memory: memory,
                                                          quote: quote,
                                                          config: config)
                await MainActor.run { apply(result, to: thinking.id, error: nil) }
            } catch {
                let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled
                await MainActor.run {
                    if cancelled {
                        applyStopped(to: thinking.id)
                    } else {
                        apply(AIResult(), to: thinking.id, error: error.localizedDescription)
                    }
                }
            }
        }
    }

    /// 用户点了「停止」：保留已经拿到的部分，不要报成失败
    private func stopGenerating() {
        sendTask?.cancel()
        sendTask = nil
    }

    private func applyStopped(to id: String) {
        updateEntry(id) { entry in
            entry.state = .ok
            if entry.text.isEmpty { entry.text = "已停止。" }
        }
        chats.saveNow()
    }

    private func apply(_ result: AIResult, to id: String, error: String?) {
        // 模型说要记住的东西在这里落库；它和条目无关，失败了也不该影响这一轮对话
        var remembered = (facts: 0, logs: 0)
        if error == nil {
            remembered = MemoryStore.shared.remember(result.memories, source: threadID)
        }

        updateEntry(id) { entry in
            if let error {
                entry.state = .failed
                entry.text = "这条没处理成功：\(error)"
                return
            }
            entry.state = .ok
            entry.items = result.items
            entry.remembered = result.memories.prefix(3).map { $0.content }
            if !result.reply.isEmpty {
                // 模型自己的话优先：问「我今天做了什么」时要的就是这句回答
                entry.text = result.reply
            } else if result.items.isEmpty {
                entry.text = """
                这段里没有找到可以执行的事。\
                如果是想让我记下一件事，可以说得更具体一点，比如「明天下午三点跟老王过方案」。
                """
            } else {
                entry.text = "整理出 \(result.items.count) 条，核对一下，没问题就写进系统。"
            }
        }
        if remembered.facts + remembered.logs > 0 {
            AppLog.info("Chat", "记忆已更新：长期 \(remembered.facts) 条、流水 \(remembered.logs) 条")
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

        let counts = Dictionary(grouping: selected, by: { $0.kind })
            .map { "\($0.key.label) \($0.value.count)" }
            .sorted()
            .joined(separator: "、")
        AppLog.info("Chat", "开始存下：\(counts)")

        updateEntry(id) { $0.busy = true }

        // 存的是本机数据库里的一行，不再是别的 App——写库是同步的、毫秒级，
        // 所以不需要再起一个 Task 等系统接口（也就没有「权限被拒」这类失败）
        let result = ItemWriter.saveAll(selected, source: threadID)
        AppLog.info("Chat", "存下结束：成功 \(result.succeeded.count)，失败 \(result.failed.count)")

        updateEntry(id) { entry in
            entry.busy = false
            entry.items = nil
            entry.writtenKinds = selected.map { $0.kind.rawValue }
            var lines: [String] = []
            if !result.succeeded.isEmpty {
                lines.append("已存下：")
                lines.append(contentsOf: result.succeeded.map { "· " + $0 })
            }
            if !result.failed.isEmpty {
                lines.append("这 \(result.failed.count) 条没存下：")
                lines.append(contentsOf: result.failed.map { "· " + $0 })
            }
            entry.result = lines.joined(separator: "\n")

            if result.failed.isEmpty {
                hapticSuccess += 1
                entry.text = ItemWriter.summary(for: selected)
            } else {
                entry.text = "存下 \(result.succeeded.count) 条，\(result.failed.count) 条没成。"
            }
        }
        chats.saveNow()
    }

    // MARK: - 日期分隔

    private static func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return date.formatted(date: .abbreviated, time: .omitted)
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
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .disabled(busy)
    }

    private func itemRow(_ item: Binding<ParsedItem>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                item.wrappedValue.include.toggle()
            } label: {
                Image(systemName: item.wrappedValue.include ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.wrappedValue.include ? Color.accentColor : Color.secondary)
                    // 圈本身只有 20 pt 上下，热区按 HIG 补到 44×44
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.wrappedValue.include ? "不存这条" : "存这条")

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: item.wrappedValue.kind.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("标题", text: item.title, axis: .vertical)
                        .font(.body.weight(.medium))
                        .lineLimit(1...3)
                    kindMenu(item)
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

                if !item.wrappedValue.notes.isEmpty {
                    Text(item.wrappedValue.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// 这一条会怎么提醒你——顺手也能改类型。
    ///
    /// 模型把照片里的东西判成「备忘」是常见的事，而备忘不提醒。
    /// 与其让用户回到对话里重新说一遍，不如在这里点一下就改过去。
    private func kindMenu(_ item: Binding<ParsedItem>) -> some View {
        Menu {
            ForEach(ParsedItem.Kind.allCases, id: \.self) { candidate in
                Button {
                    item.wrappedValue.kind = candidate
                } label: {
                    Label("\(candidate.label)（\(candidate.behavior)）", systemImage: candidate.symbol)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(item.wrappedValue.kind.behavior)
                    .font(.caption2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.accentColor)
        }
        .accessibilityLabel("这条怎么提醒：\(item.wrappedValue.kind.behavior)，点按改类型")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(allSelected ? "全不选" : "全选") {
                let target = !allSelected
                for index in items.indices { items[index].include = target }
            }
            .font(.footnote)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Text("\(items.filter { $0.include }.count)/\(items.count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: onWrite) {
                HStack(spacing: 6) {
                    if busy {
                        ProgressView().controlSize(.mini)
                    }
                    Text(writeTitle)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(busy || items.allSatisfy { !$0.include })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var allSelected: Bool {
        !items.isEmpty && items.allSatisfy { $0.include }
    }

    /// 按钮上直接说清这批东西存几条、会不会响
    private var writeTitle: String {
        if busy { return "存下中…" }
        let selected = items.filter { $0.include }
        guard !selected.isEmpty else { return "存下来" }
        return "存下（\(selected.count) 条）"
    }
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
