import SwiftUI
import UIKit
import AVFoundation

// 这一份是界面语汇的唯一出处。整套观感照元宝抄，抄的是四条：
//
//   1. 纯黑底 + 比系统分组灰更「中性」的深灰卡片，不用 systemBackground
//      那套偏蓝灰的分级色；
//   2. 分组不是一堆小卡，而是一张卡里若干行，首尾各自收圆角、行间一条细线；
//   3. 主操作是卡片正中一个蓝图标 + 蓝字，不是系统按钮；
//   4. 文档类页面（会议详情）反过来用暖米色的纸，深色模式也不变黑——
//      元宝的纪要页就是这么干的，阅读长文字时比黑底舒服。
//
// 深浅色各给一套值：只在深色下能看的东西，切到浅色就是白字压白底。

// MARK: - 色板

enum YBColor {
    /// 页面底色
    static let bg = dynamic(light: 0xFFFFFF, dark: 0x000000)
    /// 卡片、搜索框、主操作按钮的底色
    static let surface = dynamic(light: 0xF2F2F7, dark: 0x1C1C1E)
    /// 比卡片再亮一档：胶囊、气泡、次要按钮
    static let surfaceHi = dynamic(light: 0xE8E8ED, dark: 0x2C2C2E)
    /// 分隔线
    static let line = dynamic(light: 0xE3E3E8, dark: 0x2C2C2E)
    static let textSecondary = dynamic(light: 0x6C6C70, dark: 0x9A9A9F)
    static let textTertiary = dynamic(light: 0xA0A0A6, dark: 0x6E6E73)
    static let danger = dynamic(light: 0xD70015, dark: 0xFF453A)
    static let accent = dynamic(light: 0x0A62E8, dark: 0x2B7DFF)
    static let success = dynamic(light: 0x1A8F4A, dark: 0x35C759)
    static let warning = dynamic(light: 0xB86A00, dark: 0xFF9F0A)

    // 纪要那张「纸」。深色模式下也维持米黄，所以不走 dynamic。
    static let paper = Color(red: 0.957, green: 0.941, blue: 0.867)        // #F4F0DD
    static let paperHi = Color(red: 0.929, green: 0.910, blue: 0.827)      // #EDE8D3
    static let paperButton = Color(red: 0.898, green: 0.874, blue: 0.769)  // #E5DFC4
    static let paperLine = Color(red: 0.851, green: 0.827, blue: 0.714)    // #D9D3B6
    static let paperInk = Color(red: 0.137, green: 0.129, blue: 0.106)     // #23211B
    static let paperInkSoft = Color(red: 0.427, green: 0.404, blue: 0.322) // #6D6752

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(ybHex: dark) : UIColor(ybHex: light)
        })
    }
}

extension UIColor {
    /// 0xRRGGBB
    convenience init(ybHex value: UInt32) {
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - 尺寸与字号

enum YBMetric {
    static let pagePad: CGFloat = 16
    static let cardRadius: CGFloat = 14
    static let rowPadV: CGFloat = 14
    static let rowGap: CGFloat = 10
    /// 主操作卡片的高度
    static let actionHeight: CGFloat = 64
}

enum YBFont {
    static let pageTitle = Font.system(size: 34, weight: .bold)
    static let rowTitle = Font.system(size: 16, weight: .medium)
    static let rowSubtitle = Font.system(size: 13)
    static let sectionHeader = Font.system(size: 14)
    static let actionLabel = Font.system(size: 18, weight: .semibold)
    static let hint = Font.system(size: 13)
    static let chatBody = Font.system(size: 16)
    static let docTitle = Font.system(size: 22, weight: .bold)
    static let docHeading = Font.system(size: 18, weight: .bold)
    static let docBody = Font.system(size: 15.5)
    static let docMeta = Font.system(size: 13)
}

// MARK: - 形状

/// 只给指定几个角收圆。分组卡片靠它做到「一张卡」而不是「一堆小卡」。
struct YBRoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect,
                                byRoundingCorners: corners,
                                cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

/// 这一行在分组里的位置——决定收哪几个角、上面要不要补分隔线
enum YBRowPosition: Equatable {
    case only, first, middle, last

    var corners: UIRectCorner {
        switch self {
        case .only:   return .allCorners
        case .first:  return [.topLeft, .topRight]
        case .middle: return []
        case .last:   return [.bottomLeft, .bottomRight]
        }
    }

    var showsTopLine: Bool {
        switch self {
        case .only, .first: return false
        case .middle, .last: return true
        }
    }
}

/// 元宝那种「文件夹标签」式分页：上宽下窄的梯形，顶上两个圆角。
/// 选中的那个和下面的纸同色，看起来是连成一片的。
struct YBFolderTabShape: Shape {
    var slant: CGFloat

    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 8
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + slant + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - slant - r, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - slant, y: rect.minY + r),
                       control: CGPoint(x: rect.maxX - slant, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + slant, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + slant + r, y: rect.minY),
                       control: CGPoint(x: rect.minX + slant, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - 通用按钮样式

/// 按下就淡一点。卡片行用它，省得点了没反馈。
struct YBPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// 深色面上的次要按钮（灰胶囊）
struct YBSoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(YBColor.surfaceHi, in: Capsule())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

/// 深色面上的主按钮（蓝胶囊）
struct YBPrimaryButtonStyle: ButtonStyle {
    var tint: Color = YBColor.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(tint, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// 纸面上的次要按钮
struct YBPaperButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(YBColor.paperInk)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(YBColor.paperButton, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// 纸面上的主按钮
struct YBPaperPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(YBColor.accent, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - 列表积木

/// 一张卡。行自己声明在分组里的位置，卡就自己把该收的角收掉。
struct YBCard<Content: View>: View {
    var position: YBRowPosition = .only
    var fill: Color = YBColor.surface
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if position.showsTopLine {
                Rectangle()
                    .fill(YBColor.line)
                    .frame(height: 1)
                    .padding(.leading, YBMetric.pagePad)
            }
            content()
        }
        .background(
            YBRoundedCorner(radius: YBMetric.cardRadius, corners: position.corners)
                .fill(fill)
        )
    }
}

/// 分组里的一行。图标 / 标题 / 副标题 / 右侧说明 / 箭头，自由组合。
struct YBRow: View {
    var title: String
    var subtitle: String? = nil
    var detail: String? = nil
    var icon: String? = nil
    var indent: CGFloat = 0
    /// 传 SF Symbol 名：展开态给 chevron.up，收起态给 chevron.down，能进下一页给 chevron.right
    var chevron: String? = nil
    var tint: Color? = nil
    var position: YBRowPosition = .only
    var action: (() -> Void)? = nil

    var body: some View {
        YBCard(position: position) {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(YBPressStyle())
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(YBColor.textSecondary)
                    .frame(width: 22, alignment: .center)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(YBFont.rowTitle)
                    .foregroundStyle(tint ?? Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(YBFont.rowSubtitle)
                        .foregroundStyle(YBColor.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer(minLength: 8)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(YBFont.rowSubtitle)
                    .foregroundStyle(YBColor.textSecondary)
                    .lineLimit(1)
            }

            if let chevron {
                Image(systemName: chevron)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YBColor.textTertiary)
            }
        }
        .padding(.horizontal, YBMetric.pagePad)
        .padding(.leading, indent)
        .padding(.vertical, YBMetric.rowPadV)
        .contentShape(Rectangle())
    }
}

/// 分组标题。右上角可以挂个按钮（元宝的「分组 +」就是这个位置）。
struct YBSectionHeader<Trailing: View>: View {
    private let title: String
    private let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(YBFont.sectionHeader)
                .foregroundStyle(YBColor.textSecondary)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, YBMetric.pagePad)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}

extension YBSectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// 吸顶的分组标签。
///
/// 贴在 List 的 Section header 上：滚动时钉在顶部不动，下面滚过去的行
/// 被这块底色挡住——就是元宝那种「今天 / 本月 / 更早」的冻结行。
/// 只有 .plain 的 List 会钉住 Section header，所以列表页都用 ybPageList()。
struct YBPinnedHeader<Trailing: View>: View {
    private let title: String
    private let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        YBSectionHeader(title) { trailing }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YBColor.bg)
            .listRowInsets(EdgeInsets())
    }
}

extension YBPinnedHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// 余额胶囊。放在会产生 token 的页面顶部，点一下重新查。
struct YBBalanceChip: View {
    var text: String
    var icon: String
    var tint: Color
    var busy: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(YBColor.surface, in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(YBPressStyle())
        .disabled(busy)
    }
}

/// 卡片下面那行灰色说明。元宝几乎每个主操作下面都跟一句。
struct YBHint: View {
    var text: String
    var icon: String? = nil
    var tint: Color = YBColor.textTertiary

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
                    .padding(.top, 2)
            }
            Text(text)
                .font(YBFont.hint)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, YBMetric.pagePad)
        .padding(.top, 10)
    }
}

/// 主操作卡片：整块灰底、正中一个蓝图标加蓝字
struct YBActionCard: View {
    var title: String
    var icon: String
    var busy: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 21, weight: .medium))
                }
                Text(title)
                    .font(YBFont.actionLabel)
            }
            .foregroundStyle(YBColor.accent)
            .frame(maxWidth: .infinity)
            .frame(height: YBMetric.actionHeight)
            .background(YBColor.surface,
                        in: RoundedRectangle(cornerRadius: YBMetric.cardRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(YBPressStyle())
        .disabled(busy)
    }
}

/// 搜索框：整条圆角灰底，左边放大镜，右边清空
struct YBSearchField: View {
    var placeholder: String
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(YBColor.textSecondary)

            TextField(placeholder, text: $text)
                .font(.system(size: 16))
                .foregroundStyle(Color.primary)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(onSubmit)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(YBColor.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(YBColor.surface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 搜索历史里的那种小圆角标签
struct YBTag: View {
    var text: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(YBColor.surface, in: Capsule())
        }
        .buttonStyle(YBPressStyle())
    }
}

/// 消息下面那排方形小按钮（元宝是复制/赞/踩/朗读/转发）
struct YBSquareButton: View {
    var icon: String
    var tint: Color = YBColor.textSecondary
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(YBColor.surface,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(YBColor.line, lineWidth: 1)
                )
        }
        .buttonStyle(YBPressStyle())
    }
}

/// 静态波形。柱高由文件名派生，同一个文件每次画出来一样——
/// 不是真波形，但比一条直线像录音。
struct YBWaveform: View {
    var seed: String
    var bars: Int = 34
    var tint: Color
    var height: CGFloat = 24

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<bars, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: 2, height: max(3, heights[index] * height))
            }
        }
        .frame(height: height)
    }

    private var heights: [CGFloat] {
        var state: UInt64 = 5381
        for scalar in seed.unicodeScalars {
            state = state &* 33 &+ UInt64(scalar.value)
        }
        state |= 1
        var out: [CGFloat] = []
        for _ in 0..<bars {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = CGFloat((state >> 33) % 1000) / 1000
            out.append(0.25 + unit * 0.75)
        }
        return out
    }
}

/// 「文件夹标签」分页条。要贴在纸面上方用，选中的标签和纸同色。
struct YBFolderTabs: View {
    var titles: [String]
    var icons: [String] = []
    @Binding var index: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(titles.indices, id: \.self) { i in
                let active = i == index
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { index = i }
                } label: {
                    HStack(spacing: 6) {
                        if i < icons.count {
                            Image(systemName: icons[i]).font(.system(size: 13))
                        }
                        Text(titles[i])
                            .font(.system(size: 14, weight: active ? .semibold : .regular))
                    }
                    .foregroundStyle(active ? YBColor.paperInk : YBColor.paperInkSoft)
                    .frame(maxWidth: .infinity)
                    .frame(height: active ? 44 : 38)
                    .background(
                        YBFolderTabShape(slant: 10)
                            .fill(active ? YBColor.paper : YBColor.paperHi)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(YBPressStyle())
            }
        }
        .padding(.horizontal, 12)
    }
}

/// 进度条。系统 Slider 在深色胶囊里太粗，拖动条自己画一个。
struct YBScrubber: View {
    @Binding var value: Double
    var total: Double
    var onEditing: (Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fraction = total > 0 ? min(max(value / total, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(YBColor.line).frame(height: 3)
                Capsule().fill(YBColor.accent)
                    .frame(width: width * fraction, height: 3)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onEditing(true)
                        let ratio = min(max(gesture.location.x / width, 0), 1)
                        value = ratio * max(total, 0)
                    }
                    .onEnded { _ in onEditing(false) }
            )
        }
        .frame(height: 22)
    }
}

/// 搜索历史。两个页面各存一份，最多 10 条。
final class YBSearchHistory: ObservableObject {
    static let meetings = YBSearchHistory(key: "yb.search.meetings")
    static let chats = YBSearchHistory(key: "yb.search.chats")

    @Published private(set) var items: [String] = []

    private let key: String

    private init(key: String) {
        self.key = key
        items = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = items.filter { $0 != trimmed }
        next.insert(trimmed, at: 0)
        items = Array(next.prefix(10))
        UserDefaults.standard.set(items, forKey: key)
    }

    func clear() {
        items = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// 朗读。同一时刻只念一条，再点一次就是停。
enum YBSpeech {
    private static let synthesizer = AVSpeechSynthesizer()

    static func toggle(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        synthesizer.speak(utterance)
    }

    static func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }
}

/// 纸面上的多行输入框。
///
/// 不用 SwiftUI 的 TextEditor：它的文字颜色在深色模式下由系统定，
/// 落在米黄纸上会变成浅色字，读不出来。这里直接把 UITextView 的文字色、
/// 背景色、边距都钉死，不受明暗模式影响。
struct YBPaperTextEditor: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.font = UIFont.systemFont(ofSize: 15.5)
        view.textColor = UIColor(YBColor.paperInk)
        view.tintColor = UIColor(YBColor.accent)
        view.textContainerInset = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        view.alwaysBounceVertical = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        view.textColor = UIColor(YBColor.paperInk)
        view.font = UIFont.systemFont(ofSize: 15.5)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}

// MARK: - 给 List 用的小工具
//
// 列表页仍然用 List（要它的左滑删除和行复用），但把系统的行外观全部关掉，
// 改成自己画的卡片：行的左右留白交给 listRowInsets，卡片自己只画背景，
// 于是「一张卡」的左右边界就是 16 点，和元宝一致。

extension View {
    /// 行的留白。分组内的行用默认值；分组最后一行传 bottom: rowGap 隔开下一组。
    /// 自己带左右留白的组件（YBHint、YBSectionHeader）传 horizontal: 0。
    func ybRow(horizontal: CGFloat = YBMetric.pagePad, bottom: CGFloat = 0) -> some View {
        self
            .listRowInsets(EdgeInsets(top: 0, leading: horizontal,
                                      bottom: bottom, trailing: horizontal))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// 整页统一的 List 外观：黑底、无系统行背景
extension View {
    func ybPageList() -> some View {
        self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(YBColor.bg)
            .environment(\.defaultMinListRowHeight, 1)
    }
}
