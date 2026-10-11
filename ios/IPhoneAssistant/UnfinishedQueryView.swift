import SwiftUI
import UIKit

/// 查未完成的事项：选一段时间，把「还没做完的」交给助理整理成一段话。
///
/// 为什么不做成「安排」里的一个筛选：安排是一张**要动手处理**的清单，
/// 这里要的是「看一眼这段时间我落了什么」——筛出来的原始记录本身不值得看第二遍，
/// 值得看的是助理把逾期最久、最要紧的那几件拎出来讲清楚。
///
/// 版式按 HIG 的 Layout 页那条来（「Make essential information easy to find by giving it
/// sufficient space… you can make secondary information available in other parts…」）：
/// 上面是助理整理的那段话（主要内容），下面是本地筛出来的原始记录（用来核对）。
///
/// 上面那段话是模型生成的，所以：原始记录一并摆在下面（能核对、能追问「这条不对」），
/// 整理结果可以选中复制，失败就说清失败、原始清单照样能看。
///
/// **整理是手动触发的**：打开这张表和换时间段都只重算本地清单，一次请求都不发——
/// 要花 token 的事必须由用户自己点那一下（自动整理对 token 不友好，
/// 用户明确要求改掉）。上次整理过的结果会从缓存里直接显示出来，也是不花钱的。
struct UnfinishedQueryView: View {

    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var items = ItemStore.shared
    @ObservedObject private var memory = MemoryStore.shared
    @ObservedObject private var balance = BalanceStore.shared
    @Environment(\.dismiss) private var dismiss

    /// 默认看一周：接得住这两天的漏，又不至于长到看不完
    @State private var range: UnfinishedRange = .week
    /// 每段范围最近一次的整理结果（含当时那份清单的签名，用来判断本地清单有没有变）
    @State private var reports: [UnfinishedRange: UnfinishedReportCache] = [:]
    /// 正在问的是哪一段（不是 Bool：切档位时新任务和旧任务的收尾会互相盖）
    @State private var askingRange: UnfinishedRange?
    @State private var errorMessage: String?
    @State private var askTask: Task<Void, Never>?
    @State private var toast = ""
    @State private var hapticSuccess = 0

    private var digest: UnfinishedDigest { UnfinishedQuery.run(range: range) }

    private var report: UnfinishedReportCache? { reports[range] }

    var body: some View {
        NavigationStack {
            List {
                rangeSection
                reportSection
                digestSection
                actionsSection
            }
            .navigationTitle("未完成的事项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if balance.supports(settings) { balanceChip }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                // 清单要现算：记忆库的流水可能是别的页面改过的
                memory.reload()
                loadCache()
                // 这里**不**问模型：整理要花 token，等用户点「让助理整理」（缓存里有就直接显示）
            }
            // 换档位只清掉上一段的报错/停止提示，不发请求
            .onChange(of: range) { _, _ in errorMessage = nil }
            .onDisappear { askTask?.cancel() }
            .toast($toast)
            .sensoryFeedback(.success, trigger: hapticSuccess) { _, _ in settings.hapticsEnabled }
        }
    }

    // MARK: - 时间范围

    /// 分段控件放 List 的行里，不放工具栏——HIG 的 Segmented controls 页：
    /// 「i OS: Avoid using a segmented control in a toolbar」。
    /// 标签是纯文字的五个短词（那页：「no more than about five segments on iPhone」
    /// 「Prefer using either text or images — not a mix of both」）。
    private var rangeSection: some View {
        Section {
            Picker("时间范围", selection: $range) {
                ForEach(UnfinishedRange.allCases) { candidate in
                    Text(candidate.label).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } footer: {
            Text("\(range.summary())。换一段只重算本地清单，不问模型；整理要点了按钮才发请求。")
        }
    }

    // MARK: - 助理整理的

    @ViewBuilder
    private var reportSection: some View {
        Section {
            if digest.isEmpty {
                Label("这段时间没有未完成的事项。", systemImage: "checkmark.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else if askingRange == range {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在整理…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    // 能中断：HIG 的 Progress indicators 页「let people halt processing」
                    Button("停止") { stop() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.vertical, 2)
            } else if let report {
                VStack(alignment: .leading, spacing: 10) {
                    rendered(report.report)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    // 缓存里的那份如果对不上现在的清单（打过勾、改过时间、加过条目），
                    // 说清它是什么时候的，别让人拿一份过期的话当真
                    if report.signature != digest.signature {
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .padding(.top, 1)
                            Text("本地清单变过了（打过勾、改过时间或加了新条目）。这份是 \(agoText(report.askedAt))整理的，点「重新整理」按现在的清单重算。")
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = report.report
                            toast = "已复制"
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)

                        Button {
                            start()
                        } label: {
                            Label("重新整理", systemImage: "arrow.clockwise")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            } else if let errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试") { start() }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                }
                .padding(.vertical, 2)
            } else {
                // 还没整理过：等用户点这一下。花 token 的事不自动做
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        start()
                    } label: {
                        Label("让助理整理", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Text("点一下会把下面这份清单发给模型，算一次用量。同一份清单不会再重复算。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("助理整理的")
        } footer: {
            if digest.isEmpty {
                Text("本地筛的是「安排」里到点没打勾的、没设时间的，以及记忆里写着「打算做」的。")
            } else if let report {
                Text("这段话是 \(agoText(report.askedAt))整理的。它是模型按下面这份清单归纳的，核对以下面的记录为准。")
            }
        }
    }

    /// 「刚刚」「12 分钟前」「3 小时前」——整理的时间离现在多久
    private func agoText(_ date: Date) -> String {
        let seconds = Int(max(0, Date().timeIntervalSince(date)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3600) 小时前" }
        return "\(seconds / 86_400) 天前"
    }

    // MARK: - 本地筛出来的原始记录

    @ViewBuilder
    private var digestSection: some View {
        if !digest.overdue.isEmpty {
            Section {
                ForEach(digest.overdue) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(overdueLine(item))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("到点了还没打勾（\(digest.overdue.count) 条）")
            } footer: {
                Text("这些在「安排」里都还在，打完勾就不会再出现在这里。")
            }
        }

        if !digest.timeless.isEmpty {
            Section {
                ForEach(digest.timeless) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(item.kind.label) · 记于 \(item.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("没设时间的（\(digest.timeless.count) 条）")
            } footer: {
                Text("这些没设时间，哪一段都算「还没完成」。想让它到点提醒，在「安排」里补个时间。")
            }
        }

        if !digest.plans.isEmpty {
            Section {
                ForEach(digest.plans) { log in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(log.content)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(MemoryStore.dayLabel(log.day))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("记忆里「打算做」的（\(digest.plans.count) 条）")
            } footer: {
                Text("这是你说过打算做的事，App 不知道做没做——做过了就在「对话」里说一句，它记下之后这里就不会再列。")
            }
        }
    }

    private func overdueLine(_ item: AssistantItem) -> String {
        var parts: [String] = []
        if let due = item.dueAt { parts.append("原定 \(ItemTimeText.when(due))") }
        if let fire = item.fireDate { parts.append(ItemTimeText.relative(fire)) }
        parts.append(item.kind.label)
        if item.remindBeforeMinutes > 0 { parts.append("提前 \(item.remindBeforeMinutes) 分钟提醒过") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 去处理

    @ViewBuilder
    private var actionsSection: some View {
        if !digest.isEmpty {
            Section {
                Button {
                    // 先让「今日」把请求消费掉（它会推进「安排」），再收起这张表
                    AppRouter.shared.showSchedule = true
                    dismiss()
                } label: {
                    Label("去「安排」里改时间或打勾", systemImage: "checklist")
                }
            } footer: {
                Text("「安排」里点开一条能改时间、改标题，往左滑能打勾或删除。")
            }
        }
    }

    // MARK: - 问模型（只有用户点了按钮才会走到这里）

    /// 用户点了「让助理整理」/「重新整理」/「重试」
    private func start() {
        askTask?.cancel()
        askTask = Task { await ask() }
    }

    /// 把上次整理的读回来（存在 UserDefaults 里，退出 App 也还在）。
    /// 读回来只是**显示**，不代表会重算——重算只发生在用户点按钮时。
    private func loadCache() {
        for candidate in UnfinishedRange.allCases {
            if let hit = UnfinishedReportCache.load(candidate) { reports[candidate] = hit }
        }
    }

    private func stop() {
        askTask?.cancel()
        askTask = nil
        askingRange = nil
        errorMessage = "已停止。下面的清单是本地筛的，可以先看；想再整理一次点「重试」。"
    }

    /// 真正问模型的那一段。标成 @MainActor：几个 @State 都在主线程上改
    /// （Task 是从来处继承 actor 的，不标就可能落到后台线程去改视图状态）。
    @MainActor
    private func ask() async {
        let target = range
        guard !digest.isEmpty else { return }
        guard let config = config() else { return }

        askingRange = target
        errorMessage = nil
        let material = digest.material()
        let rangeText = target.summary()
        AppLog.info("Unfinished", "手动整理「\(range.label)」：逾期 \(digest.overdue.count)、没时间 \(digest.timeless.count)、计划 \(digest.plans.count) 条，材料 \(material.count) 字")

        do {
            let answer = try await AIStructurer.organize(material: material,
                                                         rangeText: rangeText,
                                                         config: config)
            guard !Task.isCancelled else { return }
            let entry = UnfinishedReportCache(report: answer,
                                              signature: digest.signature,
                                              askedAt: Date())
            reports[target] = entry
            entry.save(for: target)
            if range == target { hapticSuccess += 1 }
            balance.refresh(settings: settings)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "没整理出来：\(error.localizedDescription)"
            AppLog.warn("Unfinished", "整理失败：\(error.localizedDescription)")
        }
        if askingRange == target { askingRange = nil }
    }

    private func config() -> LLMConfig? {
        var config = settings.makeConfig()
        guard config.chatCompletionsURL != nil, !config.apiKey.isEmpty else {
            errorMessage = "还没有可用的密钥，去「我的」里填一个，就能让它把这几条整理成人话。下面的清单是本地筛出来的，先看着也一样。"
            return nil
        }
        // 固定一个会话 id：这类网关按它做路由和 prompt 缓存
        config.sessionID = "unfinished-query"
        return config
    }

    // MARK: - 余额

    private var balanceChip: some View {
        Button {
            balance.refresh(settings: settings)
        } label: {
            HStack(spacing: 5) {
                if balance.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: balance.isLow ? "exclamationmark.triangle.fill" : balance.chipIcon)
                        .font(.caption)
                }
                Text(balance.chipText).font(.footnote)
            }
            .foregroundStyle(balance.isLow ? Color.orange : Color.primary)
        }
        .disabled(balance.isRefreshing)
        .accessibilityLabel("余额：\(balance.chipText)，点击刷新")
    }

    // MARK: - 轻渲染

    /// 和对话页一样的受控 Markdown：粗体、列表这些正常显示，解析不了就当纯文本画出来，绝不吞内容。
    private func rendered(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}

#Preview {
    UnfinishedQueryView()
        .environmentObject(SettingsStore())
}
