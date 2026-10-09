import Foundation
import SQLite3

/// 一层很薄的 SQLite 封装。
///
/// 为什么用 SQLite 而不是 JSON 文件（上一版就是 JSON）：数据开始有「关系」了——
/// 对话、长期记忆、每日流水要互相查（比如「上周都做了什么」「关于桥杆记过什么」），
/// 这些用 JSON 得整个读进内存再自己筛，用 SQL 就是一句 where。
/// 也没有引第三方库：系统自带 sqlite3，文件就落在 Documents/assistant.sqlite3，
/// 开了文件共享，「文件」App 里能直接把它拷出来用别的工具看。
///
/// 线程约定：所有调用都发生在主线程（几个 Store 都是主线程上的 ObservableObject）。
/// 数据库开了 FULLMUTEX，真被后台线程碰到也不会立刻炸，但不要依赖它。
final class SQLiteDatabase {

    private var handle: OpaquePointer?

    /// 告诉 SQLite「这个字符串的内存你先别动，我马上要改写它」时要传的回调。
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK, let opened = db else {
            let reason = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(code)"
            AppLog.error("DB", "打开数据库失败：\(reason)")
            if let db { sqlite3_close(db) }
            return
        }
        handle = opened
        AppLog.info("DB", "打开数据库 \(path)")
    }

    deinit {
        if let opened = handle { sqlite3_close(opened) }
    }

    var isOpen: Bool { handle != nil }

    // MARK: - 执行

    /// 多条语句一起跑（建表、PRAGMA、DELETE 这种没有参数的最合适）。
    @discardableResult
    func exec(_ sql: String) -> Bool {
        guard let handle = handle else { return false }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "未知错误"
            if let error { sqlite3_free(error) }
            AppLog.error("DB", "SQL 失败：\(message)｜\(sql.prefix(160))")
            return false
        }
        return true
    }

    /// 带参数的单条语句。返回值只表示「语句跑完了」，INSERT OR IGNORE 被忽略的也算跑完。
    @discardableResult
    func run(_ sql: String, _ params: [Any?] = []) -> Bool {
        guard let handle = handle else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            AppLog.error("DB", "SQL 准备失败：\(String(cString: sqlite3_errmsg(handle)))｜\(sql.prefix(160))")
            if let stmt { sqlite3_finalize(stmt) }
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        let code = sqlite3_step(stmt)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            AppLog.error("DB", "SQL 执行失败：\(String(cString: sqlite3_errmsg(handle)))｜\(sql.prefix(160))")
            return false
        }
        return true
    }

    /// 查询。每一行是「列名 → 值」，值是 String / Int / Double；SQL 里给列起别名就能拿到想要的名字。
    func query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        guard let handle = handle else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            AppLog.error("DB", "SQL 准备失败：\(String(cString: sqlite3_errmsg(handle)))｜\(sql.prefix(160))")
            if let stmt { sqlite3_finalize(stmt) }
            return []
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)

        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            let columns = sqlite3_column_count(stmt)
            var index: Int32 = 0
            while index < columns {
                if let name = sqlite3_column_name(stmt, index) {
                    let key = String(cString: name)
                    switch sqlite3_column_type(stmt, index) {
                    case SQLITE_INTEGER:
                        row[key] = Int(sqlite3_column_int64(stmt, index))
                    case SQLITE_FLOAT:
                        row[key] = sqlite3_column_double(stmt, index)
                    case SQLITE_TEXT:
                        if let text = sqlite3_column_text(stmt, index) {
                            row[key] = String(cString: text)
                        }
                    default:
                        break
                    }
                }
                index += 1
            }
            rows.append(row)
        }
        return rows
    }

    /// 一整批写操作要么全成、要么全不成。
    /// 注意别在 body 里再调 transaction——SQLite 不支持嵌套事务。
    func transaction(_ body: () -> Void) {
        exec("BEGIN IMMEDIATE")
        body()
        exec("COMMIT")
    }

    // MARK: - 绑定

    private func bind(_ stmt: OpaquePointer?, _ params: [Any?]) {
        guard let stmt else { return }
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case nil:
                sqlite3_bind_null(stmt, index)
            case let text as String:
                sqlite3_bind_text(stmt, index, text, -1, Self.transient)
            case let number as Int:
                sqlite3_bind_int64(stmt, index, Int64(number))
            case let number as Double:
                sqlite3_bind_double(stmt, index, number)
            case let flag as Bool:
                sqlite3_bind_int(stmt, index, flag ? 1 : 0)
            case let date as Date:
                sqlite3_bind_double(stmt, index, date.timeIntervalSince1970)
            default:
                sqlite3_bind_text(stmt, index, String(describing: value), -1, Self.transient)
            }
        }
    }
}

/// 全局唯一的数据库。
///
/// 建表放在这里一次性做完：对话（三张表）、安排（条目）、附件、长期记忆、每日流水。
/// 都用 IF NOT EXISTS，所以升级 App 之后再进来只是补上缺的表，不会动已有数据。
enum AppDatabase {

    static let shared: SQLiteDatabase = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let db = SQLiteDatabase(path: dir.appendingPathComponent("assistant.sqlite3").path)
        db.exec("PRAGMA journal_mode=WAL;")
        db.exec("PRAGMA synchronous=NORMAL;")
        createSchema(db)
        return db
    }()

    private static func createSchema(_ db: SQLiteDatabase) {
        db.exec("""
        CREATE TABLE IF NOT EXISTS chat_folders (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS chat_threads (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          folder_id TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS chat_entries (
          id TEXT PRIMARY KEY,
          thread_id TEXT NOT NULL,
          payload TEXT NOT NULL,
          created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_chat_entries_thread ON chat_entries(thread_id);
        CREATE TABLE IF NOT EXISTS memories (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          content TEXT NOT NULL,
          keywords TEXT NOT NULL DEFAULT '',
          importance INTEGER NOT NULL DEFAULT 1,
          source TEXT NOT NULL DEFAULT '',
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_memories_content ON memories(content);
        CREATE TABLE IF NOT EXISTS items (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          title TEXT NOT NULL,
          notes TEXT NOT NULL DEFAULT '',
          due_at REAL,
          duration_minutes INTEGER NOT NULL DEFAULT 0,
          priority TEXT NOT NULL DEFAULT 'normal',
          remind_before INTEGER NOT NULL DEFAULT 0,
          is_done INTEGER NOT NULL DEFAULT 0,
          sort_index REAL NOT NULL DEFAULT 0,
          source TEXT NOT NULL DEFAULT '',
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_items_due ON items(due_at);
        CREATE TABLE IF NOT EXISTS media (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          file_name TEXT NOT NULL,
          entry_id TEXT NOT NULL DEFAULT '',
          thread_id TEXT NOT NULL DEFAULT '',
          pixel_width INTEGER NOT NULL DEFAULT 0,
          pixel_height INTEGER NOT NULL DEFAULT 0,
          duration_seconds REAL NOT NULL DEFAULT 0,
          bytes INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_media_entry ON media(entry_id);
        CREATE TABLE IF NOT EXISTS meetings (
          id TEXT PRIMARY KEY,
          started_at REAL NOT NULL,
          payload TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_meetings_started ON meetings(started_at);
        CREATE TABLE IF NOT EXISTS timeline (
          id TEXT PRIMARY KEY,
          day TEXT NOT NULL,
          at REAL NOT NULL,
          kind TEXT NOT NULL,
          content TEXT NOT NULL,
          thread_id TEXT NOT NULL DEFAULT '',
          created_at REAL NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_timeline_unique ON timeline(day, kind, content);
        CREATE INDEX IF NOT EXISTS idx_timeline_day ON timeline(day);
        """)
    }
}
