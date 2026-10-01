import SwiftUI
import UIKit

/// 会议详情。
///
/// 版式照元宝的记录页：上半截是深色的——标题栏 + 一条浮着的播放胶囊，
/// 下半截是一张米黄的「纸」，纸的上沿压着四个文件夹标签（转写 / 纪要 / 录音 / 导出），
/// 选中的那个和纸同色，看起来是连成一片的。
///
/// 播放条一直在视野里：边听边看文字是会后整理最常用的动作。
struct MeetingDetailView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    /// 生成纪要是花钱的动作，余额摆在顶上随时能看到
    @ObservedObject private var balance = BalanceStore.shared

    let meetingID: String

    @StateObject private var player = MeetingPlayer()

    /// 用索引而不是枚举，方便直接喂给文件夹标签
    @State private var tab = 0
    @State private var titleDraft = ""
    @State private var transcriptDraft = ""
    @State private var loadedDraft = false
    @State private var loadedPlayer = false
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var toast = ""
    @State private var showRename = false
    @State private var showDeleteConfirm = false
    /// 合并多段录音的时候禁用按钮，避免连点
    @State private var merging = false
    /// 刚合并出来的整文件，用来直接分享（分享要走系统的分享面板）
    @State private var mergedFile: URL?

    private let tabTitles = ["转写", "纪要", "录音", "导出"]
    private let tabIcons = ["text.alignleft", "wand.and.stars", "waveform", "square.and.arrow.up"]

    private var meeting: Meeting? { store.meeting(id: meetingID) }

    var body: some View {
        Group {
            if let m = meeting {
                VStack(spacing: 0) {
                    playerPill
                        .padding(.horizontal, 16)
                    segmentHint
                        .padding(.top, 6)
                    paperSheet(m)
                        .padding(.top, 12)
                }
            } else {
                missingView
            }
        }
        .background(YBColor.bg)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
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
        .alert("提示", isPresented: Binding(
            get: { !toast.isEmpty },
            set: { if !$0 { toast = "" } }
        )) {
            Button("知道了") { toast = "" }
        } message: {
            Text(toast)
        }
        .confirmationDialog("删除这场会议？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) { deleteMeeting() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("音频文件和转写文字会一起删掉，删了拿不回来。")
        }
    }

    // MARK: - 深色区：播放条

    private var playerPill: some View {
        HStack(spacing: 10) {
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(player.loaded ? Color.white : YBColor.textTertiary)
                    .frame(width: 34, height: 34)
                    .background(YBColor.surfaceHi, in: Circle())
            }
            .buttonStyle(YBPressStyle())
            .disabled(!player.loaded)

            Text(clock(isScrubbing ? scrubValue : player.elapsedTotal))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.primary)
                .frame(width: 46, alignment: .leading)

            YBScrubber(value: $scrubValue, total: player.totalDuration) { editing in
                isScrubbing = editing
                player.setScrubbing(editing)
            }
            .disabled(!player.loaded)

            Text(player.loaded
                 ? "-" + clock(max(player.totalDuration - (isScrubbing ? scrubValue : player.elapsedTotal), 0))
                 : "无音频")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(YBColor.textSecondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(YBColor.surface, in: Capsule())
    }

    @ViewBuilder
    private var segmentHint: some View {
        if player.loaded && player.isPlaying {
            Text("正在播第 \(min(player.currentIndex + 1, player.segmentCount))/\(player.segmentCount) 段")
                .font(.system(size: 11))
                .foregroundStyle(YBColor.textTertiary)
                .lineLimit(1)
        }
    }

    // MARK: - 纸面

    private func paperSheet(_ m: Meeting) -> some View {
        VStack(spacing: 0) {
            YBFolderTabs(titles: tabTitles, icons: tabIcons, index: $tab)
            Group {
                switch tab {
                case 0: transcriptTab(m)
                case 1: MeetingSummaryPanel(meetingID: meetingID) { paperHeader(m) }
                case 2: audioTab(m)
                default: exportTab(m)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(YBColor.paper)
            .clipShape(YBRoundedCorner(radius: 14, corners: [.topRight, .bottomLeft, .bottomRight]))
        }
    }

    /// 纸上那行文档抬头：标题 + 时间 + 改名
    private func paperHeader(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 10) {
                Text(m.title)
                    .font(YBFont.docTitle)
                    .foregroundStyle(YBColor.paperInk)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    titleDraft = m.title
                    showRename = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 15))
                        .foregroundStyle(YBColor.paperInkSoft)
                }
                .buttonStyle(YBPressStyle())
            }
            Text(metaLine(m))
                .font(YBFont.docMeta)
                .foregroundStyle(YBColor.paperInkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var missingView: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.folder")
                .font(.largeTitle)
                .foregroundStyle(YBColor.textSecondary)
            Text("记录不存在，可能已经被删了")
                .font(.system(size: 14))
                .foregroundStyle(YBColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 转写

    private func transcriptTab(_ m: Meeting) -> some View {
        VStack(spacing: 0) {
            paperHeader(m)
            Rectangle().fill(YBColor.paperLine).frame(height: 1)

            ZStack(alignment: .topLeading) {
                YBPaperTextEditor(text: $transcriptDraft)

                if transcriptDraft.isEmpty {
                    Text("还没有文字。可以把会议记录粘进来，也可以点下面的「自动转写」，把 \(m.segments.count) 段录音逐段转成文字。")
                        .font(.system(size: 15))
                        .foregroundStyle(YBColor.paperInkSoft)
                        .padding(.horizontal, 19)
                        .padding(.top, 16)
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
            .buttonStyle(YBPaperButtonStyle())

            Button {
                saveTranscript(silently: false)
            } label: {
                Label("保存", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(YBPaperButtonStyle())

            Spacer(minLength: 0)

            Button {
                saveTranscript(silently: true)
                tab = 1
            } label: {
                Label("生成纪要", systemImage: "wand.and.stars")
            }
            .buttonStyle(YBPaperPrimaryButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(YBColor.paperHi)
    }

    // MARK: - 录音段

    private func audioTab(_ m: Meeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if m.segments.isEmpty {
                    Text("这场会议没有留下音频段。")
                        .font(.system(size: 14))
                        .foregroundStyle(YBColor.paperInkSoft)
                        .padding(.top, 20)
                } else {
                    ForEach(m.segments.indices, id: \.self) { index in
                        segmentCard(index: index, segment: m.segments[index])
                    }
                }

                if !m.markers.isEmpty { markersCard(m.markers) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
    }

    /// 一段录音一张卡，形态照元宝的录音卡：标题行 + 时长 + 波形 + 播放键
    private func segmentCard(index: Int, segment: Meeting.AudioSegment) -> some View {
        let active = player.loaded && player.currentIndex == index

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(YBColor.paperInkSoft)
                Text("第 \(index + 1) 段")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(YBColor.paperInk)
                Spacer(minLength: 8)
                Text(String(format: "%.0f 秒", segment.durationSeconds))
                    .font(.system(size: 12))
                    .foregroundStyle(YBColor.paperInkSoft)
            }

            HStack(spacing: 12) {
                Text(clock(segment.startOffset))
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundStyle(YBColor.paperInk)

                YBWaveform(seed: segment.fileName,
                           tint: active ? YBColor.paperInkSoft : YBColor.paperLine,
                           height: 22)

                Spacer(minLength: 0)

                Button {
                    if active && player.isPlaying {
                        player.pause()
                    } else {
                        player.play(from: index)
                    }
                } label: {
                    Image(systemName: active && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(YBColor.paper)
                        .frame(width: 34, height: 34)
                        .background(active ? YBColor.accent : YBColor.paperInk.opacity(0.85), in: Circle())
                }
                .buttonStyle(YBPressStyle())
            }
        }
        .padding(14)
        .background(YBColor.paperHi,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(active ? YBColor.accent.opacity(0.6) : Color.clear, lineWidth: 1.5)
        )
    }

    private func markersCard(_ markers: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("录制时打的标记（\(markers.count) 个）", systemImage: "flag")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(YBColor.paperInk)
            Text(markers.map { clock($0) }.joined(separator: "、"))
                .font(.system(size: 14))
                .foregroundStyle(YBColor.paperInkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(YBColor.paperHi,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 导出

    private func exportTab(_ m: Meeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                paperCard("导出", icon: "square.and.arrow.up") {
                    Button {
                        exportMarkdown(m)
                    } label: {
                        Label("导出为文本文件到「文件」", systemImage: "doc.text")
                    }
                    .buttonStyle(YBPaperButtonStyle())

                    Button {
                        mergeAudio(m)
                    } label: {
                        Label(merging ? "正在合并…" : "合并成一个音频文件（.m4a）", systemImage: "waveform.badge.plus")
                    }
                    .buttonStyle(YBPaperButtonStyle())
                    .disabled(merging)

                    if let file = mergedFile {
                        ShareLink(item: file) {
                            Label("分享 \(file.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(YBPaperButtonStyle())
                    }

                    Button {
                        UIPasteboard.general.string = markdown(m)
                        toast = "已复制到剪贴板"
                    } label: {
                        Label("复制全部内容到剪贴板", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(YBPaperButtonStyle())
                }

                paperCard("这场会议", icon: "info.circle") {
                    infoLine("开始", m.startedAt.formatted(date: .numeric, time: .shortened))
                    infoLine("时长", RecordingService.durationText(m.durationSeconds))
                    if let gap = m.gapSeconds, gap > 0.5 {
                        infoLine("中断漏录", RecordingService.durationText(gap))
                    }
                    infoLine("录音段", "\(m.segments.count) 段")
                    infoLine("文字", m.transcript.isEmpty ? "（无）" : "\(m.transcript.count) 字")
                    infoLine("纪要", m.summaryJSON.isEmpty ? "（还没生成）" : "已生成")
                    infoLine("状态", Self.statusText(m.status))
                }

                Text("免费签名只给 7 天，也没有云端同步。定期导出是唯一的保险，别等签名过期了才想起来。")
                    .font(.system(size: 12))
                    .foregroundStyle(YBColor.paperInkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 20)
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
                    toast = "已合并：\(url.lastPathComponent)\n可以直接分享，也可以去「文件 → 私人助理」里找。"
                }
            } catch {
                await MainActor.run {
                    merging = false
                    toast = error.localizedDescription
                }
            }
        }
    }

    private func paperCard<Content: View>(_ title: String,
                                          icon: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(YBColor.paperInk)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(YBColor.paperHi,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func infoLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(YBColor.paperInkSoft)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(YBColor.paperInk)
            Spacer(minLength: 0)
        }
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

    // MARK: - 工具栏

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
                    showDeleteConfirm = true
                } label: {
                    Label("删除这场会议", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    /// 顶上的余额胶囊：点一下重新查
    private var balanceChip: some View {
        YBBalanceChip(text: balance.chipText,
                      icon: balance.chipIcon,
                      tint: balanceTint,
                      busy: balance.isRefreshing) {
            balance.refresh(settings: settings)
        }
    }

    private var balanceTint: Color {
        if balance.isLow { return YBColor.warning }
        if balance.isUnavailable { return YBColor.textSecondary }
        return Color.primary
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

    private func deleteMeeting() {
        guard let m = meeting else { return }
        player.stop()
        store.delete(m)
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
