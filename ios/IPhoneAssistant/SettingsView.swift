import SwiftUI

/// 设置页。
///
/// 版式照元宝的设置页：居中的窄标题 + 一张张分组卡片，
/// 能点的行是蓝字，危险动作是红字，说明一律放在分组下面那行灰字里。
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var balance = BalanceStore.shared

    var body: some View {
        NavigationStack {
            Form {
                serviceSection
                balanceSection
                credentialSection
                testSection
            }
            .scrollContentBackground(.hidden)
            .background(YBColor.bg)
            .listRowBackground(YBColor.surface)
            .navigationTitle("设置")
            .onAppear { balance.refreshIfStale(settings: settings, maxAge: 30) }
        }
    }

    // MARK: - 余额 / 用量

    private var balanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: balance.chipIcon)
                        .font(.system(size: 15))
                        .foregroundStyle(YBColor.textSecondary)
                    Text(balance.report?.headline ?? "还没查到")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(balance.isLow ? YBColor.warning : Color.primary)
                }
                if let detail = balance.report?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !balance.message.isEmpty {
                    Text(balance.message)
                        .font(.caption2)
                        .foregroundStyle(balance.report == nil ? YBColor.warning : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)

            Button {
                balance.refresh(settings: settings)
            } label: {
                Text(balance.isRefreshing ? "查询中…" : "刷新余额")
                    .foregroundStyle(balance.isRefreshing ? YBColor.textTertiary : YBColor.accent)
            }
            .disabled(balance.isRefreshing)
        } header: {
            Text("余额与用量")
        } footer: {
            Text("DeepSeek 官方查 /user/balance（金额 + 赠送），OpenCode Go 查 /zen/go/v1/usage（5 小时 / 本周 / 本月三个窗口的用量）。打开会产生 token 的页面时会自动查一次，两分钟内不重复请求；用完一次模型之后再查一次，所以数字跟着花费走。请求只发给你自己填的那个地址，密钥不写进日志。")
        }
    }

    // MARK: - 模型服务

    private var serviceSection: some View {
        Section {
            Picker("供应商", selection: $settings.preset) {
                ForEach(LLMProviderPreset.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            TextField("接口地址", text: $settings.baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("模型名", text: $settings.model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("可选模型")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(settings.isFetchingModels ? "拉取中…" : "拉取模型列表") {
                        settings.fetchModels()
                    }
                    .font(.footnote)
                    .disabled(settings.isFetchingModels)
                }
                modelChips
                if !settings.modelListResult.isEmpty {
                    Text(settings.modelListResult)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("模型服务")
        } footer: {
            Text(settings.preset.note)
        }
    }

    /// 优先显示服务端实际给的模型；没拉过就显示预设里那几个常见的
    private var modelChips: some View {
        let models = settings.availableModels.isEmpty ? settings.preset.suggestedModels : settings.availableModels
        return Group {
            if models.isEmpty {
                Text("点「拉取模型列表」看看这个服务有哪些模型，再填到上面。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(models, id: \.self) { name in
                            modelChip(name)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func modelChip(_ name: String) -> some View {
        let selected = settings.model == name
        return Button {
            settings.model = name
            settings.persist()
        } label: {
            Text(name)
                .font(.system(size: 13))
                .foregroundStyle(selected ? YBColor.accent : Color.primary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(selected ? YBColor.accent.opacity(0.16) : YBColor.surfaceHi,
                            in: Capsule())
        }
        .buttonStyle(YBPressStyle())
    }

    // MARK: - 凭证

    private var credentialSection: some View {
        Section {
            LabeledContent("当前状态", value: settings.keyStatus)

            SecureField("粘贴密钥", text: $settings.apiKeyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                settings.saveAPIKey()
            } label: {
                Text("保存密钥")
                    .foregroundStyle(settings.apiKeyInput.isEmpty ? YBColor.textTertiary : YBColor.accent)
            }
            .disabled(settings.apiKeyInput.isEmpty)

            if settings.hasKey {
                Button(role: .destructive) {
                    settings.clearAPIKey()
                } label: {
                    Text("清除「\(settings.preset.displayName)」的密钥")
                        .foregroundStyle(YBColor.danger)
                }
            }
        } header: {
            Text("凭证")
        } footer: {
            Text("密钥存在系统的钥匙串里，不写进任何配置文件，也不会随导出备份泄露。每个供应商单独存一份。")
        }
    }

    // MARK: - 连接测试

    private var testSection: some View {
        Section {
            Button {
                settings.testConnection()
            } label: {
                Text(settings.isTesting ? "测试中…" : "测试连接")
                    .foregroundStyle(settings.isTesting ? YBColor.textTertiary : YBColor.accent)
            }
            .disabled(settings.isTesting)

            if !settings.testResult.isEmpty {
                Text(settings.testResult)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        } header: {
            Text("连接测试")
        } footer: {
            Text("会真的向上面填的地址发一次请求。成功会显示模型的回复，失败会显示具体错误——包括服务端返回的原文，方便判断是地址填错了还是密钥不对。")
        }
    }
}

#Preview {
    SettingsView().environmentObject(SettingsStore())
}
