import SwiftUI

struct RecordView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: MeetingStore
    @StateObject private var recorder = RecordingService()
    @State private var finished = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                Text(clock(recorder.elapsed))
                    .font(.system(size: 58, weight: .light, design: .monospaced))
                    .monospacedDigit()

                Text(recorder.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 8)

                HStack(spacing: 26) {
                    stat("已存段数", "\(recorder.segmentCount)")
                    stat("当前段", "\(recorder.currentFileKB) KB")
                    stat("标记", "\(recorder.markerCount)")
                }
                .padding(.top, 26)

                Spacer()

                if recorder.isRecording {
                    Button {
                        recorder.addMarker()
                    } label: {
                        Label("打标记", systemImage: "flag")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, 24)

                    Button {
                        finishAndSave()
                    } label: {
                        Label("结束并保存", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                } else if finished {
                    Label("已保存到会议列表", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                    Button("返回列表") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 12)
                } else {
                    Button {
                        recorder.start()
                    } label: {
                        Label("开始录音", systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 24)
                }

                Text("录音期间可以锁屏、可以切到别的 App。来电或闹钟打断后会尝试自动接上。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 18)
                    .padding(.bottom, 24)
            }
            .navigationTitle("记录会议")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        if recorder.isRecording { finishAndSave() }
                        dismiss()
                    }
                }
            }
            .onAppear {
                if !recorder.isRecording && !finished {
                    recorder.start()
                }
            }
        }
    }

    private func finishAndSave() {
        if let meeting = recorder.stop() {
            store.add(meeting)
            AppLog.info("Record", "已保存会议 \(meeting.id)，\(meeting.segments.count) 段")
            finished = true
        } else {
            AppLog.error("Record", "结束录音但没有可用音频")
            finished = true
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(.headline, design: .monospaced))
            Text(label).font(.caption2).foregroundStyle(.secondary)
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
    RecordView().environmentObject(MeetingStore())
}
