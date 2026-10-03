import SwiftUI

/// 对话列表：新建对话、分组、按时间分段的会话。
///
/// 一个话题一个会话，比所有东西都堆在一条时间线里好找；
/// 长期用下来再按「工作」「家里」这类分组建文件夹。
/// 版式用系统 List + 系统搜索：分段、取消按钮、键盘收起都是系统给的。
struct ChatListView: View {
    @EnvironmentObject private var chats: ChatStore
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var history = YBSearchHistory.chats

    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renamingFolder: ChatFolder?
    @State private var renameText = ""
    @State private var undoMessage = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                newChatSection
                if !chats.folders.isEmpty { folderSection }
                threadSections
            }
            .navigationTitle("对话")
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "搜索对话")
            .searchSuggestions {
                if query.isEmpty {
                    ForEach(history.items, id: \.self) { keyword in
                        Label(keyword, systemImage: "clock.arrow.circlepath")
                            .searchCompletion(keyword)
                    }
                }
            }
            .onSubmit(of: .search) { history.add(query) }
            .navigationDestination(for: String.self) { id in
                ChatView(threadID: id)
            }
            .navigationDestination(for: FolderRoute.self) { route in
                ChatFolderView(path: $path, folderID: route.folderID)
            }
            .navigationDestination(for: MemoryRoute.self) { _ in
                MemoryView()
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        path.append(MemoryRoute())
                    } label: {
                        Image(systemName: "brain")
                    }
                    .accessibilityLabel("记忆：助理记住了什么")

                    Button {
                        router.showQuickAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("记一条")

                    Button {
                        showNewFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .accessibilityLabel("新建分组")
                }
            }
            .alert("新建分组", isPresented: $showNewFolder) {
                TextField("分组名字", text: $newFolderName)
                Button("创建") {
                    chats.createFolder(name: newFolderName)
                    newFolderName = ""
                }
                Button("取消", role: .cancel) { newFolderName = "" }
            } message: {
                Text("分组只是给对话分类，删掉分组不会删掉里面的对话。")
            }
            .alert("重命名分组", isPresented: Binding(
                get: { renamingFolder != nil },
                set: { if !$0 { renamingFolder = nil } }
            )) {
                TextField("分组名字", text: $renameText)
                Button("保存") {
                    if let folder = renamingFolder {
                        chats.renameFolder(id: folder.id, name: renameText)
                    }
                    renamingFolder = nil
                }
                Button("取消", role: .cancel) { renamingFolder = nil }
            }
            .onAppear(perform: consumeShortcut)
            .onChange(of: router.pending) { _, _ in consumeShortcut() }
            .onChange(of: chats.recentlyDetachedThread?.id) { _, _ in
                if let thread = chats.recentlyDetachedThread {
                    undoMessage = "已删除「\(thread.title)」"
                }
            }
            .toast($undoMessage,
                   actionTitle: "撤销",
                   duration: 4,
                   onExpire: { chats.commitDetachThread() },
                   action: { chats.undoDetachThread() })
        }
    }

    /// 长按图标点了「新建对话」：建一个直接推进去
    private func consumeShortcut() {
        guard router.pending == .newChat else { return }
        router.pending = nil
        DispatchQueue.main.async {
            let thread = chats.createThread()
            path.append(thread.id)
        }
    }

    // MARK: - 新建

    private var newChatSection: some View {
        Section {
            Button {
                let thread = chats.createThread()
                path.append(thread.id)
            } label: {
                Label("新建对话", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
        } footer: {
            Text("说一句话就把待办、日程、备忘、提醒建出来，不用自己填表。右上角的脑子图标里能看到它记住了什么。")
        }
    }

    // MARK: - 分组

    private var folderSection: some View {
        Section("分组") {
            ForEach(chats.folders) { folder in
                Button {
                    path.append(FolderRoute(folderID: folder.id))
                } label: {
                    HStack {
                        Label(folder.name, systemImage: "folder")
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text("\(chats.threadCount(inFolder: folder.id))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        chats.deleteFolder(id: folder.id)
                    } label: {
                        Label("删分组", systemImage: "trash")
                    }
                    Button {
                        renameText = folder.name
                        renamingFolder = folder
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    .tint(.accentColor)
                }
            }
        }
    }

    // MARK: - 会话

    @ViewBuilder
    private var threadSections: some View {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ungrouped = chats.threads(inFolder: nil)

        if searching {
            let results = searchResults
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            } else {
                Section("找到 \(results.count) 段对话") {
                    ForEach(results) { thread in
                        threadRow(thread,
                                  subtitle: thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
        } else if ungrouped.isEmpty {
            Section {
                ContentUnavailableView {
                    Label(chats.threads.isEmpty ? "还没有对话" : "未分组的对话是空的",
                          systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text(chats.threads.isEmpty
                         ? "点上面的「新建对话」开始，说完一句话就会在这里留下一条。"
                         : "展开分组看看，或者新建一段对话。")
                }
                .listRowBackground(Color.clear)
            }
        } else {
            ForEach(TimeBucket.allCases) { bucket in
                let list = bucket.filter(ungrouped)
                if !list.isEmpty {
                    Section(bucket.title) {
                        ForEach(list) { thread in
                            threadRow(thread, subtitle: bucketSubtitle(thread))
                        }
                    }
                }
            }
        }
    }

    private func bucketSubtitle(_ thread: ChatThread) -> String {
        let time = thread.updatedAt.formatted(date: .omitted, time: .shortened)
        return thread.preview.isEmpty ? time : time + " · " + thread.preview
    }

    private var searchResults: [ChatThread] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return chats.threads }
        return chats.threads.filter {
            $0.title.localizedCaseInsensitiveContains(keyword)
                || $0.preview.localizedCaseInsensitiveContains(keyword)
        }
    }

    /// 一行会话：整行可点进对话，行尾一个「…」是**不用手势**的入口
    /// （移到分组、删除都在里面——长按不能是唯一的路，HIG 的 Gestures 页有明文）。
    private func threadRow(_ thread: ChatThread, subtitle: String) -> some View {
        HStack(spacing: 8) {
            Button {
                path.append(thread.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(thread.title)
                        .font(.body)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            Menu {
                Menu {
                    Button("不分组") { chats.moveThread(id: thread.id, to: nil) }
                    ForEach(chats.folders) { folder in
                        Button(folder.name) { chats.moveThread(id: thread.id, to: folder.id) }
                    }
                } label: {
                    Label("移到分组", systemImage: "folder")
                }
                Button(role: .destructive) {
                    chats.detachThread(id: thread.id)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("「\(thread.title)」的更多操作")
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                chats.detachThread(id: thread.id)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 会话按最近更新时间分段
    private enum TimeBucket: String, CaseIterable, Identifiable {
        case today, yesterday, thisMonth, earlier

        var id: String { rawValue }

        var title: String {
            switch self {
            case .today:     return "今天"
            case .yesterday: return "昨天"
            case .thisMonth: return "本月"
            case .earlier:   return "更早"
            }
        }

        func filter(_ threads: [ChatThread]) -> [ChatThread] {
            let calendar = Calendar.current
            return threads.filter { thread in
                switch self {
                case .today:     return calendar.isDateInToday(thread.updatedAt)
                case .yesterday: return calendar.isDateInYesterday(thread.updatedAt)
                case .thisMonth: return calendar.isDate(thread.updatedAt, equalTo: Date(), toGranularity: .month)
                    && !calendar.isDateInToday(thread.updatedAt)
                    && !calendar.isDateInYesterday(thread.updatedAt)
                case .earlier:
                    return !calendar.isDate(thread.updatedAt, equalTo: Date(), toGranularity: .month)
                }
            }
        }
    }
}

/// 分组里那一层：只列这个分组下的对话
struct ChatFolderView: View {
    @EnvironmentObject private var chats: ChatStore
    @Binding var path: NavigationPath
    let folderID: String

    var body: some View {
        List {
            let list = chats.threads(inFolder: folderID)
            if list.isEmpty {
                ContentUnavailableView {
                    Label("这个分组还是空的", systemImage: "folder")
                } description: {
                    Text("在对话列表里左滑一条，或者点行尾的「…」，选「移到分组」。")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(list) { thread in
                    Button {
                        path.append(thread.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(thread.title)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Text(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            chats.detachThread(id: thread.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle(chats.folderName(folderID))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 分组页的跳转标识。会话 id 也是字符串，用不同的类型区分开，
/// 免得两个 navigationDestination(for: String.self) 撞在一起。
struct FolderRoute: Hashable {
    let folderID: String
}
