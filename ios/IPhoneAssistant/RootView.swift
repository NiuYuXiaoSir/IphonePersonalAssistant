import SwiftUI

struct RootView: View {
    @StateObject private var settings = SettingsStore()
    @StateObject private var meetings = MeetingStore()

    var body: some View {
        TabView {
            MeetingsView()
                .tabItem { Label("会议", systemImage: "waveform") }
            // 对话：说一句话就把待办/日程/备忘建出来，不用自己填表
            ChatView()
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
            // 速记：自己知道要记什么时的手动新建表单
            AssistantView()
                .tabItem { Label("速记", systemImage: "square.and.pencil") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
            DiagnosticsView()
                .tabItem { Label("诊断", systemImage: "stethoscope") }
        }
        .environmentObject(settings)
        .environmentObject(meetings)
    }
}

#Preview {
    RootView()
}
