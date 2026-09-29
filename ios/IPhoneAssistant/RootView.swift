import SwiftUI

struct RootView: View {
    @StateObject private var settings = SettingsStore()
    @StateObject private var meetings = MeetingStore()

    var body: some View {
        TabView {
            MeetingsView()
                .tabItem { Label("会议", systemImage: "waveform") }
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
