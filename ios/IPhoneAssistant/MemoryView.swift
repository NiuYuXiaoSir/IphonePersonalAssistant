import SwiftUI

/// 记忆页的跳转标识。会话 id 也是字符串，用不同的类型区分开，
/// 免得两个 navigationDestination(for: String.self) 撞在一起。
struct MemoryRoute: Hashable {}

/// 记忆页：助理到底记住了什么。
///
/// 上面是长期记忆（你是谁、在做什么、有什么偏好），下面是每天的流水（做了什么、打算做什么）。
/// 这些内容会直接进模型的 prompt，所以记错了必须能删——错的东西留着会一直误导它。
struct MemoryView: View {
    @ObservedObject private var memory = MemoryStore.shared

    @State private var showClearConfirm = false

    var body: some View {
        List {
            Section {
                YBHint(text: "这些是助理记住的事，每轮对话都会挑相关的带上。它只记在手机上（assistant.sqlite3），不会同步到任何地方。")
                    .padding(.top, 12)
                    .ybRow(horizontal: 0)
            }

            factsSection
            timelineSection
        }
        .ybPageList()
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
                YBHint(text: "还没有长期记忆。对话里说「老王是桥杆供应商」「我一般十点睡」这类话，它会记在这里。")
                    .ybRow(horizontal: 0)
            } else {
                ForEach(memory.facts.indices, id: \.self) { index in
                    let fact = memory.facts[index]
                    let last = index == memory.facts.count - 1
                    YBRow(title: fact.content,
                          subtitle: "\(fact.kind.label) · \(fact.updatedAt.formatted(date: .numeric, time: .omitted))",
                          icon: fact.kind.symbol,
                          position: position(index, memory.facts.count))
                        .swipeActions {
                            Button(role: .destructive) {
                                memory.delete(fact: fact)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .ybRow(bottom: last ? YBMetric.rowGap : 0)
                }
            }
        } header: {
            YBPinnedHeader("长期记忆（\(memory.facts.count)）")
        }
    }

    // MARK: - 每日流水

    @ViewBuilder
    private var timelineSection: some View {
        if memory.dayGroups.isEmpty {
            Section {
                YBHint(text: "还没有流水。对话里说「今天去厂里看了桥杆」，或者在速记页记一条，都会按天记在这里。")
                    .ybRow(horizontal: 0)
            } header: {
                YBPinnedHeader("每日流水")
            }
        } else {
            ForEach(memory.dayGroups) { group in
                Section {
                    ForEach(group.logs.indices, id: \.self) { index in
                        let log = group.logs[index]
                        YBRow(title: log.content,
                              subtitle: "\(log.kind.label) · \(log.at.formatted(date: .omitted, time: .shortened))",
                              icon: log.kind.symbol,
                              position: position(index, group.logs.count))
                            .swipeActions {
                                Button(role: .destructive) {
                                    memory.delete(log: log)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .ybRow(bottom: index == group.logs.count - 1 ? YBMetric.rowGap : 0)
                    }
                } header: {
                    YBPinnedHeader(group.title)
                }
            }
        }
    }

    private func position(_ index: Int, _ count: Int) -> YBRowPosition {
        if count <= 1 { return .only }
        if index == 0 { return .first }
        if index == count - 1 { return .last }
        return .middle
    }
}

#Preview {
    NavigationStack {
        MemoryView()
    }
}
