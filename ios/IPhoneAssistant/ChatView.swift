import SwiftUI
import UIKit
import PhotosUI
import AVFoundation
import AVKit

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
    /// 正在全屏播的那段视频
    @State private var playingMedia: ChatMedia?
    /// 语音输入是「接着已经打的字往下说」，不是把输入框清空重来
    @State private var voicePrefix = ""
    /// 正在跑的请求。用来支持「停止」。
    @State private var sendTask: Task<Void, Never>?
    /// 条目卡片上的编辑 → 库里那一行的同步（合并 0.6 秒再跑）
    @State private var syncTask: Task<Void, Never>?
    /// 触觉触发器：写入成功一次、删除一次
    @State private var hapticSuccess = 0
    @State private var hapticWarning = 0

    /// 还没发出去的附件。图片先压成 JPEG 留在内存，视频先躺在相册给的临时文件里，
    /// 点发送时才一起落盘到 chatMedia/。
    private struct Attachment: Identifiable {
        let id = UUID()
        var kind: ChatMedia.Kind = .image
        /// 图片：压好的 JPEG
        var data: Data?
        /// 图片：界面上的预览
        var image: UIImage?
        /// 视频：相册导出的临时文件
        var videoURL: URL?
        var durationSeconds: Double = 0
        var pixelSize: CGSize = .zero
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
                      matching: .any(of: [.images, .videos]))
        .onChange(of: libraryItems) { _, items in loadLibrary(items) }
        .sheet(item: $playingMedia) { item in
            VideoPlayerSheet(url: MediaLibrary.url(for: item))
        }
        .onAppear {
            balance.refreshIfStale(settings: settings)
            if openCameraOnAppear { openCamera() }
        }
        .onChange(of: liveASR.liveText) { _, text in
            if liveASR.isRunning { draft = voicePrefix + text }
        }
        // 第三方引擎是「说完才出字」，最终文字走 transcript
        .onChange(of: liveASR.transcript) { _, text in
            guard !text.isEmpty else { return }
            draft = voicePrefix + text
            voicePrefix = ""
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
                if entry.hasAttachments { mediaStrip(entry.allMedia) }
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

    /// 气泡上的附件条：图片和视频缩略图。视频点一下全屏播。
    private func mediaStrip(_ items: [ChatMedia]) -> some View {
        HStack(spacing: 6) {
            ForEach(items) { item in
                if item.isVideo {
                    Button {
                        playingMedia = item
                    } label: {
                        mediaThumbnail(item)
                    }
                    .buttonStyle(.plain)
                } else {
                    mediaThumbnail(item)
                }
            }
        }
    }

    private func mediaThumbnail(_ item: ChatMedia) -> some View {
        Group {
            if let image = chats.thumbnail(for: item) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .overlay(Image(systemName: item.isVideo ? "video" : "photo")
                        .foregroundStyle(.secondary))
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if item.isVideo {
                ZStack {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(item.durationText)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(5)
                }
            }
        }
        .accessibilityLabel(item.isVideo ? "视频，\(item.durationText)，点按播放" : "图片")
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
                ItemsCard(items: itemsBinding(entry.id)) { itemID in
                    toggleInclude(itemID: itemID, entryID: entry.id)
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
        let failed = entry.items?.contains { $0.include && $0.saveError != nil } ?? false
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(failed ? Color.orange : Color.green)
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
                    Group {
                        if liveASR.isTranscribing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: liveASR.isRunning ? "waveform.circle.fill" : "waveform")
                                .font(.title2)
                                .foregroundStyle(liveASR.isRunning ? Color.red : Color.secondary)
                                .symbolEffect(.variableColor, isActive: liveASR.isRunning)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .disabled(busy || liveASR.isTranscribing)
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
                    attachmentThumb(item)
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
                            .accessibilityLabel(item.kind == .video ? "移除这段视频" : "移除这张照片")
                        }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func attachmentThumb(_ item: Attachment) -> some View {
        Group {
            if let image = item.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle()
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .overlay(Image(systemName: "video").foregroundStyle(.secondary))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if item.kind == .video {
                Text(Self.durationText(item.durationSeconds))
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(4)
            }
        }
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) 秒" }
        return "\(total / 60):\(String(format: "%02d", total % 60))"
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
                    Image(systemName: balance.isLow ? "exclamationmark.triangle.fill" : balance.chipIcon).font(.caption)
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
        if liveASR.isTranscribing { return "正在识别…" }
        return liveASR.isRunning ? "在听…" : "发消息或按住说话…"
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    private func itemsBinding(_ id: String) -> Binding<[ParsedItem]> {
        Binding(
            get: { entry(id)?.items ?? [] },
            set: { newValue in
                let previous = entry(id)?.items ?? []
                updateEntry(id) { $0.items = newValue }
                // 卡片上的改动直接落到「安排」里那一行——卡片不是草稿，是监督面板。
                // 打字是连续动作：合并 0.6 秒再同步，免得每敲一个字就重排一遍通知。
                // 也不能就地同步：这句是在视图更新里跑的，直接改 store 会撞
                // 「Modifying state during view update」。
                syncTask?.cancel()
                syncTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }
                    applyEdits(from: previous, entryID: id)
                }
            }
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
        attachments.append(Attachment(kind: .image,
                                      data: data,
                                      image: image,
                                      pixelSize: image.size))
    }

    /// 相册里选的可能是图片也可能是视频。视频按文件引用来（不把整段读进内存）。
    private func loadLibrary(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        libraryItems = []
        Task {
            for item in items {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    await attachVideo(url: movie.url)
                    continue
                }
                if let raw = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: raw) {
                    await MainActor.run { attach(image) }
                }
            }
        }
    }

    private func attachVideo(url: URL) async {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        var size = CGSize.zero
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize) {
            size = natural
        }
        guard seconds > 0.2 else {
            toast = "这段视频读不出来（太短，或者格式不支持）。"
            try? FileManager.default.removeItem(at: url)
            return
        }
        attachments.append(Attachment(kind: .video,
                                      videoURL: url,
                                      durationSeconds: seconds,
                                      pixelSize: size))
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

        // 附件落盘，消息里只留元信息；发给模型时才读回来（视频抽帧）
        let media = saveAttachments()
        var user = ChatEntry(role: .user, text: text)
        user.media = media
        user.quote = quoting
        let quote = quoting
        quoting = nil
        draft = ""
        attachments = []
        chats.append(user, to: threadID)

        dispatch(text: text, media: media, quote: quote)
    }

    /// 附件落盘。图片是写文件，视频是从相册的临时文件拷进来（拷完把临时的删掉）。
    private func saveAttachments() -> [ChatMedia] {
        attachments.compactMap { item in
            switch item.kind {
            case .image:
                guard let data = item.data else { return nil }
                return MediaLibrary.saveImage(data, size: item.pixelSize)
            case .video:
                guard let url = item.videoURL else { return nil }
                let saved = MediaLibrary.saveVideo(from: url,
                                                   duration: item.durationSeconds,
                                                   size: item.pixelSize)
                try? FileManager.default.removeItem(at: url)
                return saved
            }
        }
    }

    /// 失败重试：把上一条用户消息原样再发一次（附件从磁盘读回来，不丢图也不丢视频）
    private func retry(assistantEntryID: String) {
        guard let index = entries.firstIndex(where: { $0.id == assistantEntryID }),
              index > 0 else { return }
        let userEntry = entries[index - 1]
        guard userEntry.role == .user else { return }

        removeEntry(assistantEntryID)
        dispatch(text: userEntry.text, media: userEntry.allMedia, quote: userEntry.quote)
    }

    /// 真正发请求的那一段。send 和 retry 都走这里。
    private func dispatch(text: String, media: [ChatMedia], quote: ChatQuote? = nil) {
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
                // 附件变成图：图片直接编码，视频抽四帧，并在文字里说明那是视频的画面
                let payload = await Self.modelPayload(for: media)
                let promptText = payload.note.isEmpty ? text : text + "\n" + payload.note
                let result = try await AIStructurer.parse(text: promptText,
                                                          images: payload.images,
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

    /// 附件 → 能发给模型的图（data URL）+ 一句说明。
    ///
    /// 网关只吃图片，视频没法直接发，所以抽几帧当画面。抽帧比整段视频省得多，
    /// 而「拍一段白板 / 扫一眼现场」这类用途，四帧和整段给的信息差不多。
    private static func modelPayload(for media: [ChatMedia]) async -> (images: [String], note: String) {
        guard !media.isEmpty else { return ([], "") }
        var images: [String] = []
        var videoCount = 0
        for item in media {
            if item.isVideo {
                videoCount += 1
                for frame in await VideoFrames.extract(from: MediaLibrary.url(for: item)) {
                    images.append("data:image/jpeg;base64,\(frame.base64EncodedString())")
                }
            } else if let data = try? Data(contentsOf: MediaLibrary.url(for: item)) {
                images.append("data:image/jpeg;base64,\(data.base64EncodedString())")
            }
        }
        let note = videoCount > 0
            ? "（用户发来 \(videoCount) 段视频，下面的图片是视频里的画面，请按这些画面理解）"
            : ""
        return (images, note)
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
                // 条目这一轮就建好了，下面那张卡片是核对的入口，不用再点一次「存下」
                entry.text = ItemWriter.summary(for: result.items) + "在下面核对一下：改哪一项都会同步过去，点左边的圈可以撤下。"
            }
        }
        if remembered.facts + remembered.logs > 0 {
            AppLog.info("Chat", "记忆已更新：长期 \(remembered.facts) 条、流水 \(remembered.logs) 条")
        }
        // 条目不等用户确认，模型一回来就落库——用户只监督，不再点「存下」
        autosave(id)
        // 模型刚回来的东西立刻落盘，别等那 0.8 秒的合并窗口
        chats.saveNow()
        // 这一趟已经花掉 token 了，余额重新查一次，胶囊上的数字才是真的
        balance.refresh(settings: settings)
    }

    // MARK: - 条目的自动落库与监督

    /// 模型刚整理出的条目立刻写进「安排」，一条失败不拖垮其余。
    private func autosave(_ id: String) {
        guard let items = entry(id)?.items, !items.isEmpty else { return }
        for item in items where item.include && item.savedItemID == nil {
            save(itemID: item.id, entryID: id, announce: false)
        }
        if entry(id)?.items?.contains(where: { $0.savedItemID != nil }) == true {
            hapticSuccess += 1
        }
        refreshStatus(id)
        chats.saveNow()
    }

    /// 存一条到「安排」。失败就在那张卡片上写明原因（缺时间、时间认不出），
    /// 用户改完时间会自动再试一次——不再有「点了按钮才知道存不下」。
    ///
    /// 模型带回来的 `existing_item_id` 能对上库里哪一行时，走的是**改**那一行：
    /// 用户说「第二条改成周五」，模型会把整份清单重列一遍，那几条是改不是新建。
    private func save(itemID: String, entryID id: String, announce: Bool = true) {
        guard var item = entry(id)?.items?.first(where: { $0.id == itemID }) else { return }
        guard item.include else { return }

        // 认一认模型抄回来的 id：对得上就当成「改那条」
        if item.savedItemID == nil, let echoed = item.existingItemID,
           ItemStore.shared.item(id: echoed) != nil {
            item.savedItemID = echoed
            AppLog.info("Chat", "条目「\(item.title)」认作改「安排」里已有的那条 \(echoed)")
        }
        item.existingItemID = nil

        do {
            if let savedID = item.savedItemID, let existing = ItemStore.shared.item(id: savedID) {
                let updated = try ItemWriter.makeItem(from: item, existing: existing, source: threadID)
                ItemStore.shared.update(updated)
            } else {
                let saved = try ItemWriter.save(item, source: threadID)
                item.savedItemID = saved.id
            }
            item.saveError = nil
            updateItem(item, entryID: id)
            if announce { hapticSuccess += 1 }
        } catch {
            item.saveError = error.localizedDescription
            updateItem(item, entryID: id)
            AppLog.warn("Chat", "条目「\(item.title)」没存下：\(error.localizedDescription)")
        }
        refreshStatus(id)
    }

    /// 卡片上的圈：勾上就建，撤下就从「安排」里删掉（还能再勾回来）
    private func toggleInclude(itemID: String, entryID id: String) {
        guard var item = entry(id)?.items?.first(where: { $0.id == itemID }) else { return }
        item.include.toggle()
        if item.include {
            updateItem(item, entryID: id)
            save(itemID: itemID, entryID: id)
            toast = "已加进「安排」"
            return
        }
        if let savedID = item.savedItemID, let existing = ItemStore.shared.item(id: savedID) {
            ItemStore.shared.delete(existing)
        }
        item.savedItemID = nil
        item.saveError = nil
        updateItem(item, entryID: id)
        toast = "已从「安排」里撤下「\(item.title)」，再点一下能加回来"
        hapticWarning += 1
        refreshStatus(id)
    }

    /// 卡片上改过的字段（标题、时间、类型、重复、时长）同步到库里那一行。
    /// 之前没存下的（比如时间认不出）改完再试一次。
    private func applyEdits(from previous: [ParsedItem], entryID id: String) {
        guard let items = entry(id)?.items else { return }
        for item in items {
            guard let old = previous.first(where: { $0.id == item.id }) else { continue }
            guard item.title != old.title
                    || item.notes != old.notes
                    || item.dueDate != old.dueDate
                    || item.durationMinutes != old.durationMinutes
                    || item.kind != old.kind
                    || item.repeatRule != old.repeatRule
                    || item.remindBeforeMinutes != old.remindBeforeMinutes else { continue }
            guard item.include else { continue }

            if let savedID = item.savedItemID {
                // 那一行可能已经在「安排」里被删了（用户的动作优先），删了就什么都不做
                guard let existing = ItemStore.shared.item(id: savedID) else { continue }
                do {
                    let updated = try ItemWriter.makeItem(from: item, existing: existing, source: threadID)
                    ItemStore.shared.update(updated)
                    if item.saveError != nil { saveError(nil, itemID: item.id, entryID: id) }
                } catch {
                    saveError(error.localizedDescription, itemID: item.id, entryID: id)
                }
            } else if item.saveError != nil {
                save(itemID: item.id, entryID: id)
            }
        }
        refreshStatus(id)
    }

    /// 卡片顶上的那句话：存下几条、哪几条没成
    private func refreshStatus(_ id: String) {
        guard let items = entry(id)?.items, !items.isEmpty else { return }
        let saved = items.filter { $0.savedItemID != nil }
        let failed = items.filter { $0.include && $0.saveError != nil }
        var lines: [String] = []
        if !saved.isEmpty {
            let names = saved.map { "\($0.kind.label)「\($0.title)」" }.joined(separator: "、")
            lines.append("已存下 \(saved.count) 条：\(names)")
        }
        if !failed.isEmpty {
            let reasons = failed.map { "「\($0.title)」\($0.saveError ?? "")" }.joined(separator: "；")
            lines.append("这 \(failed.count) 条没存下：\(reasons)")
        }
        updateEntry(id) { entry in
            entry.writtenKinds = saved.map { $0.kind.rawValue }
            entry.result = lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
    }

    private func updateItem(_ item: ParsedItem, entryID id: String) {
        updateEntry(id) { entry in
            guard var items = entry.items, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[index] = item
            entry.items = items
        }
    }

    private func saveError(_ message: String?, itemID: String, entryID id: String) {
        guard var item = entry(id)?.items?.first(where: { $0.id == itemID }) else { return }
        item.saveError = message
        updateItem(item, entryID: id)
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

/// 助手消息里的那张卡片。**它不再是「草稿 + 存下按钮」**，而是已经建好的那几条的监督面板：
/// 模型一回来条目就写进「安排」了，这里改什么（标题、时间、类型、重复）就同步改库里那一行，
/// 点左边的圈就是撤下（从「安排」里删掉）或加回来。
/// 它直接绑定到 ChatStore 里的那条消息，所以改完切页面再回来还在。
private struct ItemsCard: View {

    @Binding var items: [ParsedItem]
    /// 点某一条左边的圈：存下 / 撤下
    let onToggle: (String) -> Void

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
    }

    private func itemRow(_ item: Binding<ParsedItem>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                onToggle(item.wrappedValue.id)
            } label: {
                Image(systemName: circleIcon(item.wrappedValue))
                    .font(.title3)
                    .foregroundStyle(circleTint(item.wrappedValue))
                    // 圈本身只有 20 pt 上下，热区按 HIG 补到 44×44
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.wrappedValue.include ? "从安排里撤下这条" : "把这条加进安排")

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

                // 没存下的原因写在原地：用户在这儿改一下时间就会自动再存一次
                if let reason = item.wrappedValue.saveError {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text(reason)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.orange)
                }
            }
            .opacity(item.wrappedValue.include ? 1 : 0.55)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func circleIcon(_ item: ParsedItem) -> String {
        if item.include && item.saveError != nil { return "exclamationmark.circle.fill" }
        return item.include ? "checkmark.circle.fill" : "circle"
    }

    private func circleTint(_ item: ParsedItem) -> Color {
        if item.include && item.saveError != nil { return .orange }
        return item.include ? Color.accentColor : Color.secondary
    }

    /// 这一条会怎么提醒你——顺手也能改类型，以及**多久重复一次**（每天 / 工作日 / 每周 / 每月）。
    ///
    /// 模型把照片里的东西判成「备忘」是常见的事，而备忘不提醒。
    /// 与其让用户回到对话里重新说一遍，不如在这里点一下就改过去。
    private func kindMenu(_ item: Binding<ParsedItem>) -> some View {
        Menu {
            ForEach(ParsedItem.Kind.allCases, id: \.self) { candidate in
                Button {
                    item.wrappedValue.kind = candidate
                    if candidate == .note { item.wrappedValue.repeatRule = .none }
                } label: {
                    Label("\(candidate.label)（\(candidate.behavior)）", systemImage: candidate.symbol)
                }
            }
            if item.wrappedValue.kind != .note {
                Section("重复") {
                    ForEach(RepeatRule.allCases, id: \.self) { rule in
                        Button {
                            item.wrappedValue.repeatRule = rule
                        } label: {
                            Label(rule.pickerLabel,
                                  systemImage: item.wrappedValue.repeatRule == rule ? "checkmark" : "repeat")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(capsuleText(item.wrappedValue))
                    .font(.caption2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.accentColor)
        }
        .accessibilityLabel("这条怎么提醒：\(capsuleText(item.wrappedValue))，点按改类型或重复")
    }

    private func capsuleText(_ item: ParsedItem) -> String {
        guard item.kind != .note, item.repeatRule != .none else { return item.kind.behavior }
        return "\(item.kind.behavior) · \(item.repeatRule.label)"
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(allSelected ? "全部撤下" : "全部加回") {
                let target = !allSelected
                if target {
                    for index in items.indices where !items[index].include {
                        onToggle(items[index].id)
                    }
                } else {
                    for index in items.indices where items[index].include {
                        onToggle(items[index].id)
                    }
                }
            }
            .font(.footnote)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Text(countText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var allSelected: Bool {
        !items.isEmpty && items.allSatisfy { $0.include }
    }

    private var countText: String {
        let saved = items.filter { $0.savedItemID != nil }.count
        if saved == items.count { return "\(saved) 条都在「安排」里" }
        return "\(saved)/\(items.count) 条在「安排」里"
    }
}

// MARK: - 视频播放

/// 全屏播一段视频。用系统的 `VideoPlayer`：播放控件、全屏、画中画、AirPlay 都是系统给的，
/// 自己画一套只会把「暂停」「拖动」这些人人都会的东西做坏。
private struct VideoPlayerSheet: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView()
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear {
            player = AVPlayer(url: url)
        }
        .onDisappear { player?.pause() }
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
