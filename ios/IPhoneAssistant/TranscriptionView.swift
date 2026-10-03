import SwiftUI
import Speech

/// 语音转写页。
///
/// 版式用系统 List。转写是长任务，所以：进度是确定的（第 N / M 段），
/// 并且随时可以停下来——已经转好的部分会保留（HIG 的 Progress 页：让用户能中断）。
struct TranscriptionView: View {
    @EnvironmentObject private var store: MeetingStore
    let meetingID: String

    @State private var busy = false
    @State private var progress = ""
    @State private var progressDone = 0
    @State private var progressTotal = 0
    @State private var report = ""
    @State private var useOnDevice = true
    @State private var authStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @State private var preview = ""
    @State private var loaded = false
    @State private var runTask: Task<Void, Never>?

    private var meeting: Meeting? { store.meeting(id: meetingID) }

    var body: some View {
        List {
            if let m = meeting {
                authSection
                optionsSection
                singleSection(m)
                batchSection(m)
                if !preview.isEmpty {
                    Section("当前文字（\(preview.count) 字）") {
                        Text(preview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text("记录不存在，可能已被删除").foregroundStyle(.secondary)
            }

            if !report.isEmpty {
                Section("报告") {
                    Text(report)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("语音转写")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .onDisappear {
            // 离开页面就把任务停掉，别让它在后台接着跑
            runTask?.cancel()
        }
    }

    // MARK: - 区块

    private var authSection: some View {
        Section {
            LabeledContent("授权状态", value: TranscriptionService.statusText(authStatus))
            if authStatus != .authorized {
                Button("请求语音识别权限") { requestAuth() }
            }
        } header: {
            Text("权限")
        } footer: {
            Text("语音识别权限和麦克风权限是两回事，要单独授权。")
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle("只用端上识别（不上传录音）", isOn: $useOnDevice)
            LabeledContent("本机支持端上中文识别",
                           value: TranscriptionService.supportsOnDevice() ? "是" : "否")
        } header: {
            Text("模式")
        } footer: {
            Text("端上识别不联网、录音不出手机，但准确率可能不如联网识别。关掉这个开关会走苹果的服务器，录音会被上传。")
        }
    }

    private func singleSection(_ m: Meeting) -> some View {
        Section {
            Button(busy ? "处理中…" : "只转写第 1 段（先验证能不能用）") { runSingle(m) }
                .disabled(busy || m.segments.isEmpty)
        } header: {
            Text("先试一段")
        } footer: {
            Text("建议先点这个。一段只要几秒，能用了再跑全部——一小时会议有 60 段，会跑很久。")
        }
    }

    private func batchSection(_ m: Meeting) -> some View {
        Section {
            Button(busy ? "转写中…" : "转写全部 \(m.segments.count) 段") { runAll(m) }
                .disabled(busy || m.segments.isEmpty)

            if busy {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(progressDone),
                                 total: Double(max(progressTotal, 1)))
                    Text(progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("停止", role: .destructive) {
                        runTask?.cancel()
                        runTask = nil
                        busy = false
                        progress = ""
                        report = "已停止。已经转好的部分都保存了，可以之后接着转。"
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("全部转写")
        } footer: {
            Text("每转完一段就立即存一次。中途失败或手动停止，都不会丢掉已经转好的部分。")
        }
    }

    // MARK: - 动作

    private func refresh() {
        authStatus = TranscriptionService.authorizationStatus()
        if !loaded, let m = meeting {
            preview = m.transcript
            loaded = true
        }
    }

    private func requestAuth() {
        Task {
            let status = await TranscriptionService.requestAuthorization()
            await MainActor.run {
                self.authStatus = status
                self.report = "授权结果：\(TranscriptionService.statusText(status))"
            }
        }
    }

    private func runSingle(_ m: Meeting) {
        guard let first = m.segments.first else { return }
        busy = true
        report = ""
        progress = "正在转写 \(first.fileName)…"
        progressDone = 0
        progressTotal = 1
        let onDevice = useOnDevice

        runTask = Task {
            do {
                let url = MeetingStore.recordingsDirectory().appendingPathComponent(first.fileName)
                let text = try await TranscriptionService.recognize(url: url, onDevice: onDevice)
                await MainActor.run {
                    self.busy = false
                    self.progress = ""
                    self.progressDone = 1
                    self.preview = text
                    self.report = "✅ 第 1 段成功，\(text.count) 字\n\n预览：\n\(text.prefix(400))"
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.progress = ""
                    self.report = "❌ 第 1 段失败\n\(error.localizedDescription)\n\n如果提示不支持端上识别，把上面的开关关掉再试。"
                }
            }
        }
    }

    private func runAll(_ m: Meeting) {
        busy = true
        report = ""
        let segments = m.segments
        let onDevice = useOnDevice
        progressTotal = segments.count
        progressDone = 0

        runTask = Task {
            var pieces: [String] = []
            var failures: [String] = []
            var stopped = false

            for (index, seg) in segments.enumerated() {
                if Task.isCancelled { stopped = true; break }
                await MainActor.run {
                    self.progress = "第 \(index + 1) / \(segments.count) 段：\(seg.fileName)"
                    self.progressDone = index
                }
                do {
                    let url = MeetingStore.recordingsDirectory().appendingPathComponent(seg.fileName)
                    let text = try await TranscriptionService.recognize(url: url, onDevice: onDevice)
                    if !text.isEmpty {
                        pieces.append(text)
                    }
                    // 逐段增量保存：中途出错也不会丢掉已经转好的部分
                    let joined = pieces.joined(separator: "\n")
                    await MainActor.run {
                        self.saveTranscript(joined)
                        self.progressDone = index + 1
                    }
                } catch {
                    failures.append("第 \(index + 1) 段：\(error.localizedDescription)")
                    AppLog.error("ASR", "第 \(index + 1) 段失败：\(error.localizedDescription)")
                }
            }

            let ok = pieces.count
            let bad = failures
            await MainActor.run {
                self.busy = false
                self.progress = ""
                var lines = ["完成：\(ok) / \(segments.count) 段有文字"]
                if stopped { lines.append("（中途停止了，剩下的段没转）") }
                if !bad.isEmpty {
                    lines.append("失败 \(bad.count) 段：")
                    lines.append(contentsOf: bad.prefix(10).map { "  " + $0 })
                }
                self.report = lines.joined(separator: "\n")
                if let updated = self.store.meeting(id: self.meetingID) {
                    self.preview = updated.transcript
                }
            }
        }
    }

    private func saveTranscript(_ text: String) {
        guard var m = store.meeting(id: meetingID) else { return }
        m.transcript = text
        if m.status == "recorded" && !text.isEmpty {
            m.status = "transcribed"
        }
        store.update(m)
        preview = text
    }
}

#Preview {
    NavigationStack {
        TranscriptionView(meetingID: "none")
    }
    .environmentObject(MeetingStore())
}
