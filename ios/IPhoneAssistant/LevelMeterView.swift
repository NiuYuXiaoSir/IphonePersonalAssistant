import SwiftUI

/// 录音电平表：把最近的电平值滚成一条柱状波。
///
/// 录的时候它是「麦克风真的在收」的唯一直观证据。上一版只有段数和字数，
/// 录一场三小时的会，中途没有任何东西能说明还在收音。
struct LevelMeterView: View {

    /// 0...1
    var level: Float
    var isActive: Bool
    var bars: Int = 36
    var height: CGFloat = 44

    @State private var history: [Float]

    init(level: Float, isActive: Bool, bars: Int = 36, height: CGFloat = 44) {
        self.level = level
        self.isActive = isActive
        self.bars = bars
        self.height = height
        _history = State(initialValue: Array(repeating: 0, count: bars))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(history.indices, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(height: max(2, CGFloat(history[index]) * height))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .animation(.linear(duration: 0.1), value: history)
        .onChange(of: level) { _, new in push(new) }
        .accessibilityElement()
        .accessibilityLabel(isActive ? "正在收音" : "没有收音")
    }

    private var tint: Color {
        isActive ? Color.accentColor : Color(uiColor: .tertiaryLabel)
    }

    private func push(_ value: Float) {
        var next = history
        next.removeFirst()
        next.append(max(0, min(1, value)))
        history = next
    }
}
