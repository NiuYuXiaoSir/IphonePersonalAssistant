import SwiftUI
import UIKit

/// 设置页。
///
/// 用系统 Form：分组卡片、行、页脚说明全是系统给的，不再自己画。
/// 唯一自己定的是品牌蓝（`Assets.xcassets/AccentColor`），通过 `.tint` 全局生效，
/// 页面里不写任何颜色值——深浅色、增强对比度都由系统负责。
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var balance = BalanceStore.shared
    @ObservedObject private var speech = SpeechSettings.shared

    var body: some View {
        NavigationStack {
            Form {
                serviceSection
                balanceSection
                credentialSection
                testSection
                speechSection
                systemSection
                interfaceSection
                advancedSection
            }
            // 这一页有三个输入框（地址、模型名、密钥），往下滑一下收掉，
            // 右上角也给一个明确的按钮
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { hideKeyboard() }
                }
            }
            .navigationTitle("设置")
            .onAppear { balance.refreshIfStale(settings: settings, maxAge: 30) }
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
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
                        .font(.caption)
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
                    .font(.caption)
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
        return Button(name) {
            settings.model = name
            settings.persist()
        }
        .font(.footnote)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(selected ? Color.accentColor : Color.secondary)
    }

    // MARK: - 余额 / 用量

    private var balanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: balance.isLow ? "exclamationmark.triangle.fill" : balance.chipIcon)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(balance.report?.headline ?? "还没查到")
                        .font(.headline)
                        .foregroundStyle(balance.isLow ? Color.orange : Color.primary)
                }
                if let detail = balance.report?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !balance.message.isEmpty {
                    Text(balance.message)
                        .font(.caption)
                        .foregroundStyle(balance.report == nil ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)

            Button(balance.isRefreshing ? "查询中…" : "刷新余额") {
                balance.refresh(settings: settings)
            }
            .disabled(balance.isRefreshing)
        } header: {
            Text("余额与用量")
        } footer: {
            Text("DeepSeek 官方查 /user/balance（金额 + 赠送），OpenCode Go 查 /zen/go/v1/usage（5 小时 / 本周 / 本月三个窗口的用量）。打开会产生 token 的页面时会自动查一次，两分钟内不重复请求；用完一次模型之后再查一次，所以数字跟着花费走。请求只发给你自己填的那个地址，密钥不写进日志。")
        }
    }

    // MARK: - 凭证

    private var credentialSection: some View {
        Section {
            LabeledContent("当前状态", value: settings.keyStatus)

            SecureField("粘贴密钥", text: $settings.apiKeyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button("保存密钥") {
                settings.saveAPIKey()
            }
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
    }

    // MARK: - 连接测试

    private var testSection: some View {
        Section {
            Button(settings.isTesting ? "测试中…" : "测试连接") {
                settings.testConnection()
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

    // MARK: - 语音识别

    /// 语音识别单独一张卡：它和对话用的模型是两个服务、两份密钥，
    /// 混在一起填很容易把某家的 key 填到另一家上。
    private var speechSection: some View {
        Section {
            Picker("引擎", selection: $speech.engine) {
                ForEach(SpeechEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }

            if speech.engine != .system {
                TextField("接口地址", text: $speech.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("模型名", text: $speech.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                LabeledContent("密钥", value: speech.keyStatus)
                SecureField("粘贴语音识别的密钥", text: $speech.apiKeyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存密钥") { speech.saveAPIKey() }
                    .disabled(speech.apiKeyInput.isEmpty)
                if speech.hasKey {
                    Button("清除密钥", role: .destructive) { speech.clearAPIKey() }
                }

                Button(speech.isTesting ? "测试中…" : "测试端点") { speech.testEndpoint() }
                    .disabled(speech.isTesting)

                if !speech.testResult.isEmpty {
                    Text(speech.testResult)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("语音识别")
        } footer: {
            Text(speechFooter)
        }
    }

    private var speechFooter: String {
        if speech.engine == .system {
            return speech.engine.note + " 想识别得更准，把引擎换成第三方（会把手里的语音上传到对方服务器）——这一步由你选，默认不出手机。"
        }
        return speech.engine.note + "\n注意：选了第三方，听写和会议转写的语音都会上传到上面这个地址。密钥存在系统钥匙串里，不写进日志。"
    }

    // MARK: - 系统设置

    /// 权限被拒之后，唯一能改的地方在系统的设置里，从 App 里给个直达入口
    private var systemSection: some View {
        Section {
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            } label: {
                Label("打开系统设置", systemImage: "gear")
            }
        } header: {
            Text("权限")
        } footer: {
            Text("麦克风、语音识别、相机、通知的开关都在系统设置里。这些权限都是用到的时候才申请，拒绝了也能随时在这里改回来。App 不读写系统里的日历和提醒事项——那些数据在本机数据库里。")
        }
    }
    // MARK: - 界面

    private var interfaceSection: some View {
        Section {
            Toggle("触觉反馈", isOn: $settings.hapticsEnabled)
        } header: {
            Text("界面")
        } footer: {
            Text("开始和结束录音、打标记、写入系统成功、删除时会有一点点振动。录音过程中只用最轻的一档，免得连续振动干扰麦克风。")
        }
    }

    // MARK: - 高级

    /// 诊断原本占一个页签，那是拿开发者的便利换日常的眼球——收进这里，功能一个不少。
    private var advancedSection: some View {
        Section {
            NavigationLink {
                DiagnosticsView()
            } label: {
                Label("诊断与日志", systemImage: "stethoscope")
            }
        } header: {
            Text("高级")
        } footer: {
            Text("探针、权限与签名信息、运行日志、数据占用。装机链路出问题时先看这里——免费签名 7 天要重装一次，装机相关的现象都在这一页验证。")
        }
    }
}

#Preview {
    SettingsView().environmentObject(SettingsStore())
}
