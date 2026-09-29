import SwiftUI
import AVFoundation

/// 极简播放器，用来试听某个录音段。
/// 它的另一个作用是一一能播出来，就说明这个文件是完整的，这是验证分段录制有没有坏掉的最快方法。
final class SimplePlayer: ObservableObject {
    @Published private(set) var playingID: String?
    private var player: AVAudioPlayer?

    func toggle(id: String, url: URL) {
        if playingID == id {
            stop()
            return
        }
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.play()
            player = p
            playingID = id
            AppLog.info("Player", "播放 \(url.lastPathComponent)，时长 \(String(format: "%.1f", p.duration)) 秒")
        } catch {
            AppLog.error("Player", "播放失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct MeetingDetailView: View {
    @EnvironmentObject private var store: MeetingStore
    let meetingID: String

    @StateObject private var player = SimplePlayer()
    @State private var titleDraft = ""
    @State private var transcriptDraft = ""
    @State private var loaded = false
    @State private var message = ""

    private var meeting: Meeting? { store.meeting(id: meetingID) }

    var body: some View {
        List {
            if let m = meeting {
                summarySection(m)
                audioSection(m)
                textSection
                if !m.summaryJSON.isEmpty { aiSection(m) }
                exportSection(m)
            } else {
                Text("记录不存在，可能已被删除").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(meeting?.title ?? "会议")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadDrafts)
        .onDisappear { player.stop() }
    }

    private func loadDrafts() {
        guard !loaded, let m = meeting else { return }
        titleDraft = m.title
        transcriptDraft = m.transcript
        loaded = true
    }

    // MARK: - 区块

    private func summarySection(_ m: Meeting) -> some View {
        Section("基本信息") {
            LabeledContent("开始", value: m.startedAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("时长", value: RecordingService.durationText(m.durationSeconds))
            LabeledContent("录音段数", value: "\(m.segments.count)")
            if !m.markers.isEmpty {
                LabeledContent("标记点", value: m.markers.map { "\(Int($0 / 60))分\(Int($0 % 60))秒" }.joined(separator: "、"))
            }
            LabeledContent("状态", value: m.status)
            TextField("标题", text: $titleDraft)
                .onSubmit { renameMeeting() }
        }
    }

    private func audioSection(_ m: Meeting) -> some View {
        Section {
            ForEach(m.segments) { seg in
                HStack {
                    Button {
                        let url = MeetingStore.recordingsDirectory().appendingPathComponent(seg.fileName)
                        player.toggle(id: seg.id, url: url)
                    } label: {
                        Label(player.playingID == seg.id ? "停止" : "试听",
                              systemImage: player.playingID == seg.id ? "stop.fill" : "play.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(seg.fileName).font(.system(.caption2, design: .monospaced))
                        Text(String(format: "偏移 %.0f 秒 · 时长 %.1f 秒", seg.startOffset, seg.durationSeconds))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("录音段")
        } footer: {
            Text("每一段都是独立完整的文件。能正常试听，就说明这段录音没有损坏。")
        }
    }

    private var textSection: some View {
        Section {
            TextEditor(text: $transcriptDraft)
                .frame(minHeight: 140)
                .font(.system(.footnote, design: .monospaced))
            Button("保存文字") { saveTranscript() }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("会议文字")
        } footer: {
            Text("语音自动转写还没做（下一轮）。现在可以手动粘会议记录、聊天记录或你自己的笔记到这里，后面的 AI 纪要和待办就基于这段文字生成。")
        }
    }

    private func aiSection(_ m: Meeting) -> some View {
        Section("AI 纪要") {
            Text(m.summaryJSON)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func exportSection(_ m: Meeting) -> some View {
        Section {
            Button("导出为 Markdown 到「文件」App") { exportMarkdown(m) }
            Button("复制 Markdown 到剪贴板") {
                UIPasteboard.general.string = markdown(m)
                message = "已复制到剪贴板"
            }
        } header: {
            Text("导出")
        } footer: {
            Text("免费签名只给 7 天，而且没有 iCloud。定期导出是唯一的保险，别等签名过期了才想起来。")
        }
    }

    // MARK: - 动作

    private func renameMeeting() {
        guard var m = meeting else { return }
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        m.title = trimmed
        store.update(m)
        message = "标题已保存"
    }

    private func saveTranscript() {
        guard var m = meeting else { return }
        m.transcript = transcriptDraft
        if !m.transcript.isEmpty && m.status == "recorded" {
            m.status = "transcribed"
        }
        store.update(m)
        message = "已保存 \(m.transcript.count) 字"
        AppLog.info("Meeting", "保存文字 \(m.transcript.count) 字")在
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
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        do {
            try markdown(m).write(to: url, atomically: true, encoding: .utf8)
            message = "已导出：\(name)"
            AppLog.info("Export", "导出 \(name)")
        } catch {
            message = "导出失败：\(error.localizedDescription)"
            AppLog.error("Export", message)
        }
    }
}

#Preview {
    NavigationStack {
        MeetingDetailView(meetingID: "none")
    }
    .environmentObject(MeetingStore())
}
