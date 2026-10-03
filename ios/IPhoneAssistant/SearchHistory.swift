import Foundation

/// 搜索历史。会议页和对话页各存一份，最多 10 条。
///
/// 它喂给系统搜索框的「搜索建议」（`.searchSuggestions`）：
/// 一开始搜索就先看到最近搜过的词，点一下直接填进去。
final class SearchHistory: ObservableObject {

    static let meetings = SearchHistory(key: "yb.search.meetings")
    static let chats = SearchHistory(key: "yb.search.chats")

    @Published private(set) var items: [String] = []

    private let key: String

    /// key 里那串 "yb" 是历史遗留（原来整套观感叫 YB），保留不改成新名字——
    /// 改了就等于把已经记住的搜索词丢掉，不值当。
    private init(key: String) {
        self.key = key
        items = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = items.filter { $0 != trimmed }
        next.insert(trimmed, at: 0)
        items = Array(next.prefix(10))
        UserDefaults.standard.set(items, forKey: key)
    }

    func clear() {
        items = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}
