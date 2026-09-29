import SwiftUI

/// 诊断页：原本的 E1 探针界面。特意保留，因为它还要继续用——
/// 7 天续签后的数据保留验证、后台录音复测、App Groups 复测都依赖它。
struct DiagnosticsView: View {
    @StateObject private var store = ProbeStore()

    var body: some View {
        NavigationStack {
            List {
                installSection
                signingSection
                recordingSection
                systemDataSection
                notificationSection
                reportSection
            }
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { store.refreshInstallInfo() }
            .alert("提示", isPresented: Binding(
                get: { !store.toast.isEmpty },
                set: { if !$0 { store.toast = "" } }
            )) {
                Button("知道了") { store.toast = "" }
            } message: {
                Text(store.toast)
            }
        }
    }

    // MARK: - 装机链路

    private var installSection: some View {
        Section {
            LabeledContent("首次安装", value: store.firstLaunch.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("已安装", value: "\(store.installDays) 天")
            LabeledContent("累计启动", value: "\(store.launchCount) 次")
            Text("「累计启动」是判断数据是否保留的关键：等免费签名过期、用同一个 Apple ID 重新签名安装之后，如果这个数字接着往上涨（而不是变回 1），说明覆盖安装不会清数据。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("① 装机链路（E1 核心）")
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
                HStack {
                    Image(systemName: store.isRecording ? "stop.circle.fill" : "record.circle")
                    Text(store.isRecording
                         ? "停止录音（已录 \(Int(store.recordSeconds)) 秒）"
                         : "开始录音测试")
                    Spacer()
                }
                .foregroundStyle(store.isRecording ? Color.red : Color.accentColor)
            }

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
            Text("④ 日历与提醒事项（EventKit）")
        } footer: {
            Text("最后一项是本次最有价值的测试：它走的就是正式版本里「AI 总结 → 一键生成待办」的完整写入路径。")
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

    // MARK: - 报告

    private var reportSection: some View {
        Section {
            Button("复制报告到剪贴板") { store.copyReport() }
            Button("保存报告到「文件」App") { store.saveReportToFiles() }
            if !store.reportSavedPath.isEmpty {
                Text("已保存：\(store.reportSavedPath)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(store.buildReport())
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
        } header: {
            Text("⑥ 把结果带回来")
        } footer: {
            Text("把报告贴给我，我就能判断这条链路能不能支撑正式开发。")
        }
    }
}

#Preview {
    DiagnosticsView()
}
