import Foundation
import UIKit
import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers

/// 一条附件的元信息。图片和视频共用一种结构，差别在 `kind` 和后面那三个字段。
///
/// 它随消息一起存进数据库（`chat_entries` 的 payload），另外 `media` 表里也有一行——
/// 表那一行是给「占了多少空间」「哪些文件是孤儿」这类查询用的，消息按文件名找文件。
struct ChatMedia: Codable, Equatable, Identifiable {

    enum Kind: String, Codable {
        case image
        case video
    }

    var id: String = UUID().uuidString
    var kind: Kind = .image
    /// chatMedia/ 下的文件名（老版本的图片在 chatImages/ 下，靠 `isLegacy` 区分）
    var fileName: String = ""
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    /// 视频时长，图片是 0
    var durationSeconds: Double = 0
    var bytes: Int = 0
    /// 上一版存的图片（在 chatImages/ 里），只读不改
    var isLegacy: Bool = false

    var isVideo: Bool { kind == .video }

    /// 「12 秒」这种时长文案
    var durationText: String {
        let total = Int(durationSeconds.rounded())
        if total < 60 { return "\(total) 秒" }
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, fileName, pixelWidth, pixelHeight, durationSeconds, bytes, isLegacy
    }

    init(id: String = UUID().uuidString,
         kind: Kind = .image,
         fileName: String = "",
         pixelWidth: Int = 0,
         pixelHeight: Int = 0,
         durationSeconds: Double = 0,
         bytes: Int = 0,
         isLegacy: Bool = false) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
        self.bytes = bytes
        self.isLegacy = isLegacy
    }

    /// 手写解码：以后加字段时旧消息还得能读出来（和 ChatEntry 一个理由）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        kind = Kind(rawValue: (try? c.decode(String.self, forKey: .kind)) ?? "") ?? .image
        fileName = (try? c.decode(String.self, forKey: .fileName)) ?? ""
        pixelWidth = (try? c.decode(Int.self, forKey: .pixelWidth)) ?? 0
        pixelHeight = (try? c.decode(Int.self, forKey: .pixelHeight)) ?? 0
        durationSeconds = (try? c.decode(Double.self, forKey: .durationSeconds)) ?? 0
        bytes = (try? c.decode(Int.self, forKey: .bytes)) ?? 0
        isLegacy = (try? c.decode(Bool.self, forKey: .isLegacy)) ?? false
    }
}

/// 附件的落盘与读回。
///
/// 文件放 `Documents/chatMedia/`（老版本拍的照在 `chatImages/`，只读不改），
/// 数据库里 `media` 表记一行。为什么文件不塞进数据库：视频动辄几十上百 MB，
/// SQLite 里放 BLOB 会让整个库膨胀、备份和迁移都变重；而「谁引用它」这件事，
/// 消息体里已经记了。表里那一行是索引和账本。
enum MediaLibrary {

    static func directory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("chatMedia", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 老版本的图片目录
    static func legacyDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("chatImages", isDirectory: true)
    }

    static func url(for media: ChatMedia) -> URL {
        (media.isLegacy ? legacyDirectory() : directory()).appendingPathComponent(media.fileName)
    }

    /// 存一张图片。压缩在调用方做（`compressedForLLM`），这里只管落盘。
    static func saveImage(_ data: Data, size: CGSize) -> ChatMedia? {
        let name = UUID().uuidString + ".jpg"
        do {
            try data.write(to: directory().appendingPathComponent(name), options: .atomic)
            return ChatMedia(kind: .image,
                             fileName: name,
                             pixelWidth: Int(size.width.rounded()),
                             pixelHeight: Int(size.height.rounded()),
                             bytes: data.count)
        } catch {
            AppLog.error("Media", "保存图片失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 存一段视频：从临时文件拷进来（系统给的是临时文件，随时可能被清掉）
    static func saveVideo(from source: URL, duration: Double, size: CGSize) -> ChatMedia? {
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let name = UUID().uuidString + "." + ext
        let target = directory().appendingPathComponent(name)
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
            AppLog.info("Media", "存入视频 \(name)，\(String(format: "%.1f", duration)) 秒，\(bytes / 1024) KB")
            return ChatMedia(kind: .video,
                             fileName: name,
                             pixelWidth: Int(size.width.rounded()),
                             pixelHeight: Int(size.height.rounded()),
                             durationSeconds: duration,
                             bytes: bytes)
        } catch {
            AppLog.error("Media", "保存视频失败：\(error.localizedDescription)")
            return nil
        }
    }

    static func delete(_ media: ChatMedia) {
        guard !media.isLegacy else { return }
        try? FileManager.default.removeItem(at: url(for: media))
    }

    /// 磁盘占用（给诊断页用）
    static func storageBytes() -> (files: Int, bytes: Int) {
        var files = 0
        var bytes = 0
        for dir in [directory(), legacyDirectory()] {
            let list = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                    includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for file in list {
                files += 1
                bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return (files, bytes)
    }
}

/// 相册里选出来的视频。
///
/// 不用 `loadTransferable(type: Data.self)`：那会把整段视频读进内存（几十上百 MB），
/// 而 FileRepresentation 让系统拷一个临时文件给我们，拷完直接用。
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedMovie(url: target)
        }
    }
}

/// 视频里的画面。
///
/// 网关只吃图片，视频没法直接发。所以抽几帧当画面送给模型——
/// 拍白板、扫码、看合同这种「本来就是拍个画面」的场景，抽帧和整段视频给它的信息差不多。
enum VideoFrames {

    /// 抽 `count` 帧。位置取 10% / 35% / 60% / 85%：
    /// 开头常有黑场或对焦过程，结尾常是手一抖的画面，中间四帧信息最密。
    static func extract(from url: URL, count: Int = 4) async -> [Data] {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let seconds = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        guard seconds > 0.2 else { return [] }

        var frames: [Data] = []
        for fraction in [0.1, 0.35, 0.6, 0.85].prefix(count) {
            let time = CMTime(seconds: seconds * fraction, preferredTimescale: 600)
            guard let result = try? await generator.image(at: time) else { continue }
            if let data = UIImage(cgImage: result.image).compressedForLLM(maxSide: 1024, quality: 0.6) {
                frames.append(data)
            }
        }
        AppLog.info("Media", "从视频里抽了 \(frames.count) 帧送给模型")
        return frames
    }
}
