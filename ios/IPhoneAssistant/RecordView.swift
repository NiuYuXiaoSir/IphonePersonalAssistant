import SwiftUI

struct RecordView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var settings: SettingsStore
    /// 录完会自动生成纪要，那一步要花 token
    @ObservedObject private var balance = BalanceStore.shared

    @StateObject private var recorder = RecordingService()
    @StateObject private var transcriber = RealtimeTranscriber()

    private enum Phase { case idle, recording, finishing, done }
    @State private var phase: Phase = .idle
    @State private var saveMessage = ""
    @State private var summaryMessage = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    headerBlock
                    statsBlock
                    if phase == .idle || phase == .recording { transcribeToggle }
                    if !transcriber.text.isEmpty { liveTextBlock }
                    if phase == .done { resultBlock }
                    actionBlock
                    if phase != .done { footerNote }
                }
                .padding(.vertical, 20)
            }
            .background(YBColor.bg)
            .navigationTitle("记录会议")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        if phase == .recording {
                            finishAndSave()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .onAppear(perform: onAppearAction)
        }
    }

    // MARK: - 各区块

    private var headerBlock: some View {
        VStack(spacing: 6) {
            Text(clock(recorder.elapsed))
                .font(.system(size: 56, weight: .light, design: .monospaced))
                .monospacedDigit()
            Text(recorder.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var statsBlock: some View {
        HStack(spacing: 22) {
            stat("已存段数", "\(recorder.segmentCount)")
            stat("已转写", "\(transcriber.completedSegments)")
            stat("文字", "\(transcriber.text.count)")
            if transcriber.failedSegments > 0 {
                stat("转写失败", "\(transcriber.failedSegments)")
            }
        }
        .padding(.top, 18)
    }

    private var transcribeToggle: some View {
        Toggle("边录边转（每段录完自动转成文字）", isOn: $transcriber.isEnabled)
            .font(.footnote)
            .padding(.horizontal, 24)
            .padding(.top, 16)
    }

    private var liveTextBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("实时转写（只显示最近 300 字，完整内容保存在会议里）")
                .font(.caption2)
                .foregroundStyle(YBColor.textSecondary)
            Text(String(transcriber.text.suffix(300)))
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(YBColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var resultBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("已保存到会议列表", systemImage: "checkmark.circle.fill")
                .foregroundStyle(YBColor.success)
                .font(.headline)
            if !saveMessage.isEmpty {
                Text(saveMessage)
                    .font(.footnote)
                    .foregroundStyle(YBColor.textSecondary)
            }
            if !summaryMessage.isEmpty {
                Text(summaryMessage)
                    .font(.footnote)
                    .foregroundStyle(YBColor.textSecondary)
            }
            // 自动纪要刚花掉一次 token，顺手把余额显示出来
            if balance.supports(settings) {
                Text("余额 \(balance.chipText)")
                    .font(.caption2)
                    .foregroundStyle(balance.isLow ? YBColor.warning : YBColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(YBColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    @ViewBuilder
    private var actionBlock: some View {
        VStack(spacing: 10) {
            switch phase {
            case .idle:
                primary("开始录音", icon: "record.circle", tint: YBColor.accent) { start() }
            case .recording:
                soft("打标记", icon: "flag") { recorder.addMarker() }
                primary("结束并保存", icon: "stop.circle.fill", tint: YBColor.danger) { finishAndSave() }
            case .finishing:
                ProgressView()
                Text("正在收尾并等最后一段转写…")
                    .font(.footnote)
                    .foregroundStyle(YBColor.textSecondary)
            case .done:
                primary("返回会议列表", icon: "list.bullet", tint: YBColor.accent) { dismiss() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
    }

    private var footerNote: some View {
        Text("录音期间可以锁屏、可以切到别的应用。来电或闹钟打断后会尝试自动接上。边录边转读的是已经落盘的文件，不会影响录音。")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .padding(.top, 16)
    }

    // MARK: - 动作

    private func onAppearAction() {
        // 用局部变量捕获，避开把视图本身存进录音服务的闭包里（那会形成引用环）
        let t = transcriber
        recorder.onSegmentFinished = { segment in
            t.enqueue(segment)
        }
        if phase == .idle {
            start()
        }
    }

    private func start() {
        transcriber.reset()
        saveMessage = ""
        summaryMessage = ""
        phase = .recording
        recorder.start()
    }

    private func finishAndSave() {
        guard phase == .recording else { return }
        phase = .finishing

        guard let meeting = recorder.stop() else {
            phase = .done
            saveMessage = "没有录到可用的音频"
            return
        }

        Task {
            // 等最后一段的实时转写跑完
            await transcriber.finish()
            let transcript = transcriber.text
            let failed = transcriber.failedSegments

            await MainActor.run {
                var m = meeting
                m.transcript = transcript
                if !transcript.isEmpty { m.status = "transcribed" }
                self.store.add(m)
                self.phase = .done

                var lines = ["已保存 \(m.segments.count) 段，共 \(RecordingService.durationText(m.durationSeconds))"]
                if transcript.isEmpty {
                    lines.append("边录边转没有得到文字" + (failed > 0 ? "（\(failed) 段转写失败）" : ""))
                } else {
                    lines.append("边录边转得到 \(transcript.count) 字" + (failed > 0 ? "，\(failed) 段失败" : ""))
                }
                self.saveMessage = lines.joined(separator: "\n")

                if transcript.isEmpty {
                    self.summaryMessage = "没有文字，跳过自动纪要。可以在会议详情里手动转写或粘文字。"
                } else if !self.settings.hasKey {
                    self.summaryMessage = "还没配密钥，跳过自动纪要。"
                } else {
                    self.runAutoSummary(meetingID: m.id, transcript: transcript)
                }
            }
        }
    }

    private func runAutoSummary(meetingID: String, transcript: String) {
        var config = settings.makeConfig()
        // 这一场会议自己的 id，OpenCode 的网关按它做路由与缓存
        config.sessionID = meetingID
        summaryMessage = "正在生成纪要…"

        Task {
            do {
                let raw = try await MeetingSummarizer.generate(transcript: transcript, config: config)
                let parsed = try MeetingSummarizer.decode(raw)
                await MainActor.run {
                    if var updated = self.store.meeting(id: meetingID) {
                        updated.summaryJSON = raw
                        updated.status = "summarized"
                        self.store.update(updated)
                    }
                    self.summaryMessage = "纪要已生成：待办 \(parsed.actionItems.count) 条，日程 \(parsed.events.count) 条。去会议详情里确认写入。"
                    // 这一步花掉了 token，回来的时候余额要跟着变
                    BalanceStore.shared.refresh(settings: self.settings)
                }
            } catch {
                await MainActor.run {
                    self.summaryMessage = "自动纪要失败：\(error.localizedDescription)\n录音和文字都已保存，可在会议详情里重试。"
                }
            }
        }
    }

    // MARK: - 小组件

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(.headline, design: .monospaced))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// 大圆角主按钮，整行宽
    private func primary(_ title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(tint, in: Capsule())
        }
        .buttonStyle(YBPressStyle())
    }

    /// 次要按钮：灰胶囊
    private func soft(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(YBColor.surfaceHi, in: Capsule())
        }
        .buttonStyle(YBPressStyle())
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

#Preview {
    RecordView()
        .environmentObject(MeetingStore())
        .environmentObject(SettingsStore())
}
