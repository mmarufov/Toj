import Foundation
import GRDB
import os
import Security

nonisolated struct LocalMessage: Identifiable, Equatable, Sendable {
    let localId: String
    var id: String { localId }
    let dialogId: String
    let msgId: Int64?
    let clientMsgId: String
    let senderAccountId: String
    let senderDisplayName: String?
    let kind: String
    let text: String
    let replyToMsgId: Int64?
    let forwardedFromAccountId: String?
    let forwardedFromDialogId: String?
    let forwardedFromMsgId: Int64?
    let isForwarded: Bool
    let reactions: [CloudReaction]
    let mentions: [CloudMention]
    let media: CloudMedia?
    var mediaGroupId: String? = nil
    var mediaGroupIndex: Int? = nil
    var mediaGroupCount: Int? = nil
    let serviceType: String?
    let serviceData: CloudServiceData?
    var linkPreview: CloudLinkPreview? = nil
    let editVersion: Int
    let state: String
    let serverTs: String?
    let localState: String
}

nonisolated struct LocalDialog: Identifiable, Equatable, Sendable {
    let dialogId: String
    var id: String { dialogId }
    let type: String
    let title: String?
    let photo: CloudMedia?
    let lastMsgId: Int64
    let updatedAt: String
    let lastText: String?
    let lastKind: String?
    let lastState: String?
    let lastSenderAccountId: String?
    let lastLocalState: String?
    let lastServerTs: String?
    let unreadCount: Int
    let mentionCount: Int
    let peerAccountId: String?
    let peerBio: String?
    let peerBirthday: String?
    let peerColorIndex: Int?
    let revision: Int64
    let memberCount: Int
    let selfRole: String?
    let notificationMode: String
    let accessState: String
    var draftText: String? = nil
    var draftAttachmentCount: Int = 0
    var hasDraftReply: Bool = false
    let isPinned: Bool
    let pinnedAt: String?
    let isMuted: Bool
    let isArchived: Bool
}

nonisolated struct LocalPresenceSnapshot: Equatable, Sendable {
    let observerAccountId: String
    let subjectAccountId: String
    let lastSeenAt: String?
    let revision: Int64
}

nonisolated struct LocalDraftAttachment: Identifiable, Equatable, Sendable {
    let attachmentId: String
    var id: String { attachmentId }
    let mediaId: String?
    let position: Int
    let media: CloudMedia?
    let transferId: String?
    let state: String
    let progress: Double
    let lastError: String?
}

nonisolated struct LocalDraft: Identifiable, Equatable, Sendable {
    var id: String { "\(accountId)|\(dialogId)" }
    let accountId: String
    let dialogId: String
    let state: String
    let text: String
    let replyToMsgId: Int64?
    let replyPreview: CloudDraftReplyPreview?
    let mentions: [CloudMention]
    let attachments: [LocalDraftAttachment]
    let localGeneration: Int64
    let operationId: String
    let serverRevision: Int64
    let terminal: Bool
    let lastError: String?
    let updatedAt: String
}

nonisolated struct PendingDraftMutation: Identifiable, Equatable, Sendable {
    var id: String { "\(accountId)|\(dialogId)" }
    let accountId: String
    let dialogId: String
    let operationId: String
    let localGeneration: Int64
    let state: String
    let text: String
    let replyToMsgId: Int64?
    let mentions: [CloudMention]
    let attachments: [DraftAttachmentRequest]
    let retryCount: Int
    let nextRetryAt: String?
    let lastError: String?
    let terminal: Bool
}

nonisolated struct PendingMediaGroupSend: Identifiable, Equatable, Sendable {
    let clientGroupId: String
    var id: String { clientGroupId }
    let accountId: String
    let dialogId: String
    let payload: PendingMediaGroupPayload
    var draftConsumeOperationId: String? = nil
    let retryCount: Int
    let nextRetryAt: String?
    let lastError: String?
    let terminal: Bool
}

nonisolated struct PendingMediaGroupItem: Codable, Equatable, Sendable {
    let clientMsgId: String
    let mediaId: String
    let transferId: String
    let media: CloudMedia
}

nonisolated struct PendingMediaGroupPayload: Codable, Equatable, Sendable {
    let items: [PendingMediaGroupItem]
    let caption: String
    let replyToMsgId: Int64?
    let mentions: [CloudMention]
    let silent: Bool

    init(
        items: [PendingMediaGroupItem],
        caption: String,
        replyToMsgId: Int64?,
        mentions: [CloudMention],
        silent: Bool = false
    ) {
        self.items = items
        self.caption = caption
        self.replyToMsgId = replyToMsgId
        self.mentions = mentions
        self.silent = silent
    }

    enum CodingKeys: String, CodingKey {
        case items, caption, replyToMsgId, mentions, silent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([PendingMediaGroupItem].self, forKey: .items)
        caption = try container.decode(String.self, forKey: .caption)
        replyToMsgId = try container.decodeIfPresent(Int64.self, forKey: .replyToMsgId)
        mentions = try container.decodeIfPresent([CloudMention].self, forKey: .mentions) ?? []
        silent = try container.decodeIfPresent(Bool.self, forKey: .silent) ?? false
    }
}

nonisolated struct PendingMediaGroupCleanup: Identifiable, Equatable, Sendable {
    let clientGroupId: String
    var id: String { clientGroupId }
    let transferIds: [String]
}

nonisolated struct StoredDraftMutationPayload: Codable {
    let state: String
    let text: String
    let replyToMsgId: Int64?
    let mentions: [CloudMention]
    let attachments: [DraftAttachmentRequest]
}

nonisolated struct PendingGroupCreation: Identifiable, Equatable, Sendable {
    let groupId: String
    var id: String { groupId }
    let title: String
    let memberIds: [String]
    let localPhotoReference: String?
    let state: String
    let retryCount: Int
    let nextRetryAt: String?
    let lastError: String?
    let terminal: Bool
}

nonisolated struct PendingGroupMutation: Identifiable, Equatable, Sendable {
    let clientMutationId: String
    var id: String { clientMutationId }
    let dialogId: String
    let operation: String
    let payloadJSON: String
    let retryCount: Int
    let nextRetryAt: String?
    let lastError: String?
    let terminal: Bool
    let localOrder: Int64
    let attemptedAt: String?
}

nonisolated enum DialogPreferenceField: String, CaseIterable, Sendable {
    case pinned
    case muted
    case archived
}

nonisolated struct PendingDialogPreferenceMutation: Identifiable, Equatable, Sendable {
    var id: String { clientMutationId }
    let accountId: String
    let dialogId: String
    let field: DialogPreferenceField
    let desiredValue: Bool
    let clientMutationId: String
    let retryCount: Int
    let nextRetryAt: String?
    let acknowledgedPts: Int64?
    let lastError: String?
    let localOrder: Int64
    let attemptedAt: String?
    let dormant: Bool
}

nonisolated struct LocalLaunchSnapshot: Equatable, Sendable {
    let pts: Int64
    let dialogs: [LocalDialog]
}

nonisolated struct MediaPresentationAuthorization: Equatable, Sendable {
    let dialogId: String
    let mediaId: String
    let accessGeneration: Int64
}

nonisolated struct PendingOutboxItem: Identifiable, Equatable, Sendable {
    let clientMsgId: String
    var id: String { clientMsgId }
    let dialogId: String
    let body: String
    let replyToMsgId: Int64?
    let forwardedFromDialogId: String?
    let forwardedFromMsgId: Int64?
    var mentions: [CloudMention] = []
    var draftConsumeOperationId: String? = nil
    var silent = false
    let retryCount: Int
    let nextRetryAt: String?
}

nonisolated enum InvalidReplyTextRecovery: Equatable, Sendable {
    case restoredDraft(dialogId: String)
    case keptFailedMessage(dialogId: String)
}

nonisolated struct PendingReadReceipt: Identifiable, Equatable, Sendable {
    var id: String { "\(accountId)|\(dialogId)" }
    let dialogId: String
    let accountId: String
    let maxReadMsgId: Int64
    let retryCount: Int
    let nextRetryAt: String?
}

nonisolated struct PendingMessageMutation: Identifiable, Equatable, Sendable {
    let clientMutationId: String
    var id: String { clientMutationId }
    let operation: String
    let dialogId: String
    let msgId: Int64
    let body: String?
    let expectedEditVersion: Int?
    let emoji: String?
    let retryCount: Int
    let nextRetryAt: String?
    let lastError: String?
}

nonisolated struct MediaTransferRecord: Identifiable, Equatable, Sendable {
    let transferId: String
    var id: String { transferId }
    let dialogId: String
    let clientMsgId: String
    let caption: String
    let replyToMsgId: Int64?
    var purpose: String = "message"
    var draftOperationId: String? = nil
    var mentions: [CloudMention] = []
    var silent: Bool = false
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
    let mediaId: String?
    let uploadOffset: Int64
    let state: String
    let retryCount: Int
    let nextRetryAt: String?
    let lastError: String?
    let terminal: Bool

    var media: CloudMedia {
        return CloudMedia(
            id: mediaId ?? "pending:\(transferId)", kind: kind, contentType: contentType, fileName: fileName,
            byteSize: byteSize, durationMs: durationMs, width: width, height: height,
            hasThumbnail: encryptedThumbnailPath != nil
        )
    }
}

nonisolated struct PendingProfilePhotoMutation: Identifiable, Equatable, Sendable {
    var id: String { clientMutationId }
    let accountId: String
    let clientMutationId: String
    let basePhotoRevision: Int64
    let operation: String
    let transferId: String?
    let mediaId: String?
    let source: String
    let state: String
    let retryCount: Int
    let nextRetryAt: String?
    let lastError: String?
    let terminal: Bool
}

nonisolated struct TimelineWindow: Equatable, Sendable {
    static let initialLimit = 120
    static let pageLimit = 80
    static let maximumRetainedMessages = 400

    let beforeMsgId: Int64?
    let afterMsgId: Int64?
    let limit: Int

    static let initial = TimelineWindow(beforeMsgId: nil, afterMsgId: nil, limit: initialLimit)

    static func earlier(beforeMsgId: Int64) -> TimelineWindow {
        TimelineWindow(beforeMsgId: beforeMsgId, afterMsgId: nil, limit: pageLimit)
    }

    init(beforeMsgId: Int64? = nil, afterMsgId: Int64? = nil, limit: Int = initialLimit) {
        self.beforeMsgId = beforeMsgId
        self.afterMsgId = afterMsgId
        self.limit = max(1, min(limit, Self.maximumRetainedMessages))
    }
}

nonisolated struct TimelineSnapshot: Equatable, Sendable {
    let messages: [LocalMessage]
    let oldestServerMsgId: Int64?
    let newestServerMsgId: Int64?
    let hasEarlierLocalMessages: Bool
    let hasLaterLocalMessages: Bool
}

/// The complete local input required to present one conversation. GRDB produces this value from a
/// single read transaction, so the first frame cannot mix messages from one database revision with
/// mutations, transfers, or read cursors from another.
nonisolated struct ConversationLocalSnapshot: Equatable, Sendable {
    let timeline: TimelineSnapshot
    let mutations: [PendingMessageMutation]
    let transfers: [MediaTransferRecord]
    let peerReadMsgId: Int64
    let historyState: DialogHistoryState?
}

nonisolated enum TimelineAnchor: Equatable, Sendable {
    /// The semantic unread watermark is known, but the actual first incoming row has not yet been
    /// proven from a contiguous local history range. The UI may render cached content immediately
    /// while targeted forward hydration resolves this into `firstUnread`.
    case provisionalFirstUnread(msgId: Int64)
    case firstUnread(msgId: Int64)
    case saved(msgId: Int64)
    case bottom
}

nonisolated struct ChatViewportState: Equatable, Sendable {
    let dialogId: String
    let accountId: String
    let topVisibleMsgId: Int64?
    let wasAtBottom: Bool
    let updatedAt: String

    init(
        dialogId: String,
        accountId: String,
        topVisibleMsgId: Int64?,
        wasAtBottom: Bool,
        updatedAt: String = CloudLocalStore.sqliteTimestamp(Date())
    ) {
        self.dialogId = dialogId
        self.accountId = accountId
        self.topVisibleMsgId = topVisibleMsgId
        self.wasAtBottom = wasAtBottom
        self.updatedAt = updatedAt
    }
}

nonisolated struct DialogHistoryState: Equatable, Sendable {
    let dialogId: String
    let ceilingMsgId: Int64
    let nextBeforeMsgId: Int64?
    let historyComplete: Bool
    let retryCount: Int
    let nextRetryAt: String?
    let updatedAt: String

    init(
        dialogId: String,
        ceilingMsgId: Int64,
        nextBeforeMsgId: Int64?,
        historyComplete: Bool,
        retryCount: Int = 0,
        nextRetryAt: String? = nil,
        updatedAt: String = CloudLocalStore.sqliteTimestamp(Date())
    ) {
        self.dialogId = dialogId
        self.ceilingMsgId = ceilingMsgId
        self.nextBeforeMsgId = nextBeforeMsgId
        self.historyComplete = historyComplete
        self.retryCount = retryCount
        self.nextRetryAt = nextRetryAt
        self.updatedAt = updatedAt
    }
}

nonisolated struct ReplicaBootstrapState: Equatable, Sendable {
    let accountId: String
    let token: String?
    let nextCursor: String?
    let snapshotPts: Int64
    let status: String
    let mode: ReplicaBootstrapMode
    let updatedAt: String
}

nonisolated enum ReplicaBootstrapMode: String, Equatable, Sendable {
    /// Used for a device with no published replica. Pages are committed to the live tables as they
    /// arrive so the first page can render without waiting for the entire account snapshot.
    case initial

    /// Used when replacing an existing replica. Pages remain in staging tables until the complete
    /// snapshot can be merged atomically, keeping the old replica readable throughout the fetch.
    case replacement
}

nonisolated enum CloudLocalStoreBootstrapError: LocalizedError, Equatable, Sendable {
    case notInProgress
    case invalidStagedMessage
    case invalidGroupState

    var errorDescription: String? {
        switch self {
        case .notInProgress:
            return "No local replica bootstrap is in progress"
        case .invalidStagedMessage:
            return "The staged local replica contains an invalid message"
        case .invalidGroupState:
            return "The local group state is invalid"
        }
    }
}

nonisolated enum CloudLocalStoreAccessError: LocalizedError, Equatable, Sendable {
    case revoked

    var errorDescription: String? {
        String(localized: "The dialog is no longer authorized for this account")
    }
}

nonisolated struct StagedBootstrapSnapshot: Sendable {
    let dialogs: [BootstrapDialog]
    let profiles: [CloudProfile]
}

nonisolated struct MessageMediaRecord: Equatable, Sendable {
    let localId: String
    let dialogId: String
    let msgId: Int64?
    let media: CloudMedia
}

nonisolated struct MediaCacheEntry: Equatable, Sendable {
    let mediaId: String
    let variant: String
    let encryptedPath: String
    let byteSize: Int64
    let cachedBytes: Int64
    let contiguousOffset: Int64
    let state: String
    let lastAccessedAt: String
    let protectedUntil: String?
}

nonisolated enum AccessPurgePhase: String, Equatable, Sendable {
    case staged
    case filesDeleted = "files_deleted"
}

nonisolated struct AccessPurgeJob: Equatable, Sendable, Identifiable {
    let id: String
    let dialogId: String
    let allMediaIds: Set<String>
    let purgeMediaIds: Set<String>
    let encryptedPaths: Set<String>
    let phase: AccessPurgePhase
    let attempts: Int
    let lastError: String?
}

nonisolated enum MediaDownloadJobState: String, Equatable, Sendable {
    case queued
    case downloading
    case paused
    case completed
    case failed
}

nonisolated enum LocalStoreOpenError: LocalizedError, Sendable {
    case integrityCheckFailed

    var errorDescription: String? {
        switch self {
        case .integrityCheckFailed:
            "The encrypted local replica failed its integrity check"
        }
    }
}

nonisolated struct MediaDownloadJobRecord: Equatable, Sendable {
    let mediaId: String
    let variant: String
    let dialogId: String?
    let priority: Int
    let state: MediaDownloadJobState
    let userInitiated: Bool
    let retryCount: Int
    let nextRetryAt: String?
    let lastError: String?
    let updatedAt: String
}

nonisolated final class AsyncObservationBox<Element>: @unchecked Sendable {
    let values: AsyncValueObservation<Element>

    init(_ values: AsyncValueObservation<Element>) {
        self.values = values
    }
}
