import SwiftUI

@main
struct IPhoneAssistantApp: App {

    /// 只为了接长按图标的快捷菜单（冷启动那条路必须走 AppDelegate）
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        AppLog.info("App", "启动，版本 \(version) (\(build))")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
