import Foundation

/// 一条备忘。
struct NoteItem: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var title: String = ""
    var body: String = ""
    var createdAt: Date = Date()
}

/// 备忘的本地存储。
///
/// 为什么单独存文件：iOS 的「备忘录」没有对外写入的 API，之前备忘只能写进运行日志，
/// 等于写完就没了。存在 Documents/notes.json 里至少是看得见、能导出、备份得了的
/// （App 开了 UIFileSharingEnabled，这个文件在「文件」App 里能直接翻到）。
final class NoteStore: ObservableObject {

    static let shared = NoteStore()

    @Published private(set) var notes: [NoteItem] = []

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("notes.json")
    }

    private init() {
        load()
    }

    // MARK: - 读写

    func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([NoteItem].self, from: data) else {
            notes = []
            return
        }
        notes = decoded.sorted { $0.createdAt > $1.createdAt }
        AppLog.info("Note", "载入 \(notes.count) 条备忘")
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        do {
            let data = try encoder.encode(notes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.error("Note", "保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 增删

    @discardableResult
    func add(title: String, body: String) -> NoteItem {
        let note = NoteItem(title: title, body: body)
        notes.insert(note, at: 0)
        save()
        AppLog.info("Note", "记下备忘「\(title)」")
        return note
    }

    func delete(_ note: NoteItem) {
        notes.removeAll { $0.id == note.id }
        save()
    }
}
