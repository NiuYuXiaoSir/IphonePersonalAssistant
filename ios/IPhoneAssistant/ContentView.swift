import SwiftUI
import UIKit

/// 诊断页：原本的 E1 探针界面。特意保留，因为它还要继续用——
/// 7 天续签后的数据保留验证、后台录音复测、App Groups 复测都依赖它。
///
/// 版式用系统 Form。这一页之后会从页签降级到「我的 → 高级」，内容一项不少。
struct DiagnosticsView: View {
    @StateObject private var store = ProbeStore()
    @State private var logPreview = ""

    var body: some View {
        NavigationStack {
            Form {
                // 出问题时第一件事是把报告复制走，所以放在最前面
                reportSection
                installSection
                signingSection
                recordingSection
                systemDataSection
                notificationSection
                loggerSection
            }
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                store.refreshInstallInfo()
                logPreview = AppLog.exportText(limitBytes: 3000)
            }
            .toast($store.toast)
        }
    }

    // MARK: - 报告

    private var reportSection: some View {
        Section {
            Button {
                store.copyReport()
            } label: {
                Label("复制报告到剪贴板", systemImage: "doc.on.doc")
            }
            Button {
                store.saveReportToFiles()
            } label: {
                Label("保存报告到「文件」", systemImage: "folder")
            }
            if !store.reportSavedPath.isEmpty {
                Text("已保存：\(store.reportSavedPath)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(store.buildReport())
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        } header: {
            Text("⓪ 探针报告")
        } footer: {
            Text("把报告贴给我，我就能判断这条链路能不能支撑正式开发。")
        }
    }

    // MARK: - 装机链路

    private var installSection: some View {
        Section {
            LabeledContent("首次安装", value: store.firstLaunch.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("已安装", value: "\(store.installDays) 天")
            LabeledContent("累计启动", value: "\(store.launchCount) 次")
        } header: {
            Text("① 装机链路")
        } footer: {
            Text("「累计启动」是判断数据是否保留的关键：等免费签名过期、用同一个苹果账号重新签名安装之后，如果这个数字接着往上涨（而不是变回 1），说明覆盖安装不会清数据。")
        }
    }

    private var signingSection: some View {
        Section {
            Text(store.provisioningReport())
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        } header: {
            Text("② 签名与权限（免费账号到底给了什么）")
        }
    }

    // MARK: - 录音

    private var recordingSection: some View {
        Section {
            Button {
                store.toggleRecording()
            } label: {
                Label(store.isRecording
                      ? "停止录音（已录 \(Int(store.recordSeconds)) 秒）"
                      : "开始录音测试",
                      systemImage: store.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .tint(store.isRecording ? Color.red : Color.accentColor)

            Text(store.recordStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !store.recordings.isEmpty {
                ForEach(store.recordings, id: \.self) { name in
                    Text(name).font(.system(.caption, design: .monospaced))
                }
            }
        } header: {
            Text("③ 麦克风与后台录音")
        } footer: {
            Text("测法：开始录音后立刻锁屏，等 2 分钟以上再回来停止。判定看「实际流逝」和「文件实际音频」两个数字是否吻合。")
        }
    }

    // MARK: - 日历 / 提醒事项

    private var systemDataSection: some View {
        Section {
            Button("测试读取日历") { store.testCalendar() }
            Text(store.calendarStatus).font(.footnote).foregroundStyle(.secondary)

            Button("测试读取提醒事项") { store.testReminders() }
            Text(store.reminderStatus).font(.footnote).foregroundStyle(.secondary)

            Button("测试写入待办到「AI助理」列表") { store.testReminderWrite() }
            Text(store.reminderWriteStatus).font(.footnote).foregroundStyle(.secondary)
        } header: {
            Text("④ 日历与提醒事项")
        } footer: {
            Text("第三项走的是和「速记」页保存待办完全相同的写入路径。")
        }
    }

    private var notificationSection: some View {
        Section {
            Button("安排一条 10 秒后的本地通知") { store.testNotification() }
            Text(store.notificationStatus).font(.footnote).foregroundStyle(.secondary)
        } header: {
            Text("⑤ 本地通知（免费签名没有推送，只能靠它）")
        }
    }

    // MARK: - 日志

    private var loggerSection: some View {
        Section {
            Button("刷新日志预览") { logPreview = AppLog.exportText(limitBytes: 3000) }
            Button("全部日志复制到剪贴板") {
                UIPasteboard.general.string = AppLog.exportText()
                store.toast = "日志已复制到剪贴板"
            }
            Button("导出日志到「文件」") {
                let url = AppLog.directory().appendingPathComponent("export-\(Int(Date().timeIntervalSince1970)).txt")
                do {
                    try AppLog.exportText().write(to: url, atomically: true, encoding: .utf8)
                    store.toast = "已保存：\(url.lastPathComponent)"
                } catch {
                    store.toast = "保存失败：\(error.localizedDescription)"
                }
            }
            Button("清空日志", role: .destructive) {
                AppLog.clear()
                logPreview = AppLog.exportText(limitBytes: 3000)
            }
            Text(logPreview)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
        } header: {
            Text("⑥ 运行日志")
        } footer: {
            Text("这台手机上装不了开发工具，出问题时这段日志就是唯一的线索。把它发给我就行。")
        }
    }
}

#Preview {
    DiagnosticsView()
}
