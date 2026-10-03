import SwiftUI

/// 入口：四个页签 + 一个全局的「＋」面板。
///
/// 页签只管导航（HIG 的 Tab bars 页：Use a tab bar to support navigation,
/// not to provide actions）——所以「速记」不再占一个页签，它变成任何页面上都能叫起来的「＋」；
/// 「诊断」是开发工具，下沉到「我的 → 高级」。
struct RootView: View {
    @StateObject private var settings = SettingsStore()
    @StateObject private var meetings = MeetingStore()
    @StateObject private var chats = ChatStore()
    /// 页签切换由路由决定，长按图标的快捷菜单才能把页面直接推到前面
    @ObservedObject private var router = AppRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $router.selectedTab) {
            // 今日：今天的待办、流水、会、通知，一屏看完
            TodayView()
                .tabItem { Label("今日", systemImage: "sun.max") }
                .tag(AppRouter.Tab.today)
            MeetingsView()
                .tabItem { Label("会议", systemImage: "waveform") }
                .tag(AppRouter.Tab.meetings)
            // 对话：说一句话就把待办/日程/备忘/提醒建出来，不用自己填表
            ChatListView()
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppRouter.Tab.chat)
            SettingsView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(AppRouter.Tab.settings)
        }
        // 页签、开关、分段控件这些系统控件统一走品牌蓝
        .tint(Color.accentColor)
        .environmentObject(settings)
        .environmentObject(meetings)
        .environmentObject(chats)
        .sheet(isPresented: $router.showQuickAdd) {
            QuickAddSheet()
        }
        .onChange(of: router.selectedTab) { _, _ in
            router.rememberTab()
        }
        .onChange(of: scenePhase) { _, phase in
            // 退到后台就把撤销窗口收掉：不然 App 在窗口里被杀掉，
            // 撤下的记录会和音频文件对不上（会议那边会被当成「意外中断」又找回来）
            if phase != .active {
                meetings.commitDetach()
                chats.commitDetachThread()
            }
        }
    }
}

#Preview {
    RootView()
}
