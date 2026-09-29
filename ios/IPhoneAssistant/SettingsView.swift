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
                    if !settings.preset.suggestedModels.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("常用模型").font(.footnote).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                ForEach(settings.preset.suggestedModels, id: \.self) { m in
                                    Button(m) { settings.model = m; settings.persist() }
                                        .font(.caption)
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                } header: {
                    Text("模型服务")
                } footer: {
                    Text(settings.preset.note)
                }

                Section {
                    LabeledContent("当前状态", value: settings.keyStatus)
                    SecureField("粘贴 API Key", text: $settings.apiKeyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存 API Key") { settings.saveAPIKey() }
                        .disabled(settings.apiKeyInput.isEmpty)
                    if settings.hasKey {
                        Button("清除「\(settings.preset.displayName)」的 Key", role: .destructive) {
                            settings.clearAPIKey()
                        }
                    }
                } header: {
                    Text("凭证")
                } footer: {
                    Text("Key 存在 Keychain 里，不写进任何配置文件，也不会随导出备份泄露。每个供应商单独存一份。")
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
                    Text("会真的向上面填的地址发一次请求。成功会打印模型的回复，失败会打印具体错误——包括服务端返回的原文，方便定位是地址错了还是 Key 不对。")
                }
            }
            .navigationTitle("设置")
            .onChange(of: settings.baseURL) { _, _ in settings.persist() }
            .onChange(of: settings.model) { _, _ in settings.persist() }
        }
    }
}

#Preview {
    SettingsView().environmentObject(SettingsStore())
}
