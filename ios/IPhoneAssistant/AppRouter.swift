import SwiftUI

/// 长按图标弹出的快捷菜单项。
/// rawValue 必须和 project.yml 里 UIApplicationShortcutItemType 写的一模一样，
/// 对不上就会点了没反应。
enum AppShortcut: String {
    case record   = "com.niuyuxiaosir.iphoneassistant.probe.record"
    case newChat  = "com.niuyuxiaosir.iphoneassistant.probe.newchat"
    case quickAdd = "com.niuyuxiaosir.iphoneassistant.probe.quickadd"
}

/// 意图中转站。
///
/// 快捷菜单是在 AppDelegate 里收到的，而「切到哪个页签」「弹出录音页」是 SwiftUI 的事，
/// 中间需要一个两边都拿得到的地方放这个意图，就是这个对象。
/// 冷启动和热启动两条路都会把意图放进来，页面自己来取。
final class AppRouter: ObservableObject {

    static let shared = AppRouter()

    /// 四个页签。用的字符串而不是序号——序号在这份数据里会变，
    /// 存到 UserDefaults 里的旧序号会指到别的页签上。
    enum Tab: String, Hashable, CaseIterable {
        case today, meetings, chat, settings
    }

    private static let tabKey = "router.selectedTab"

    /// 页签切换。改动会记住，下次启动回到这一页
    /// （HIG 的 Launching 页：Avoid making people retrace steps）。
    @Published var selectedTab: Tab {
        didSet { UserDefaults.standard.set(selectedTab.rawValue, forKey: Self.tabKey) }
    }

    /// 还没被目标页面取走的意图
    @Published var pending: AppShortcut?
    /// 「＋」速记面板。任何页签都能把它叫起来，所以放在这里而不是某个页面里。
    @Published var showQuickAdd = false

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.tabKey)
        selectedTab = saved.flatMap(Tab.init(rawValue:)) ?? .today
    }

    func handle(_ shortcut: AppShortcut) {
        switch shortcut {
        case .record:
            selectedTab = .meetings
            pending = .record
        case .newChat:
            selectedTab = .chat
            pending = .newChat
        case .quickAdd:
            // 面板本身就是要看的东西，直接拉起来
            showQuickAdd = true
            pending = nil
        }
    }
}

/// 只有接管快捷菜单这一件事需要 AppDelegate，
/// SwiftUI 里用 @UIApplicationDelegateAdaptor 挂上即可。
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// App 没在运行时走这里：快捷项放在 launchOptions 里，performActionFor 不会被调用
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if let item = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem,
           let shortcut = AppShortcut(rawValue: item.type) {
            AppLog.info("Shortcut", "冷启动带快捷项：\(shortcut.rawValue)")
            AppRouter.shared.handle(shortcut)
        }
        return true
    }

    /// App 已经在后台或前台时走这里
    func application(_ application: UIApplication,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        guard let shortcut = AppShortcut(rawValue: shortcutItem.type) else {
            completionHandler(false)
            return
        }
        AppLog.info("Shortcut", "快捷项：\(shortcut.rawValue)")
        AppRouter.shared.handle(shortcut)
        completionHandler(true)
    }
}
