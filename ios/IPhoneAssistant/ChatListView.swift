import SwiftUI

/// 对话列表：新建对话、分组、按时间分段的会话。
///
/// 一个话题一个会话，比所有东西都堆在一条时间线里好找；
/// 长期用下来再按「工作」「家里」这类分组建文件夹。
struct ChatListView: View {
    @EnvironmentObject private var chats: ChatStore
    @ObservedObject private var router = AppRouter.shared

    @State private var path: [String] = []
    @State private var foldersExpanded = true
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renamingFolder: ChatFolder?
    @State private var renameText = ""
    @State private var showSettingsHint = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                newChatSection
                if !chats.folders.isEmpty { folderSection }
                threadSections
            }
            .listStyle(.insetGrouped)
            .navigationTitle("对话")
            .navigationDestination(for: String.self) { id in
                ChatView(threadID: id)
            }
            .navigationDestination(for: FolderRoute.self) { route in
                ChatFolderView(folderID: route.folderID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            .alert("新建分组", isPresented: $showNewFolder) {
                TextField("分组名字", text: $newFolderName)
                Button("创建") {
                    chats.createFolder(name: newFolderName)
                    newFolderName = ""
                    foldersExpanded = true
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
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            }
        } footer: {
            Text("说一句话就把待办、日程、备忘、提醒建出来，不用自己填表。")
        }
    }

    // MARK: - 分组

    private var folderSection: some View {
        Section {
            ForEach(chats.folders) { folder in
                NavigationLink(value: FolderRoute(folderID: folder.id)) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(folder.name)
                        Spacer()
                        Text("\(chats.threadCount(inFolder: folder.id))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    .tint(.blue)
                }
            }

            if foldersExpanded {
                Button {
                    foldersExpanded = false
                } label: {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text("收起分组")
                        Spacer()
                        Image(systemName: "chevron.up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Button {
                    foldersExpanded = true
                } label: {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text("展开分组（\(chats.folders.count) 个）")
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("分组")
        }
    }

    // MARK: - 会话

    private var noThreadHint: String {
        chats.threads.isEmpty
            ? "还没有对话。点上面的「新建对话」开始，说完一句话就会在这里留下一条。"
            : "未分组的对话是空的，展开分组看看。"
    }

    private var threadSections: some View {
        let ungrouped = chats.threads(inFolder: nil)
        return Group {
            if ungrouped.isEmpty {
                Section {
                    Text(noThreadHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("最近")
                }
            } else {
                ForEach(TimeBucket.allCases) { bucket in
                    threadSection(bucket, from: ungrouped)
                }
            }
        }
    }

    @ViewBuilder
    private func threadSection(_ bucket: TimeBucket, from threads: [ChatThread]) -> some View {
        let list = bucket.filter(threads)
        if !list.isEmpty {
            Section(bucket.title) {
                ForEach(list) { thread in
                    threadRow(thread)
                }
            }
        }
    }

    private func threadRow(_ thread: ChatThread) -> some View {
        NavigationLink(value: thread.id) {
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(thread.updatedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !thread.preview.isEmpty {
                        Text(thread.preview)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .swipeActions {
            Button(role: .destructive) {
                chats.deleteThread(id: thread.id)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .contextMenu {
            Menu {
                Button("不分组") { chats.moveThread(id: thread.id, to: nil) }
                ForEach(chats.folders) { folder in
                    Button(folder.name) { chats.moveThread(id: thread.id, to: folder.id) }
                }
            } label: {
                Label("移到分组", systemImage: "folder")
            }
            Button(role: .destructive) {
                chats.deleteThread(id: thread.id)
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
    let folderID: String

    var body: some View {
        List {
            let list = chats.threads(inFolder: folderID)
            if list.isEmpty {
                Text("这个分组里还没有对话。在对话列表里长按一条，选「移到分组」。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(list) { thread in
                    NavigationLink(value: thread.id) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(thread.title).font(.subheadline.weight(.medium))
                            Text(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            chats.deleteThread(id: thread.id)
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

#Preview {
    ChatListView().environmentObject(ChatStore())
}
