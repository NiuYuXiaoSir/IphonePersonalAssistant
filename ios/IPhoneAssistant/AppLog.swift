import Foundation

/// 结构化日志。
///
/// 为什么这是必需品而不是锦上添花：这个项目没有 Mac，也就没有 Xcode 控制台、没有断点。
/// App 自己写下的日志文件，是出问题时唯一的线索来源。所以关键路径全部埋点。
///
/// 日志落在 Documents/logs/ 下，因为开了 UIFileSharingEnabled，它也会出现在「文件」App 里，
/// 即使 App 打不开也能把日志拿出去。
 enum AppLog {

    enum Level: String {
        case debug = "DBG"
        case info  = "INF"
        case warn  = "WRN"
        case error = "ERR"
    }

    /// 单个日志文件的上限，超过就滚动备份
    private static let maxBytes = 512 * 1024

    private static let queue = DispatchQueue(label: "com.niuyuxiaosir.iphoneassistant.log")

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func debug(_ module: String, _ message: String) { append(.debug, module, message) }
    static func info(_ module: String, _ message: String) { append(.info, module, message) }
    static func warn(_ module: String, _ message: String) { append(.warn, module, message) }
    static func error(_ module: String, _ message: String) { append(.error, module, message) }

    // MARK: - 文件位置

    static func directory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("logs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func currentFile() -> URL {
        directory().appendingPathComponent("\(dayFormatter.string(from: Date())).log")
    }

    // MARK: - 写入

    private static func append(_ level: Level, _ module: String, _ message: String) {
        let line = "\(stampFormatter.string(from: Date())) [\(level.rawValue)] [\(module)] \(message)\n"
        #if DEBUG
        print(line, terminator: "")
        #endif
        queue.async {
            let url = currentFile()
            var data = (try? Data(contentsOf: url)) ?? Data()
            if data.count > maxBytes {
                let backup = url.appendingPathExtension("1")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: url, to: backup)
                data = Data()
            }
            data.append(Data(line.utf8))
            try? data.write(to: url)
        }
    }

    // MARK: - 读取

    /// 把所有日志文件拼成一段文本，用于导出。
    /// 限制返回长度是为了避免把整个日志塞进剪贴板或内存。
    static func exportText(limitBytes: Int = 200 * 1024) -> String {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)) ?? []
        let files = contents
            .filter { $0.lastPathComponent.hasSuffix(".log") || $0.lastPathComponent.hasSuffix(".log.1") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var out = ""
        for f in files {
            if let text = try? String(contentsOf: f, encoding: .utf8) {
                out += "===== \(f.lastPathComponent) =====\n" + text + "\n"
            }
        }
        if out.utf8.count > limitBytes {
            out = "（已截断，只保留最后 \(limitBytes / 1024) KB）\n" + String(out.suffix(limitBytes))
        }
        return out.isEmpty ? "（暂无日志）" : out
    }

    static func clear() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)) ?? []
        for f in contents { try? fm.removeItem(at: f) }
        info("Log", "日志已清空")
    }
}
