import SwiftUI

@main
struct IPhoneAssistantApp: App {

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
