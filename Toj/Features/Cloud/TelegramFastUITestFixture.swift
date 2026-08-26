#if DEBUG
import AVFoundation
import CoreVideo
import Foundation
import UIKit

enum TelegramFastUITestFixture {
    static let accountId = "00000000-0000-4000-8000-000000000101"
    static let peerAccountId = "00000000-0000-4000-8000-000000000102"
    static let secondPeerAccountId = "00000000-0000-4000-8000-000000000103"
    static let primaryDialogId = "00000000-0000-4000-8000-000000000201"
    static let secondDialogId = "00000000-0000-4000-8000-000000000202"
    static let savedDialogId = "00000000-0000-4000-8000-000000000203"
    static let photoMediaId = "00000000-0000-4000-8000-000000000301"
    static let videoMediaId = "00000000-0000-4000-8000-000000000302"

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["TOJ_UI_FIXTURE"] == "telegram-fast"
    }

    static var resetsStorage: Bool {
        ProcessInfo.processInfo.environment["TOJ_UI_FIXTURE_RESET"] == "1"
    }

    static var usesSingleAttachmentDraft: Bool {
        ProcessInfo.processInfo.environment["TOJ_UI_FIXTURE_SINGLE_DRAFT"] == "1"
    }

    static var presenceScenario: String? {
        ProcessInfo.processInfo.environment["TOJ_UI_FIXTURE_PRESENCE"]
    }

    static var session: StoredCloudSession {
        StoredCloudSession(
            session: CloudSession(
                accountId: accountId,
                deviceId: "00000000-0000-4000-8000-000000000401",
                token: "ui-fixture-token-never-sent"
            ),
            phone: "+992 000 00 00 00",
            displayName: "UI Fixture"
        )
    }

    static func reset() throws {
        try? CloudLocalStore.destroyDefaultStore()
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let fixtureRoot = support.appending(path: "TojUITest", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: fixtureRoot.path) {
            try FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    static func install(into store: CloudLocalStore) async throws {
        let existing = try await store.messages(dialogId: primaryDialogId)
        if existing.contains(where: { $0.clientMsgId == "ui-fixture-video" }) {
            try await ensureDialogMetadata(in: store)
            try await applyRemoteClearIfRequested(to: store)
            return
        }

        let photoData = try makePhotoData()
        let posterData = try makePosterData()
        let videoData = try await makeVideoData()
        let photo = CloudMedia(
            id: photoMediaId,
            kind: "photo",
            contentType: "image/jpeg",
            fileName: "offline-photo.jpg",
            byteSize: Int64(photoData.count),
            durationMs: nil,
            width: 1_200,
            height: 800,
            hasThumbnail: true
        )
        let video = CloudMedia(
            id: videoMediaId,
            kind: "video",
            contentType: "video/mp4",
            fileName: "offline-video.mp4",
            byteSize: Int64(videoData.count),
            durationMs: 1_000,
            width: 320,
            height: 180,
            hasThumbnail: true
        )
        let timestamps = [
            "2026-07-18T20:00:00Z",
            "2026-07-18T20:01:00Z",
            "2026-07-18T20:02:00Z",
            "2026-07-18T20:03:00Z",
            "2026-07-18T20:04:00Z",
            "2026-07-18T20:04:01Z",
        ]
        try await ensureDialogMetadata(in: store)
        try await store.applyHistoryPage(HistoryPageResponse(
            dialogId: primaryDialogId,
            messages: [
                CloudMessage(
                    dialogId: primaryDialogId,
                    msgId: 1,
                    senderAccountId: peerAccountId,
                    clientMsgId: "ui-fixture-text",
                    kind: "text",
                    text: "This conversation opened entirely from SQLCipher.",
                    editVersion: 0,
                    state: "visible",
                    serverTs: timestamps[0]
                ),
                CloudMessage(
                    dialogId: primaryDialogId,
                    msgId: 2,
                    senderAccountId: peerAccountId,
                    clientMsgId: "ui-fixture-photo",
                    kind: "photo",
                    text: "Saved photo — opens offline",
                    media: photo,
                    editVersion: 0,
                    state: "visible",
                    serverTs: timestamps[1]
                ),
                CloudMessage(
                    dialogId: primaryDialogId,
                    msgId: 3,
                    senderAccountId: accountId,
                    clientMsgId: "ui-fixture-video",
                    kind: "video",
                    text: "Saved video — encrypted on disk",
                    media: video,
                    editVersion: 0,
                    state: "visible",
                    serverTs: timestamps[2]
                ),
                CloudMessage(
                    dialogId: primaryDialogId,
                    msgId: 4,
                    senderAccountId: peerAccountId,
                    clientMsgId: "ui-fixture-latest",
                    kind: "text",
                    text: "Latest saved message",
                    editVersion: 0,
                    state: "visible",
                    serverTs: timestamps[3]
                ),
                CloudMessage(
                    dialogId: primaryDialogId,
                    msgId: 5,
                    senderAccountId: peerAccountId,
                    clientMsgId: "ui-fixture-partial-album-0",
                    kind: "photo",
                    text: "Partially delivered album",
                    media: photo,
                    mediaGroupId: "00000000-0000-4000-8000-000000000601",
                    mediaGroupIndex: 0,
                    mediaGroupCount: 3,
                    editVersion: 0,
                    state: "visible",
                    serverTs: timestamps[4]
                ),
                CloudMessage(
                    dialogId: primaryDialogId,
                    msgId: 6,
                    senderAccountId: peerAccountId,
                    clientMsgId: "ui-fixture-partial-album-2",
                    kind: "video",
                    text: "",
                    media: video,
                    mediaGroupId: "00000000-0000-4000-8000-000000000601",
                    mediaGroupIndex: 2,
                    mediaGroupCount: 3,
                    editVersion: 0,
                    state: "visible",
                    serverTs: timestamps[5]
                ),
            ],
            nextBeforeMsgId: nil,
            hasMore: false
        ))
        try await store.applyHistoryPage(HistoryPageResponse(
            dialogId: secondDialogId,
            messages: [CloudMessage(
                dialogId: secondDialogId,
                msgId: 1,
                senderAccountId: secondPeerAccountId,
                clientMsgId: "ui-fixture-second-chat",
                kind: "text",
                text: "Second saved conversation",
                editVersion: 0,
                state: "visible",
                serverTs: "2026-07-18T19:59:00Z"
            )],
            nextBeforeMsgId: nil,
            hasMore: false
        ))

        let cache = try EncryptedMediaCache(
            policy: MediaCachePolicy(sizeLimit: .unlimited, retention: .forever)
        )
        try await cache.storeThumbnail(photoData, mediaId: photo.id)
        try await cache.storeDownloadChunk(photoData, mediaId: photo.id, offset: 0)
        try await cache.storeRepresentation(photoData, mediaId: photo.id, variant: .bubble720)
        try await cache.storeRepresentation(photoData, mediaId: photo.id, variant: .screen2048)
        try await cache.storeThumbnail(posterData, mediaId: video.id)
        try await cache.storeDownloadChunk(videoData, mediaId: video.id, offset: 0)
        try await cache.storeRepresentation(posterData, mediaId: video.id, variant: .videoPoster)
        for media in [photo, video] {
            for entry in try await cache.durableEntries(media: media) {
                try await store.upsertMediaCacheEntry(entry)
            }
        }
        try await seedPersistentDraft(in: store, photo: photo, video: video)
        try await seedFailedAlbum(in: store)
        try await applyRemoteClearIfRequested(to: store)
    }

    private static func seedPersistentDraft(
        in store: CloudLocalStore,
        photo: CloudMedia,
        video: CloudMedia
    ) async throws {
        let file = CloudMedia(
            id: "00000000-0000-4000-8000-000000000303",
            kind: "file",
            contentType: "application/pdf",
            fileName: "offline-notes.pdf",
            byteSize: 512,
            durationMs: nil,
            width: nil,
            height: nil,
            hasThumbnail: false
        )
        try await store.applyCloudDraft(
            CloudDraft(
                dialogId: primaryDialogId,
                revision: 100,
                state: "active",
                text: "Persistent exact draft  ",
                replyToMsgId: 1,
                replyPreview: CloudDraftReplyPreview(
                    msgId: 1,
                    senderAccountId: peerAccountId,
                    text: "This conversation opened entirely from SQLCipher.",
                    unavailable: false
                ),
                mentions: [],
                attachments: (usesSingleAttachmentDraft ? [photo] : [photo, video, file])
                    .enumerated().map { index, media in
                    CloudDraftAttachment(
                        attachmentId: "ui-draft-\(index)",
                        mediaId: media.id,
                        position: index,
                        media: media
                    )
                },
                operationId: "00000000-0000-4000-8000-000000000501",
                updatedAt: "2026-07-18T20:04:00Z"
            ),
            accountId: accountId
        )
    }

    private static func seedFailedAlbum(in store: CloudLocalStore) async throws {
        let media = (0..<2).map { index in
            CloudMedia(
                id: "00000000-0000-4000-8000-00000000030\(index + 4)",
                kind: "file",
                contentType: "application/pdf",
                fileName: "failed-\(index + 1).pdf",
                byteSize: 512,
                durationMs: nil,
                width: nil,
                height: nil,
                hasThumbnail: false
            )
        }
        let operationId = "00000000-0000-4000-8000-000000000503"
        try await store.applyCloudDraft(
            CloudDraft(
                dialogId: secondDialogId,
                revision: 200,
                state: "active",
                text: "Recoverable failed album",
                replyToMsgId: nil,
                replyPreview: nil,
                mentions: [],
                attachments: media.enumerated().map { index, item in
                    CloudDraftAttachment(
                        attachmentId: "ui-failed-\(index)",
                        mediaId: item.id,
                        position: index,
                        media: item
                    )
                },
                operationId: operationId,
                updatedAt: "2026-07-18T20:06:00Z"
            ),
            accountId: accountId
        )
        let group = try await store.consumeDraftAsMediaGroup(
            accountId: accountId,
            dialogId: secondDialogId,
            operationId: operationId
        )
        try await store.markMediaGroupSendFailed(
            clientGroupId: group.clientGroupId,
            error: "fixture network failure",
            retryAfter: nil,
            terminal: false
        )
    }

    private static func applyRemoteClearIfRequested(to store: CloudLocalStore) async throws {
        guard ProcessInfo.processInfo.environment["TOJ_UI_FIXTURE_REMOTE_CLEAR"] == "1" else {
            return
        }
        try await store.applyCloudDraft(
            CloudDraft(
                dialogId: primaryDialogId,
                revision: 101,
                state: "cleared",
                text: "",
                replyToMsgId: nil,
                replyPreview: nil,
                mentions: [],
                attachments: [],
                operationId: "00000000-0000-4000-8000-000000000502",
                updatedAt: "2026-07-18T20:05:00Z"
            ),
            accountId: accountId
        )
    }

    private static func ensureDialogMetadata(in store: CloudLocalStore) async throws {
        try await store.savePts(4, accountId: accountId)
        try await store.ensureSavedDialog(
            dialogId: savedDialogId,
            accountId: accountId,
            updatedAt: "2026-07-18T20:04:00Z"
        )
        try await store.applyHistoryPage(HistoryPageResponse(
            dialogId: savedDialogId,
            messages: [CloudMessage(
                dialogId: savedDialogId,
                msgId: 1,
                senderAccountId: accountId,
                clientMsgId: "ui-fixture-saved-note",
                kind: "text",
                text: "Saved Messages opens from encrypted local storage.",
                editVersion: 0,
                state: "visible",
                serverTs: "2026-07-18T20:04:00Z"
            )],
            nextBeforeMsgId: nil,
            hasMore: false
        ))
        try await store.upsertDialog(
            dialogId: primaryDialogId,
            title: "Mehrona Offline",
            lastMsgId: 4,
            updatedAt: "2026-07-18T20:03:00Z"
        )
        try await store.saveMembers(dialogId: primaryDialogId, members: [
            BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 4),
            BootstrapDialogMember(accountId: peerAccountId, role: "member", lastReadMsgId: 4),
        ])
        try await store.upsertDialog(
            dialogId: secondDialogId,
            title: "Firooz Saved",
            lastMsgId: 1,
            updatedAt: "2026-07-18T19:59:00Z"
        )
        try await store.saveMembers(dialogId: secondDialogId, members: [
            BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 1),
            BootstrapDialogMember(accountId: secondPeerAccountId, role: "member", lastReadMsgId: 1),
        ])
    }

    private static func makePhotoData() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 1_200, height: 800),
            format: format
        ).image { context in
            UIColor(red: 0.04, green: 0.08, blue: 0.13, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 800))
            UIColor(red: 0.86, green: 0.67, blue: 0.22, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 330, y: 130, width: 540, height: 540))
            let text = "TOJ OFFLINE"
            text.draw(
                at: CGPoint(x: 420, y: 370),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 54, weight: .bold),
                    .foregroundColor: UIColor.black,
                ]
            )
        }
        guard let data = image.jpegData(compressionQuality: 0.86) else {
            throw FixtureError.encodingFailed
        }
        return data
    }

    private static func makePosterData() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 640, height: 360),
            format: format
        ).image { context in
            UIColor(red: 0.12, green: 0.05, blue: 0.18, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            let symbol = UIImage(
                systemName: "play.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 92, weight: .bold)
            )?.withTintColor(.white, renderingMode: .alwaysOriginal)
            symbol?.draw(at: CGPoint(x: 280, y: 134))
        }
        guard let data = image.jpegData(compressionQuality: 0.82) else {
            throw FixtureError.encodingFailed
        }
        return data
    }

    private static func makeVideoData() async throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "toj-ui-fixture-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 180,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 180,
            ]
        )
        guard writer.canAdd(input) else { throw FixtureError.encodingFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.encodingFailed }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<15 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                320,
                180,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw FixtureError.encodingFailed
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let address = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                for y in 0..<180 {
                    let row = address.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
                    for x in 0..<320 {
                        let red = UInt32((x + frame * 8) % 256)
                        let green = UInt32((y * 2) % 256)
                        row[x] = 0xff00_0000 | (red << 16) | (green << 8) | 0x45
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 15)) else {
                throw writer.error ?? FixtureError.encodingFailed
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? FixtureError.encodingFailed
        }
        return try Data(contentsOf: url)
    }

    private enum FixtureError: Error {
        case encodingFailed
    }
}
#endif
