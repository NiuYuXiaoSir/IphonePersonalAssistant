import SwiftUI

/// 对话列表：新建对话、分组、按时间分段的会话。
///
/// 版式和元宝的侧栏一致：新建按钮、分组（文件夹）、今天/本月这样按时间分段。
/// 一个话题一个会话，比所有东西都堆在一条时间线里好找；
/// 长期用下来再按「工作」「家里」这类分组建文件夹。
struct ChatListView: View {
    @EnvironmentObject private var chats: ChatStore
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var history = YBSearchHistory.chats

    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var showingSearch = false
    @FocusState private var searchFocused: Bool
    @State private var foldersExpanded = true
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renamingFolder: ChatFolder?
    @State private var renameText = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if searchActive {
                    Section { searchRow }
                    searchContent
                } else {
                    homeContent
                }
            }
            .ybPageList()
            .navigationTitle("对话")
            .navigationDestination(for: String.self) { id in
                ChatView(threadID: id)
            }
            .navigationDestination(for: FolderRoute.self) { route in
                ChatFolderView(path: $path, folderID: route.folderID)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        if showingSearch {
                            cancelSearch()
                        } else {
                            showingSearch = true
                            DispatchQueue.main.async { searchFocused = true }
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
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

    // MARK: - 搜索

    private var searchActive: Bool {
        showingSearch || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchRow: some View {
        HStack(spacing: 12) {
            YBSearchField(placeholder: "搜索对话",
                          text: $query,
                          focused: $searchFocused,
                          onSubmit: { history.add(trimmedQuery) })
            Button("取消") { cancelSearch() }
                .font(.system(size: 16))
                .foregroundStyle(YBColor.accent)
        }
        .padding(.top, 4)
        .ybRow()
    }

    private func cancelSearch() {
        searchFocused = false
        showingSearch = false
        query = ""
    }

    @ViewBuilder
    private var searchContent: some View {
        if trimmedQuery.isEmpty {
            if !history.items.isEmpty {
                Section {
                    historyChips
                } header: {
                    YBPinnedHeader("历史记录") {
                        Button {
                            history.clear()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15))
                                .foregroundStyle(YBColor.textSecondary)
                        }
                        .buttonStyle(YBPressStyle())
                    }
                }
            }
        } else {
            let results = searchResults
            if results.isEmpty {
                Section {
                    YBHint(text: "没有匹配「\(trimmedQuery)」的对话。搜索会同时匹配标题和对话内容。",
                           icon: "magnifyingglass")
                        .padding(.top, 12)
                        .ybRow(horizontal: 0)
                }
            } else {
                Section {
                    ForEach(results.indices, id: \.self) { index in
                        threadRow(results[index],
                                  subtitle: results[index].updatedAt.formatted(date: .abbreviated, time: .shortened),
                                  position: position(index, results.count),
                                  isLast: index == results.count - 1)
                    }
                } header: {
                    YBPinnedHeader("找到 \(results.count) 段对话")
                }
            }
        }
    }

    private var historyChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(history.items, id: \.self) { keyword in
                    YBTag(text: keyword) {
                        query = keyword
                        history.add(keyword)
                    }
                }
            }
            .padding(.horizontal, YBMetric.pagePad)
            .padding(.bottom, YBMetric.rowGap)
        }
        .ybRow(horizontal: 0)
    }

    private var searchResults: [ChatThread] {
        let keyword = trimmedQuery
        guard !keyword.isEmpty else { return chats.threads }
        return chats.threads.filter {
            $0.title.localizedCaseInsensitiveContains(keyword)
                || $0.preview.localizedCaseInsensitiveContains(keyword)
        }
    }

    // MARK: - 正常态

    @ViewBuilder
    private var homeContent: some View {
        Section {
            YBActionCard(title: "新建对话", icon: "square.and.pencil") {
                let thread = chats.createThread()
                path.append(thread.id)
            }
            .padding(.top, 4)
            .ybRow()

            YBHint(text: "说一句话就把待办、日程、备忘、提醒建出来，不用自己填表。")
                .ybRow(horizontal: 0)
        }

        if !chats.folders.isEmpty { folderSection }
        threadSections
    }

    // MARK: - 分组

    @ViewBuilder
    private var folderSection: some View {
        // 「收起分组」是这一组的最后一行：收起来时只剩它自己，
        // 和元宝那边一样，一点就收掉整列文件夹
        let total = foldersExpanded ? chats.folders.count + 1 : 1

        Section {
            if foldersExpanded {
                ForEach(chats.folders.indices, id: \.self) { index in
                    folderRow(chats.folders[index], position: position(index, total))
                }
            }

            YBRow(title: foldersExpanded ? "收起分组" : "展开分组（\(chats.folders.count) 个）",
                  icon: "folder",
                  chevron: foldersExpanded ? "chevron.up" : "chevron.down",
                  position: position(foldersExpanded ? chats.folders.count : 0, total)) {
                withAnimation(.easeOut(duration: 0.15)) { foldersExpanded.toggle() }
            }
            .ybRow(bottom: YBMetric.rowGap)
        } header: {
            YBPinnedHeader("分组") {
                Button {
                    showNewFolder = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(YBColor.textSecondary)
                }
                .buttonStyle(YBPressStyle())
            }
        }
    }

    private func folderRow(_ folder: ChatFolder, position: YBRowPosition) -> some View {
        YBRow(title: folder.name,
              detail: "\(chats.threadCount(inFolder: folder.id))",
              icon: "folder",
              chevron: "chevron.right",
              position: position) {
            path.append(FolderRoute(folderID: folder.id))
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
            .tint(YBColor.accent)
        }
        .ybRow(bottom: position == .last ? YBMetric.rowGap : 0)
    }

    // MARK: - 会话

    @ViewBuilder
    private var threadSections: some View {
        let ungrouped = chats.threads(inFolder: nil)
        if ungrouped.isEmpty {
            Section {
                YBRow(title: chats.threads.isEmpty ? "还没有对话" : "未分组的对话是空的",
                      subtitle: chats.threads.isEmpty
                          ? "点上面的「新建对话」开始，说完一句话就会在这里留下一条。"
                          : "展开分组看看，或者新建一段对话。",
                      position: .only)
                    .ybRow(bottom: YBMetric.rowGap)
            } header: {
                YBPinnedHeader("最近")
            }
        } else {
            ForEach(TimeBucket.allCases) { bucket in
                let list = bucket.filter(ungrouped)
                if !list.isEmpty {
                    Section {
                        ForEach(list.indices, id: \.self) { index in
                            threadRow(list[index],
                                      subtitle: bucketSubtitle(list[index]),
                                      position: position(index, list.count),
                                      isLast: index == list.count - 1)
                        }
                    } header: {
                        // 今天 / 昨天 / 本月 / 更早：滚动时钉在屏幕顶上
                        YBPinnedHeader(bucket.title)
                    }
                }
            }
        }
    }

    private func bucketSubtitle(_ thread: ChatThread) -> String {
        let time = thread.updatedAt.formatted(date: .omitted, time: .shortened)
        return thread.preview.isEmpty ? time : time + " · " + thread.preview
    }

    private func threadRow(_ thread: ChatThread,
                           subtitle: String,
                           position: YBRowPosition,
                           isLast: Bool) -> some View {
        YBRow(title: thread.title,
              subtitle: subtitle,
              position: position) {
            path.append(thread.id)
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
        .ybRow(bottom: isLast ? YBMetric.rowGap : 0)
    }

    private func position(_ index: Int, _ count: Int) -> YBRowPosition {
        if count <= 1 { return .only }
        if index == 0 { return .first }
        if index == count - 1 { return .last }
        return .middle
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
                YBHint(text: "这个分组里还没有对话。在对话列表里长按一条，选「移到分组」。")
                    .padding(.top, 12)
                    .ybRow(horizontal: 0)
            } else {
                ForEach(list.indices, id: \.self) { index in
                    let thread = list[index]
                    YBRow(title: thread.title,
                          subtitle: thread.updatedAt.formatted(date: .abbreviated, time: .shortened),
                          position: position(index, list.count)) {
                        path.append(thread.id)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            chats.deleteThread(id: thread.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .ybRow(bottom: index == list.count - 1 ? YBMetric.rowGap : 0)
                }
            }
        }
        .ybPageList()
        .navigationTitle(chats.folderName(folderID))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func position(_ index: Int, _ count: Int) -> YBRowPosition {
        if count <= 1 { return .only }
        if index == 0 { return .first }
        if index == count - 1 { return .last }
        return .middle
    }
}

/// 分组页的跳转标识。会话 id 也是字符串，用不同的类型区分开，
/// 免得两个 navigationDestination(for: String.self) 撞在一起。
struct FolderRoute: Hashable {
    let folderID: String
}
