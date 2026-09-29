import SwiftUI

struct MeetingsView: View {
    @EnvironmentObject private var store: MeetingStore
    @State private var showRecorder = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showRecorder = true
                    } label: {
                        Label("开始记录会议", systemImage: "record.circle")
                            .font(.headline)
                    }
                } footer: {
                    Text("点一下就开始录音，然后可以把手机锁屏放桌上。每分钟自动存一段，即使 App 被系统回收也只会丢最后一段。")
                }

                Section {
                    if store.meetings.isEmpty {
                        Text("还没有会议记录")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.meetings) { meeting in
                            NavigationLink(value: meeting.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(meeting.title).font(.headline)
                                    Text(metaLine(meeting))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                guard index < store.meetings.count else { continue }
                                store.delete(store.meetings[index])
                            }
                        }
                    }
                } header: {
                    Text("历史记录")
                } footer: {
                    if !store.meetings.isEmpty {
                        Text("音频占用 \(formatBytes(store.storageBytes()))。左滑删除会连同音频一起删掉。")
                    }
                }
            }
            .navigationTitle("会议")
            .navigationDestination(for: String.self) { id in
                MeetingDetailView(meetingID: id)
            }
            .fullScreenCover(isPresented: $showRecorder) {
                RecordView()
            }
        }
    }

    private func metaLine(_ m: Meeting) -> String {
        var parts: [String] = []
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日 HH:mm"
        parts.append(df.string(from: m.startedAt))
        parts.append(RecordingService.durationText(m.durationSeconds))
        parts.append("\(m.segments.count) 段录音")
        if m.status == "recovered" { parts.append("⚠️ 意外中断恢复") }
        if !m.transcript.isEmpty { parts.append("有文字") }
        return parts.joined(separator: " · ")
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}

#Preview {
    MeetingsView().environmentObject(MeetingStore())
}
