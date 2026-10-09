import SwiftUI
import UIKit

/// 会议详情。
///
/// 一条流水线：听、看文字、读纪要、写进系统。
/// 版式用系统件：上面一条播放条（系统 Slider + 播放键），下面一个系统分段控件切四个页，
/// 正文直接排在系统背景上——不再有米黄纸，可读性交给字号、行距和留白。
struct MeetingDetailView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    /// 生成纪要是花钱的动作，余额摆在顶上随时能看到
    @ObservedObject private var balance = BalanceStore.shared

    let meetingID: String

    @StateObject private var player = MeetingPlayer()

    /// 用索引而不是枚举，方便直接喂给分段控件
    @State private var tab = 0
    @State private var titleDraft = ""
    @State private var transcriptDraft = ""
    @State private var loadedDraft = false
    @State private var loadedPlayer = false
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var toast = ""
    @State private var showRename = false
    /// 合并多段录音的时候禁用按钮，避免连点
    @State private var merging = false
    /// 刚合并出来的整文件，用来直接分享（分享要走系统的分享面板）
    @State private var mergedFile: URL?

    private let tabTitles = ["转写", "纪要", "录音", "导出"]

    private var meeting: Meeting? { store.meeting(id: meetingID) }

    var body: some View {
        Group {
            if let m = meeting {
                VStack(spacing: 0) {
                    playerBar
                        .padding(.horizontal, 16)
                        .padding(.top, 4)

                    Picker("内容", selection: $tab) {
                        ForEach(tabTitles.indices, id: \.self) { index in
                            Text(tabTitles[index]).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    Divider()

                    Group {
                        switch tab {
                        case 0: transcriptTab(m)
                        case 1: MeetingSummaryPanel(meetingID: meetingID) { documentHeader(m) }
                        case 2: audioTab(m)
                        default: exportTab(m)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            } else {
                missingView
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { topBarMenu }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("收起键盘") { hideKeyboard() }
            }
        }
        .onAppear {
            loadDrafts()
            loadPlayer()
            balance.refreshIfStale(settings: settings)
        }
        .onDisappear {
            player.stop()
            saveTranscript(silently: true)
        }
        .onChange(of: meeting?.transcript) { _, newValue in
            // 在「自动转写」页里跑完识别回来，文字要跟着刷新，否则一保存就把刚转出来的覆盖没了
            guard let newValue, newValue != transcriptDraft else { return }
            transcriptDraft = newValue
        }
        .onChange(of: player.elapsedTotal) { _, value in
            if !isScrubbing { scrubValue = value }
        }
        .onChange(of: scrubValue) { _, value in
            if isScrubbing { player.seek(to: value) }
        }
        .alert("重命名", isPresented: $showRename) {
            TextField("标题", text: $titleDraft)
            Button("保存") { renameMeeting() }
            Button("取消", role: .cancel) {}
        }
        .toast($toast)
    }

    // MARK: - 播放条

    private var playerBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(!player.loaded)
                .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

                Text(clock(isScrubbing ? scrubValue : player.elapsedTotal))
                    .font(.footnote.monospacedDigit())
                    .frame(width: 46, alignment: .leading)

                Slider(value: $scrubValue, in: 0...max(player.totalDuration, 0.1)) { editing in
                    isScrubbing = editing
                    player.setScrubbing(editing)
                }
                .disabled(!player.loaded)
                .accessibilityLabel("播放进度")

                Text(player.loaded
                     ? "-" + clock(max(player.totalDuration - (isScrubbing ? scrubValue : player.elapsedTotal), 0))
                     : "无音频")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }

            if player.loaded {
                HStack(spacing: 16) {
                    Button {
                        player.seek(to: max(0, player.elapsedTotal - 15))
                        scrubValue = max(0, player.elapsedTotal - 15)
                    } label: {
                        Label("15 秒", systemImage: "gobackward.15")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)

                    Button {
                        let target = min(player.totalDuration, player.elapsedTotal + 15)
                        player.seek(to: target)
                        scrubValue = target
                    } label: {
                        Label("15 秒", systemImage: "goforward.15")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    if player.isPlaying {
                        Text("正在播第 \(min(player.currentIndex + 1, player.segmentCount))/\(player.segmentCount) 段")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.title3)
            }
        }
    }

    /// 纸上那行文档抬头：标题 + 时间 + 改名。四个页都用它，切过去不会像换了个页面。
    private func documentHeader(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 10) {
                Text(m.title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    titleDraft = m.title
                    showRename = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重命名")
            }
            Text(metaLine(m))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var missingView: some View {
        ContentUnavailableView {
            Label("记录不存在", systemImage: "questionmark.folder")
        } description: {
            Text("可能已经被删了")
        }
    }

    // MARK: - 转写

    private func transcriptTab(_ m: Meeting) -> some View {
        VStack(spacing: 0) {
            documentHeader(m)
            Divider()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $transcriptDraft)
                    .font(.body)
                    .scrollContentBackground(.hidden)

                if transcriptDraft.isEmpty {
                    Text("还没有文字。可以把会议记录粘进来，也可以点下面的「自动转写」，把 \(m.segments.count) 段录音逐段转成文字。")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
            }

            transcriptBar
        }
    }

    private var transcriptBar: some View {
        HStack(spacing: 10) {
            NavigationLink {
                TranscriptionView(meetingID: meetingID)
            } label: {
                Label("自动转写", systemImage: "text.bubble")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                saveTranscript(silently: false)
            } label: {
                Label("保存", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer(minLength: 0)

            Button {
                saveTranscript(silently: true)
                tab = 1
            } label: {
                Label("生成纪要", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 录音段

    private func audioTab(_ m: Meeting) -> some View {
        List {
            documentHeader(m)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

            if m.segments.isEmpty {
                Text("这场会议没有留下音频段。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(m.segments.indices, id: \.self) { index in
                    segmentRow(index: index, segment: m.segments[index])
                }
            }

            if !m.markers.isEmpty {
                Section("录制时打的标记（\(m.markers.count) 个）") {
                    Text(m.markers.map { clock($0) }.joined(separator: "、"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// 一段录音一行：第几段 + 时间 + 真波形 + 播放键
    private func segmentRow(index: Int, segment: Meeting.AudioSegment) -> some View {
        let active = player.loaded && player.currentIndex == index
        let url = MeetingStore.recordingsDirectory().appendingPathComponent(segment.fileName)

        return HStack(spacing: 12) {
            Button {
                if active && player.isPlaying {
                    player.pause()
                } else {
                    player.play(from: index)
                }
            } label: {
                Image(systemName: active && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 44, height: 44)
                    .background(active ? Color.accentColor : Color.secondary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(active && player.isPlaying ? "暂停第 \(index + 1) 段" : "播放第 \(index + 1) 段")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("第 \(index + 1) 段")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    Text(String(format: "%.0f 秒", segment.durationSeconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                WaveformView(url: url,
                             bars: 40,
                             tint: active ? Color.accentColor : Color(uiColor: .secondaryLabel),
                             height: 22)
                Text(clock(segment.startOffset))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 导出

    private func exportTab(_ m: Meeting) -> some View {
        List {
            documentHeader(m)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

            Section("导出") {
                Button {
                    exportMarkdown(m)
                } label: {
                    Label("导出为文本文件到「文件」", systemImage: "doc.text")
                }
                Button {
                    mergeAudio(m)
                } label: {
                    Label(merging ? "正在合并…" : "合并成一个音频文件（.m4a）", systemImage: "waveform.badge.plus")
                }
                .disabled(merging)
                if let file = mergedFile {
                    ShareLink(item: file) {
                        Label("分享 \(file.lastPathComponent)", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    UIPasteboard.general.string = markdown(m)
                    toast = "已复制到剪贴板"
                } label: {
                    Label("复制全部内容到剪贴板", systemImage: "doc.on.doc")
                }
            }

            Section("这场会议") {
                LabeledContent("开始", value: m.startedAt.formatted(date: .numeric, time: .shortened))
                LabeledContent("时长", value: RecordingService.durationText(m.durationSeconds))
                if let gap = m.gapSeconds, gap > 0.5 {
                    LabeledContent("中断漏录", value: RecordingService.durationText(gap))
                }
                LabeledContent("录音段", value: "\(m.segments.count) 段")
                LabeledContent("文字", value: m.transcript.isEmpty ? "（无）" : "\(m.transcript.count) 字")
                LabeledContent("纪要", value: m.summaryJSON.isEmpty ? "（还没生成）" : "已生成")
                LabeledContent("状态", value: Self.statusText(m.status))
            }

            Section {
                EmptyView()
            } footer: {
                Text("免费签名只给 7 天，也没有云端同步。定期导出是唯一的保险，别等签名过期了才想起来。")
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 分组标题栏

    @ToolbarContentBuilder
    private var topBarMenu: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if balance.supports(settings) { balanceChip }
            Menu {
                Button {
                    titleDraft = meeting?.title ?? ""
                    showRename = true
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Button {
                    if let m = meeting {
                        UIPasteboard.general.string = markdown(m)
                        toast = "已复制到剪贴板"
                    }
                } label: {
                    Label("复制全部内容", systemImage: "doc.on.doc")
                }
                Divider()
                Button(role: .destructive) {
                    deleteMeeting()
                } label: {
                    Label("删除这场会议", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    /// 顶上的余额：点一下重新查
    private var balanceChip: some View {
        Button {
            balance.refresh(settings: settings)
        } label: {
            HStack(spacing: 5) {
                if balance.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: balance.isLow ? "exclamationmark.triangle.fill" : balance.chipIcon).font(.caption)
                }
                Text(balance.chipText).font(.footnote)
            }
            .foregroundStyle(balanceTint)
        }
        .disabled(balance.isRefreshing)
        .accessibilityLabel("余额：\(balance.chipText)，点击刷新")
    }

    private var balanceTint: Color {
        if balance.isLow { return .orange }
        if balance.isUnavailable { return .secondary }
        return .primary
    }

    // MARK: - 动作

    private func loadDrafts() {
        guard !loadedDraft, let m = meeting else { return }
        loadedDraft = true
        titleDraft = m.title
        transcriptDraft = m.transcript
    }

    private func loadPlayer() {
        guard !loadedPlayer, let m = meeting, !m.segments.isEmpty else { return }
        loadedPlayer = true
        let directory = MeetingStore.recordingsDirectory()
        player.load(urls: m.segments.map { directory.appendingPathComponent($0.fileName) },
                    durations: m.segments.map { $0.durationSeconds })
    }

    private func renameMeeting() {
        guard var m = meeting else { return }
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        m.title = trimmed
        store.update(m)
        toast = "标题已改为「\(trimmed)」"
    }

    private func saveTranscript(silently: Bool) {
        guard var m = meeting else { return }
        guard m.transcript != transcriptDraft else {
            if !silently { toast = "文字没有变化" }
            return
        }
        m.transcript = transcriptDraft
        if !m.transcript.isEmpty && (m.status == "recorded" || m.status == "recovered") {
            m.status = "transcribed"
        }
        store.update(m)
        if !silently { toast = "已保存 \(m.transcript.count) 字" }
        AppLog.info("Meeting", "保存文字 \(m.transcript.count) 字")
    }

    /// 删除走「撤下 + 撤销」：这里只摘掉记录并退回列表，
    /// 撤销条由列表页显示（它一直在导航栈下面活着），4 秒内可以捡回来。
    private func deleteMeeting() {
        guard let m = meeting else { return }
        player.stop()
        store.detach(m)
        dismiss()
    }

    private func metaLine(_ m: Meeting) -> String {
        var parts: [String] = []
        parts.append(m.startedAt.formatted(date: .numeric, time: .shortened))
        parts.append("录到 " + RecordingService.durationText(m.durationSeconds))
        if let gap = m.gapSeconds, gap > 0.5 {
            parts.append("中断漏录 " + RecordingService.durationText(gap))
        }
        parts.append("\(m.segments.count) 段录音")
        if m.status == "recovered" { parts.append("意外中断恢复") }
        return parts.joined(separator: " · ")
    }

    /// 记录里的状态是英文标识，界面上一律显示中文
    private static func statusText(_ status: String) -> String {
        switch status {
        case "recording":   return "正在录音"
        case "recorded":    return "已录音"
        case "transcribed": return "已转写"
        case "summarized":  return "已生成纪要"
        case "recovered":   return "意外中断，已恢复"
        case "failed":      return "失败"
        default:            return status
        }
    }

    private func markdown(_ m: Meeting) -> String {
        var out = "# \(m.title)\n\n"
        out += "- 开始：\(m.startedAt.formatted(date: .numeric, time: .shortened))\n"
        out += "- 时长（实际录到）：\(RecordingService.durationText(m.durationSeconds))\n"
        if let gap = m.gapSeconds, gap > 0.5 {
            out += "- 中断漏录：\(RecordingService.durationText(gap))（来电/闹钟打断，这段时间没有音频）\n"
        }
        out += "- 录音段：\(m.segments.count)\n"
        if !m.markers.isEmpty {
            out += "- 标记点：\(m.markers.map { "\(Int($0))s" }.joined(separator: ", "))\n"
        }
        out += "\n## 文字\n\n\(m.transcript.isEmpty ? "（无）" : m.transcript)\n"
        if !m.summaryJSON.isEmpty {
            out += "\n## AI 纪要\n\n```json\n\(m.summaryJSON)\n```\n"
        }
        return out
    }

    private func exportMarkdown(_ m: Meeting) {
        let name = "\(m.title.replacingOccurrences(of: "/", with: "-")).md"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        do {
            try markdown(m).write(to: url, atomically: true, encoding: .utf8)
            toast = "已导出：\(name)"
            AppLog.info("Export", "导出 \(name)")
        } catch {
            toast = "导出失败：\(error.localizedDescription)"
            AppLog.error("Export", toast)
        }
    }

    /// 分段是录音安全的保险，但导出、发人、存档都想要一个整文件。
    /// 合并结果落在 Documents 根目录，文件名带「完整录音」。
    private func mergeAudio(_ m: Meeting) {
        guard !merging else { return }
        merging = true
        toast = "正在合并 \(m.segments.count) 段录音…"
        Task {
            do {
                let url = try await MeetingAudioExport.merge(meeting: m)
                await MainActor.run {
                    merging = false
                    mergedFile = url
                    toast = "已合并：\(url.lastPathComponent)"
                }
            } catch {
                await MainActor.run {
                    merging = false
                    toast = error.localizedDescription
                }
            }
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    /// mm:ss；超过一小时给 h:mm:ss
    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let minutes = total / 60
        let secs = total % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

#Preview {
    NavigationStack {
        MeetingDetailView(meetingID: "none")
    }
    .environmentObject(MeetingStore())
    .environmentObject(SettingsStore())
}
