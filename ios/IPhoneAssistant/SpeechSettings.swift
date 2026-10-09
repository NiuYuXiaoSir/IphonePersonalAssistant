import Foundation
import SwiftUI

/// 语音识别用哪个引擎。
///
/// 为什么要有这个开关：系统自带的端上识别（`SFSpeechRecognizer`）不联网、隐私最好，
/// 但中文识别率确实一般，专业词、口音、快语速都容易错。第三方免费额度里的
/// Whisper / SenseVoice 那一类是整段上传、按整句上下文解码，准确率高一截。
/// 两种各有取舍，所以做成选项而不是替用户决定：
///   - 系统：不联网、不花钱、边说边出字，识别率一般
///   - 第三方：要联网、语音会上传到对方服务器、说完才出字，识别率明显更好
///
/// HIG 的 Privacy 页两条都点名了：「Process data on the device where possible」
/// 和「Be transparent about how your app collects and uses people's data」——
/// 所以默认留在系统端上，选了第三方就在设置页把「语音会上传」写在明处。
enum SpeechEngine: String, CaseIterable, Identifiable {
    case system
    case groq
    case siliconflow
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:      return "系统（端上，不联网）"
        case .groq:        return "Groq（免费额度）"
        case .siliconflow: return "硅基流动（免费额度）"
        case .custom:      return "自定义（OpenAI 兼容）"
        }
    }

    /// 默认地址。各家都走 OpenAI 那套 `/audio/transcriptions` 约定，
    /// 地址和模型名在设置页都能改——额度政策、模型名会变，别把猜测写死。
    var defaultBaseURL: String {
        switch self {
        case .system:      return ""
        case .groq:        return "https://api.groq.com/openai/v1"
        case .siliconflow: return "https://api.siliconflow.cn/v1"
        case .custom:      return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .system:      return ""
        case .groq:        return "whisper-large-v3-turbo"
        case .siliconflow: return "FunAudioLLM/SenseVoiceSmall"
        case .custom:      return ""
        }
    }

    var note: String {
        switch self {
        case .system:
            return "用 iOS 自带的识别，完全不出手机。边说边出字，但中文识别率一般——专业词和快语速容易错。"
        case .groq:
            return "走 OpenAI 兼容的 /audio/transcriptions，模型默认 whisper-large-v3-turbo（免费额度有速率限制）。地址和模型名可以改；第一次用之前点下面的「测试端点」，认一下密钥通不通。"
        case .siliconflow:
            return "硅基流动的音频转写接口，默认模型 FunAudioLLM/SenseVoiceSmall（中文场景好用，有免费额度）。地址和模型名可以改；先点「测试端点」确认密钥可用。"
        case .custom:
            return "任何兼容 /audio/transcriptions 的服务：填到 v1 那一层为止，再填模型名和密钥。"
        }
    }
}

/// 一次识别需要的参数（和 LLMConfig 一样，刻意不做 Codable：别让密钥被顺手写进磁盘）
struct SpeechConfig {
    var engine: SpeechEngine = .system
    var baseURL: String = ""
    var model: String = ""
    var apiKey: String = ""

    var isCloud: Bool { engine != .system }

    /// OpenAI 兼容的转写端点
    var transcriptionURL: URL? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty, s.lowercased().hasPrefix("http") else { return nil }
        return URL(string: s + "/audio/transcriptions")
    }
}

/// 语音识别的设置。做成单例是因为识别发生在非界面的地方
/// （实时听写、会议逐段转写），拿不到 SwiftUI 的 EnvironmentObject。
final class SpeechSettings: ObservableObject {

    static let shared = SpeechSettings()

    @Published var engine: SpeechEngine {
        didSet {
            UserDefaults.standard.set(engine.rawValue, forKey: Keys.engine)
            // 各家分开存：把上一家填的地址/模型记到它自己名下，
            // 再把这一家上次填的取回来（没填过就用那家的默认值）
            UserDefaults.standard.set(baseURL, forKey: Keys.baseURL(oldValue))
            UserDefaults.standard.set(model, forKey: Keys.model(oldValue))
            baseURL = UserDefaults.standard.string(forKey: Keys.baseURL(engine)) ?? engine.defaultBaseURL
            model = UserDefaults.standard.string(forKey: Keys.model(engine)) ?? engine.defaultModel
            testResult = ""
            refreshKeyStatus()
        }
    }
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Keys.baseURL(engine)) }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Keys.model(engine)) }
    }

    @Published var apiKeyInput: String = ""
    @Published var keyStatus: String = "未保存"
    @Published var hasKey: Bool = false
    @Published var testResult: String = ""
    @Published var isTesting: Bool = false

    private enum Keys {
        static let engine = "speech.engine"
        static func baseURL(_ engine: SpeechEngine) -> String { "speech.baseURL.\(engine.rawValue)" }
        static func model(_ engine: SpeechEngine) -> String { "speech.model.\(engine.rawValue)" }
    }

    private init() {
        let saved = SpeechEngine(rawValue: UserDefaults.standard.string(forKey: Keys.engine) ?? "") ?? .system
        engine = saved
        // didSet 在 init 里不会触发，所以这里手动取一次（元素初始化前不能用 didSet）
        baseURL = UserDefaults.standard.string(forKey: Keys.baseURL(saved)) ?? saved.defaultBaseURL
        model = UserDefaults.standard.string(forKey: Keys.model(saved)) ?? saved.defaultModel
        refreshKeyStatus()
    }

    // MARK: - 凭证

    private static func keyAccount(for engine: SpeechEngine) -> String {
        "speechkey.\(engine.rawValue)"
    }

    func refreshKeyStatus() {
        let key = KeychainStore.load(for: Self.keyAccount(for: engine))
        hasKey = !(key ?? "").isEmpty
        keyStatus = hasKey ? "已保存（\((key ?? "").count) 位）" : "未保存"
    }

    func saveAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            testResult = "密钥不能为空"
            return
        }
        if KeychainStore.save(trimmed, for: Self.keyAccount(for: engine)) {
            apiKeyInput = ""
            refreshKeyStatus()
            testResult = "已把「\(engine.displayName)」的密钥存进系统钥匙串"
        } else {
            testResult = "写入系统钥匙串失败"
        }
    }

    func clearAPIKey() {
        KeychainStore.delete(for: Self.keyAccount(for: engine))
        refreshKeyStatus()
        testResult = "已清除「\(engine.displayName)」的密钥"
    }

    func makeConfig() -> SpeechConfig {
        SpeechConfig(engine: engine,
                     baseURL: baseURL,
                     model: model,
                     apiKey: KeychainStore.load(for: Self.keyAccount(for: engine)) ?? "")
    }

    // MARK: - 测试端点

    /// 传一段 0.4 秒的静音 WAV 过去，看服务端认不认这个地址、模型和密钥。
    /// 用静音而不是真录音：不需要麦克风权限，也不占时间，但足以验证
    /// 「地址对不对、密钥通不通、模型名存不存在」这三件事。
    func testEndpoint() {
        let config = makeConfig()
        guard config.isCloud else {
            testResult = "当前用的是系统端上识别，不需要端点。要接第三方就把上面的引擎换掉。"
            return
        }
        guard config.transcriptionURL != nil else {
            testResult = "接口地址无效：\(baseURL)"
            return
        }
        guard !config.apiKey.isEmpty else {
            testResult = "还没有保存「\(engine.displayName)」的密钥，先在下面填一条"
            return
        }
        isTesting = true
        testResult = "正在把一段静音传给 \(config.transcriptionURL?.absoluteString ?? "") …"

        Task {
            do {
                let text = try await CloudSpeechService.selfTest(config: config)
                await MainActor.run {
                    self.isTesting = false
                    self.testResult = """
                    ✅ 端点和密钥都能用
                    模型：\(config.model)
                    返回：（静音，识别结果为空是正常的）「\(text.isEmpty ? "空" : text)」
                    """
                }
            } catch {
                await MainActor.run {
                    self.isTesting = false
                    self.testResult = "❌ 失败\n\(error.localizedDescription)"
                }
            }
        }
    }
}
