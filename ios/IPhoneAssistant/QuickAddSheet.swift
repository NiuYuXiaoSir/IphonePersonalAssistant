import SwiftUI

/// 「＋」速记面板：从任何页签两步之内记一条。
///
/// 三条路各走各的：
///   - 语音速记：说完就存（直接进速记表单，话筒已经开着）
///   - 手动填：自己选类型和时间
///   - 拍照：建一段新对话并把相机打开，拍完让助理读出来
///
/// 它替掉了原来那个「速记」页签——创建动作放「＋」而不是页签，
/// 主流 App 都这么做（苹果备忘录的编辑键、语音备忘录的录音键），
/// HIG 也明说页签是用来导航的、不是用来做动作的。
struct QuickAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var chats: ChatStore

    @State private var path = NavigationPath()
    @State private var detent: PresentationDetent = .medium

    private enum Route: Hashable {
        case voice
        case manual
        case camera(threadID: String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    option("语音速记", detail: "说完就存下来", icon: "mic.fill") {
                        path.append(Route.voice)
                    }
                    option("手动填", detail: "自己选类型和时间", icon: "square.and.pencil") {
                        path.append(Route.manual)
                    }
                    option("拍照", detail: "拍白板、纸质笔记，让助理读出来", icon: "camera") {
                        let thread = chats.createThread()
                        path.append(Route.camera(threadID: thread.id))
                    }
                } footer: {
                    Text("记一条不需要联网，没配密钥也能用。想让助理从一段话里替你拆出待办，走「对话」。")
                }
            }
            .navigationTitle("记一条")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .voice:
                    AssistantView(autoStartVoice: true)
                case .manual:
                    AssistantView()
                case .camera(let threadID):
                    ChatView(threadID: threadID, openCameraOnAppear: true)
                }
            }
            .onChange(of: path.count) { _, count in
                // 进去了就展开到全高，表单在半个屏幕里填不舒服
                if count > 0 { detent = .large }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    private func option(_ title: String, detail: String, icon: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
    }
}

#Preview {
    QuickAddSheet().environmentObject(ChatStore())
}
