import SwiftUI
import UIKit

/// 会议详情。
///
/// 布局参考了录音类 App 的通用形态：标题和播放条钉在顶部，下面用分页切换
/// 「转写 / 纪要 / 录音 / 导出」。比起原来一长条列表，最大的区别是
/// 播放器一直在视野里——边听边看文字是会后整理最常用的动作。
struct MeetingDetailView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    let meetingID: String

    @StateObject private var player = MeetingPlayer()

    @State private var tab: DetailTab = .transcript
    @State private var titleDraft = ""
    @State private var transcriptDraft = ""
    @State private var loadedDraft = false
    @State private var loadedPlayer = false
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var toast = ""
    @State private var showRename = false
    @State private var showDeleteConfirm = false

    private enum DetailTab: String, CaseIterable, Identifiable {
        case transcript = "转写"
        case summary = "纪要"
        case audio = "录音"
        case export = "导出"

        var id: String { rawValue }
    }

    private var meeting: Meeting? { store.meeting(id: meetingID) }

    var body: some View {
        Group {
            if let m = meeting {
                VStack(spacing: 0) {
                    header(m)
                    tabPicker
                    Divider()
                    content(m)
                }
            } else {
                missingView
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(meeting?.title ?? "会议")
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

    // MARK: - 顶部

    private func header(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(metaLine(m))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    titleDraft = m.title
                    showRename = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }

            playerBar
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var playerBar: some View {
        HStack(spacing: 12) {
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(player.loaded ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!player.loaded)

            VStack(spacing: 2) {
                Slider(value: $scrubValue, in: 0...max(player.totalDuration, 1)) { editing in
                    isScrubbing = editing
                    player.setScrubbing(editing)
                }
                .disabled(!player.loaded)

                HStack(spacing: 0) {
                    Text(clock(isScrubbing ? scrubValue : player.elapsedTotal))
                    Spacer()
                    if player.loaded {
                        Text("第 \(min(player.currentIndex + 1, player.segmentCount))/\(player.segmentCount) 段")
                    } else {
                        Text("没有音频")
                    }
                    Spacer()
                    Text("-" + clock(max(player.totalDuration - (isScrubbing ? scrubValue : player.elapsedTotal), 0)))
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(DetailTab.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var missingView: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.folder")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("记录不存在，可能已经被删了")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(_ m: Meeting) -> some View {
        switch tab {
        case .transcript:
            transcriptTab(m)
        case .summary:
            MeetingSummaryPanel(meetingID: meetingID)
        case .audio:
            audioTab(m)
        case .export:
            exportTab(m)
        }
    }

    // MARK: - 转写

    private func transcriptTab(_ m: Meeting) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $transcriptDraft)
                    .font(.footnote)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                if transcriptDraft.isEmpty {
                    Text("还没有文字。可以把会议记录粘进来，也可以点下面的「自动转写」，把 \(m.segments.count) 段录音逐段转成文字。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(.systemBackground))

            transcriptBar
        }
    }

    private var transcriptBar: some View {
        HStack(spacing: 10) {
            NavigationLink {
                TranscriptionView(meetingID: meetingID)
            } label: {
                Label("自动转写", systemImage: "text.bubble")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)

            Button {
                saveTranscript(silently: false)
            } label: {
                Label("保存", systemImage: "square.and.arrow.down")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)

            Spacer(minLength: 0)

            Button {
                saveTranscript(silently: true)
                tab = .summary
            } label: {
                Label("生成纪要", systemImage: "wand.and.stars")
                    .font(.footnote)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - 录音段

    private func audioTab(_ m: Meeting) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if m.segments.isEmpty {
                    Text("这场会议没有留下音频段。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                } else {
                    ForEach(Array(m.segments.enumerated()), id: \.element.id) { index, segment in
                        segmentRow(index: index, segment: segment)
                    }
                }

                if !m.markers.isEmpty {
                    markersCard(m.markers)
                }
            }
            .padding(16)
        }
    }

    private func segmentRow(index: Int, segment: Meeting.AudioSegment) -> some View {
        let active = player.loaded && player.currentIndex == index
        return HStack(spacing: 12) {
            Image(systemName: active && player.isPlaying ? "waveform" : "play.fill")
                .font(.caption)
                .frame(width: 28, height: 28)
                .background(active ? Color.accentColor : Color.secondary.opacity(0.12), in: Circle())
                .foregroundStyle(active ? Color.white : Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text("第 \(index + 1) 段")
                    .font(.subheadline.weight(.medium))
                Text("从 \(clock(segment.startOffset)) 开始 · 时长 \(String(format: "%.0f", segment.durationSeconds)) 秒")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(segment.fileName)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(active ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.05),
                              lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if active && player.isPlaying {
                player.pause()
            } else {
                player.play(from: index)
            }
        }
    }

    private func markersCard(_ markers: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("录制时打的标记（\(markers.count) 个）", systemImage: "flag")
                .font(.subheadline.weight(.medium))
            Text(markers.map { clock($0) }.joined(separator: "、"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 导出

    private func exportTab(_ m: Meeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                card("导出", icon: "square.and.arrow.up") {
                    Button {
                        exportMarkdown(m)
                    } label: {
                        Label("导出为文本文件到「文件」", systemImage: "doc.text")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        UIPasteboard.general.string = markdown(m)
                        toast = "已复制到剪贴板"
                    } label: {
                        Label("复制全部内容到剪贴板", systemImage: "doc.on.doc")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                }

                card("这场会议", icon: "info.circle") {
                    infoLine("开始", m.startedAt.formatted(date: .numeric, time: .shortened))
                    infoLine("时长", RecordingService.durationText(m.durationSeconds))
                    infoLine("录音段", "\(m.segments.count) 段")
                    infoLine("文字", m.transcript.isEmpty ? "（无）" : "\(m.transcript.count) 字")
                    infoLine("纪要", m.summaryJSON.isEmpty ? "（还没生成）" : "已生成")
                    infoLine("状态", Self.statusText(m.status))
                }

                Text("免费签名只给 7 天，也没有云端同步。定期导出是唯一的保险，别等签名过期了才想起来。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private func card<Content: View>(_ title: String,
                                     icon: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func infoLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .font(.caption)
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
        ToolbarItem(placement: .topBarTrailing) {
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
        parts.append(m.startedAt.formatted(date: .abbreviated, time: .shortened))
        parts.append(RecordingService.durationText(m.durationSeconds))
        parts.append("\(m.segments.count) 段录音")
        if m.status == "recovered" { parts.append("⚠️ 意外中断恢复") }
        return parts.joined(separator: " · ")
    }

    private func markdown(_ m: Meeting) -> String {
        var out = "# \(m.title)\n\n"
        out += "- 开始：\(m.startedAt.formatted(date: .numeric, time: .shortened))\n"
        out += "- 时长：\(RecordingService.durationText(m.durationSeconds))\n"
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
