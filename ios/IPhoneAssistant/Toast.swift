import SwiftUI
import UIKit

/// 轻提示浮层。
///
/// iOS 没有系统级的 toast 组件，但 Apple 自己的「拷贝」也是浮层——所以这里按同一路子自己画一个：
/// 顶部一条 `.regularMaterial` 胶囊，1.6 秒后自动收起，点一下立刻收掉，可以带一个动作（撤销）。
///
/// 用途只限「说一句就完了」的反馈（已复制、已恢复、已保存）。
/// 需要用户做决定的（删除确认、错误详情）用系统 Alert，不要混着来——
/// HIG 的 Alerts 页明说不要把弹窗当提示用。
struct ToastModifier: ViewModifier {

    @Binding var message: String
    /// 带一个动作的（比如「撤销」）
    var actionTitle: String?
    var action: (() -> Void)?

    @State private var visible = false
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if visible, !message.isEmpty {
                    bubble
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: visible)
            .onChange(of: message) { _, new in
                guard !new.isEmpty else { return }
                present()
            }
    }

    private var bubble: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(actionTitle) {
                    action()
                    hide()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(uiColor: .separator), lineWidth: 0.5))
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .onTapGesture(perform: hide)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private func present() {
        dismissTask?.cancel()
        visible = true
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    private func hide() {
        dismissTask?.cancel()
        visible = false
        // 把绑定清空：同一条文案连着弹两次时，onChange 才会再触发一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [visible] in
            if !visible { message = "" }
        }
    }
}

extension View {
    /// 轻提示。把字符串塞进这个绑定就浮一下。
    func toast(_ message: Binding<String>) -> some View {
        modifier(ToastModifier(message: message))
    }

    /// 带一个动作的轻提示（撤销、重试）。
    func toast(_ message: Binding<String>,
               actionTitle: String,
               action: @escaping () -> Void) -> some View {
        modifier(ToastModifier(message: message, actionTitle: actionTitle, action: action))
    }
}
