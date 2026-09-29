import SwiftUI

/// 主界面。现阶段只做一件事：确认「App → 模型服务」这条链路通。
/// 会议录音、转写、总结、写入系统数据是后面几轮的事。
struct AssistantView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var input = ""
    @State private var output = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if settings.hasKey {
                        Label("凭证已就绪 · \(settings.model)", systemImage: "checkmark.seal")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    } else {
                        Label("还没配置 API Key，点下面的「去设置」填一个", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    TextField("跟模型说一句话…", text: $input, axis: .vertical)
                        .lineLimit(1...4)
                    Button(busy ? "请求中…" : "发送") { send() }
                        .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("连通性试跑")
                } footer: {
                    Text("这一步只验证「App → 模型服务」的链路。会议录音、转写、总结和写入系统数据是后面几步。")
                }

                if !output.isEmpty {
                    Section("回复") {
                        Text(output)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("助手")
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true
        output = ""
        let config = settings.makeConfig()

        Task {
            do {
                let client = OpenAICompatibleClient(config: config)
                let reply = try await client.chat([
                    .system("你是一个中文工作助理。回答简洁，不要客套话。"),
                    .user(text)
                ], jsonMode: false)
                await MainActor.run {
                    self.busy = false
                    self.output = reply
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.output = "❌ \(error.localizedDescription)"
                }
            }
        }
    }
}

#Preview {
    AssistantView().environmentObject(SettingsStore())
}
