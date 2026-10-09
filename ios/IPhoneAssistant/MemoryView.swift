import SwiftUI

/// 记忆页的跳转标识。会话 id 也是字符串，用不同的类型区分开，
/// 免得两个 navigationDestination(for: String.self) 撞在一起。
struct MemoryRoute: Hashable {}

/// 记忆页：助理到底记住了什么。
///
/// 上面是长期记忆（你是谁、在做什么、有什么偏好），下面是每天的流水（做了什么、打算做什么）。
/// 这些内容会直接进模型的 prompt，所以记错了必须能删——错的东西留着会一直误导它。
///
/// 版式用系统 List（insetGrouped）：分组、行、页脚说明都是系统给的。
struct MemoryView: View {
    @ObservedObject private var memory = MemoryStore.shared

    @State private var clearScope: MemoryStore.Scope?

    var body: some View {
        List {
            factsSection
            timelineSection
        }
        .navigationTitle("记忆")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        clearScope = .timeline
                    } label: {
                        Label("清空每日流水", systemImage: "calendar")
                    }
                    Button {
                        clearScope = .facts
                    } label: {
                        Label("清空长期记忆", systemImage: "brain")
                    }
                    Button(role: .destructive) {
                        clearScope = .all
                    } label: {
                        Label("清空全部记忆", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多操作")
                .disabled(memory.facts.isEmpty && memory.logs.isEmpty)
            }
        }
        // 清空是不可撤销的，所以三档清空都先问一次——
        // 以前只有「全部」问，另外两档点一下就没了（HIG 的 Alerts 页：
        // 不可撤销的动作要弹一下，免得是误触）
        .confirmationDialog(clearTitle,
                            isPresented: Binding(get: { clearScope != nil },
                                                 set: { if !$0 { clearScope = nil } }),
                            titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                if let scope = clearScope { memory.clear(scope) }
                clearScope = nil
            }
            Button("取消", role: .cancel) { clearScope = nil }
        } message: {
            Text(clearMessage)
        }
        .onAppear { memory.reload() }
    }

    private var clearTitle: String {
        switch clearScope {
        case .facts:    return "清空长期记忆？"
        case .timeline: return "清空每日流水？"
        default:        return "清空全部记忆？"
        }
    }

    private var clearMessage: String {
        switch clearScope {
        case .facts:
            return "关于你的稳定事实（人物、偏好、在做的事）会被删掉，流水留着。清空之后只能重新告诉它。"
        case .timeline:
            return "按天记的流水（做了什么、打算做什么）会被删掉，长期记忆留着。"
        default:
            return "长期记忆和每日流水都会被删掉。已经存下的条目和备忘不受影响。"
        }
    }

    // MARK: - 长期记忆

    @ViewBuilder
    private var factsSection: some View {
        Section {
            if memory.facts.isEmpty {
                ContentUnavailableView {
                    Label("还没有长期记忆", systemImage: "brain")
                } description: {
                    Text("在对话里说「老王是桥杆供应商」「我一般十点睡」这类话，它就会记在这里。")
                }
            } else {
                ForEach(memory.facts) { fact in
                    logRow(icon: fact.kind.symbol,
                           title: fact.content,
                           subtitle: "\(fact.kind.label) · \(fact.updatedAt.formatted(date: .numeric, time: .omitted))")
                    .swipeActions {
                        Button(role: .destructive) {
                            memory.delete(fact: fact)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    // 左滑不是唯一入口：长按也能删（HIG 的 Gestures 页要求重要动作有第二条路）
                    .contextMenu {
                        Button(role: .destructive) {
                            memory.delete(fact: fact)
                        } label: {
                            Label("删除这条", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Text("长期记忆（\(memory.facts.count)）")
        } footer: {
            Text("这些是助理记住的事，每轮对话都会挑相关的带上。它只记在手机上（assistant.sqlite3），不会同步到任何地方。")
        }
    }

    // MARK: - 每日流水

    @ViewBuilder
    private var timelineSection: some View {
        if memory.dayGroups.isEmpty {
            Section {
                ContentUnavailableView {
                    Label("还没有流水", systemImage: "calendar.badge.clock")
                } description: {
                    Text("说一句「今天去厂里看了桥杆」，或者在「＋」里记一条，都会按天记在这里。")
                }
            } header: {
                Text("每日流水")
            }
        } else {
            ForEach(memory.dayGroups) { group in
                Section {
                    ForEach(group.logs) { log in
                        logRow(icon: log.kind.symbol,
                               title: log.content,
                               subtitle: "\(log.kind.label) · \(log.at.formatted(date: .omitted, time: .shortened))")
                        .swipeActions {
                            Button(role: .destructive) {
                                memory.delete(log: log)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                memory.delete(log: log)
                            } label: {
                                Label("删除这条", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(group.title)
                }
            }
        }
    }

    /// 一条记忆：图标 + 内容 + 「类型 · 时间」。
    /// 用文本样式而不是写死字号，系统字号调大时能跟着长。
    private func logRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        MemoryView()
    }
}
