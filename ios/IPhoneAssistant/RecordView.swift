import SwiftUI

/// 录音页。
///
/// 从列表点「开始记录会议」进来就自动开录（一路上只点了一次）。
/// 这一页最重要的是**让人心里有底**：计时是实际录到的时长、电平表说明麦克风在收、
/// 中断会当场标出来、打完的标记马上能看见。
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
    /// 触觉的触发器：这两个数字一动，对应的振动就响一次
    @State private var hapticStart = 0
    @State private var hapticSaved = 0

    /// 计时器字号跟着系统字号放大，但仍然是大号的
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 56

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
            // 触觉：开始、打标记、存好各一次；录音中只有最轻的那一档
            .sensoryFeedback(.impact(weight: .medium), trigger: hapticStart) { settings.hapticsEnabled }
            .sensoryFeedback(.impact(weight: .light), trigger: recorder.markerCount) { settings.hapticsEnabled }
            .sensoryFeedback(.success, trigger: hapticSaved) { settings.hapticsEnabled }
        }
    }

    // MARK: - 各区块

    private var headerBlock: some View {
        VStack(spacing: 6) {
            // 这里是「录到的时长」，不是「开始到现在过了多久」。
            // 中断期间录音是停的，钟也停下来，免得再出现「显示 59 分钟、其实只录了 4 分钟」。
            Text(clock(recorder.elapsed))
                .font(.system(size: timerSize, weight: .regular, design: .rounded))
                .monospacedDigit()

            // 电平表：录的时候「麦克风在收」的唯一直观证据
            LevelMeterView(level: recorder.level,
                           isActive: recorder.isRecording && !recorder.isWaitingForAudio)
                .padding(.horizontal, 32)
                .padding(.top, 4)

            Text(recorder.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 4)

            if recorder.isWaitingForAudio || recorder.lostSeconds > 0.5 {
                Label(recorder.lostSeconds > 0.5
                      ? "中断漏录 \(RecordingService.durationText(recorder.lostSeconds))（这段时间没有音频）"
                      : "音频被系统抢走了，正在自动重连",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 2)
            }
        }
    }

    private var statsBlock: some View {
        HStack(spacing: 22) {
            stat("已存段数", "\(recorder.segmentCount)")
            stat("已转写", "\(transcriber.completedSegments)")
            stat("文字", "\(transcriber.text.count)")
            stat("标记", "\(recorder.markerCount)")
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
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(transcriber.text.suffix(300)))
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var resultBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("已保存到会议列表", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            if !saveMessage.isEmpty {
                Text(saveMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !summaryMessage.isEmpty {
                Text(summaryMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 自动纪要刚花掉一次 token，顺手把余额显示出来
            if balance.supports(settings) {
                Text("余额 \(balance.chipText)")
                    .font(.caption)
                    .foregroundStyle(balance.isLow ? Color.orange : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    @ViewBuilder
    private var actionBlock: some View {
        VStack(spacing: 10) {
            switch phase {
            case .idle:
                prominent("开始录音", icon: "record.circle", tint: .accentColor) { start() }
            case .recording:
                Button {
                    recorder.addMarker()
                } label: {
                    Label("打标记", systemImage: "flag")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                // 结束是危险动作，所以用红色；但它不是「主线按钮」，没有 primary role
                prominent("结束并保存", icon: "stop.circle.fill", tint: .red) { finishAndSave() }
            case .finishing:
                ProgressView()
                Text("正在收尾并等最后一段转写…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .done:
                prominent("返回会议列表", icon: "list.bullet", tint: .accentColor) { dismiss() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
    }

    private func prominent(_ title: String, icon: String, tint: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(tint)
    }

    private var footerNote: some View {
        Text("录音期间可以锁屏、可以切到别的应用。来电或闹钟打断后会立刻把已录到的一段封存，然后每几秒试着接上，接上之前的时间是没有音频的（会单独标出来）。")
            .font(.footnote)
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
        hapticStart += 1
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
                self.hapticSaved += 1

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
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
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
