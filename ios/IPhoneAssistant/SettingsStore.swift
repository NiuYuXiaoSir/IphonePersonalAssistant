import SwiftUI

/// 设置与凭证。API Key 存 Keychain，其余偏好存 UserDefaults。
final class SettingsStore: ObservableObject {

    @Published var preset: LLMProviderPreset {
        didSet { presetChanged() }
    }
    @Published var baseURL: String
    @Published var model: String
    @Published var apiKeyInput: String = ""
    @Published var hasKey: Bool = false
    @Published var keyStatus: String = "未保存"
    @Published var testResult: String = ""
    @Published var isTesting: Bool = false
    /// 从服务端拉回来的模型清单，点一下就能选中
    @Published var availableModels: [String] = []
    @Published var isFetchingModels: Bool = false
    @Published var modelListResult: String = ""

    private enum Keys {
        static let preset = "llm.preset"
        static let baseURL = "llm.baseURL"
        static let model = "llm.model"
    }

    init() {
        let saved = LLMProviderPreset(rawValue: UserDefaults.standard.string(forKey: Keys.preset) ?? "") ?? .deepseek
        preset = saved
        baseURL = UserDefaults.standard.string(forKey: Keys.baseURL) ?? saved.defaultBaseURL
        model = UserDefaults.standard.string(forKey: Keys.model) ?? saved.defaultModel
        refreshKeyStatus()
    }

    // MARK: - 供应商

    private func presetChanged() {
        baseURL = preset.defaultBaseURL
        model = preset.defaultModel
        testResult = ""
        availableModels = []
        modelListResult = ""
        refreshKeyStatus()
        persist()
    }

    func persist() {
        UserDefaults.standard.set(preset.rawValue, forKey: Keys.preset)
        UserDefaults.standard.set(baseURL, forKey: Keys.baseURL)
        UserDefaults.standard.set(model, forKey: Keys.model)
    }

    // MARK: - 凭证

    /// 每个供应商单独存一份 Key——DeepSeek 和 OpenCode 的 Key 不是同一个
    private static func keyAccount(for preset: LLMProviderPreset) -> String {
        "apikey.\(preset.rawValue)"
    }

    func refreshKeyStatus() {
        if let k = KeychainStore.load(for: Self.keyAccount(for: preset)), !k.isEmpty {
            hasKey = true
            keyStatus = "已保存（\(k.count) 位）"
        } else {
            hasKey = false
            keyStatus = "未保存"
        }
    }

    func saveAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            testResult = "密钥不能为空"
            return
        }
        if KeychainStore.save(trimmed, for: Self.keyAccount(for: preset)) {
            apiKeyInput = ""
            refreshKeyStatus()
            testResult = "已把「\(preset.displayName)」的密钥存进系统钥匙串"
        } else {
            testResult = "写入系统钥匙串失败"
        }
    }

    func clearAPIKey() {
        KeychainStore.delete(for: Self.keyAccount(for: preset))
        refreshKeyStatus()
        testResult = "已清除「\(preset.displayName)」的密钥"
    }

    func makeConfig() -> LLMConfig {
        LLMConfig(
            presetID: preset.rawValue,
            baseURL: baseURL,
            model: model,
            apiKey: KeychainStore.load(for: Self.keyAccount(for: preset)) ?? ""
        )
    }

    // MARK: - 拉取模型列表

    /// 订阅套餐里的模型名经常变，与其猜不如问服务端要一份
    func fetchModels() {
        persist()
        let config = makeConfig()
        guard config.modelsURL != nil else {
            modelListResult = "接口地址无效：\(baseURL)"
            return
        }
        guard !config.apiKey.isEmpty else {
            modelListResult = "还没有保存「\(preset.displayName)」的密钥，先在下面填一条"
            return
        }

        isFetchingModels = true
        modelListResult = "正在拉取…"

        Task {
            do {
                let models = try await OpenAICompatibleClient.listModels(config: config)
                await MainActor.run {
                    self.isFetchingModels = false
                    self.availableModels = models
                    self.modelListResult = "服务端返回 \(models.count) 个模型，点名字就能选中"
                }
            } catch {
                await MainActor.run {
                    self.isFetchingModels = false
                    self.modelListResult = "拉取失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 连接测试

    func testConnection() {
        persist()
        let config = makeConfig()
        guard let url = config.chatCompletionsURL else {
            testResult = "接口地址无效：\(baseURL)"
            return
        }
        guard !config.apiKey.isEmpty else {
            testResult = "还没有保存「\(preset.displayName)」的密钥"
            return
        }

        isTesting = true
        testResult = "正在请求 \(url.absoluteString) …"

        Task {
            let started = Date()
            do {
                let client = OpenAICompatibleClient(config: config)
                let reply = try await client.chat([
                    .system("你是连通性测试用的助手，只回一句话。"),
                    .user("用一句话说明你是什么模型。")
                ], jsonMode: false)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                await MainActor.run {
                    self.isTesting = false
                    self.testResult = """
                    ✅ 连接成功（耗时 \(ms) 毫秒）
                    模型：\(config.model)
                    回复：\(reply)
                    """
                }
            } catch {
                await MainActor.run {
                    self.isTesting = false
                    self.testResult = "❌ 连接失败\n\(error.localizedDescription)"
                }
            }
        }
    }
}
