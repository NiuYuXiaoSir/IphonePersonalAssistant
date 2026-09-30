import SwiftUI

struct RootView: View {
    @StateObject private var settings = SettingsStore()
    @StateObject private var meetings = MeetingStore()
    @StateObject private var chats = ChatStore()
    /// 页签切换由路由决定，长按图标的快捷菜单才能把页面直接推到前面
    @ObservedObject private var router = AppRouter.shared

    var body: some View {
        TabView(selection: $router.selectedTab) {
            MeetingsView()
                .tabItem { Label("会议", systemImage: "waveform") }
                .tag(AppRouter.Tab.meetings)
            // 对话：说一句话就把待办/日程/备忘/提醒建出来，不用自己填表
            ChatListView()
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppRouter.Tab.chat)
            // 速记：自己知道要记什么时的手动新建表单
            AssistantView()
                .tabItem { Label("速记", systemImage: "square.and.pencil") }
                .tag(AppRouter.Tab.quickAdd)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(AppRouter.Tab.settings)
            DiagnosticsView()
                .tabItem { Label("诊断", systemImage: "stethoscope") }
                .tag(AppRouter.Tab.diagnostics)
        }
        .environmentObject(settings)
        .environmentObject(meetings)
        .environmentObject(chats)
    }
}

#Preview {
    RootView()
}
