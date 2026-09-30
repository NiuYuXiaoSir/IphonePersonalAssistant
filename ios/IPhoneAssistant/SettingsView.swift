import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        NavigationStack {
            Form {
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

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("可选模型")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(settings.isFetchingModels ? "拉取中…" : "拉取模型列表") {
                                settings.fetchModels()
                            }
                            .font(.caption)
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

                Section {
                    LabeledContent("当前状态", value: settings.keyStatus)
                    SecureField("粘贴密钥", text: $settings.apiKeyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存密钥") { settings.saveAPIKey() }
                        .disabled(settings.apiKeyInput.isEmpty)
                    if settings.hasKey {
                        Button("清除「\(settings.preset.displayName)」的密钥", role: .destructive) {
                            settings.clearAPIKey()
                        }
                    }
                } header: {
                    Text("凭证")
                } footer: {
                    Text("密钥存在系统的钥匙串里，不写进任何配置文件，也不会随导出备份泄露。每个供应商单独存一份。")
                }

                Section {
                    Button(settings.isTesting ? "测试中…" : "测试连接") { settings.testConnection() }
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
            .navigationTitle("设置")
            .onChange(of: settings.baseURL) { _, _ in settings.persist() }
            .onChange(of: settings.model) { _, _ in settings.persist() }
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
                            Button(name) {
                                settings.model = name
                                settings.persist()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .tint(settings.model == name ? Color.accentColor : Color.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

#Preview {
    SettingsView().environmentObject(SettingsStore())
}
