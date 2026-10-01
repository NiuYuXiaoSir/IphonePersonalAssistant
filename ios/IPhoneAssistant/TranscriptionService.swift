import Foundation
import Speech

enum TranscriptionError: LocalizedError {
    case notAuthorized(String)
    case noRecognizer
    case onDeviceUnsupported
    case failed(String)
    case timeout(Double)

    var errorDescription: String? {
        switch self {
        case .notAuthorized(let s):
            return "语音识别未授权（当前状态：\(s)）。去 设置 → 隐私与安全性 → 语音识别 里打开。"
        case .noRecognizer:
            return "系统拿不到中文（zh-CN）识别器"
        case .onDeviceUnsupported:
            return "这台设备不支持中文端上识别。关掉「只用端上识别」改用联网识别试试。"
        case .failed(let s):
            return "识别失败：\(s)"
        case .timeout(let s):
            return "单段识别超过 \(Int(s)) 秒未返回，已放弃这一段"
        }
    }
}

/// 语音转写。
///
/// 关键设计：**以录音段为单位逐段转写**，而不是把整场会议当做一个长音频。
/// 这正好利用了分段录制的结构：每段都是 60 秒的独立文件，
/// 不会碰到端上识别对单次时长的限制，而且某一段失败不影响其他段。
///
/// 另一个关键：每段结果由调用方立即写回存储，不是全部跑完再存。
/// 一小时会议有 60 段，跑到第 50 段失败也不会白干。
enum TranscriptionService {

    /// 单段识别的硬超时。没有它的话，一旦回调不返回，界面会永远挂在“转写中”。
    static let perSegmentTimeout: Double = 120

    static func authorizationStatus() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    static func statusText(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "未询问"
        case .denied:        return "已拒绝"
        case .restricted:    return "受系统限制"
        case .authorized:    return "已授权"
        @unknown default:    return "未知(\(status.rawValue))"
        }
    }

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                AppLog.info("ASR", "语音识别授权结果：\(statusText(status))")
                cont.resume(returning: status)
            }
        }
    }

    /// 这台设备能不能做中文端上识别
    static func supportsOnDevice() -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))?.supportsOnDeviceRecognition ?? false
    }

    /// 转写单个音频文件
    static func recognize(url: URL, onDevice: Bool) async throws -> String {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else {
            throw TranscriptionError.notAuthorized(statusText(status))
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) else {
            throw TranscriptionError.noRecognizer
        }
        guard recognizer.isAvailable else {
            throw TranscriptionError.failed("识别器当前不可用（系统忙或需要网络）")
        }
        if onDevice && !recognizer.supportsOnDeviceRecognition {
            throw TranscriptionError.onDeviceUnsupported
        }

        AppLog.info("ASR", "开始识别 \(url.lastPathComponent)，端上=\(onDevice)，时长文件=\(String(format: "%.1f", MeetingStore.fileDuration(url))) 秒")

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await recognizeWithoutTimeout(recognizer: recognizer, url: url, onDevice: onDevice)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(perSegmentTimeout * 1_000_000_000))
                throw TranscriptionError.timeout(perSegmentTimeout)
            }
            guard let first = try await group.next() else {
                throw TranscriptionError.failed("任务组意外为空")
            }
            group.cancelAll()
            return first
        }
    }

    private static func recognizeWithoutTimeout(recognizer: SFSpeechRecognizer,
                                                url: URL,
                                                onDevice: Bool) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = onDevice
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            var settled = false

            // recognizer 必须在识别期间活着，所以在闭包里引用一次
            let task = recognizer.recognitionTask(with: request) { result, error in
                guard !settled else { return }
                _ = recognizer

                if let error {
                    settled = true
                    AppLog.error("ASR", "\(url.lastPathComponent) 失败：\(error.localizedDescription)")
                    cont.resume(throwing: TranscriptionError.failed(error.localizedDescription))
                    return
                }
                guard let result else { return }
                if result.isFinal {
                    settled = true
                    let text = result.bestTranscription.formattedString
                    if text.isEmpty {
                        // 0 字要能事后判断原因：64kbps 单声道下 1 秒约 8KB，
                        // 一个 60 秒的段只有几十 KB，就说明那一段本来就没有声音，
                        // 不是识别出了问题。体积带上，日志里才看得出来。
                        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                        let bytes = (attrs?[.size] as? Int) ?? 0
                        AppLog.warn("ASR", "\(url.lastPathComponent) 完成，0 字（文件 \(bytes) 字节）")
                    } else {
                        AppLog.info("ASR", "\(url.lastPathComponent) 完成，\(text.count) 字")
                    }
                    cont.resume(returning: text)
                }
            }
            _ = task
        }
    }
}
