import SwiftUI

struct RootView: View {
    @StateObject private var settings = SettingsStore()

    var body: some View {
        TabView {
            AssistantView()
                .tabItem { Label("助手", systemImage: "sparkles") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
            DiagnosticsView()
                .tabItem { Label("诊断", systemImage: "stethoscope") }
        }
        .environmentObject(settings)
    }
}

#Preview {
    RootView()
}
