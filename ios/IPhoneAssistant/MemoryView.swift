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

    @State private var showClearConfirm = false

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
                        memory.clear(.timeline)
                    } label: {
                        Label("清空每日流水", systemImage: "calendar")
                    }
                    Button {
                        memory.clear(.facts)
                    } label: {
                        Label("清空长期记忆", systemImage: "brain")
                    }
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("清空全部记忆", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(memory.facts.isEmpty && memory.logs.isEmpty)
            }
        }
        .confirmationDialog("清空全部记忆？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空", role: .destructive) { memory.clear(.all) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("长期记忆和每日流水都会被删掉。已经写进提醒事项、日历、备忘的东西不受影响。")
        }
        .onAppear { memory.reload() }
    }

    // MARK: - 长期记忆

    @ViewBuilder
    private var factsSection: some View {
        Section {
            if memory.facts.isEmpty {
                Text("还没有长期记忆。对话里说「老王是桥杆供应商」「我一般十点睡」这类话，它会记在这里。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                Text("还没有流水。对话里说「今天去厂里看了桥杆」，或者在速记页记一条，都会按天记在这里。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
