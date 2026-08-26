import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

nonisolated struct SafeDecodedImage: @unchecked Sendable {
    let image: UIImage
    let pixelWidth: Int
    let pixelHeight: Int
}

nonisolated struct PreparedPhotoUpload: Sendable {
    let data: Data
    let thumbnail: Data?
    let pixelWidth: Int
    let pixelHeight: Int
    let contentType: String
    let filenameExtension: String
}

nonisolated struct DetectedVideoContainer: Equatable, Sendable {
    let contentType: String
    let filenameExtension: String
}

enum SafeMediaVideoInspector {
    nonisolated static func container(for data: Data) -> DetectedVideoContainer? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes[0...3].elementsEqual([0x1a, 0x45, 0xdf, 0xa3]) {
            return DetectedVideoContainer(contentType: "video/webm", filenameExtension: "webm")
        }
        guard bytes[4...7].elementsEqual([0x66, 0x74, 0x79, 0x70]) else { return nil }
        let brand = String(bytes: bytes[8...11], encoding: .ascii)
        if brand == "qt  " {
            return DetectedVideoContainer(contentType: "video/quicktime", filenameExtension: "mov")
        }
        return DetectedVideoContainer(contentType: "video/mp4", filenameExtension: "mp4")
    }
}

enum SafeMediaFileMetadata {
    nonisolated static func sanitizedFileName(_ rawValue: String) -> String? {
        let normalized = rawValue.replacingOccurrences(of: "\\", with: "/")
        guard let leaf = normalized.split(separator: "/").last.map(String.init) else { return nil }
        let trimmed = leaf.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lengthOfBytes(using: .utf8) <= 255,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }
}

enum SafeMediaImageDecoder {
    nonisolated private static let maxDimension = 8_192
    nonisolated private static let maxPixels = 40_000_000

    nonisolated static func decode(_ data: Data, maxPixelSize: Int) -> SafeDecodedImage? {
        guard !data.isEmpty, maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= maxDimension, height <= maxDimension,
              Int64(width) * Int64(height) <= Int64(maxPixels)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, maxDimension),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return SafeDecodedImage(image: UIImage(cgImage: cgImage), pixelWidth: width, pixelHeight: height)
    }

    nonisolated static func preparePhotoUpload(_ data: Data) -> PreparedPhotoUpload? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            CGImageSourceGetType(source) != nil,
            let decoded = decode(data, maxPixelSize: 2_560),
            let cgImage = decoded.image.cgImage
        else { return nil }
        let image = UIImage(cgImage: cgImage)
        var encoded: Data?
        for quality in [0.86, 0.78, 0.68] {
            guard let candidate = image.jpegData(compressionQuality: quality) else { continue }
            encoded = candidate
            if candidate.count <= 3 * 1024 * 1024 { break }
        }
        guard let encoded, !encoded.isEmpty else { return nil }
        return PreparedPhotoUpload(
            data: encoded,
            thumbnail: thumbnailData(image),
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            contentType: "image/jpeg",
            filenameExtension: "jpg"
        )
    }

    nonisolated static func prepareProfilePhotoUpload(_ data: Data) -> PreparedPhotoUpload? {
        guard let decoded = decode(data, maxPixelSize: 1_024), let cgImage = decoded.image.cgImage else {
            return nil
        }
        let image = UIImage(cgImage: cgImage)
        var encoded: Data?
        for quality in [0.86, 0.76, 0.64, 0.52] {
            guard let candidate = image.jpegData(compressionQuality: quality) else { continue }
            encoded = candidate
            if candidate.count <= 3 * 1024 * 1024 { break }
        }
        guard let encoded, !encoded.isEmpty, encoded.count <= 3 * 1024 * 1024,
              cgImage.width <= 1_024, cgImage.height <= 1_024
        else { return nil }
        return PreparedPhotoUpload(
            data: encoded,
            thumbnail: thumbnailData(image),
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            contentType: "image/jpeg",
            filenameExtension: "jpg"
        )
    }

    nonisolated static func thumbnailData(_ image: UIImage) -> Data? {
        for dimension in [640.0, 480.0, 320.0] {
            guard let resized = image.preparingThumbnail(
                of: CGSize(width: dimension, height: dimension)
            ) else { continue }
            for quality in [0.72, 0.55, 0.4] {
                if let data = resized.jpegData(compressionQuality: quality), data.count <= 256 * 1024 {
                    return data
                }
            }
        }
        return nil
    }
}

nonisolated struct CloudMedia: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let kind: String
    let contentType: String
    let fileName: String?
    let byteSize: Int64
    let durationMs: Int64?
    let width: Int?
    let height: Int?
    let hasThumbnail: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind
        case contentType = "content_type"
        case fileName = "file_name"
        case byteSize = "byte_size"
        case durationMs = "duration_ms"
        case width, height
        case hasThumbnail = "has_thumbnail"
    }

    var displayName: String {
        if let fileName { return fileName }
        switch kind {
        case "photo": return String(localized: "Photo")
        case "video": return String(localized: "Video")
        case "voice": return String(localized: "Voice message")
        default: return String(localized: "File")
        }
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    var formattedDuration: String? {
        guard let durationMs else { return nil }
        let seconds = max(0, durationMs / 1_000)
        return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
    }
}

nonisolated struct MediaUploadCreation: Codable, Sendable {
    nonisolated struct Quota: Codable, Sendable {
        let usedBytes: Int64
        let limitBytes: Int64
    }

    let mediaId: String
    let uploadOffset: Int64
    let chunkSize: Int
    let expiresAt: String
    let quota: Quota
    let uploadProtocol: String?
    let partSize: Int?
    let totalParts: Int?
    let receivedParts: [Int]?
}

nonisolated struct MediaUploadState: Codable, Sendable {
    let mediaId: String
    let uploadOffset: Int64
    let byteSize: Int64
    let status: String
    let expiresAt: String
    let chunkSize: Int
    let uploadProtocol: String?
    let partSize: Int?
    let totalParts: Int?
    let receivedParts: [Int]?
}

nonisolated struct MediaChunkResponse: Codable, Sendable {
    let mediaId: String
    let uploadOffset: Int64
    let complete: Bool
    let duplicate: Bool
}

nonisolated struct MediaPartResponse: Codable, Sendable {
    let mediaId: String
    let partIndex: Int
    let receivedBytes: Int64
    let complete: Bool
    let duplicate: Bool
}

nonisolated struct MediaCompleteResponse: Codable, Sendable {
    let mediaId: String
    let ready: Bool
    let duplicate: Bool
}

nonisolated struct MediaUploadRequest: Codable, Sendable {
    let kind: String
    let contentType: String
    let fileName: String?
    let byteSize: Int64
    let sha256: String
    let durationMs: Int64?
    let width: Int?
    let height: Int?
    let uploadProtocol: String?
    var purpose: String? = nil
}

nonisolated struct PreparedMediaUpload: Sendable {
    let transferId: String
    let kind: String
    let contentType: String
    let fileName: String?
    let byteSize: Int64
    let sha256: String
    let durationMs: Int64?
    let width: Int?
    let height: Int?
    let encryptedSourcePath: String
    let encryptedThumbnailPath: String?
}

struct CloudMediaAPI: Sendable {
    let config: CloudConfig
    var session: URLSession = .shared

    func createUpload(_ requestBody: MediaUploadRequest, token: String) async throws -> MediaUploadCreation {
        try await jsonRequest(path: "v1/media/uploads", method: "POST", body: requestBody, token: token)
    }

    func uploadState(mediaId: String, token: String) async throws -> MediaUploadState {
        try await jsonRequest(path: "v1/media/uploads/\(mediaId)", method: "GET", body: Optional<String>.none, token: token)
    }

    func uploadChunk(mediaId: String, offset: Int64, bytes: Data, token: String) async throws -> MediaChunkResponse {
        var request = URLRequest(url: config.httpURL(path: "v1/media/uploads/\(mediaId)/chunks"))
        request.httpMethod = "PUT"
        request.httpBody = bytes
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await runJSON(request)
    }

    func uploadPart(
        mediaId: String, partIndex: Int, bytes: Data, token: String,
        progress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> MediaPartResponse {
        var request = URLRequest(url: config.httpURL(path: "v1/media/uploads/\(mediaId)/parts/\(partIndex)"))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let delegate = MediaUploadTaskDelegate(progress: progress)
        let (data, response) = try await session.upload(for: request, from: bytes, delegate: delegate)
        _ = try validate(data: data, response: response)
        return try JSONDecoder().decode(MediaPartResponse.self, from: data)
    }

    func uploadThumbnail(mediaId: String, bytes: Data, token: String) async throws {
        var request = URLRequest(url: config.httpURL(path: "v1/media/uploads/\(mediaId)/thumbnail"))
        request.httpMethod = "PUT"
        request.httpBody = bytes
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let _: MediaThumbnailResponse = try await runJSON(request)
    }

    func completeUpload(mediaId: String, token: String) async throws -> MediaCompleteResponse {
        try await jsonRequest(
            path: "v1/media/uploads/\(mediaId)/complete", method: "POST",
            body: EmptyMediaBody(), token: token
        )
    }

    func cancelUpload(mediaId: String, token: String) async throws {
        var request = URLRequest(url: config.httpURL(path: "v1/media/uploads/\(mediaId)"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let _: MediaCancelResponse = try await runJSON(request)
    }

    func downloadChunk(mediaId: String, offset: Int64, token: String) async throws -> MediaDownloadChunk {
        var components = URLComponents(url: config.httpURL(path: "v1/media/\(mediaId)/chunks"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "offset", value: String(offset))]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let http = try validate(data: data, response: response)
        guard
            let next = http.value(forHTTPHeaderField: "X-Media-Next-Offset").flatMap(Int64.init),
            let total = http.value(forHTTPHeaderField: "X-Media-Total-Size").flatMap(Int64.init)
        else { throw CloudAPIError(status: -1, message: "Invalid media response", retryAfter: nil) }
        guard
            !data.isEmpty, data.count <= 1024 * 1024,
            total > 0, total <= TojMediaLimits.maximumMessageBytes,
            next == offset + Int64(data.count), next <= total
        else { throw CloudAPIError(status: -1, message: "Invalid media response", retryAfter: nil) }
        return MediaDownloadChunk(data: data, nextOffset: next, totalSize: total)
    }

    func downloadThumbnail(mediaId: String, token: String) async throws -> Data {
        var request = URLRequest(url: config.httpURL(path: "v1/media/\(mediaId)/thumbnail"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        _ = try validate(data: data, response: response)
        guard !data.isEmpty, data.count <= 256 * 1024 else {
            throw CloudAPIError(status: -1, message: "Invalid media preview", retryAfter: nil)
        }
        return data
    }

    private func jsonRequest<Body: Encodable, Response: Decodable>(
        path: String, method: String, body: Body?, token: String
    ) async throws -> Response {
        var request = URLRequest(url: config.httpURL(path: path))
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await runJSON(request)
    }

    private func runJSON<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        _ = try validate(data: data, response: response)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func validate(data: Data, response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw CloudAPIError(status: -1, message: "Invalid server response", retryAfter: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(MediaServerError.self, from: data)
            let message = payload?.error ?? "HTTP \(http.statusCode)"
            throw CloudAPIError(
                status: http.statusCode, message: message,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init),
                code: payload?.code
            )
        }
        return http
    }
}

private struct EmptyMediaBody: Codable {}
private struct MediaThumbnailResponse: Codable { let mediaId: String; let uploaded: Bool }
private struct MediaCancelResponse: Codable { let mediaId: String; let cancelled: Bool }
private struct MediaServerError: Codable { let error: String; let code: String? }
nonisolated struct MediaDownloadChunk: Sendable { let data: Data; let nextOffset: Int64; let totalSize: Int64 }

nonisolated enum MediaNetworkClass: String, Codable, CaseIterable, Hashable, Sendable {
    case wifi
    case cellular
    case constrained
    case roaming
}

nonisolated enum MediaChatClass: String, Codable, CaseIterable, Hashable, Sendable {
    case privateChat
    case group
}

nonisolated enum MediaDownloadPriority: Int, Codable, Comparable, Sendable {
    case background = 0
    case automatic = 10
    case visible = 50
    case userInitiated = 100

    static func < (lhs: MediaDownloadPriority, rhs: MediaDownloadPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated struct MediaAutoDownloadLimits: Codable, Equatable, Sendable {
    let photoBytes: Int64
    let voiceBytes: Int64
    let videoBytes: Int64
    let fileBytes: Int64

    func byteLimit(for kind: String) -> Int64 {
        switch kind {
        case "photo": photoBytes
        case "voice": voiceBytes
        case "video": videoBytes
        default: fileBytes
        }
    }
}

nonisolated struct MediaAutoDownloadNetworkPolicy: Codable, Equatable, Sendable {
    var wifi: MediaAutoDownloadLimits
    var cellular: MediaAutoDownloadLimits
    var constrained: MediaAutoDownloadLimits
    var roaming: MediaAutoDownloadLimits

    func limits(for network: MediaNetworkClass) -> MediaAutoDownloadLimits {
        switch network {
        case .wifi: wifi
        case .cellular: cellular
        case .constrained: constrained
        case .roaming: roaming
        }
    }
}

nonisolated struct MediaDownloadDirective: Equatable, Sendable {
    let downloadsThumbnail: Bool
    let downloadsFullMedia: Bool
    let priority: MediaDownloadPriority
}

/// Durable, user-customizable auto-download rules. A zero byte limit disables automatic full-media
/// downloads for that media kind while still allowing its thumbnail to be prefetched.
nonisolated struct MediaAutoDownloadPolicy: Codable, Equatable, Sendable {
    static let maximumSupportedMediaBytes = TojMediaLimits.maximumMessageBytes

    var privateChats: MediaAutoDownloadNetworkPolicy
    var groupChats: MediaAutoDownloadNetworkPolicy

    static let `default`: MediaAutoDownloadPolicy = {
        let megabyte: Int64 = 1024 * 1024
        let wifi = MediaAutoDownloadLimits(
            photoBytes: 25 * megabyte, voiceBytes: 25 * megabyte,
            videoBytes: 25 * megabyte, fileBytes: 25 * megabyte
        )
        let cellular = MediaAutoDownloadLimits(
            photoBytes: 3 * megabyte, voiceBytes: 10 * megabyte,
            videoBytes: 10 * megabyte, fileBytes: 5 * megabyte
        )
        let restricted = MediaAutoDownloadLimits(
            photoBytes: 0, voiceBytes: 10 * megabyte, videoBytes: 0, fileBytes: 0
        )
        let network = MediaAutoDownloadNetworkPolicy(
            wifi: wifi, cellular: cellular, constrained: restricted, roaming: restricted
        )
        return MediaAutoDownloadPolicy(privateChats: network, groupChats: network)
    }()

    func directive(
        for media: CloudMedia,
        chat: MediaChatClass,
        network: MediaNetworkClass,
        userInitiated: Bool = false,
        visible: Bool = false
    ) -> MediaDownloadDirective {
        if userInitiated {
            return MediaDownloadDirective(
                downloadsThumbnail: media.hasThumbnail,
                downloadsFullMedia: media.byteSize > 0 && media.byteSize <= Self.maximumSupportedMediaBytes,
                priority: .userInitiated
            )
        }
        let policy = chat == .privateChat ? privateChats : groupChats
        let maximum = policy.limits(for: network).byteLimit(for: media.kind)
        return MediaDownloadDirective(
            downloadsThumbnail: media.hasThumbnail,
            downloadsFullMedia: maximum > 0 && media.byteSize > 0 && media.byteSize <= maximum,
            priority: visible ? .visible : .automatic
        )
    }
}

nonisolated enum MediaCacheSizeLimit: Codable, Hashable, Sendable {
    case megabytes500
    case gigabytes2
    case gigabytes5
    case gigabytes10
    case unlimited
    case custom(Int64)

    var bytes: Int64? {
        switch self {
        case .megabytes500: 500 * 1024 * 1024
        case .gigabytes2: 2 * 1024 * 1024 * 1024
        case .gigabytes5: 5 * 1024 * 1024 * 1024
        case .gigabytes10: 10 * 1024 * 1024 * 1024
        case .unlimited: nil
        case let .custom(bytes): max(0, bytes)
        }
    }
}

nonisolated enum MediaCacheRetention: String, Codable, CaseIterable, Hashable, Sendable {
    case threeDays
    case oneWeek
    case oneMonth
    case forever

    var interval: TimeInterval? {
        switch self {
        case .threeDays: 3 * 24 * 60 * 60
        case .oneWeek: 7 * 24 * 60 * 60
        case .oneMonth: 30 * 24 * 60 * 60
        case .forever: nil
        }
    }
}

nonisolated struct MediaCachePolicy: Codable, Equatable, Sendable {
    var sizeLimit: MediaCacheSizeLimit
    var retention: MediaCacheRetention

    static let `default` = MediaCachePolicy(sizeLimit: .unlimited, retention: .forever)

    /// Keeps at least 5% of the volume free, clamped to the 1...5 GB safety range.
    static func minimumFreeSpaceBytes(totalCapacity: Int64) -> Int64 {
        max(1 * 1024 * 1024 * 1024, min(5 * 1024 * 1024 * 1024, totalCapacity / 20))
    }
}

nonisolated struct MediaDownloadState: Codable, Equatable, Sendable {
    let mediaId: String
    let cachedBytes: Int64
    let expectedBytes: Int64?
    let hasThumbnail: Bool
    let lastAccess: Date?
    let isActive: Bool

    var isComplete: Bool {
        guard let expectedBytes else { return false }
        return expectedBytes > 0 && cachedBytes >= expectedBytes
    }
}

nonisolated struct MediaCacheUsage: Codable, Equatable, Sendable {
    let downloadedBytes: Int64
    let protectedUploadBytes: Int64
    let entryCount: Int
    let limitBytes: Int64?
}

nonisolated struct MediaVolumeCapacity: Equatable, Sendable {
    let availableBytes: Int64
    let totalCapacityBytes: Int64
}

nonisolated struct MediaCacheLedgerKey: Hashable, Sendable {
    let mediaId: String
    let variant: String
}

nonisolated struct MediaCacheClearResult: Equatable, Sendable {
    let clearedMediaIds: Set<String>
    let protectedMediaIds: Set<String>
}

nonisolated final class MediaPolicyStore: @unchecked Sendable {
    private enum Key {
        static let autoDownload = "toj.media.auto-download-policy.v1"
        static let cache = "toj.media.cache-policy.v1"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAutoDownloadPolicy() -> MediaAutoDownloadPolicy {
        load(MediaAutoDownloadPolicy.self, key: Key.autoDownload) ?? .default
    }

    func saveAutoDownloadPolicy(_ policy: MediaAutoDownloadPolicy) throws {
        try save(policy, key: Key.autoDownload)
    }

    func loadCachePolicy() -> MediaCachePolicy {
        load(MediaCachePolicy.self, key: Key.cache) ?? .default
    }

    func saveCachePolicy(_ policy: MediaCachePolicy) throws {
        try save(policy, key: Key.cache)
    }

    private func load<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: key), let value = try? decoder.decode(type, from: data) else {
            return nil
        }
        return value
    }

    private func save<Value: Encodable>(_ value: Value, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(try encoder.encode(value), forKey: key)
    }
}

nonisolated enum MediaDownloadComponent: String, Codable, Sendable {
    case thumbnail
    case fullMedia = "full"
}

nonisolated struct MediaAccessRestoreLease: Equatable, Sendable {
    let mediaId: String
    let generation: UInt64
    fileprivate let cache: EncryptedMediaCache

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mediaId == rhs.mediaId
            && lhs.generation == rhs.generation
            && lhs.cache === rhs.cache
    }
}

/// Token-free and Codable so the local replica can persist queue items without ever persisting an
/// account credential. Callers provide the current session token only when executing a dequeued item.
nonisolated struct MediaDownloadQueueItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let media: CloudMedia
    let component: MediaDownloadComponent
    let priority: MediaDownloadPriority
    let sequence: Int64
    let dialogId: String?
    let userInitiated: Bool
    let retryCount: Int

    init(
        media: CloudMedia,
        component: MediaDownloadComponent,
        priority: MediaDownloadPriority,
        sequence: Int64,
        dialogId: String? = nil,
        userInitiated: Bool = false,
        retryCount: Int = 0
    ) {
        self.id = "\(media.id)|\(component.rawValue)"
        self.media = media
        self.component = component
        self.priority = priority
        self.sequence = sequence
        self.dialogId = dialogId
        self.userInitiated = userInitiated
        self.retryCount = retryCount
    }
}

private final class MediaUploadTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64, Int64) async -> Void

    init(progress: @escaping @Sendable (Int64, Int64) async -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        Task { await progress(totalBytesSent, totalBytesExpectedToSend) }
    }
}

actor EncryptedMediaCache {
    static let defaultLimitBytes: Int64 = 2 * 1024 * 1024 * 1024

    private struct DownloadEntry {
        var cipherBytes: Int64
        var plaintextBytes: Int64
        var lastAccess: Date
    }

    private struct ThumbnailEntry {
        var cipherBytes: Int64
        var plaintextBytes: Int64
        var lastAccess: Date
    }

    private struct ChunkExtent {
        let offset: Int64
        let size: Int64
        let cipherSize: Int64
        let url: URL
    }

    private let root: URL
    private let previewRoot: URL
    private let key: SymmetricKey
    private let fileManager = FileManager.default
    private var policy: MediaCachePolicy
    private var indexLoaded = false
    private var trackedBytes: Int64 = 0
    private var uploadBytesByPath: [String: Int64] = [:]
    private var downloads: [String: DownloadEntry] = [:]
    private var thumbnails: [String: ThumbnailEntry] = [:]
    private var representations: [MediaCacheLedgerKey: ThumbnailEntry] = [:]
    private var activeAccessCounts: [String: Int] = [:]
    private var removedLedgerKeys: Set<MediaCacheLedgerKey> = []
    private var revokedMediaIds: Set<String> = []
    private var mediaAccessGenerations: [String: UInt64] = [:]
    private var lastRetentionSweep: Date?

    init(
        root: URL? = nil,
        keyData: Data? = nil,
        limitBytes: Int64 = defaultLimitBytes,
        retention: MediaCacheRetention = .oneMonth,
        policy: MediaCachePolicy? = nil
    ) throws {
        let base: URL
        if let root { base = root }
        else {
            let support = try fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let rootName = LocalDatabaseKeyStore.usesTelegramFastUITestFixture
                ? "TojUITest/media"
                : "Toj/media"
            base = support.appending(path: rootName, directoryHint: .isDirectory)
        }
        self.root = base
        self.previewRoot = root == nil
            ? fileManager.temporaryDirectory.appending(path: "TojMediaPreviews", directoryHint: .isDirectory)
            : base.appending(path: "previews", directoryHint: .isDirectory)
        self.policy = policy ?? MediaCachePolicy(sizeLimit: .custom(limitBytes), retention: retention)
        let sourceKey = try keyData ?? LocalDatabaseKeyStore.currentEnvironment().loadOrCreateKey()
        var material = Data("toj/media-cache/v1".utf8)
        material.append(sourceKey)
        self.key = SymmetricKey(data: Data(SHA256.hash(data: material)))
        try Self.createProtectedDirectory(base, fileManager: fileManager)
        for name in ["uploads", "downloads", "thumbnails", "representations"] {
            try Self.createProtectedDirectory(
                base.appending(path: name, directoryHint: .isDirectory), fileManager: fileManager
            )
        }
        // Decrypted previews are unavoidable for AVPlayer and the system share sheet. Purge crash
        // leftovers at cache warmup, keep them out of backups, and apply strong file protection.
        if fileManager.fileExists(atPath: previewRoot.path) { try fileManager.removeItem(at: previewRoot) }
        try Self.createProtectedDirectory(previewRoot, fileManager: fileManager)
    }

    private nonisolated static func createProtectedDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedURL = url
        try? protectedURL.setResourceValues(values)
    }

    func prepareUpload(
        data: Data, kind: String, contentType: String, fileName: String?,
        durationMs: Int64? = nil, width: Int? = nil, height: Int? = nil,
        thumbnail: Data? = nil
    ) throws -> PreparedMediaUpload {
        guard !data.isEmpty, data.count <= TojMediaLimits.maximumMessageBytesInt else { throw MediaCacheError.unsupportedSize }
        guard (thumbnail?.count ?? 0) <= 256 * 1024 else { throw MediaCacheError.thumbnailTooLarge }
        try loadIndexIfNeeded()
        let reservation = Int64(data.count + 128) + Int64((thumbnail?.count ?? 0) + (thumbnail == nil ? 0 : 128))
        try ensureCapacity(additionalBytes: reservation)
        let transferId = UUID().uuidString.lowercased()
        let source = root.appending(path: "uploads/\(transferId).tojmedia")
        let thumbnailURL = root.appending(path: "uploads/\(transferId).thumb")
        do {
            let sourceSize = try writeEncrypted(data, to: source, aad: "upload|\(transferId)")
            recordUploadFile(source, size: sourceSize)
            var thumbnailPath: String?
            if let thumbnail, !thumbnail.isEmpty {
                let thumbnailSize = try writeEncrypted(
                    thumbnail, to: thumbnailURL, aad: "upload-thumb|\(transferId)"
                )
                recordUploadFile(thumbnailURL, size: thumbnailSize)
                thumbnailPath = thumbnailURL.path
            }
            return PreparedMediaUpload(
                transferId: transferId, kind: kind, contentType: contentType,
                fileName: fileName, byteSize: Int64(data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                durationMs: durationMs, width: width, height: height,
                encryptedSourcePath: source.path, encryptedThumbnailPath: thumbnailPath
            )
        } catch {
            removeTrackedUpload(source)
            removeTrackedUpload(thumbnailURL)
            throw error
        }
    }

    func uploadData(for transfer: MediaTransferRecord) throws -> Data {
        try readEncrypted(
            from: URL(filePath: transfer.encryptedSourcePath),
            aad: "upload|\(transfer.transferId)"
        )
    }

    func uploadThumbnail(for transfer: MediaTransferRecord) throws -> Data? {
        guard let path = transfer.encryptedThumbnailPath else { return nil }
        return try readEncrypted(from: URL(filePath: path), aad: "upload-thumb|\(transfer.transferId)")
    }

    func preparedData(transferId: String) throws -> Data {
        try readEncrypted(
            from: root.appending(path: "uploads/\(transferId).tojmedia"),
            aad: "upload|\(transferId)"
        )
    }

    func preparedThumbnail(transferId: String) throws -> Data? {
        let url = root.appending(path: "uploads/\(transferId).thumb")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try readEncrypted(from: url, aad: "upload-thumb|\(transferId)")
    }

    /// Promotes a successfully sent upload into the normal encrypted download cache before its
    /// outbox files are removed, so the sender can reopen the media offline without downloading it.
    func finishUpload(_ transfer: MediaTransferRecord) throws {
        guard let mediaId = transfer.mediaId, !mediaId.isEmpty else { throw MediaCacheError.invalidState }
        try promoteUpload(transfer, mediaId: mediaId)
        try discardUpload(transfer)
    }

    func promoteUpload(_ transfer: MediaTransferRecord, mediaId: String) throws {
        guard !revokedMediaIds.contains(mediaId) else { throw MediaCacheError.accessRevoked }
        try loadIndexIfNeeded()
        let sourceData = try uploadData(for: transfer)
        guard Int64(sourceData.count) == transfer.byteSize else { throw MediaCacheError.invalidState }
        let thumbnailData = try uploadThumbnail(for: transfer)
        if try contiguousDownloadOffset(mediaId: mediaId) != transfer.byteSize {
            let chunkSize = 512 * 1024
            let chunkCount = (sourceData.count + chunkSize - 1) / chunkSize
            let reservation = Int64(sourceData.count + chunkCount * 128)
            try ensureCapacity(additionalBytes: reservation, protecting: mediaId)
            let staging = root.appending(
                path: "downloads/.promote-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory
            )
            try Self.createProtectedDirectory(staging, fileManager: fileManager)
            var stagedCipherBytes: Int64 = 0
            do {
                var offset = 0
                while offset < sourceData.count {
                    let end = min(sourceData.count, offset + chunkSize)
                    let bytes = Data(sourceData[offset..<end])
                    let url = staging.appending(path: "\(offset).tojchunk")
                    stagedCipherBytes += try writeEncrypted(
                        bytes, to: url, aad: "download|\(mediaId)|\(offset)"
                    )
                    offset = end
                }
                removeDownload(mediaId: mediaId)
                let destination = downloadDirectory(mediaId)
                try fileManager.moveItem(at: staging, to: destination)
                let now = Date()
                downloads[mediaId] = DownloadEntry(
                    cipherBytes: stagedCipherBytes,
                    plaintextBytes: Int64(sourceData.count),
                    lastAccess: now
                )
                trackedBytes += stagedCipherBytes
                try touch(destination, date: now)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
        }
        if let thumbnailData, !thumbnailData.isEmpty {
            try storeThumbnail(thumbnailData, mediaId: mediaId)
        }
    }

    func discardUpload(_ transfer: MediaTransferRecord) throws {
        try loadIndexIfNeeded()
        removeTrackedUpload(URL(filePath: transfer.encryptedSourcePath))
        if let path = transfer.encryptedThumbnailPath { removeTrackedUpload(URL(filePath: path)) }
    }

    func discardPrepared(_ prepared: PreparedMediaUpload) {
        try? loadIndexIfNeeded()
        removeTrackedUpload(URL(filePath: prepared.encryptedSourcePath))
        if let path = prepared.encryptedThumbnailPath {
            removeTrackedUpload(URL(filePath: path))
        }
    }

    func thumbnail(mediaId: String) throws -> Data? {
        try loadIndexIfNeeded()
        let url = root.appending(path: "thumbnails/\(mediaId).tojthumb")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try readEncrypted(from: url, aad: "thumbnail|\(mediaId)")
            try touchMedia(mediaId: mediaId)
            return data
        } catch {
            // A partial write, disk corruption, or stale key must never permanently poison media.
            removeThumbnail(mediaId: mediaId)
            return nil
        }
    }

    func storeThumbnail(_ data: Data, mediaId: String) throws {
        guard !revokedMediaIds.contains(mediaId) else { throw MediaCacheError.accessRevoked }
        try loadIndexIfNeeded()
        let url = root.appending(path: "thumbnails/\(mediaId).tojthumb")
        let oldSize = thumbnails[mediaId]?.cipherBytes ?? 0
        try ensureCapacity(
            additionalBytes: max(0, Int64(data.count + 128) - oldSize), protecting: mediaId
        )
        let newSize = try writeEncrypted(data, to: url, aad: "thumbnail|\(mediaId)")
        trackedBytes += newSize - oldSize
        thumbnails[mediaId] = ThumbnailEntry(
            cipherBytes: newSize, plaintextBytes: Int64(data.count), lastAccess: Date()
        )
        try enforceQuota(protecting: mediaId)
    }

    func representation(mediaId: String, variant: MediaPresentationVariant) throws -> Data? {
        try loadIndexIfNeeded()
        let key = MediaCacheLedgerKey(mediaId: mediaId, variant: variant.rawValue)
        let url = representationURL(mediaId: mediaId, variant: variant)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try readEncrypted(
                from: url,
                aad: "representation|\(mediaId)|\(variant.rawValue)"
            )
            let now = Date()
            if var entry = representations[key] {
                entry.lastAccess = now
                representations[key] = entry
            }
            try? touch(url, date: now)
            return data
        } catch {
            removeRepresentation(mediaId: mediaId, variant: variant)
            return nil
        }
    }

    func storeRepresentation(
        _ data: Data,
        mediaId: String,
        variant: MediaPresentationVariant
    ) throws {
        guard !revokedMediaIds.contains(mediaId) else { throw MediaCacheError.accessRevoked }
        guard !data.isEmpty, data.count <= 8 * 1_024 * 1_024 else {
            throw MediaCacheError.unsupportedSize
        }
        try loadIndexIfNeeded()
        let key = MediaCacheLedgerKey(mediaId: mediaId, variant: variant.rawValue)
        let directory = representationDirectory(mediaId)
        try Self.createProtectedDirectory(directory, fileManager: fileManager)
        let url = representationURL(mediaId: mediaId, variant: variant)
        let oldSize = representations[key]?.cipherBytes ?? 0
        try ensureCapacity(
            additionalBytes: max(0, Int64(data.count + 128) - oldSize),
            protecting: mediaId
        )
        let newSize = try writeEncrypted(
            data,
            to: url,
            aad: "representation|\(mediaId)|\(variant.rawValue)"
        )
        trackedBytes += newSize - oldSize
        representations[key] = ThumbnailEntry(
            cipherBytes: newSize,
            plaintextBytes: Int64(data.count),
            lastAccess: Date()
        )
        try enforceQuota(protecting: mediaId)
    }

    func contiguousDownloadOffset(mediaId: String) throws -> Int64 {
        do {
            let entries = try sortedChunkExtents(mediaId: mediaId)
            var expected: Int64 = 0
            for entry in entries {
                guard entry.offset == expected else { break }
                expected += entry.size
            }
            return expected
        } catch {
            // Restart a corrupt partial download from zero instead of failing forever.
            removeDownload(mediaId: mediaId)
            return 0
        }
    }

    func storeDownloadChunk(_ data: Data, mediaId: String, offset: Int64) throws {
        guard !revokedMediaIds.contains(mediaId) else { throw MediaCacheError.accessRevoked }
        try loadIndexIfNeeded()
        let url = chunkURL(mediaId: mediaId, offset: offset)
        let oldCipherSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let oldPlaintextSize = oldCipherSize > Self.sealOverhead ? oldCipherSize - Self.sealOverhead : 0
        try ensureCapacity(
            additionalBytes: max(0, Int64(data.count + 128) - oldCipherSize), protecting: mediaId
        )
        let dir = downloadDirectory(mediaId)
        try Self.createProtectedDirectory(dir, fileManager: fileManager)
        let newCipherSize = try writeEncrypted(data, to: url, aad: "download|\(mediaId)|\(offset)")
        let now = Date()
        var entry = downloads[mediaId] ?? DownloadEntry(
            cipherBytes: 0, plaintextBytes: 0, lastAccess: now
        )
        entry.cipherBytes += newCipherSize - oldCipherSize
        entry.plaintextBytes += Int64(data.count) - oldPlaintextSize
        entry.lastAccess = now
        downloads[mediaId] = entry
        trackedBytes += newCipherSize - oldCipherSize
        try touch(dir, date: now)
        try enforceQuota(protecting: mediaId)
    }

    func downloadedData(mediaId: String, expectedSize: Int64) throws -> Data? {
        do {
            let entries = try sortedChunkExtents(mediaId: mediaId)
            var expectedOffset: Int64 = 0
            for entry in entries {
                guard entry.offset == expectedOffset else { return nil }
                expectedOffset += entry.size
            }
            guard expectedOffset == expectedSize else { return nil }
            var result = Data(capacity: Int(expectedSize))
            for entry in entries {
                result.append(try readEncrypted(
                    from: entry.url, aad: "download|\(mediaId)|\(entry.offset)"
                ))
            }
            try touchMedia(mediaId: mediaId)
            return result
        } catch {
            removeDownload(mediaId: mediaId)
            return nil
        }
    }

    /// Returns decrypted bytes for `[offset, offset+length)` iff every byte in that range is already
    /// cached (chunks are contiguous across it); otherwise `nil`. Chunk plaintext sizes are derived
    /// from the sealed file size (AES-GCM `.combined` adds a fixed 28-byte nonce+tag) so coverage can
    /// be computed without decrypting chunks outside the requested window. Enables streaming playback.
    func cachedByteRange(mediaId: String, offset start: Int64, length: Int64) throws -> Data? {
        guard length > 0 else { return Data() }
        let end = start + length
        let entries = try sortedChunkExtents(mediaId: mediaId)
        guard !entries.isEmpty else { return nil }
        var result = Data(capacity: Int(length))
        var pos = start
        for entry in entries {
            let chunkEnd = entry.offset + entry.size
            if chunkEnd <= pos { continue }
            if entry.offset > pos { break }
            let plaintext = try readEncrypted(
                from: entry.url, aad: "download|\(mediaId)|\(entry.offset)"
            )
            let localStart = Int(pos - entry.offset)
            let localEnd = Int(min(chunkEnd, end) - entry.offset)
            guard localStart >= 0, localEnd <= plaintext.count, localStart <= localEnd else { return nil }
            result.append(plaintext.subdata(in: localStart..<localEnd))
            pos = chunkEnd
            if pos >= end { break }
        }
        guard pos >= end else { return nil }
        try? touchMedia(mediaId: mediaId)
        return result
    }

    /// How far contiguous cached coverage extends from `start` (returns `start` when nothing is
    /// cached there). The engine downloads the next chunk at this offset to grow the covered range.
    func coverageEnd(mediaId: String, from start: Int64) throws -> Int64 {
        let entries = try sortedChunkExtents(mediaId: mediaId)
        var pos = start
        for entry in entries {
            let chunkEnd = entry.offset + entry.size
            if chunkEnd <= pos { continue }
            if entry.offset > pos { break }
            pos = chunkEnd
        }
        return pos
    }

    func downloadState(mediaId: String, expectedSize: Int64? = nil) throws -> MediaDownloadState {
        try loadIndexIfNeeded()
        let download = downloads[mediaId]
        let thumbnail = thumbnails[mediaId]
        return MediaDownloadState(
            mediaId: mediaId,
            cachedBytes: download?.plaintextBytes ?? 0,
            expectedBytes: expectedSize,
            hasThumbnail: thumbnail != nil,
            lastAccess: [download?.lastAccess, thumbnail?.lastAccess].compactMap { $0 }.max(),
            isActive: (activeAccessCounts[mediaId] ?? 0) > 0
        )
    }

    /// Seeds the fast in-memory quota index from SQLCipher without walking the cache tree. Stale
    /// files are validated lazily when that specific media is opened or resumed.
    func hydrateDurableLedger(_ entries: [MediaCacheEntry]) {
        var hydratedDownloads: [String: DownloadEntry] = [:]
        var hydratedThumbnails: [String: ThumbnailEntry] = [:]
        var hydratedRepresentations: [MediaCacheLedgerKey: ThumbnailEntry] = [:]
        for entry in entries {
            let lastAccess = Self.sqliteDate(entry.lastAccessedAt) ?? .distantPast
            switch entry.variant {
            case "full" where entry.encryptedPath == downloadDirectory(entry.mediaId).path:
                hydratedDownloads[entry.mediaId] = DownloadEntry(
                    cipherBytes: max(0, entry.cachedBytes),
                    plaintextBytes: max(0, entry.contiguousOffset),
                    lastAccess: lastAccess
                )
            case "thumbnail" where entry.encryptedPath == thumbnailURL(entry.mediaId).path:
                hydratedThumbnails[entry.mediaId] = ThumbnailEntry(
                    cipherBytes: max(0, entry.cachedBytes),
                    plaintextBytes: max(0, entry.byteSize),
                    lastAccess: lastAccess
                )
            case let variant where MediaPresentationVariant(rawValue: variant) != nil:
                guard let representation = MediaPresentationVariant(rawValue: variant),
                      entry.encryptedPath == representationURL(
                        mediaId: entry.mediaId,
                        variant: representation
                      ).path else { continue }
                hydratedRepresentations[MediaCacheLedgerKey(
                    mediaId: entry.mediaId,
                    variant: variant
                )] = ThumbnailEntry(
                    cipherBytes: max(0, entry.cachedBytes),
                    plaintextBytes: max(0, entry.byteSize),
                    lastAccess: lastAccess
                )
            default:
                continue
            }
        }
        downloads = hydratedDownloads
        thumbnails = hydratedThumbnails
        representations = hydratedRepresentations
        trackedBytes = uploadBytesByPath.values.reduce(0, +) + downloadedBytes
        removedLedgerKeys.removeAll()
        indexLoaded = true
    }

    func drainRemovedLedgerKeys() -> Set<MediaCacheLedgerKey> {
        defer { removedLedgerKeys.removeAll() }
        return removedLedgerKeys
    }

    func restoreRemovedLedgerKeys(_ keys: Set<MediaCacheLedgerKey>) {
        removedLedgerKeys.formUnion(keys)
    }

    func durableEntries(media: CloudMedia) throws -> [MediaCacheEntry] {
        try loadIndexIfNeeded()
        var result: [MediaCacheEntry] = []
        if let thumbnail = thumbnails[media.id] {
            result.append(MediaCacheEntry(
                mediaId: media.id,
                variant: "thumbnail",
                encryptedPath: thumbnailURL(media.id).path,
                byteSize: thumbnail.plaintextBytes,
                cachedBytes: thumbnail.cipherBytes,
                contiguousOffset: thumbnail.plaintextBytes,
                state: "complete",
                lastAccessedAt: CloudLocalStore.sqliteTimestamp(thumbnail.lastAccess),
                protectedUntil: nil
            ))
        }
        if downloads[media.id] != nil {
            let contiguous = try contiguousDownloadOffset(mediaId: media.id)
            if let download = downloads[media.id] {
                result.append(MediaCacheEntry(
                    mediaId: media.id,
                    variant: "full",
                    encryptedPath: downloadDirectory(media.id).path,
                    byteSize: media.byteSize,
                    cachedBytes: download.cipherBytes,
                    contiguousOffset: contiguous,
                    state: contiguous >= media.byteSize ? "complete" : "partial",
                    lastAccessedAt: CloudLocalStore.sqliteTimestamp(download.lastAccess),
                    protectedUntil: nil
                ))
            }
        }
        for variant in MediaPresentationVariant.allCases {
            let key = MediaCacheLedgerKey(mediaId: media.id, variant: variant.rawValue)
            guard let representation = representations[key] else { continue }
            result.append(MediaCacheEntry(
                mediaId: media.id,
                variant: variant.rawValue,
                encryptedPath: representationURL(mediaId: media.id, variant: variant).path,
                byteSize: representation.plaintextBytes,
                cachedBytes: representation.cipherBytes,
                contiguousOffset: representation.plaintextBytes,
                state: "complete",
                lastAccessedAt: CloudLocalStore.sqliteTimestamp(representation.lastAccess),
                protectedUntil: nil
            ))
        }
        return result
    }

    func usageSnapshot() throws -> MediaCacheUsage {
        try loadIndexIfNeeded()
        return MediaCacheUsage(
            downloadedBytes: downloadedBytes,
            protectedUploadBytes: uploadBytesByPath.values.reduce(0, +),
            entryCount: Set(downloads.keys)
                .union(thumbnails.keys)
                .union(representations.keys.map(\.mediaId))
                .count,
            limitBytes: policy.sizeLimit.bytes
        )
    }

    func beginAccess(mediaId: String) throws {
        guard !revokedMediaIds.contains(mediaId) else { throw MediaCacheError.accessRevoked }
        try loadIndexIfNeeded()
        activeAccessCounts[mediaId, default: 0] += 1
        try touchMedia(mediaId: mediaId)
    }

    func endAccess(mediaId: String) {
        guard let count = activeAccessCounts[mediaId] else { return }
        if count <= 1 { activeAccessCounts[mediaId] = nil }
        else { activeAccessCounts[mediaId] = count - 1 }
    }

    func touchMedia(mediaId: String, at date: Date = Date()) throws {
        try loadIndexIfNeeded()
        if var download = downloads[mediaId] {
            download.lastAccess = date
            downloads[mediaId] = download
            try? touch(downloadDirectory(mediaId), date: date)
        }
        if var thumbnail = thumbnails[mediaId] {
            thumbnail.lastAccess = date
            thumbnails[mediaId] = thumbnail
            try? touch(thumbnailURL(mediaId), date: date)
        }
        for key in representations.keys where key.mediaId == mediaId {
            guard var representation = representations[key],
                  let variant = MediaPresentationVariant(rawValue: key.variant) else { continue }
            representation.lastAccess = date
            representations[key] = representation
            try? touch(representationURL(mediaId: mediaId, variant: variant), date: date)
        }
    }

    func enforcePolicy(now: Date = Date()) throws {
        try loadIndexIfNeeded()
        if let retention = policy.retention.interval {
            let cutoff = now.addingTimeInterval(-retention)
            let expired = cachedMediaIds().filter { mediaId in
                guard (activeAccessCounts[mediaId] ?? 0) == 0 else { return false }
                return lastAccess(mediaId: mediaId) < cutoff
            }
            for mediaId in expired { removeCachedMedia(mediaId: mediaId) }
        }
        try enforceQuota()
        lastRetentionSweep = now
    }

    func updatePolicy(_ policy: MediaCachePolicy, now: Date = Date()) throws {
        self.policy = policy
        lastRetentionSweep = nil
        try enforcePolicy(now: now)
    }

    func currentPolicy() -> MediaCachePolicy { policy }

    /// Applies the free-space safety reserve using capacity values supplied by the platform layer.
    /// Returning the number of encrypted bytes removed keeps disk-space API usage outside this actor
    /// and makes the operation deterministic in tests. Active media and pending uploads are protected.
    @discardableResult
    func trimForLowDisk(
        availableBytes: Int64,
        totalCapacity: Int64,
        additionalBytes: Int64 = 0
    ) throws -> Int64 {
        try loadIndexIfNeeded()
        let required = MediaCachePolicy.minimumFreeSpaceBytes(totalCapacity: totalCapacity)
        let bytesToFree = max(0, required + max(0, additionalBytes) - availableBytes)
        guard bytesToFree > 0 else { return 0 }
        let before = trackedBytes
        try evict(until: max(0, trackedBytes - bytesToFree), protecting: nil)
        return before - trackedBytes
    }

    func volumeCapacitySnapshot() throws -> MediaVolumeCapacity {
        let values = try root.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ])
        guard let total = values.volumeTotalCapacity, total > 0 else {
            throw MediaCacheError.invalidState
        }
        let immediatelyAvailable = values.volumeAvailableCapacity.map(Int64.init)
        let available = immediatelyAvailable ?? values.volumeAvailableCapacityForImportantUsage
        guard let available else { throw MediaCacheError.invalidState }
        return MediaVolumeCapacity(
            availableBytes: max(0, available),
            totalCapacityBytes: Int64(total)
        )
    }

    /// AES-GCM `.combined` layout overhead = 12-byte nonce + 16-byte tag.
    private static let sealOverhead: Int64 = 28

    func clearAll() throws {
        if fileManager.fileExists(atPath: root.path) { try fileManager.removeItem(at: root) }
        if fileManager.fileExists(atPath: previewRoot.path) { try fileManager.removeItem(at: previewRoot) }
        try Self.createProtectedDirectory(root, fileManager: fileManager)
        for name in ["uploads", "downloads", "thumbnails", "representations"] {
            try Self.createProtectedDirectory(root.appending(path: name), fileManager: fileManager)
        }
        try Self.createProtectedDirectory(previewRoot, fileManager: fileManager)
        indexLoaded = true
        trackedBytes = 0
        uploadBytesByPath.removeAll()
        downloads.removeAll()
        thumbnails.removeAll()
        representations.removeAll()
        activeAccessCounts.removeAll()
        removedLedgerKeys.removeAll()
        revokedMediaIds.removeAll()
        mediaAccessGenerations.removeAll()
    }

    @discardableResult
    func clearDownloaded() throws -> MediaCacheClearResult {
        try loadIndexIfNeeded()
        let protected = Set(activeAccessCounts.compactMap { mediaId, count in
            count > 0 ? mediaId : nil
        })
        let removable = cachedMediaIds().subtracting(protected)
        for mediaId in removable { removeCachedMedia(mediaId: mediaId) }
        if fileManager.fileExists(atPath: previewRoot.path) { try fileManager.removeItem(at: previewRoot) }
        try Self.createProtectedDirectory(previewRoot, fileManager: fileManager)
        return MediaCacheClearResult(
            clearedMediaIds: removable,
            protectedMediaIds: protected
        )
    }

    /// Clears a caller-selected chat/type subset while preserving anything currently playing,
    /// sharing, or exporting under an active access lease.
    @discardableResult
    func clearMedia(mediaIds: Set<String>) throws -> MediaCacheClearResult {
        try loadIndexIfNeeded()
        let protected = Set(mediaIds.filter { (activeAccessCounts[$0] ?? 0) > 0 })
        let removable = mediaIds.subtracting(protected)
        for mediaId in removable {
            removeCachedMedia(mediaId: mediaId)
        }
        return MediaCacheClearResult(
            clearedMediaIds: removable,
            protectedMediaIds: protected
        )
    }

    /// Access revocation overrides active playback leases. UI and network activity are cancelled
    /// before this call; physical deletion is verified so SQL finalization cannot race ahead of
    /// encrypted bytes that survived a filesystem error.
    func purgeRevokedMedia(
        mediaIds: Set<String>,
        additionalEncryptedPaths: Set<String>
    ) throws {
        try loadIndexIfNeeded()
        // Install the fence before touching disk. Foreground, background, streaming, and
        // presentation-representation continuations that arrive after this point are rejected.
        revokedMediaIds.formUnion(mediaIds)
        for mediaId in mediaIds {
            _ = advanceMediaAccessGeneration(mediaId: mediaId)
            activeAccessCounts[mediaId] = nil
            removeCachedMedia(mediaId: mediaId)
            let paths = [
                downloadDirectory(mediaId),
                thumbnailURL(mediaId),
                representationDirectory(mediaId),
            ]
            for path in paths where fileManager.fileExists(atPath: path.path) {
                try fileManager.removeItem(at: path)
            }
        }
        for rawPath in additionalEncryptedPaths where !rawPath.isEmpty {
            let url = URL(fileURLWithPath: rawPath)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            if let uploadBytes = uploadBytesByPath.removeValue(forKey: url.path) {
                trackedBytes = max(0, trackedBytes - uploadBytes)
            }
        }
    }

    func restoreAuthorizedMedia(mediaId: String) -> MediaAccessRestoreLease {
        let generation = advanceMediaAccessGeneration(mediaId: mediaId)
        revokedMediaIds.remove(mediaId)
        return MediaAccessRestoreLease(
            mediaId: mediaId,
            generation: generation,
            cache: self
        )
    }

    /// Reinstalls the fence only if no later purge or authorized restore superseded this lease.
    /// Deleting again closes the brief unfenced window for late chunk/thumbnail/representation
    /// writers before the caller learned that its SQLCipher authorization was stale.
    func rollbackUnauthorizedMedia(_ lease: MediaAccessRestoreLease) throws -> Bool {
        guard lease.cache === self,
              mediaAccessGenerations[lease.mediaId] == lease.generation
        else {
            return false
        }
        _ = advanceMediaAccessGeneration(mediaId: lease.mediaId)
        revokedMediaIds.insert(lease.mediaId)
        activeAccessCounts[lease.mediaId] = nil
        removeCachedMedia(mediaId: lease.mediaId)
        let paths = [
            downloadDirectory(lease.mediaId),
            thumbnailURL(lease.mediaId),
            representationDirectory(lease.mediaId),
        ]
        for path in paths where fileManager.fileExists(atPath: path.path) {
            try fileManager.removeItem(at: path)
        }
        return true
    }

    private func advanceMediaAccessGeneration(mediaId: String) -> UInt64 {
        let generation = (mediaAccessGenerations[mediaId] ?? 0) &+ 1
        mediaAccessGenerations[mediaId] = generation
        return generation
    }

    func createTemporaryPreview(_ data: Data, fileExtension: String?) throws -> URL {
        guard !data.isEmpty, data.count <= TojMediaLimits.maximumMessageBytesInt else { throw MediaCacheError.unsupportedSize }
        let candidate = (fileExtension ?? "").lowercased()
        let safeExtension = candidate.range(of: "^[a-z0-9]{1,10}$", options: .regularExpression) == nil
            ? "bin" : candidate
        let url = previewRoot.appending(path: "\(UUID().uuidString.lowercased()).\(safeExtension)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    func removeTemporaryPreview(_ url: URL) {
        let parent = previewRoot.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(parent) else { return }
        try? fileManager.removeItem(at: url)
    }

    func downloadedUsageBytes() throws -> Int64 {
        try loadIndexIfNeeded()
        return downloadedBytes
    }

    private var downloadedBytes: Int64 {
        downloads.values.reduce(0) { $0 + $1.cipherBytes }
            + thumbnails.values.reduce(0) { $0 + $1.cipherBytes }
            + representations.values.reduce(0) { $0 + $1.cipherBytes }
    }

    @discardableResult
    private func writeEncrypted(_ data: Data, to url: URL, aad: String) throws -> Int64 {
        let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(aad.utf8))
        guard let combined = sealed.combined else { throw MediaCacheError.encryptionFailed }
        try combined.write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        return Int64(combined.count)
    }

    private func readEncrypted(from url: URL, aad: String) throws -> Data {
        let combined = try Data(contentsOf: url)
        let sealed = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealed, using: key, authenticating: Data(aad.utf8))
    }

    private func downloadDirectory(_ mediaId: String) -> URL {
        root.appending(path: "downloads/\(mediaId)", directoryHint: .isDirectory)
    }

    private func chunkURL(mediaId: String, offset: Int64) -> URL {
        downloadDirectory(mediaId).appending(path: "\(offset).tojchunk")
    }

    private func thumbnailURL(_ mediaId: String) -> URL {
        root.appending(path: "thumbnails/\(mediaId).tojthumb")
    }

    private func representationDirectory(_ mediaId: String) -> URL {
        root.appending(path: "representations/\(mediaId)", directoryHint: .isDirectory)
    }

    private func representationURL(
        mediaId: String,
        variant: MediaPresentationVariant
    ) -> URL {
        representationDirectory(mediaId).appending(path: "\(variant.rawValue).tojrep")
    }

    private func touch(_ url: URL, date: Date) throws {
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private nonisolated static func sqliteDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }

    private func loadIndexIfNeeded() throws {
        guard !indexLoaded else { return }
        var indexedUploads: [String: Int64] = [:]
        let uploadsRoot = root.appending(path: "uploads", directoryHint: .isDirectory)
        if let enumerator = fileManager.enumerator(
            at: uploadsRoot, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) {
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true { indexedUploads[url.path] = Int64(values.fileSize ?? 0) }
            }
        }

        var indexedDownloads: [String: DownloadEntry] = [:]
        let downloadsRoot = root.appending(path: "downloads", directoryHint: .isDirectory)
        let childKeys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        for url in try fileManager.contentsOfDirectory(
            at: downloadsRoot, includingPropertiesForKeys: Array(childKeys)
        ) {
            if url.lastPathComponent.hasPrefix(".promote-") {
                try? fileManager.removeItem(at: url)
                continue
            }
            let values = try url.resourceValues(forKeys: childKeys)
            guard values.isDirectory == true else {
                try? fileManager.removeItem(at: url)
                continue
            }
            let mediaId = url.lastPathComponent
            do {
                let extents = try chunkExtents(in: url)
                guard !extents.isEmpty else { continue }
                indexedDownloads[mediaId] = DownloadEntry(
                    cipherBytes: extents.reduce(0) { $0 + $1.cipherSize },
                    plaintextBytes: extents.reduce(0) { $0 + $1.size },
                    lastAccess: values.contentModificationDate ?? .distantPast
                )
            } catch {
                try? fileManager.removeItem(at: url)
            }
        }

        var indexedThumbnails: [String: ThumbnailEntry] = [:]
        let thumbnailsRoot = root.appending(path: "thumbnails", directoryHint: .isDirectory)
        let thumbnailKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        for url in try fileManager.contentsOfDirectory(
            at: thumbnailsRoot, includingPropertiesForKeys: Array(thumbnailKeys)
        ) {
            let values = try url.resourceValues(forKeys: thumbnailKeys)
            guard values.isRegularFile == true, (values.fileSize ?? 0) > Int(Self.sealOverhead) else {
                try? fileManager.removeItem(at: url)
                continue
            }
            indexedThumbnails[url.deletingPathExtension().lastPathComponent] = ThumbnailEntry(
                cipherBytes: Int64(values.fileSize ?? 0),
                plaintextBytes: Int64(values.fileSize ?? 0) - Self.sealOverhead,
                lastAccess: values.contentModificationDate ?? .distantPast
            )
        }
        var indexedRepresentations: [MediaCacheLedgerKey: ThumbnailEntry] = [:]
        let representationsRoot = root.appending(
            path: "representations",
            directoryHint: .isDirectory
        )
        let directoryKeys: Set<URLResourceKey> = [.isDirectoryKey]
        for directory in try fileManager.contentsOfDirectory(
            at: representationsRoot,
            includingPropertiesForKeys: Array(directoryKeys)
        ) {
            let directoryValues = try directory.resourceValues(forKeys: directoryKeys)
            guard directoryValues.isDirectory == true else {
                try? fileManager.removeItem(at: directory)
                continue
            }
            let mediaId = directory.lastPathComponent
            for url in try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(thumbnailKeys)
            ) {
                let values = try url.resourceValues(forKeys: thumbnailKeys)
                let rawVariant = url.deletingPathExtension().lastPathComponent
                guard values.isRegularFile == true,
                      (values.fileSize ?? 0) > Int(Self.sealOverhead),
                      let variant = MediaPresentationVariant(rawValue: rawVariant),
                      url.pathExtension == "tojrep" else {
                    try? fileManager.removeItem(at: url)
                    continue
                }
                indexedRepresentations[MediaCacheLedgerKey(
                    mediaId: mediaId,
                    variant: variant.rawValue
                )] = ThumbnailEntry(
                    cipherBytes: Int64(values.fileSize ?? 0),
                    plaintextBytes: Int64(values.fileSize ?? 0) - Self.sealOverhead,
                    lastAccess: values.contentModificationDate ?? .distantPast
                )
            }
        }
        uploadBytesByPath = indexedUploads
        downloads = indexedDownloads
        thumbnails = indexedThumbnails
        representations = indexedRepresentations
        trackedBytes = indexedUploads.values.reduce(0, +) + downloadedBytes
        indexLoaded = true
    }

    private func sortedChunkExtents(mediaId: String) throws -> [ChunkExtent] {
        try loadIndexIfNeeded()
        let dir = downloadDirectory(mediaId)
        guard fileManager.fileExists(atPath: dir.path) else { return [] }
        let extents = try chunkExtents(in: dir).sorted { $0.offset < $1.offset }
        let values = try dir.resourceValues(forKeys: [.contentModificationDateKey])
        let updated = DownloadEntry(
            cipherBytes: extents.reduce(0) { $0 + $1.cipherSize },
            plaintextBytes: extents.reduce(0) { $0 + $1.size },
            lastAccess: values.contentModificationDate ?? downloads[mediaId]?.lastAccess ?? .distantPast
        )
        let oldSize = downloads[mediaId]?.cipherBytes ?? 0
        downloads[mediaId] = extents.isEmpty ? nil : updated
        trackedBytes += updated.cipherBytes - oldSize
        return extents
    }

    private func chunkExtents(in directory: URL) throws -> [ChunkExtent] {
        try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).map { url in
            guard
                url.pathExtension == "tojchunk",
                let offset = Int64(url.deletingPathExtension().lastPathComponent),
                offset >= 0
            else { throw MediaCacheError.invalidState }
            let cipherSize = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard cipherSize > Self.sealOverhead else { throw MediaCacheError.invalidState }
            return ChunkExtent(
                offset: offset, size: cipherSize - Self.sealOverhead,
                cipherSize: cipherSize, url: url
            )
        }
    }

    private func recordUploadFile(_ url: URL, size: Int64) {
        let old = uploadBytesByPath[url.path] ?? 0
        uploadBytesByPath[url.path] = size
        trackedBytes += size - old
    }

    private func removeTrackedUpload(_ url: URL) {
        let size = uploadBytesByPath.removeValue(forKey: url.path) ?? 0
        try? fileManager.removeItem(at: url)
        trackedBytes = max(0, trackedBytes - size)
    }

    private func removeDownload(mediaId: String) {
        let removed = downloads.removeValue(forKey: mediaId)
        let oldSize = removed?.cipherBytes ?? 0
        if removed != nil { removedLedgerKeys.insert(MediaCacheLedgerKey(mediaId: mediaId, variant: "full")) }
        try? fileManager.removeItem(at: downloadDirectory(mediaId))
        trackedBytes = max(0, trackedBytes - oldSize)
    }

    private func removeThumbnail(mediaId: String) {
        let removed = thumbnails.removeValue(forKey: mediaId)
        let oldSize = removed?.cipherBytes ?? 0
        if removed != nil {
            removedLedgerKeys.insert(MediaCacheLedgerKey(mediaId: mediaId, variant: "thumbnail"))
        }
        try? fileManager.removeItem(at: thumbnailURL(mediaId))
        trackedBytes = max(0, trackedBytes - oldSize)
    }

    private func removeRepresentation(
        mediaId: String,
        variant: MediaPresentationVariant
    ) {
        let key = MediaCacheLedgerKey(mediaId: mediaId, variant: variant.rawValue)
        let removed = representations.removeValue(forKey: key)
        let oldSize = removed?.cipherBytes ?? 0
        if removed != nil { removedLedgerKeys.insert(key) }
        try? fileManager.removeItem(at: representationURL(mediaId: mediaId, variant: variant))
        if !representations.keys.contains(where: { $0.mediaId == mediaId }) {
            try? fileManager.removeItem(at: representationDirectory(mediaId))
        }
        trackedBytes = max(0, trackedBytes - oldSize)
    }

    private func removeCachedMedia(mediaId: String) {
        removeDownload(mediaId: mediaId)
        removeThumbnail(mediaId: mediaId)
        for variant in MediaPresentationVariant.allCases {
            removeRepresentation(mediaId: mediaId, variant: variant)
        }
    }

    private func cachedMediaIds() -> Set<String> {
        Set(downloads.keys)
            .union(thumbnails.keys)
            .union(representations.keys.map(\.mediaId))
    }

    private func lastAccess(mediaId: String) -> Date {
        let representationAccess = representations.compactMap { key, value in
            key.mediaId == mediaId ? value.lastAccess : nil
        }
        return ([downloads[mediaId]?.lastAccess, thumbnails[mediaId]?.lastAccess]
            .compactMap { $0 } + representationAccess).max() ?? .distantPast
    }

    private func enforceQuota(protecting mediaId: String? = nil) throws {
        guard let limit = policy.sizeLimit.bytes else { return }
        guard trackedBytes > limit else { return }
        try evict(until: limit, protecting: mediaId)
        if trackedBytes > limit { throw MediaCacheError.localQuotaExceeded }
    }

    private func ensureCapacity(additionalBytes: Int64, protecting mediaId: String? = nil) throws {
        try loadIndexIfNeeded()
        if lastRetentionSweep.map({ Date().timeIntervalSince($0) > 60 * 60 }) ?? true {
            try enforcePolicy(now: Date())
        }
        guard let limit = policy.sizeLimit.bytes else { return }
        guard trackedBytes + additionalBytes > limit else { return }
        try evict(until: max(0, limit - additionalBytes), protecting: mediaId)
        if trackedBytes + additionalBytes > limit { throw MediaCacheError.localQuotaExceeded }
    }

    private func evict(until targetBytes: Int64, protecting mediaId: String?) throws {
        let candidates = cachedMediaIds()
            .filter { $0 != mediaId && (activeAccessCounts[$0] ?? 0) == 0 }
            .sorted { lastAccess(mediaId: $0) < lastAccess(mediaId: $1) }
        for candidate in candidates {
            removeCachedMedia(mediaId: candidate)
            if trackedBytes <= targetBytes { return }
        }
    }
}

nonisolated struct MediaMultipartPlan: Equatable, Sendable {
    let partSize: Int
    let totalParts: Int
    let receivedParts: Set<Int>

    init?(byteSize: Int64, partSize: Int?, totalParts: Int?, receivedParts: [Int]?) {
        guard byteSize > 0, let partSize, let totalParts,
              (256 * 1024...512 * 1024).contains(partSize),
              totalParts == Int((byteSize + Int64(partSize) - 1) / Int64(partSize))
        else { return nil }
        let received = Set(receivedParts ?? [])
        guard received.count == (receivedParts ?? []).count,
              received.allSatisfy({ (0..<totalParts).contains($0) })
        else { return nil }
        self.partSize = partSize
        self.totalParts = totalParts
        self.receivedParts = received
    }

    var missingParts: [Int] { (0..<totalParts).filter { !receivedParts.contains($0) } }

    func range(for partIndex: Int, byteSize: Int64) -> Range<Int> {
        let start = partIndex * partSize
        let end = min(Int(byteSize), start + partSize)
        return start..<end
    }
}

private actor MediaMultipartProgressTracker {
    private let totalBytes: Int64
    private let partSizes: [Int: Int64]
    private var acknowledged: Set<Int>
    private var sentByPart: [Int: Int64] = [:]
    private var maximumReported = 0.0

    init(totalBytes: Int64, partSizes: [Int: Int64], acknowledged: Set<Int>) {
        self.totalBytes = totalBytes
        self.partSizes = partSizes
        self.acknowledged = acknowledged
    }

    func reset(partIndex: Int) { sentByPart[partIndex] = 0 }

    func currentProgress() -> Double { nextProgress() }

    func sent(partIndex: Int, bytes: Int64) -> Double {
        guard !acknowledged.contains(partIndex) else { return maximumReported }
        sentByPart[partIndex] = min(max(0, bytes), partSizes[partIndex] ?? 0)
        return nextProgress()
    }

    func acknowledge(partIndex: Int) -> (progress: Double, acknowledgedBytes: Int64) {
        acknowledged.insert(partIndex)
        sentByPart[partIndex] = nil
        return (nextProgress(), acknowledged.reduce(0) { $0 + (partSizes[$1] ?? 0) })
    }

    private func nextProgress() -> Double {
        let acknowledgedBytes = acknowledged.reduce(Int64(0)) { $0 + (partSizes[$1] ?? 0) }
        let inFlightBytes = sentByPart.reduce(Int64(0)) { partial, entry in
            acknowledged.contains(entry.key) ? partial : partial + entry.value
        }
        let measured = Double(acknowledgedBytes + inFlightBytes) / Double(max(1, totalBytes))
        maximumReported = max(maximumReported, min(0.97, measured * 0.97))
        return maximumReported
    }
}

nonisolated enum MediaPartScheduler {
    static func run(
        partIndexes: [Int],
        maximumConcurrent: Int = 3,
        upload: @escaping @Sendable (Int) async throws -> Int64,
        didAcknowledge: @escaping @Sendable (Int, Int64) async throws -> Void
    ) async throws {
        guard !partIndexes.isEmpty else { return }
        let concurrency = max(1, min(maximumConcurrent, partIndexes.count))
        var nextIndex = 0
        try await withThrowingTaskGroup(of: (Int, Int64).self) { group in
            func enqueue(_ partIndex: Int) {
                group.addTask {
                    (partIndex, try await upload(partIndex))
                }
            }

            while nextIndex < concurrency {
                enqueue(partIndexes[nextIndex])
                nextIndex += 1
            }
            while let (partIndex, acknowledgedBytes) = try await group.next() {
                try await didAcknowledge(partIndex, acknowledgedBytes)
                if nextIndex < partIndexes.count {
                    enqueue(partIndexes[nextIndex])
                    nextIndex += 1
                }
            }
        }
    }
}

actor CloudMediaTransferEngine {
    private struct SharedFullDownload {
        let id: UUID
        let priority: MediaDownloadPriority
        let task: Task<Data, Error>
    }

    private struct SharedThumbnailDownload {
        let id: UUID
        let task: Task<Data?, Error>
    }

    private let api: CloudMediaAPI
    private let config: CloudConfig
    private let createsBackgroundDownloads: Bool
    private var backgroundDownloads: BackgroundMediaTransferSession?
    private var cache: EncryptedMediaCache?
    private let createsDefaultCache: Bool
    private let policyStore: MediaPolicyStore
    private var autoDownloadQueue: [MediaDownloadQueueItem] = []
    private var nextDownloadSequence: Int64 = 0
    private var durableLedgerHydrated = false
    private var interruptedDurableJobsRecovered = false
    private var backgroundDownloadsInstalled = false
    private var durableLocalStore: CloudLocalStore?
    private var automaticDownloadsSuspendedForLowDisk = false
    private var inFlightFullDownloads: [String: SharedFullDownload] = [:]
    private var inFlightThumbnailDownloads: [String: SharedThumbnailDownload] = [:]
    private let volumeCapacityProvider: (@Sendable () throws -> MediaVolumeCapacity)?
    #if DEBUG
    private var rollbackHandoffGate: (@Sendable () async -> Void)?
    #endif

    init(
        config: CloudConfig = .current,
        cache: EncryptedMediaCache? = nil,
        session: URLSession? = nil,
        policyStore: MediaPolicyStore = MediaPolicyStore(),
        volumeCapacityProvider: (@Sendable () throws -> MediaVolumeCapacity)? = nil
    ) {
        self.config = config
        self.api = CloudMediaAPI(config: config, session: session ?? Self.makeMediaSession())
        // Injected caches/sessions are used by deterministic tests and foreground-only tools.
        // The production engine owns the one app-wide background session.
        self.createsBackgroundDownloads = session == nil && cache == nil
        self.backgroundDownloads = session == nil && cache == nil
            ? BackgroundMediaTransferSession(config: config)
            : nil
        self.cache = cache
        self.createsDefaultCache = cache == nil
        self.policyStore = policyStore
        self.volumeCapacityProvider = volumeCapacityProvider
    }

    nonisolated private static func makeMediaSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 15 * 60
        configuration.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: configuration)
    }

    /// Opens Keychain and the encrypted cache only after callers have moved onto this actor. Keeping
    /// construction lazy makes `CloudMediaTransferEngine(config:)` safe to create during app startup.
    private func resolvedCache() throws -> EncryptedMediaCache {
        if let cache { return cache }
        guard createsDefaultCache else { throw MediaCacheError.encryptionFailed }
        let created = try EncryptedMediaCache(policy: policyStore.loadCachePolicy())
        cache = created
        return created
    }

    func warmCache() async throws {
        let cache = try resolvedCache()
        _ = try await cache.usageSnapshot()
        try await installBackgroundDownloadsIfNeeded()
    }

    /// Hydrates quota/LRU state from SQLCipher, avoiding a launch-time filesystem walk.
    func warmCache(localStore: CloudLocalStore) async throws {
        if !interruptedDurableJobsRecovered {
            interruptedDurableJobsRecovered = true
            do {
                try await localStore.recoverInterruptedMediaDownloadJobs()
            } catch {
                interruptedDurableJobsRecovered = false
                throw error
            }
        }
        let entries = try await localStore.mediaCacheEntries()
        let cache = try resolvedCache()
        await cache.hydrateDurableLedger(entries)
        durableLocalStore = localStore
        durableLedgerHydrated = true
        try await installBackgroundDownloadsIfNeeded()
    }

    private func installBackgroundDownloadsIfNeeded() async throws {
        guard createsBackgroundDownloads else { return }
        if backgroundDownloads == nil {
            backgroundDownloads = BackgroundMediaTransferSession(config: config)
        }
        guard let backgroundDownloads, !backgroundDownloadsInstalled else { return }
        backgroundDownloadsInstalled = true
        do {
            try await backgroundDownloads.installProcessor { [weak self] chunk in
                guard let self else { throw CancellationError() }
                try await self.persistBackgroundDownloadedChunk(chunk)
            }
        } catch {
            backgroundDownloadsInstalled = false
            throw error
        }
    }

    private func persistBackgroundDownloadedChunk(
        _ chunk: BackgroundMediaDownloadedChunk
    ) async throws {
        let cache = try resolvedCache()
        let cachedOffset = try await cache.contiguousDownloadOffset(mediaId: chunk.mediaId)
        if cachedOffset < chunk.nextOffset {
            guard cachedOffset == chunk.offset else { throw MediaCacheError.invalidState }
            try await cache.storeDownloadChunk(
                chunk.data,
                mediaId: chunk.mediaId,
                offset: chunk.offset
            )
        }
        if let durableLocalStore {
            let media = CloudMedia(
                id: chunk.mediaId,
                kind: "file",
                contentType: "application/octet-stream",
                fileName: nil,
                byteSize: chunk.totalSize,
                durationMs: nil,
                width: nil,
                height: nil,
                hasThumbnail: false
            )
            try await synchronizeDurableLedger(media: media, localStore: durableLocalStore)
        }
    }

    func currentAutoDownloadPolicy() -> MediaAutoDownloadPolicy {
        policyStore.loadAutoDownloadPolicy()
    }

    func updateAutoDownloadPolicy(_ policy: MediaAutoDownloadPolicy) throws {
        try policyStore.saveAutoDownloadPolicy(policy)
    }

    func currentCachePolicy() async -> MediaCachePolicy {
        if let cache { return await cache.currentPolicy() }
        return policyStore.loadCachePolicy()
    }

    func updateCachePolicy(_ policy: MediaCachePolicy) async throws {
        try policyStore.saveCachePolicy(policy)
        if let cache {
            try await cache.updatePolicy(policy)
            if let durableLocalStore {
                try await synchronizeRemovedLedgerKeys(localStore: durableLocalStore)
            }
        }
    }

    @discardableResult
    func enqueueAutoDownload(
        media: CloudMedia,
        chat: MediaChatClass,
        network: MediaNetworkClass,
        dialogId: String? = nil,
        localStore: CloudLocalStore? = nil,
        userInitiated: Bool = false,
        visible: Bool = false
    ) async -> MediaDownloadDirective {
        if let localStore { try? await hydrateDurableLedgerIfNeeded(localStore: localStore) }
        let directive = policyStore.loadAutoDownloadPolicy().directive(
            for: media, chat: chat, network: network,
            userInitiated: userInitiated, visible: visible
        )
        let state: MediaDownloadState?
        if let cache = try? resolvedCache() {
            state = try? await cache.downloadState(mediaId: media.id, expectedSize: media.byteSize)
        } else {
            state = nil
        }
        var components: [MediaDownloadComponent] = []
        if directive.downloadsThumbnail, state?.hasThumbnail != true { components.append(.thumbnail) }
        if directive.downloadsFullMedia, state?.isComplete != true { components.append(.fullMedia) }
        for component in components {
            nextDownloadSequence &+= 1
            let item = MediaDownloadQueueItem(
                media: media, component: component,
                priority: directive.priority, sequence: nextDownloadSequence,
                dialogId: dialogId, userInitiated: userInitiated
            )
            if let localStore {
                do {
                    try await localStore.enqueueMediaDownloadJob(Self.downloadJob(from: item, state: .queued))
                    continue
                } catch {
                    // Keep the request usable for this process if the durable replica is temporarily
                    // unavailable. The next sync pass will enqueue it durably again.
                }
            }
            autoDownloadQueue.removeAll { $0.id == item.id }
            autoDownloadQueue.append(item)
        }
        sortAutoDownloadQueue()
        return directive
    }

    func queuedAutoDownloads() -> [MediaDownloadQueueItem] { autoDownloadQueue }

    func replaceQueuedAutoDownloads(_ items: [MediaDownloadQueueItem]) {
        var deduplicated: [String: MediaDownloadQueueItem] = [:]
        for item in items where item.media.byteSize > 0
            && item.media.byteSize <= MediaAutoDownloadPolicy.maximumSupportedMediaBytes {
            if let existing = deduplicated[item.id], existing.priority > item.priority { continue }
            deduplicated[item.id] = item
        }
        autoDownloadQueue = Array(deduplicated.values)
        nextDownloadSequence = autoDownloadQueue.map(\.sequence).max() ?? 0
        sortAutoDownloadQueue()
    }

    func dequeueAutoDownload() -> MediaDownloadQueueItem? {
        guard !autoDownloadQueue.isEmpty else { return nil }
        return autoDownloadQueue.removeFirst()
    }

    func dequeueAutoDownload(
        localStore: CloudLocalStore,
        component requestedComponent: MediaDownloadComponent? = nil
    ) async -> MediaDownloadQueueItem? {
        for _ in 0..<50 {
            guard let job = try? await localStore.claimNextMediaDownloadJob(
                variant: requestedComponent?.rawValue
            ) else { break }
            guard let component = MediaDownloadComponent(rawValue: job.variant) else {
                try? await localStore.removeMediaDownloadJob(
                    mediaId: job.mediaId,
                    variant: job.variant
                )
                continue
            }
            guard let media = try? await localStore.messageMedia(mediaId: job.mediaId).first?.media,
                  media.byteSize > 0,
                  media.byteSize <= MediaAutoDownloadPolicy.maximumSupportedMediaBytes,
                  component != .thumbnail || media.hasThumbnail
            else {
                // A message can be deleted while its download is waiting. Remove the orphan so it
                // cannot sit at the head of the priority queue and starve valid jobs behind it.
                try? await localStore.removeMediaDownloadJob(
                    mediaId: job.mediaId,
                    variant: job.variant
                )
                continue
            }
            nextDownloadSequence &+= 1
            autoDownloadQueue.removeAll { $0.id == "\(job.mediaId)|\(job.variant)" }
            return MediaDownloadQueueItem(
                media: media,
                component: component,
                priority: MediaDownloadPriority(
                    rawValue: job.priority - (component == .thumbnail ? 1 : 0)
                ) ?? .automatic,
                sequence: nextDownloadSequence,
                dialogId: job.dialogId,
                userInitiated: job.userInitiated,
                retryCount: job.retryCount
            )
        }
        guard let requestedComponent else { return dequeueAutoDownload() }
        guard let index = autoDownloadQueue.firstIndex(where: {
            $0.component == requestedComponent
        }) else { return nil }
        return autoDownloadQueue.remove(at: index)
    }

    func removeQueuedAutoDownloads(mediaId: String) {
        autoDownloadQueue.removeAll { $0.media.id == mediaId }
    }

    func performAutoDownload(
        _ item: MediaDownloadQueueItem,
        token: String,
        localStore: CloudLocalStore? = nil,
        chat: MediaChatClass? = nil,
        network: MediaNetworkClass? = nil
    ) async throws {
        if let localStore {
            try await hydrateDurableLedgerIfNeeded(localStore: localStore)
            if !item.userInitiated {
                let currentChat: MediaChatClass = if let chat {
                    chat
                } else if let dialogId = item.dialogId {
                    (try? await localStore.mediaChatClass(dialogId: dialogId)) ?? .privateChat
                } else {
                    .privateChat
                }
                let currentNetwork = network ?? ReplicaNetworkMonitor.shared.snapshot().mediaNetworkClass
                let directive = policyStore.loadAutoDownloadPolicy().directive(
                    for: item.media,
                    chat: currentChat,
                    network: currentNetwork,
                    visible: item.priority >= .visible
                )
                let permitted = switch item.component {
                case .thumbnail: directive.downloadsThumbnail
                case .fullMedia: directive.downloadsFullMedia
                }
                guard permitted else {
                    try await deferAutomaticDownload(
                        item,
                        localStore: localStore,
                        delay: 5 * 60,
                        reason: "network_policy"
                    )
                    throw MediaCacheError.automaticDownloadDeferred
                }

                let cache = try resolvedCache()
                let state = try? await cache.downloadState(
                    mediaId: item.media.id,
                    expectedSize: item.media.byteSize
                )
                let additionalBytes: Int64 = switch item.component {
                case .thumbnail: state?.hasThumbnail == true ? 0 : 256 * 1024
                case .fullMedia: max(0, item.media.byteSize - (state?.cachedBytes ?? 0))
                }
                guard await prepareAutomaticDownloadStorage(
                    additionalBytes: additionalBytes,
                    localStore: localStore
                ) else {
                    try await deferAutomaticDownload(
                        item,
                        localStore: localStore,
                        delay: 15 * 60,
                        reason: "low_disk"
                    )
                    throw MediaCacheError.automaticDownloadDeferred
                }
            }
            try await localStore.upsertMediaDownloadJob(Self.downloadJob(from: item, state: .downloading))
        }
        do {
            switch item.component {
            case .thumbnail:
                _ = try await thumbnail(media: item.media, token: token, localStore: localStore)
            case .fullMedia:
                _ = try await data(
                    media: item.media,
                    token: token,
                    localStore: localStore,
                    priority: item.priority
                )
            }
            if let localStore {
                try await localStore.removeMediaDownloadJob(
                    mediaId: item.media.id, variant: item.component.rawValue
                )
            }
        } catch {
            if let localStore {
                let retry = MediaDownloadQueueItem(
                    media: item.media, component: item.component, priority: item.priority,
                    sequence: item.sequence, dialogId: item.dialogId,
                    userInitiated: item.userInitiated, retryCount: item.retryCount + 1
                )
                try? await synchronizeDurableLedger(media: item.media, localStore: localStore)
                try? await localStore.upsertMediaDownloadJob(Self.downloadJob(
                    from: retry, state: .failed,
                    nextRetryAt: CloudLocalStore.sqliteTimestamp(
                        Date().addingTimeInterval(Self.automaticRetryDelay(
                            retryCount: retry.retryCount
                        ))
                    ),
                    error: error.localizedDescription
                ))
            }
            throw error
        }
    }

    nonisolated static func automaticRetryDelay(
        retryCount: Int,
        randomUnit: Double = Double.random(in: 0...1)
    ) -> TimeInterval {
        let cap = min(300, pow(2, Double(max(0, retryCount))))
        return cap * min(1, max(0, randomUnit))
    }

    private func deferAutomaticDownload(
        _ item: MediaDownloadQueueItem,
        localStore: CloudLocalStore,
        delay: TimeInterval,
        reason: String
    ) async throws {
        try await localStore.upsertMediaDownloadJob(Self.downloadJob(
            from: item,
            state: .failed,
            nextRetryAt: CloudLocalStore.sqliteTimestamp(Date().addingTimeInterval(delay)),
            error: reason
        ))
    }

    private func hydrateDurableLedgerIfNeeded(localStore: CloudLocalStore) async throws {
        guard !durableLedgerHydrated else { return }
        try await warmCache(localStore: localStore)
    }

    private func prepareAutomaticDownloadStorage(
        additionalBytes: Int64,
        localStore: CloudLocalStore
    ) async -> Bool {
        guard let cache = try? resolvedCache() else { return false }
        let initial: MediaVolumeCapacity
        do {
            initial = try await currentVolumeCapacity(cache: cache)
        } catch {
            // Failure to read capacity must fail closed for discretionary network work. A direct
            // user tap remains available because it bypasses this automatic-download gate.
            automaticDownloadsSuspendedForLowDisk = true
            return false
        }
        let required = MediaCachePolicy.minimumFreeSpaceBytes(
            totalCapacity: initial.totalCapacityBytes
        ) + max(0, additionalBytes)
        if initial.availableBytes >= required {
            automaticDownloadsSuspendedForLowDisk = false
            return true
        }

        let removed = (try? await cache.trimForLowDisk(
            availableBytes: initial.availableBytes,
            totalCapacity: initial.totalCapacityBytes,
            additionalBytes: additionalBytes
        )) ?? 0
        _ = try? await synchronizeRemovedLedgerKeys(localStore: localStore)

        let refreshed = try? await currentVolumeCapacity(cache: cache)
        let effectiveAvailable = refreshed?.availableBytes ?? initial.availableBytes + removed
        automaticDownloadsSuspendedForLowDisk = effectiveAvailable < required
        return !automaticDownloadsSuspendedForLowDisk
    }

    private func currentVolumeCapacity(cache: EncryptedMediaCache) async throws -> MediaVolumeCapacity {
        if let volumeCapacityProvider { return try volumeCapacityProvider() }
        return try await cache.volumeCapacitySnapshot()
    }

    func areAutomaticDownloadsSuspendedForLowDisk() -> Bool {
        automaticDownloadsSuspendedForLowDisk
    }

    private func synchronizeDurableLedger(
        media: CloudMedia,
        localStore: CloudLocalStore
    ) async throws {
        let cache = try resolvedCache()
        try await synchronizeRemovedLedgerKeys(localStore: localStore)
        for entry in try await cache.durableEntries(media: media) {
            try await localStore.upsertMediaCacheEntry(entry)
        }
    }

    private func synchronizeRemovedLedgerKeys(localStore: CloudLocalStore) async throws {
        let cache = try resolvedCache()
        let removed = await cache.drainRemovedLedgerKeys()
        do {
            try await localStore.removeMediaCacheEntries(keys: removed)
        } catch {
            await cache.restoreRemovedLedgerKeys(removed)
            throw error
        }
    }

    nonisolated private static func downloadJob(
        from item: MediaDownloadQueueItem,
        state: MediaDownloadJobState,
        nextRetryAt: String? = nil,
        error: String? = nil
    ) -> MediaDownloadJobRecord {
        MediaDownloadJobRecord(
            mediaId: item.media.id,
            variant: item.component.rawValue,
            dialogId: item.dialogId,
            // Keep a preview for the same media ahead of its full payload even when SQLite
            // timestamps tie. The +1 is removed again when reconstructing a queue item.
            priority: item.priority.rawValue + (item.component == .thumbnail ? 1 : 0),
            state: state,
            userInitiated: item.userInitiated,
            retryCount: item.retryCount,
            nextRetryAt: nextRetryAt,
            lastError: error,
            updatedAt: CloudLocalStore.sqliteTimestamp(Date())
        )
    }

    private func sortAutoDownloadQueue() {
        autoDownloadQueue.sort {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.sequence < $1.sequence
        }
    }

    func prepare(
        data: Data, kind: String, contentType: String, fileName: String?,
        durationMs: Int64? = nil, width: Int? = nil, height: Int? = nil,
        thumbnail: Data? = nil
    ) async throws -> PreparedMediaUpload {
        let cache = try resolvedCache()
        return try await cache.prepareUpload(
            data: data, kind: kind, contentType: contentType, fileName: fileName,
            durationMs: durationMs, width: width, height: height, thumbnail: thumbnail
        )
    }

    func upload(
        transfer: MediaTransferRecord, token: String, localStore: CloudLocalStore,
        useMultipartV2: Bool = false,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        let cache = try resolvedCache()
        let data = try await cache.uploadData(for: transfer)
        var mediaId = transfer.mediaId
        var offset = transfer.uploadOffset
        var chunkSize = 256 * 1024
        var multipartPlan: MediaMultipartPlan?
        if let existingId = mediaId {
            do {
                let remote = try await api.uploadState(mediaId: existingId, token: token)
                if remote.status == "rejected" || remote.status == "deleted" {
                    try await localStore.resetMediaUpload(transferId: transfer.transferId)
                    mediaId = nil
                    offset = 0
                } else {
                    guard remote.status == "uploading" || remote.status == "ready" else {
                        throw MediaCacheError.uploadExpired
                    }
                guard
                    remote.mediaId == existingId, remote.byteSize == transfer.byteSize,
                    remote.uploadOffset >= 0, remote.uploadOffset <= transfer.byteSize,
                    remote.chunkSize > 0, remote.chunkSize <= 1024 * 1024,
                    remote.status != "ready" || remote.uploadOffset == transfer.byteSize
                else { throw MediaCacheError.invalidState }
                offset = remote.uploadOffset
                chunkSize = remote.chunkSize
                if remote.status == "ready" { return existingId }
                    if remote.uploadProtocol == "parts_v2" {
                        guard let plan = MediaMultipartPlan(
                            byteSize: transfer.byteSize, partSize: remote.partSize,
                            totalParts: remote.totalParts, receivedParts: remote.receivedParts
                        ) else { throw MediaCacheError.invalidState }
                        multipartPlan = plan
                    }
                }
            } catch let error as CloudAPIError where error.status == 404 || error.status == 410 {
                try await localStore.resetMediaUpload(transferId: transfer.transferId)
                mediaId = nil
                offset = 0
            }
        }
        if mediaId == nil {
            let created = try await api.createUpload(
                MediaUploadRequest(
                    kind: transfer.kind, contentType: transfer.contentType,
                    fileName: transfer.fileName, byteSize: transfer.byteSize,
                    sha256: transfer.sha256, durationMs: transfer.durationMs,
                    width: transfer.width, height: transfer.height,
                    uploadProtocol: useMultipartV2 ? "parts_v2" : nil,
                    purpose: transfer.purpose
                ), token: token
            )
            guard
                UUID(uuidString: created.mediaId) != nil,
                created.uploadOffset >= 0, created.uploadOffset <= transfer.byteSize,
                created.chunkSize > 0, created.chunkSize <= 1024 * 1024
            else { throw MediaCacheError.invalidState }
            mediaId = created.mediaId
            offset = created.uploadOffset
            chunkSize = created.chunkSize
            if created.uploadProtocol == "parts_v2" {
                guard let plan = MediaMultipartPlan(
                    byteSize: transfer.byteSize, partSize: created.partSize,
                    totalParts: created.totalParts, receivedParts: created.receivedParts
                ) else { throw MediaCacheError.invalidState }
                multipartPlan = plan
            }
            try await localStore.updateMediaTransfer(
                transferId: transfer.transferId, mediaId: created.mediaId,
                uploadOffset: offset, state: "uploading", error: nil
            )
        }
        guard let mediaId else { throw MediaCacheError.invalidState }
        let thumbnail = try await cache.uploadThumbnail(for: transfer)
        if let multipartPlan {
            async let thumbnailUpload: Void = uploadThumbnailIfPresent(
                thumbnail, mediaId: mediaId, token: token
            )
            try await uploadMultipart(
                data: data, transfer: transfer, mediaId: mediaId, token: token,
                plan: multipartPlan, localStore: localStore, progress: progress
            )
            try await thumbnailUpload
        } else {
            try await uploadThumbnailIfPresent(thumbnail, mediaId: mediaId, token: token)
            while offset < Int64(data.count) {
                try Task.checkCancellation()
                let end = min(data.count, Int(offset) + chunkSize)
                let response = try await api.uploadChunk(
                    mediaId: mediaId, offset: offset, bytes: Data(data[Int(offset)..<end]), token: token
                )
                guard response.mediaId == mediaId, response.uploadOffset == Int64(end) else {
                    throw MediaCacheError.invalidState
                }
                offset = response.uploadOffset
                try await localStore.updateMediaTransfer(
                    transferId: transfer.transferId, mediaId: mediaId,
                    uploadOffset: offset, state: "uploading", error: nil
                )
                await progress(min(0.97, Double(offset) / Double(max(1, data.count)) * 0.97))
            }
        }
        let completed = try await api.completeUpload(mediaId: mediaId, token: token)
        guard completed.mediaId == mediaId, completed.ready else { throw MediaCacheError.invalidState }
        await progress(1)
        return mediaId
    }

    private func uploadThumbnailIfPresent(_ thumbnail: Data?, mediaId: String, token: String) async throws {
        if let thumbnail { try await api.uploadThumbnail(mediaId: mediaId, bytes: thumbnail, token: token) }
    }

    private func uploadMultipart(
        data: Data, transfer: MediaTransferRecord, mediaId: String, token: String,
        plan: MediaMultipartPlan, localStore: CloudLocalStore,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let partSizes = Dictionary(uniqueKeysWithValues: (0..<plan.totalParts).map { index in
            (index, Int64(plan.range(for: index, byteSize: transfer.byteSize).count))
        })
        let tracker = MediaMultipartProgressTracker(
            totalBytes: transfer.byteSize, partSizes: partSizes, acknowledged: plan.receivedParts
        )
        if !plan.receivedParts.isEmpty {
            let initial = await tracker.currentProgress()
            await progress(initial)
        }
        let missing = plan.missingParts
        let api = self.api
        try await MediaPartScheduler.run(
            partIndexes: missing,
            upload: { partIndex in
                let range = plan.range(for: partIndex, byteSize: transfer.byteSize)
                let bytes = Data(data[range])
                let response = try await Self.uploadPartWithRetry(
                    api: api, mediaId: mediaId, partIndex: partIndex,
                    bytes: bytes, token: token, tracker: tracker, progress: progress
                )
                guard response.mediaId == mediaId, response.partIndex == partIndex else {
                    throw MediaCacheError.invalidState
                }
                let acknowledged = await tracker.acknowledge(partIndex: partIndex)
                await progress(acknowledged.progress)
                return acknowledged.acknowledgedBytes
            },
            didAcknowledge: { _, acknowledgedBytes in
                try await localStore.updateMediaTransfer(
                    transferId: transfer.transferId, mediaId: mediaId,
                    uploadOffset: acknowledgedBytes, state: "uploading", error: nil
                )
            }
        )
    }

    nonisolated private static func uploadPartWithRetry(
        api: CloudMediaAPI, mediaId: String, partIndex: Int, bytes: Data, token: String,
        tracker: MediaMultipartProgressTracker,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> MediaPartResponse {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            await tracker.reset(partIndex: partIndex)
            do {
                return try await api.uploadPart(
                    mediaId: mediaId, partIndex: partIndex, bytes: bytes, token: token,
                    progress: { sent, _ in
                        let value = await tracker.sent(partIndex: partIndex, bytes: sent)
                        await progress(value)
                    }
                )
            } catch {
                attempt += 1
                guard case let .transient(retryAfter) = cloudFailureDisposition(error), attempt < 3 else {
                    throw error
                }
                let delay = retryAfter ?? pow(2, Double(attempt - 1))
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    @discardableResult
    func finishUpload(
        _ transfer: MediaTransferRecord,
        localStore: CloudLocalStore? = nil
    ) async -> Bool {
        guard let cache = try? resolvedCache() else { return false }
        do {
            if let localStore { try await hydrateDurableLedgerIfNeeded(localStore: localStore) }
            try await cache.finishUpload(transfer)
            if let localStore {
                try await synchronizeDurableLedger(media: transfer.media, localStore: localStore)
            }
            return true
        } catch {
            return false
        }
    }

    func discardTransfer(_ transfer: MediaTransferRecord) async {
        guard let cache = try? resolvedCache() else { return }
        try? await cache.discardUpload(transfer)
    }

    func cancelUpload(_ transfer: MediaTransferRecord, token: String) async {
        if let mediaId = transfer.mediaId {
            // Cancellation cleanup must still run when the parent transfer task is already cancelled.
            let api = self.api
            await Task.detached { try? await api.cancelUpload(mediaId: mediaId, token: token) }.value
        }
        guard let cache = try? resolvedCache() else { return }
        try? await cache.discardUpload(transfer)
    }

    func discardPrepared(_ prepared: PreparedMediaUpload) async {
        guard let cache = try? resolvedCache() else { return }
        await cache.discardPrepared(prepared)
    }

    func thumbnail(
        media: CloudMedia,
        token: String,
        localStore: CloudLocalStore? = nil
    ) async throws -> Data? {
        if let existing = inFlightThumbnailDownloads[media.id] {
            return try await existing.task.value
        }
        let id = UUID()
        let task = Task {
            try await self.loadThumbnail(media: media, token: token, localStore: localStore)
        }
        inFlightThumbnailDownloads[media.id] = SharedThumbnailDownload(id: id, task: task)
        do {
            let result = try await task.value
            if inFlightThumbnailDownloads[media.id]?.id == id {
                inFlightThumbnailDownloads[media.id] = nil
            }
            return result
        } catch {
            if inFlightThumbnailDownloads[media.id]?.id == id {
                inFlightThumbnailDownloads[media.id] = nil
            }
            throw error
        }
    }

    private func loadThumbnail(
        media: CloudMedia,
        token: String,
        localStore: CloudLocalStore?
    ) async throws -> Data? {
        let cache = try resolvedCache()
        if let localStore { try await hydrateDurableLedgerIfNeeded(localStore: localStore) }
        if let transferId = Self.pendingTransferId(media.id) {
            return try await cache.preparedThumbnail(transferId: transferId)
        }
        guard media.hasThumbnail else { return nil }
        if let cached = try await cache.thumbnail(mediaId: media.id) {
            if let localStore {
                try? await localStore.touchMediaCacheEntry(mediaId: media.id, variant: "thumbnail")
            }
            return cached
        }
        let data = try await api.downloadThumbnail(mediaId: media.id, token: token)
        try await cache.storeThumbnail(data, mediaId: media.id)
        if let localStore { try await synchronizeDurableLedger(media: media, localStore: localStore) }
        return data
    }

    func representation(
        media: CloudMedia,
        variant: MediaPresentationVariant,
        localStore: CloudLocalStore? = nil
    ) async -> Data? {
        guard let cache = try? resolvedCache() else { return nil }
        if let localStore { try? await hydrateDurableLedgerIfNeeded(localStore: localStore) }
        guard let data = try? await cache.representation(mediaId: media.id, variant: variant) else {
            if let localStore { try? await synchronizeRemovedLedgerKeys(localStore: localStore) }
            return nil
        }
        if let localStore {
            try? await localStore.touchMediaCacheEntry(
                mediaId: media.id,
                variant: variant.rawValue
            )
        }
        return data
    }

    func storeRepresentation(
        _ data: Data,
        media: CloudMedia,
        variant: MediaPresentationVariant,
        localStore: CloudLocalStore? = nil
    ) async {
        guard let cache = try? resolvedCache() else { return }
        if let localStore { try? await hydrateDurableLedgerIfNeeded(localStore: localStore) }
        do {
            try await cache.storeRepresentation(
                data,
                mediaId: media.id,
                variant: variant
            )
        } catch {
            return
        }
        if let localStore { try? await synchronizeDurableLedger(media: media, localStore: localStore) }
    }

    func data(
        media: CloudMedia,
        token: String,
        localStore: CloudLocalStore? = nil,
        priority: MediaDownloadPriority = .userInitiated,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> Data {
        if let existing = inFlightFullDownloads[media.id] {
            if priority > existing.priority {
                existing.task.cancel()
            } else {
                return try await existing.task.value
            }
        }
        let id = UUID()
        let task = Task {
            try await self.loadData(
                media: media,
                token: token,
                localStore: localStore,
                priority: priority,
                progress: progress
            )
        }
        inFlightFullDownloads[media.id] = SharedFullDownload(
            id: id,
            priority: priority,
            task: task
        )
        do {
            let result = try await task.value
            if inFlightFullDownloads[media.id]?.id == id {
                inFlightFullDownloads[media.id] = nil
            }
            return result
        } catch {
            if inFlightFullDownloads[media.id]?.id == id {
                inFlightFullDownloads[media.id] = nil
            }
            throw error
        }
    }

    private func loadData(
        media: CloudMedia,
        token: String,
        localStore: CloudLocalStore?,
        priority: MediaDownloadPriority,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> Data {
        let cache = try resolvedCache()
        if let localStore { try await hydrateDurableLedgerIfNeeded(localStore: localStore) }
        if let transferId = Self.pendingTransferId(media.id) {
            return try await cache.preparedData(transferId: transferId)
        }
        guard media.byteSize > 0, media.byteSize <= TojMediaLimits.maximumMessageBytes else { throw MediaCacheError.unsupportedSize }
        if priority == .userInitiated { try await installBackgroundDownloadsIfNeeded() }
        try await cache.beginAccess(mediaId: media.id)
        do {
            if let cached = try await cache.downloadedData(mediaId: media.id, expectedSize: media.byteSize) {
                if let localStore {
                    try? await localStore.touchMediaCacheEntry(mediaId: media.id, variant: "full")
                }
                await cache.endAccess(mediaId: media.id)
                return cached
            }
            var offset = try await cache.contiguousDownloadOffset(mediaId: media.id)
            if priority == .userInitiated, let backgroundDownloads {
                await progress(Double(offset) / Double(max(1, media.byteSize)))
                try await backgroundDownloads.downloadFullMedia(
                    mediaId: media.id,
                    cachedOffset: offset,
                    expectedTotalSize: media.byteSize,
                    token: token,
                    progress: progress
                )
            } else {
                while offset < media.byteSize {
                    try Task.checkCancellation()
                    let chunk = try await api.downloadChunk(
                        mediaId: media.id,
                        offset: offset,
                        token: token
                    )
                    guard chunk.nextOffset > offset, chunk.totalSize == media.byteSize else {
                        throw MediaCacheError.invalidState
                    }
                    try await cache.storeDownloadChunk(
                        chunk.data,
                        mediaId: media.id,
                        offset: offset
                    )
                    offset = chunk.nextOffset
                    await progress(Double(offset) / Double(max(1, media.byteSize)))
                }
            }
            guard let result = try await cache.downloadedData(
                mediaId: media.id, expectedSize: media.byteSize
            ) else { throw MediaCacheError.invalidState }
            if let localStore { try await synchronizeDurableLedger(media: media, localStore: localStore) }
            await cache.endAccess(mediaId: media.id)
            return result
        } catch {
            if let localStore { try? await synchronizeDurableLedger(media: media, localStore: localStore) }
            await cache.endAccess(mediaId: media.id)
            throw error
        }
    }

    /// Serves `[offset, offset+length)` decrypted, downloading (and caching) only the chunks that
    /// range needs — the streaming primitive behind `AVAssetResourceLoader`. Unlike `data`, it never
    /// requires the whole file, so playback starts after the first covering chunk and seeks fetch
    /// only their target region. Requests are clamped to the media's real byte size.
    func byteRange(
        media: CloudMedia,
        token: String,
        offset: Int64,
        length: Int64,
        localStore: CloudLocalStore? = nil
    ) async throws -> Data {
        let cache = try resolvedCache()
        if let localStore { try await hydrateDurableLedgerIfNeeded(localStore: localStore) }
        if let transferId = Self.pendingTransferId(media.id) {
            // Just-sent media is already fully local — slice it in memory.
            let full = try await cache.preparedData(transferId: transferId)
            return Self.slice(full, offset: offset, length: length)
        }
        let total = media.byteSize
        guard total > 0, total <= TojMediaLimits.maximumMessageBytes else { throw MediaCacheError.unsupportedSize }
        let start = max(0, offset)
        let end = min(total, start + max(0, length))
        guard end > start else { return Data() }
        let wanted = end - start
        try await cache.beginAccess(mediaId: media.id)
        do {
            while true {
                if let data = try await cache.cachedByteRange(
                    mediaId: media.id, offset: start, length: wanted
                ) {
                    if let localStore {
                        try? await synchronizeDurableLedger(media: media, localStore: localStore)
                    }
                    await cache.endAccess(mediaId: media.id)
                    return data
                }
                try Task.checkCancellation()
                let downloadAt = try await cache.coverageEnd(mediaId: media.id, from: start)
                guard downloadAt < end, downloadAt < total else { throw MediaCacheError.invalidState }
                let chunk = try await api.downloadChunk(mediaId: media.id, offset: downloadAt, token: token)
                guard chunk.nextOffset > downloadAt, chunk.totalSize == total else {
                    throw MediaCacheError.invalidState
                }
                try await cache.storeDownloadChunk(chunk.data, mediaId: media.id, offset: downloadAt)
                if let localStore {
                    try await synchronizeDurableLedger(media: media, localStore: localStore)
                }
            }
        } catch {
            if let localStore {
                try? await synchronizeDurableLedger(media: media, localStore: localStore)
            }
            await cache.endAccess(mediaId: media.id)
            throw error
        }
    }

    /// Builds an `AVURLAsset` that streams this media through `EncryptedMediaResourceLoader`. The
    /// returned owner must be retained for the lifetime of playback (the asset holds the delegate weakly).
    nonisolated func makeStreamingAsset(
        media: CloudMedia,
        token: String,
        localStore: CloudLocalStore? = nil,
        startsAccessImmediately: Bool = true
    ) -> StreamingMediaAsset {
        StreamingMediaAsset(
            media: media,
            token: token,
            engine: self,
            localStore: localStore,
            startsAccessImmediately: startsAccessImmediately
        )
    }

    nonisolated private static func slice(_ data: Data, offset: Int64, length: Int64) -> Data {
        let start = Int(max(0, min(Int64(data.count), offset)))
        let end = Int(max(Int64(start), min(Int64(data.count), offset + max(0, length))))
        return data.subdata(in: start..<end)
    }

    func beginMediaAccess(_ mediaId: String) async {
        guard let cache = try? resolvedCache() else { return }
        try? await cache.beginAccess(mediaId: mediaId)
    }

    func endMediaAccess(_ mediaId: String) async {
        guard let cache else { return }
        await cache.endAccess(mediaId: mediaId)
    }

    func mediaDownloadState(mediaId: String, expectedSize: Int64? = nil) async -> MediaDownloadState? {
        guard let cache = try? resolvedCache() else { return nil }
        return try? await cache.downloadState(mediaId: mediaId, expectedSize: expectedSize)
    }

    func cacheUsage() async -> MediaCacheUsage? {
        guard let cache else { return nil }
        return try? await cache.usageSnapshot()
    }

    func enforceCachePolicy() async {
        if let durableLocalStore {
            await enforceCachePolicy(localStore: durableLocalStore)
            return
        }
        guard let cache = try? resolvedCache() else { return }
        try? await cache.enforcePolicy()
        guard let capacity = try? await currentVolumeCapacity(cache: cache) else {
            automaticDownloadsSuspendedForLowDisk = true
            return
        }
        _ = try? await cache.trimForLowDisk(
            availableBytes: capacity.availableBytes,
            totalCapacity: capacity.totalCapacityBytes
        )
        let refreshed = try? await currentVolumeCapacity(cache: cache)
        let required = MediaCachePolicy.minimumFreeSpaceBytes(
            totalCapacity: capacity.totalCapacityBytes
        )
        automaticDownloadsSuspendedForLowDisk = (refreshed?.availableBytes ?? 0) < required
    }

    func enforceCachePolicy(localStore: CloudLocalStore) async {
        guard let cache = try? resolvedCache() else { return }
        try? await hydrateDurableLedgerIfNeeded(localStore: localStore)
        try? await cache.enforcePolicy()
        _ = try? await synchronizeRemovedLedgerKeys(localStore: localStore)
        _ = await prepareAutomaticDownloadStorage(additionalBytes: 0, localStore: localStore)
    }

    func trimCacheForLowDisk(availableBytes: Int64, totalCapacity: Int64) async -> Int64 {
        guard let cache = try? resolvedCache() else { return 0 }
        return (try? await cache.trimForLowDisk(
            availableBytes: availableBytes, totalCapacity: totalCapacity
        )) ?? 0
    }

    func trimCacheForLowDisk(
        availableBytes: Int64,
        totalCapacity: Int64,
        localStore: CloudLocalStore
    ) async -> Int64 {
        guard let cache = try? resolvedCache() else { return 0 }
        try? await hydrateDurableLedgerIfNeeded(localStore: localStore)
        let removed = (try? await cache.trimForLowDisk(
            availableBytes: availableBytes,
            totalCapacity: totalCapacity
        )) ?? 0
        try? await synchronizeRemovedLedgerKeys(localStore: localStore)
        return removed
    }

    func clearCache() async {
        // User-facing cache clearing never removes encrypted upload sources. Logout owns the only
        // path that destroys both downloaded bytes and pending uploads.
        await clearDownloadedCache()
    }

    func clearDownloadedCache() async {
        guard let cache = try? resolvedCache() else { return }
        guard let result = try? await cache.clearDownloaded() else { return }
        autoDownloadQueue.removeAll { !result.protectedMediaIds.contains($0.media.id) }
    }

    func clearDownloadedCache(localStore: CloudLocalStore) async {
        guard let cache = try? resolvedCache() else { return }
        try? await hydrateDurableLedgerIfNeeded(localStore: localStore)
        guard let result = try? await cache.clearDownloaded() else { return }
        try? await synchronizeRemovedLedgerKeys(localStore: localStore)
        _ = try? await localStore.cancelMediaDownloadJobs(excluding: result.protectedMediaIds)
        autoDownloadQueue.removeAll { !result.protectedMediaIds.contains($0.media.id) }
    }

    func clearMediaCache(mediaIds: Set<String>) async {
        guard let cache = try? resolvedCache() else { return }
        guard let result = try? await cache.clearMedia(mediaIds: mediaIds) else { return }
        autoDownloadQueue.removeAll {
            result.clearedMediaIds.contains($0.media.id)
        }
    }

    func clearMediaCache(mediaIds: Set<String>, localStore: CloudLocalStore) async {
        guard let cache = try? resolvedCache() else { return }
        try? await hydrateDurableLedgerIfNeeded(localStore: localStore)
        guard let result = try? await cache.clearMedia(mediaIds: mediaIds) else { return }
        try? await synchronizeRemovedLedgerKeys(localStore: localStore)
        _ = try? await localStore.cancelMediaDownloadJobs(
            mediaIds: result.clearedMediaIds,
            excluding: result.protectedMediaIds
        )
        autoDownloadQueue.removeAll {
            result.clearedMediaIds.contains($0.media.id)
        }
    }

    func purgeRevokedAccess(
        allMediaIds: Set<String>,
        purgeMediaIds: Set<String>,
        encryptedPaths: Set<String>,
        localStore: CloudLocalStore
    ) async throws {
        guard !allMediaIds.isEmpty || !encryptedPaths.isEmpty else { return }
        for mediaId in allMediaIds {
            inFlightFullDownloads.removeValue(forKey: mediaId)?.task.cancel()
            inFlightThumbnailDownloads.removeValue(forKey: mediaId)?.task.cancel()
            autoDownloadQueue.removeAll { $0.media.id == mediaId }
        }
        try await backgroundDownloads?.cancelAndDelete(mediaIds: allMediaIds)
        let cache = try resolvedCache()
        try await hydrateDurableLedgerIfNeeded(localStore: localStore)
        try await cache.purgeRevokedMedia(
            mediaIds: purgeMediaIds,
            additionalEncryptedPaths: encryptedPaths
        )
        try await synchronizeRemovedLedgerKeys(localStore: localStore)
        _ = try await localStore.cancelMediaDownloadJobs(
            mediaIds: allMediaIds,
            excluding: []
        )
    }

    /// The caller must first prove a live SQLCipher message_media reference in an authorized
    /// dialog. This only removes the process-local fence; it never creates authorization.
    func restoreAuthorizedAccess(mediaId: String) async throws -> MediaAccessRestoreLease {
        let cache = try resolvedCache()
        return await cache.restoreAuthorizedMedia(mediaId: mediaId)
    }

    func rollbackUnauthorizedAccess(_ lease: MediaAccessRestoreLease) async throws -> Bool {
        // Never lazily create or address a replacement session cache for an old lease.
        guard let cache, cache === lease.cache else { return false }
        #if DEBUG
        await rollbackHandoffGate?()
        #endif
        let rolledBack = try await cache.rollbackUnauthorizedMedia(lease)
        // The engine is reentrant across the cache-actor hop. A logout may have installed a new
        // cache while the old one was rolling back, so never hand that old success to presentation.
        guard self.cache === cache else { return false }
        return rolledBack
    }

    #if DEBUG
    func testSetRollbackHandoffGate(_ gate: (@Sendable () async -> Void)?) {
        rollbackHandoffGate = gate
    }

    func testInstallReplacementCache(_ replacement: EncryptedMediaCache) {
        precondition(cache == nil, "replacement cache requires completed teardown")
        cache = replacement
    }
    #endif

    func cacheUsageBytes() async -> Int64 {
        guard let cache else { return 0 }
        return (try? await cache.downloadedUsageBytes()) ?? 0
    }

    func cacheUsageBytes(localStore: CloudLocalStore) async -> Int64 {
        if !durableLedgerHydrated {
            try? await warmCache(localStore: localStore)
        } else {
            durableLocalStore = localStore
            try? await installBackgroundDownloadsIfNeeded()
        }
        return (try? await localStore.downloadedMediaUsageBytes()) ?? 0
    }

    func destroyLocalStateForLogout() async {
        let backgroundDownloads = backgroundDownloads
        self.backgroundDownloads = nil
        await backgroundDownloads?.cancelAllAndDeleteMetadata()
        if let cache { try? await cache.clearAll() }
        cache = nil
        durableLocalStore = nil
        durableLedgerHydrated = false
        interruptedDurableJobsRecovered = false
        backgroundDownloadsInstalled = false
        automaticDownloadsSuspendedForLowDisk = false
        autoDownloadQueue.removeAll(keepingCapacity: false)
        nextDownloadSequence = 0
    }

    private func temporaryPreview(data: Data, fileExtension: String?) async throws -> URL {
        let cache = try resolvedCache()
        return try await cache.createTemporaryPreview(data, fileExtension: fileExtension)
    }

    @discardableResult
    func temporaryPreview(
        data: Data,
        fileExtension: String?,
        transferOwnership: @escaping @Sendable (URL) async -> Bool
    ) async throws -> Bool {
        let url = try await temporaryPreview(data: data, fileExtension: fileExtension)
        do {
            try Task.checkCancellation()
            let transferred = await transferOwnership(url)
            if !transferred {
                await removeTemporaryPreview(url)
            }
            return transferred
        } catch {
            await removeTemporaryPreview(url)
            throw error
        }
    }

    func removeTemporaryPreview(_ url: URL) async { await cache?.removeTemporaryPreview(url) }

    nonisolated private static func pendingTransferId(_ mediaId: String) -> String? {
        let prefix = "pending:"
        guard mediaId.hasPrefix(prefix) else { return nil }
        let value = String(mediaId.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }
}

/// Owns a streaming `AVURLAsset` and the resource-loader delegate that feeds it (the asset retains
/// the delegate only weakly, so this owner must outlive playback). Hand `asset` to an `AVPlayerItem`.
nonisolated final class StreamingMediaAsset {
    let asset: AVURLAsset
    private let delegate: EncryptedMediaResourceLoader
    private let queue = DispatchQueue(label: "com.toj.media.resource-loader")
    private let mediaId: String
    private let engine: CloudMediaTransferEngine
    private var accessTask: Task<Void, Never>?

    init(
        media: CloudMedia,
        token: String,
        engine: CloudMediaTransferEngine,
        localStore: CloudLocalStore? = nil,
        startsAccessImmediately: Bool = true
    ) {
        self.mediaId = media.id
        self.engine = engine
        let ext = UTType(mimeType: media.contentType)?.preferredFilenameExtension ?? "mp4"
        let url = URL(string: "\(EncryptedMediaResourceLoader.scheme)://stream/\(UUID().uuidString).\(ext)")!
        asset = AVURLAsset(url: url)
        delegate = EncryptedMediaResourceLoader(
            media: media,
            token: token,
            engine: engine,
            localStore: localStore
        )
        asset.resourceLoader.setDelegate(delegate, queue: queue)
        if startsAccessImmediately {
            activateAccess()
        }
    }

    func activateAccess() {
        guard accessTask == nil else { return }
        let mediaId = mediaId
        let engine = engine
        accessTask = Task { await engine.beginMediaAccess(mediaId) }
    }

    deinit {
        let mediaId = mediaId
        let engine = engine
        let accessTask = accessTask
        Task {
            await accessTask?.value
            await engine.endMediaAccess(mediaId)
        }
    }
}

/// Bridges `AVPlayer`'s byte-range requests to the encrypted chunk store via `engine.byteRange`,
/// so video streams (plays before it is fully downloaded) straight from Toj's own chunk API.
/// Delegate callbacks are serialized on the loader queue supplied to `setDelegate(_:queue:)`.
nonisolated final class EncryptedMediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "toj-media"
    private let media: CloudMedia
    private let token: String
    private let engine: CloudMediaTransferEngine
    private let localStore: CloudLocalStore?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(
        media: CloudMedia,
        token: String,
        engine: CloudMediaTransferEngine,
        localStore: CloudLocalStore? = nil
    ) {
        self.media = media
        self.token = token
        self.engine = engine
        self.localStore = localStore
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let key = ObjectIdentifier(loadingRequest)
        let media = media, token = token, engine = engine, localStore = localStore
        tasks[key] = Task {
            do {
                if let info = loadingRequest.contentInformationRequest {
                    info.contentType = UTType(mimeType: media.contentType)?.identifier ?? UTType.mpeg4Movie.identifier
                    info.isByteRangeAccessSupported = true
                    info.contentLength = media.byteSize
                }
                if let dataRequest = loadingRequest.dataRequest {
                    var pos = dataRequest.currentOffset
                    let end = dataRequest.requestsAllDataToEndOfResource
                        ? media.byteSize
                        : dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
                    while pos < end {
                        try Task.checkCancellation()
                        let sliceLength = min(Int64(512 * 1024), end - pos)
                        let data = try await engine.byteRange(
                            media: media,
                            token: token,
                            offset: pos,
                            length: sliceLength,
                            localStore: localStore
                        )
                        if data.isEmpty { break }
                        dataRequest.respond(with: data)
                        pos += Int64(data.count)
                    }
                }
                loadingRequest.finishLoading()
            } catch is CancellationError {
                // The player abandoned this request (seek/teardown); nothing to report.
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        tasks[key]?.cancel()
        tasks[key] = nil
    }
}

enum MediaCacheError: LocalizedError {
    case unsupportedSize, thumbnailTooLarge, localQuotaExceeded, encryptionFailed, invalidState
    case uploadExpired, automaticDownloadDeferred, accessRevoked

    var errorDescription: String? {
        switch self {
        case .unsupportedSize: String(localized: "This file is empty or larger than 25 MB")
        case .thumbnailTooLarge: String(localized: "The media preview is too large")
        case .localQuotaExceeded: String(localized: "Toj needs more free media storage on this device")
        case .encryptionFailed: String(localized: "Could not encrypt the local media")
        case .invalidState: String(localized: "The media transfer could not be resumed")
        case .uploadExpired: String(localized: "The upload expired and must be restarted")
        case .automaticDownloadDeferred: String(localized: "Automatic media download was deferred")
        case .accessRevoked: String(localized: "Media access was revoked")
        }
    }
}

@MainActor
@Observable
final class VoiceNoteRecorder: NSObject, AVAudioRecorderDelegate {
    private(set) var isRecording = false
    private(set) var elapsedSeconds = 0
    private(set) var level: Float = 0
    var onUnexpectedStop: (() -> Void)?
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingURL: URL?
    private let recordingsDirectory: URL
    private var previousCategory: AVAudioSession.Category?
    private var previousMode: AVAudioSession.Mode?
    private var previousOptions: AVAudioSession.CategoryOptions = []

    override init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "TojVoiceRecordings", directoryHint: .isDirectory)
        recordingsDirectory = directory
        super.init()
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(stopForInterruption),
            name: AVAudioSession.interruptionNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(stopForInterruption),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(routeChanged(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func stopForInterruption() {
        guard isRecording else { return }
        cancel()
        onUnexpectedStop?()
    }

    @objc private func routeChanged(_ notification: Notification) {
        guard isRecording,
              let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .oldDeviceUnavailable || AVAudioSession.sharedInstance().availableInputs?.isEmpty == true
        else { return }
        cancel()
        onUnexpectedStop?()
    }

    func start() async throws {
        if isRecording { cancel() }
        let permission = await AVAudioApplication.requestRecordPermission()
        guard permission else { throw VoiceRecorderError.permissionDenied }
        let session = AVAudioSession.sharedInstance()
        previousCategory = session.category
        previousMode = session.mode
        previousOptions = session.categoryOptions
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let url = recordingsDirectory.appending(path: "toj-voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            try await Task.detached(priority: .utility) { [recordingsDirectory] in
                try Self.prepareRecordingsDirectory(recordingsDirectory)
                try Self.createProtectedRecordingFile(at: url)
            }.value
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                recorder.stop()
                throw VoiceRecorderError.couldNotStart
            }
            self.recorder = recorder
            recordingURL = url
            elapsedSeconds = 0
            level = 0
            isRecording = true
            timer = .scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    let decibels = recorder.averagePower(forChannel: 0)
                    self.level = max(0.03, min(1, pow(10, decibels / 32)))
                    self.elapsedSeconds = Int(recorder.currentTime)
                }
            }
        } catch {
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    nonisolated private static func prepareRecordingsDirectory(_ inputDirectory: URL) throws {
        let fileManager = FileManager.default
        let directory = inputDirectory
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(values)
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try? fileManager.removeItem(at: url)
        }
    }

    nonisolated static func createProtectedRecordingFile(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.createFile(
            atPath: url.path,
            contents: Data(),
            attributes: [.protectionKey: FileProtectionType.complete]
        ) else {
            throw VoiceRecorderError.couldNotStart
        }
    }

    func finish() async throws -> (data: Data, durationMs: Int64) {
        guard let recorder, let url = recordingURL else { throw VoiceRecorderError.notRecording }
        let duration = Int64(recorder.currentTime * 1_000)
        stopSession()
        let data = try await Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: url) }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }.value
        guard duration >= 300, !data.isEmpty else { throw VoiceRecorderError.tooShort }
        return (data, duration)
    }

    func cancel() {
        recorder?.stop()
        if let recordingURL {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: recordingURL)
            }
        }
        stopSession()
    }

    private func stopSession() {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        recordingURL = nil
        isRecording = false
        elapsedSeconds = 0
        level = 0
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if let previousCategory, let previousMode {
            try? session.setCategory(previousCategory, mode: previousMode, options: previousOptions)
        }
        previousCategory = nil
        previousMode = nil
        previousOptions = []
    }
}

enum VoiceRecorderError: LocalizedError, Equatable {
    case permissionDenied, couldNotStart, notRecording, tooShort
    var errorDescription: String? {
        switch self {
        case .permissionDenied: String(localized: "Microphone access is required for voice messages")
        case .couldNotStart: String(localized: "Could not start recording")
        case .notRecording: String(localized: "No recording is active")
        case .tooShort: String(localized: "Hold a little longer to record a voice message")
        }
    }
}
