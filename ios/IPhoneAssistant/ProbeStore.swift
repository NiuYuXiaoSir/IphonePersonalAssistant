import SwiftUI
import AVFoundation
import UserNotifications
import UIKit

/// E1 探针：一次装机同时验证「侧载链路」和「PRD 里几个没有答案的技术假设」。
///
/// 它回答的问题：
///  1. 免费签名的描述文件多久过期？7 天续签后 App 数据还在不在？（launchCount / firstLaunch）
///  2. 麦克风 + 后台录音（UIBackgroundModes: audio）在免费签名下能不能用？
///  3. 没有推送能力时，本地通知是否正常工作？（通知现在是这个 App 唯一的提醒通道）
///  4. 免费签名下 entitlements 里到底有什么？（App Groups 有没有？）
///
/// 原本还有「日历 / 提醒事项读写」两项。2026-10-09 起 App 不再读写系统里的其他 App
/// （待办、日程、备忘全在本机数据库里），那两项连同 EventKit 依赖一起去掉了。
final class ProbeStore: ObservableObject {

    // MARK: - 装机信息
    @Published var firstLaunch: Date
    @Published var launchCount: Int
    @Published var installDays: Int = 0

    // MARK: - 录音
    @Published var isRecording = false
    @Published var recordSeconds: Double = 0
    @Published var recordStatus = "未测试"
    @Published var recordings: [String] = []

    // MARK: - 通知
    @Published var notificationStatus = "未测试"

    // MARK: - 报告
    @Published var reportSavedPath = ""
    @Published var toast = ""

    private var recorder: AVAudioRecorder?
    private var recordTimer: Timer?
    private var recordStart: Date?
    private var currentRecordURL: URL?

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    // MARK: - 生命周期

    init() {
        let d = UserDefaults.standard
        if let t = d.object(forKey: "probe.firstLaunch") as? Date {
            firstLaunch = t
        } else {
            let now = Date()
            firstLaunch = now
            d.set(now, forKey: "probe.firstLaunch")
        }
        let c = d.integer(forKey: "probe.launchCount") + 1
        launchCount = c
        d.set(c, forKey: "probe.launchCount")
    }

    func refreshInstallInfo() {
        installDays = Calendar.current.dateComponents([.day], from: firstLaunch, to: Date()).day ?? 0
        loadRecordings()
    }

    // MARK: - 描述文件 / entitlements

    func provisioningReport() -> String {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") else {
            return "没找到签名描述文件（说明这个包没有被真正签名）"
        }
        guard let data = FileManager.default.contents(atPath: path),
              let raw = String(data: data, encoding: .isoLatin1) else {
            return "读取描述文件失败"
        }
        guard let start = raw.range(of: "<?xml"),
              let end = raw.range(of: "</plist>"),
              start.lowerBound < end.upperBound else {
            return "签名文件里没找到配置段"
        }
        let xml = String(raw[start.lowerBound..<end.upperBound])
        guard let xmlData = xml.data(using: .isoLatin1),
              let plist = (try? PropertyListSerialization.propertyList(from: xmlData, format: nil)) as? [String: Any] else {
            return "签名文件解析失败"
        }

        let name = plist["Name"] as? String ?? "-"
        let team = (plist["TeamIdentifier"] as? [String])?.joined(separator: ",") ?? "-"
        var expiryText = "-"
        if let exp = plist["ExpirationDate"] as? Date {
            let left = Calendar.current.dateComponents([.day, .hour], from: Date(), to: exp)
            expiryText = "\(Self.df.string(from: exp))（剩 \(left.day ?? 0) 天 \(left.hour ?? 0) 小时）"
        }
        let ent = plist["Entitlements"] as? [String: Any] ?? [:]
        let appGroups = (ent["com.apple.security.application-groups"] as? [String]) ?? []
        let entKeys = ent.keys.sorted().joined(separator: ", ")

        return """
        签名名称: \(name)
        团队标识: \(team)
        过期时间: \(expiryText)
        应用组: \(appGroups.isEmpty ? "无（注意：这只说明本次签名没有请求它，不等于免费账号不支持）" : appGroups.joined(separator: ", "))
        授权项: \(entKeys.isEmpty ? "无" : entKeys)
        """
    }

    // MARK: - 录音测试（含后台录音）

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            requestPermissionThenStart()
        }
    }

    private func requestPermissionThenStart() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted {
                    self.startRecording()
                } else {
                    self.recordStatus = "❌ 麦克风权限被拒绝（去 设置 → 隐私与安全性 → 麦克风 打开）"
                }
            }
        }
    }

    private func startRecording() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)

            let url = Self.documentsDir().appendingPathComponent("probe-\(Self.stamp()).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000
            ]
            let rec = try AVAudioRecorder(url: url, settings: settings)
            guard rec.record() else {
                recordStatus = "❌ 录音器拒绝开始，没有再试的必要"
                return
            }

            recorder = rec
            currentRecordURL = url
            recordStart = Date()
            recordSeconds = 0
            isRecording = true
            recordStatus = "🔴 录音中…现在请锁屏（或息屏），等 2 分钟以上再回来停止。这一步是在测后台录音，是整个产品的前提。"

            recordTimer?.invalidate()
            recordTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, let s = self.recordStart else { return }
                self.recordSeconds = Date().timeIntervalSince(s)
            }
        } catch {
            recordStatus = "❌ 启动录音失败: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        recordTimer?.invalidate()
        recordTimer = nil
        // 用录音器自己记的时长，而不是界面计时器——App 在后台时计时器可能被系统节流
        let audioSeconds = recorder?.currentTime ?? 0
        let wallSeconds = recordStart.map { Date().timeIntervalSince($0) } ?? audioSeconds
        recorder?.stop()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let url = currentRecordURL else {
            recordStatus = "❌ 没有正在录制的文件"
            return
        }
        // 文件里实际存了多少秒音频——这是最权威的数字
        let fileSeconds = Self.audioDuration(of: url)
        var bytes = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let n = attrs[.size] as? Int {
            bytes = n
        }
        let mb = Double(bytes) / 1024.0 / 1024.0

        // 判定逻辑：比较「真实流逝的时间」和「文件里实际存下来的音频长度」。
        // 如果后台录音被系统掐断，文件会明显短于流逝时间。
        var verdict = ""
        if wallSeconds < 25 {
            verdict = "\n⚠️ 录制时间太短，无法判断后台录音。请重新测：开始后立刻锁屏，等 2 分钟以上再回来停止。"
        } else {
            let lost = wallSeconds - fileSeconds
            if lost > 5 {
                verdict = "\n❌ 后台录音被中断了：实际过去 \(Int(wallSeconds)) 秒，文件里只有 \(Int(fileSeconds)) 秒，丢了约 \(Int(lost)) 秒"
            } else {
                verdict = "\n✅ 后台录音正常：实际过去 \(Int(wallSeconds)) 秒，文件里 \(Int(fileSeconds)) 秒，基本吻合"
            }
        }

        recordStatus = """
        \(url.lastPathComponent)
        实际流逝: \(String(format: "%.1f", wallSeconds)) 秒
        录音器计时: \(String(format: "%.1f", audioSeconds)) 秒
        文件实际音频: \(String(format: "%.1f", fileSeconds)) 秒
        文件大小: \(String(format: "%.2f", mb)) MB\(verdict)
        """
        loadRecordings()
    }

    func loadRecordings() {
        let dir = Self.documentsDir()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        recordings = files.filter { $0.hasSuffix(".m4a") }.sorted()
    }

    // MARK: - 本地通知（验证没有推送能力时通知是否可用）

    func testNotification() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            guard granted else {
                DispatchQueue.main.async {
                    self?.notificationStatus = "❌ 通知权限被拒绝：\(error?.localizedDescription ?? "无错误信息")"
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "助理探针"
            content.body = "本地通知测试成功。现在把本应用切到后台或锁屏，10 秒后应该弹出来。"
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
            let request = UNNotificationRequest(
                identifier: "probe-\(Self.stamp())",
                content: content,
                trigger: trigger
            )
            center.add(request) { err in
                DispatchQueue.main.async {
                    if let err {
                        self?.notificationStatus = "❌ 添加通知失败: \(err.localizedDescription)"
                    } else {
                        self?.notificationStatus = "✅ 已安排一条 10 秒后的本地通知\n请立刻锁屏，看它会不会弹出来"
                    }
                }
            }
        }
    }

    // MARK: - 报告

    /// 附件占用：文件是按个存在 chatMedia/ 下的，数据库里 media 表记着账。
    /// 两边对不上就说明有孤儿文件（通常是删除时没清干净），这一行是唯一能看出来的地方。
    private func attachmentReport() -> String {
        let disk = MediaLibrary.storageBytes()
        let rows = AppDatabase.shared.query("SELECT COUNT(*) AS n, SUM(bytes) AS total FROM media")
        let count = (rows.first?["n"] as? Int) ?? 0
        // SUM 在空表上返回 NULL，而 query 遇 NULL 不写这个键
        let bytes: Int
        if let value = rows.first?["total"] as? Int {
            bytes = value
        } else if let value = rows.first?["total"] as? Double {
            bytes = Int(value)
        } else {
            bytes = 0
        }
        let mb = { (value: Int) in String(format: "%.2f MB", Double(value) / 1024 / 1024) }
        return """
        磁盘上的文件: \(disk.files) 个，\(mb(disk.bytes))
        数据库记的账: \(count) 个，\(mb(bytes))
        \(disk.files == count ? "一致" : "⚠️ 不一致（可能有一次删除没清干净）")
        """
    }

    func buildReport() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        let bundleId = Bundle.main.bundleIdentifier ?? "-"
        let model = UIDevice.current.model
        let sysVersion = UIDevice.current.systemVersion
        let bgModes = (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.joined(separator: ",") ?? "无"

        return """
        ===== E1 探针报告 =====
        生成时间: \(Self.df.string(from: Date()))

        --- 设备 / 构建 ---
        机型: \(model)
        系统: iOS \(sysVersion)
        Bundle ID: \(bundleId)
        版本: \(version) (\(build))
        UIBackgroundModes: \(bgModes)

        --- 装机链路（E1 核心）---
        首次安装: \(Self.df.string(from: firstLaunch))
        已安装: \(installDays) 天
        累计启动: \(launchCount)   ← 重新签名安装后如果这个数字继续变大，说明数据保留

        --- 签名 / 描述文件 ---
        \(provisioningReport())

        --- 录音 / 后台录音 ---
        \(recordStatus)
        已有录音文件: \(recordings.isEmpty ? "无" : recordings.joined(separator: ", "))

        --- 附件（图片与视频）---
        \(attachmentReport())

        --- 本地通知 ---
        \(notificationStatus)
        ======================
        """
    }

    func saveReportToFiles() {
        let text = buildReport()
        let url = Self.documentsDir().appendingPathComponent("E1-报告-\(Self.stamp()).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            reportSavedPath = url.lastPathComponent
            toast = "已保存到「文件」→ 我的 iPhone → 助理探针"
        } catch {
            toast = "保存失败: \(error.localizedDescription)"
        }
    }

    func copyReport() {
        UIPasteboard.general.string = buildReport()
        toast = "报告已复制到剪贴板，可以直接粘给我"
    }

    // MARK: - 工具

    static func documentsDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMdd-HHmmss"
        return f.string(from: Date())
    }

    /// 读取音频文件里实际存了多少秒。判断后台录音有没有被系统掐断，靠这个数字而不是界面计时器。
    static func audioDuration(of url: URL) -> Double {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return 0 }
        return player.duration
    }

    static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
