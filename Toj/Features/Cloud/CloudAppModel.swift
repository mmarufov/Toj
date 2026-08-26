import Foundation
import Observation
import UIKit

nonisolated enum ReplicaConnectivityState: Equatable, Sendable {
    case unknown
    case checking
    case reachable
    case offline
    case serverUnavailable
    case sessionExpired
    case configurationError
}

nonisolated enum ReplicaSyncFailureReason: Equatable, Sendable {
    case slowConnection
    case serverUnavailable
    case protocolFailure
    case localReplicaFailure
    case configuration
}

nonisolated enum ReplicaUpdatePhase: Equatable, Sendable {
    case idle
    case checkingRemoteState
    case catchingUp(appliedBatches: Int)
    case upToDate
    case stalled(reason: ReplicaSyncFailureReason)
}

nonisolated struct ReplicaSyncSnapshot: Equatable, Sendable {
    let connectivity: ReplicaConnectivityState
    let updatePhase: ReplicaUpdatePhase
    let lastSuccessfulServerContact: Date?
}

nonisolated enum ReplicaSyncState: Equatable, Sendable {
    case checking
    case updating
    case ready
    case offline
    case connectionSlow
    case serverUnavailable
    case sessionExpired
    case protocolFailure
    case localFailure
    case configurationError

    var title: String {
        switch self {
        case .checking: String(localized: "Checking connection…")
        case .updating: String(localized: "Updating chats…")
        case .ready: String(localized: "Chats are up to date")
        case .offline: String(localized: "Offline — showing saved chats")
        case .connectionSlow: String(localized: "Connection is slow — showing saved chats")
        case .serverUnavailable: String(localized: "Server unavailable — showing saved chats")
        case .sessionExpired: String(localized: "Session expired — saved chats remain available")
        case .protocolFailure: String(localized: "Update could not be read — showing saved chats")
        case .localFailure: String(localized: "Saved chats need repair")
        case .configurationError: String(localized: "Server configuration needs attention")
        }
    }

    var systemImage: String {
        switch self {
        case .checking: "network"
        case .updating: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle.fill"
        case .offline: "wifi.slash"
        case .connectionSlow: "hourglass"
        case .serverUnavailable: "exclamationmark.icloud"
        case .sessionExpired: "person.crop.circle.badge.exclamationmark"
        case .protocolFailure: "exclamationmark.triangle"
        case .localFailure: "externaldrive.badge.exclamationmark"
        case .configurationError: "gear.badge.xmark"
        }
    }

    var showsProgress: Bool { self == .checking || self == .updating }
    var showsRetry: Bool {
        switch self {
        case .offline, .connectionSlow, .serverUnavailable, .protocolFailure, .localFailure:
            true
        case .checking, .updating, .ready, .sessionExpired, .configurationError:
            false
        }
    }
}

nonisolated enum ConversationOpenState: Equatable, Sendable {
    case cached
    case loadingLocal
    case ready
    case empty
    case failedLocal
}

nonisolated private enum ReplicaStateProbeOutcome: Sendable {
    case succeeded(SyncStateResponse)
    case failed(ReplicaSyncState)
    case timedOut
    case cancelled
}

@MainActor
@Observable
final class CloudAppModel {
    static let shared = CloudAppModel()
    nonisolated static let foregroundSyncTimeoutSeconds: TimeInterval = 15

    struct ContactIdentity: Equatable, Sendable {
        let accountId: String
        let displayName: String
        let bio: String?
        let birthday: String?
        let colorIndex: Int?

        init(
            accountId: String,
            displayName: String,
            bio: String? = nil,
            birthday: String? = nil,
            colorIndex: Int? = nil
        ) {
            self.accountId = accountId
            self.displayName = displayName
            self.bio = bio
            self.birthday = birthday
            self.colorIndex = colorIndex
        }
    }

    struct GroupMember: Identifiable, Equatable, Sendable {
        let accountId: String
        let displayName: String
        var photo: CloudMedia? = nil
        let role: String
        let isActive: Bool
        var id: String { accountId }
    }

    private struct DraftMention: Equatable, Sendable {
        let accountId: String
        let token: String
    }

    private struct GroupMutationPayload: Codable, Sendable {
        var title: String? = nil
        var memberIds: [String]? = nil
        var accountId: String? = nil
        var role: String? = nil
        var mode: String? = nil
        var successorAccountId: String? = nil
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
        var opensSettings = false

        static func == (lhs: Notice, rhs: Notice) -> Bool {
            lhs.id == rhs.id
        }
    }

    struct Dialog: Identifiable, Equatable {
        let id: String
        let title: String
        var photo: CloudMedia? = nil
        var type = "direct"
        var subtitle: String
        var updatedAt: String
        var isPending: Bool
        var unreadCount: Int
        var draftPreview: String? = nil
        var isPinned = false
        var pinnedAt: String? = nil
        var isMuted = false
        var isArchived = false
        var mentionCount = 0
        var previewKind: ChatListPreviewKind = .text
        var lastMessageMine = false
        var peerAccountId: String? = nil
        var peerBio: String? = nil
        var peerBirthday: String? = nil
        var profileColorIndex: Int? = nil
        var memberCount = 0
        var selfRole: String? = nil
        var notificationMode = "all"
        var accessState = "active"
        var lastMsgId: Int64 = 0
    }

    enum BulkDialogAction: Sendable {
        case markRead
        case pin(Bool)
        case mute(Bool)
        case archive(Bool)
    }

    struct BulkDialogActionResult: Equatable, Sendable {
        let changed: Int
        let skipped: Int
    }

    struct GroupPermissions: Equatable, Sendable {
        var membersCanSend = true
        var membersCanAddMembers = false
        var membersCanEditInfo = false
    }

    struct Line: Identifiable, Equatable, Sendable {
        enum Delivery: Equatable, Sendable {
            case sending
            case sent
            case seen
            case failed(String)
        }

        enum TransferStage: Equatable, Sendable {
            case preparing
            case uploading
            case finalizing
            case retrying
        }

        let id: String
        var dialogId: String?
        var msgId: Int64?
        var clientMsgId: String
        var senderAccountId: String? = nil
        var senderDisplayName: String? = nil
        var text: String
        var kind: String = "text"
        var serviceType: String? = nil
        var serviceData: CloudServiceData? = nil
        var linkPreview: CloudLinkPreview? = nil
        var mine: Bool
        var delivery: Delivery
        var timestamp: String?
        var replyToMsgId: Int64? = nil
        var replyPreview: String? = nil
        var reactions: [String] = []
        var myReaction: String? = nil
        var forwardedFromAccountId: String? = nil
        var forwardedFromDialogId: String? = nil
        var forwardedFromMsgId: Int64? = nil
        var isForwarded = false
        var editVersion = 0
        var isEdited = false
        var isDeleted = false
        var attachment: DemoAttachment? = nil
        var media: CloudMedia? = nil
        var mediaGroupId: String? = nil
        var mediaGroupIndex: Int? = nil
        var mediaGroupCount: Int? = nil
        var transferProgress: Double? = nil
        var transferStage: TransferStage? = nil
        var transferError: String? = nil
        var pendingMutation: PendingMessageMutation? = nil
        var presentationDayLabel: String? = nil
        var presentationTimestampLabel: String? = nil
        var presentationMediaTimestampLabel: String? = nil
        var presentationIsFirstInGroup = true
        var presentationIsLastInGroup = true
    }

    private(set) var storedSession: StoredCloudSession? {
        didSet {
            let oldIdentity = oldValue.map {
                "\($0.session.accountId)\u{0}\($0.session.deviceId)\u{0}\($0.session.token)"
            }
            let newIdentity = storedSession.map {
                "\($0.session.accountId)\u{0}\($0.session.deviceId)\u{0}\($0.session.token)"
            }
            if oldIdentity != newIdentity {
                savedMessagesSessionGeneration &+= 1
                savedMessagesCapabilityState = .unknown
            }
        }
    }
    private(set) var launchPhase: LaunchPhase = .restoringLocal
    private(set) var status = "Starting"
    private(set) var operationNotice: Notice?
    private(set) var connectionViewState: ReplicaConnectionState = .connecting
    private(set) var replicaSyncState: ReplicaSyncState = .checking
    private(set) var replicaConnectivityState: ReplicaConnectivityState = .unknown
    private(set) var replicaUpdatePhase: ReplicaUpdatePhase = .idle
    private(set) var lastSuccessfulServerContact: Date?
    private(set) var requestedCode = false
    private(set) var authRequestInFlight = false
    private(set) var authVerifyInFlight = false
    private(set) var twoFactorChallengeId: String?
    private(set) var recoveredTwoFactorCodes: [String] = []
    private(set) var twoFactorEnabled = false
    private(set) var twoFactorRecoveryCodesRemaining = 0
    private(set) var securityChangeInFlight = false
    private(set) var securityStepUpToken: String?
    private(set) var requiresDifferentAccountCleanupConfirmation = false
    private(set) var resendSeconds = 0
    private(set) var activeDialogId: String?
    private(set) var pendingDeepLinkDialogId: String?
    private(set) var conversationOpenState: ConversationOpenState = .loadingLocal
    private(set) var dialogs: [Dialog] = []
    private(set) var chatFolders: [CloudChatFolder] = []
    private(set) var chatFolderCollectionRevision: Int64 = 0
    private(set) var scheduledDeliveries: [CloudScheduledDelivery] = []
    private(set) var savedMessagesDialogId: String?
    private(set) var savedMessagesSetupInFlight = false
    private(set) var savedMessagesSetupFailure: String?
    private(set) var savedMessagesCapabilityState: SavedMessagesCapabilityState = .unknown
    private(set) var groupMembersByDialog: [String: [GroupMember]] = [:]
    private(set) var groupPermissionsByDialog: [String: GroupPermissions] = [:]
    private(set) var lines: [Line] = []
    private(set) var openingTimelineAnchor: TimelineAnchor = .bottom
    private(set) var canLoadEarlier = false
    private(set) var loadingEarlier = false
    private(set) var canLoadLater = false
    private(set) var loadingLater = false
    private(set) var devices: [CloudDevice] = []
    private(set) var loadingDevices = false
    private(set) var accountDeletionRequested = false
    private(set) var accountDeletionInFlight = false
    private(set) var mediaCacheBytes: Int64 = 0
    private(set) var mediaAutoDownloadPolicy: MediaAutoDownloadPolicy = .default
    private(set) var mediaCachePolicy: MediaCachePolicy = .default
    private(set) var clearingMediaCache = false
    private(set) var composerMode: ComposerMode = .text
    private(set) var currentDraft: LocalDraft?
    private(set) var profileDetails: StoredProfileDetails = .empty
    private(set) var profileSaveInFlight = false
    private(set) var profilePhotoSyncState: ProfilePhotoSyncState = .localOnly
    private(set) var profilePhotoDisplayData: Data?
    private(set) var canonicalProfilePhoto: CloudMedia?
    private(set) var profilePhotoRevision: Int64 = 0
    #if DEBUG
    private(set) var isDemoMode = false
    #endif

    var phone = "+992 "
    var displayName = ""
    var code = ""
    var twoFactorPassword = ""
    var twoFactorRecoveryCode = ""
    var twoFactorReplacementPassword = ""
    var usesTwoFactorRecovery = false
    var securityCode = ""
    var peerPhone = ""
    var draft = "" {
        didSet {
            scheduleActiveDraftPersistence()
        }
    }
    var accountDeletionCode = ""

    #if DEBUG
    var uiFixtureDraftPersistenceComplete: Bool {
        guard TelegramFastUITestFixture.enabled,
              let dialogId = activeDialogId,
              (draftPersistenceGenerations[dialogId] ?? 0) > 0 else {
            return false
        }
        return draftPersistenceTasks[dialogId] == nil
    }
    #endif

    private var draftMentionsByDialog: [String: [DraftMention]] = [:]

    var mentionSuggestions: [GroupMember] {
        guard
            let dialogId = activeDialogId,
            dialogs.first(where: { $0.id == dialogId })?.type == "group",
            let query = activeMentionQuery(in: draft)
        else { return [] }
        let accountId = storedSession?.session.accountId
        return (groupMembersByDialog[dialogId] ?? [])
            .filter {
                $0.isActive && $0.accountId != accountId
                    && (query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query))
            }
            .prefix(6)
            .map { $0 }
    }

    private let api: CloudAPI
    private let savedMessagesService = SavedMessagesService()
    private let tokenStore: TokenStore
    private var localStore: CloudLocalStore?

    /// Owns the search index's lifecycle. Deliberately a separate actor rather than more methods
    /// here: none of it needs the main actor, and this type is large enough.
    ///
    /// Scoped to an account *and* a store instance, so recovering a quarantined replica — which
    /// produces a new store for the same account — replaces the coordinator rather than letting the
    /// old one keep writing to a database nobody is reading.
    private(set) var searchCoordinator: SearchCoordinator?

    /// The store the search screen queries. Exposed rather than routing every search through this
    /// type, which is large enough already.
    var searchStore: CloudLocalStore? { localStore }
    private let localStoreBootstrapper = CloudLocalStoreBootstrapper()
    private let opensDefaultLocalStore: Bool
    private let pushCenter: PushRegistrationCenter
    private let voipPushCenter: VoIPPushRegistrationCenter
    private let mediaEngine: CloudMediaTransferEngine
    private let accessPurgeCoordinator = AccessPurgeCoordinator()
    private let capabilityDefaults: UserDefaults
    private let capabilityCacheKey: String
    private var negotiatedCapabilities: MessagingCapabilities
    @ObservationIgnored private lazy var mediaPrefetchScheduler = MediaPrefetchScheduler { [weak self] lane in
        guard let self else { return false }
        return await self.processOneMediaDownload(component: lane.component)
    }
    @ObservationIgnored private lazy var replicaSyncCoordinator = ReplicaSyncCoordinator { [weak self] generation in
        guard let self else { return }
        await self.runForegroundSyncAttempt(generation: generation)
        self.settleReplicaSyncStateAfterAttempt()
    }
    @ObservationIgnored private lazy var draftSyncCoordinator = DraftSyncCoordinator(api: api)
    @ObservationIgnored private lazy var dialogPreferencesCoordinator =
        DialogPreferencesCoordinator(api: api)
    @ObservationIgnored private let productivitySyncCoordinator =
        CloudProductivitySyncCoordinator()
    @ObservationIgnored private lazy var profilePhotoSyncCoordinator =
        ProfilePhotoSyncCoordinator(api: api, mediaEngine: mediaEngine)
    private let voiceRecorder = VoiceNoteRecorder()
    private var pts: Int64 = 0
    private var hintSocket: CloudHintSocket?
    private var hintSocketToken: String?
    private var hintTask: Task<Void, Never>?
    private var networkObservationTask: Task<Void, Never>?
    private var offlinePaintTask: Task<Void, Never>?
    private var memoryPressureTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var resendTask: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var composerMediaTask: Task<Void, Never>?
    private var profileSyncTask: Task<Void, Never>?
    private var profileSaveTasks: [UUID: Task<Bool, Never>] = [:]
    private var productivityTerminalAcknowledgementTask: (id: UUID, task: Task<Void, Never>)?
    private var pendingProductivityTerminalNotice: (
        noticeId: UUID,
        failure: CloudProductivityTerminalError
    )?
    private var profilePhotoMigrationTask: Task<Void, Never>?
    private var postSignInTask: Task<Void, Never>?
    private var postSyncWorkTask: Task<Void, Never>?
    private var historyHydrationTask: Task<Void, Never>?
    private var openingAnchorHydrationTask: Task<Void, Never>?
    private var dialogObservationTask: Task<Void, Never>?
    private var draftObservationTask: Task<Void, Never>?
    private var draftPersistenceTasks: [String: Task<Void, Never>] = [:]
    private var timelineObservationTask: Task<Void, Never>?
    private var viewportPersistenceTask: Task<Void, Never>?
    private var mediaDownloadTask: Task<Void, Never>?
    private var readReceiptRetryTask: Task<Void, Never>?
    private var replicaIntegrityTask: Task<Void, Never>?
    private var localRestoreTask: Task<Void, Never>?
    private var credentialUpdateTask: Task<Void, Never>?
    private var credentialRefreshLoopTask: Task<Void, Never>?
    private var expiredSessionAccountId: String?
    private var pendingDifferentAccountAuthentication: (
        session: CloudSession,
        phone: String,
        displayName: String
    )?
    private var localRestoreCompleted = false
    private var backgroundMediaRuntimePrepared = false
    private var mediaSchedulerForegrounded = false
    private var composerMediaOperationId: UUID?
    private var composerMediaDialogId: String?
    private var activeComposerTransferId: String?
    private var temporaryPreviewURLsByDialog: [String: Set<URL>] = [:]
    private var dialogPresentationGenerations: [String: UInt64] = [:]
    private var mediaTransferTasks: [String: Task<Void, Never>] = [:]
    private var mediaTransferDialogIds: [String: String] = [:]
    private var preferenceMutationTasks: [UUID: Task<Void, Never>] = [:]
    private var accountSessionGeneration: UInt64 = 1
    private var isSessionTeardownInProgress = false
    private var syncInFlight = false
    private var syncAgain = false
    private var retryInFlight = false
    private var outboxDrainHalted = false
    private var mediaTransfersInFlight: Set<String> = []
    private var mediaGroupSendsInFlight: Set<String> = []
    private var draftSendsInFlightByDialog: [String: String] = [:]
    private var messageMutationsInFlight: Set<String> = []
    private var mutationTargetsBeingQueued: Set<String> = []
    private var uploadedPushRegistration: String?
    private var uploadedVoIPPushRegistration: String?
    private var uploadedGroupCallCapabilityRegistration: String?
    private var historyHasMoreByDialog: [String: Bool] = [:]
    private var draftPersistenceGenerations: [String: UInt64] = [:]
    private var minimumObservedDraftGenerations: [String: Int64] = [:]
    private var sessionEpoch: UInt64 = 0
    private var sessionTearingDown = false
    private var suppressDraftPersistence = false
    private var transientUnderlyingDraftText: String?
    private var transientUnderlyingComposerMode: ComposerMode?
    private var transientVoiceComposerMode: ComposerMode?
    private var cachedLinesByDialog: [String: [Line]] = [:]
    private var cachedLocalMessagesByDialog: [String: [LocalMessage]] = [:]
    private var cachedLineDialogOrder: [String] = []
    private var cachedConversationCostByDialog: [String: Int] = [:]
    private var conversationOpenWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var conversationOpenStartedAt: [String: Date] = [:]
    private var loadedLocalMessages: [LocalMessage] = []
    private var timelineTopVisibleMsgId: Int64?
    private var timelineIsAtBottom = true
    private var pendingVisibleReadMessages: [LocalMessage] = []
    /// Message the timeline should open on and briefly flash, set when a search result is tapped.
    ///
    /// Cleared once the flash finishes so returning to the same conversation later does not replay
    /// it — a highlight that reappears without a search behind it reads as a bug.
    var focusedSearchMsgId: Int64?

    /// In-chat find state. `nil` when the bar is closed.
    var inChatSearch: InChatSearchState?
    private var inChatSearchTask: Task<Void, Never>?
    private var inChatSearchGeneration: UInt64 = 0

    private var timelineBeforeCount = 40
    private var timelineAfterCount = 79
    private var dialogSelectionGeneration: UInt64 = 0
    private var timelineLoadGeneration: UInt64 = 0
    private var openingAnchorHydrationGeneration: UInt64 = 0
    private var openPrefetchGeneration: UInt64 = 0
    private var savedMessagesSessionGeneration: UInt64 = 0
    private(set) var sessionTeardownActive = false
    private struct TrackedSavedOperation {
        let cancel: () -> Void
        let wait: () async -> Void
    }
    private struct SessionClearBarrier {
        let id: UUID
        var waiters: [CheckedContinuation<Bool, Never>]
    }
    private var trackedSavedOperations: [UUID: TrackedSavedOperation] = [:]
    private var sessionClearBarrier: SessionClearBarrier?
    private var appliedSyncBatches = 0
    private var lastForegroundSyncFailure: ReplicaSyncState?
    private var timelineForwardCursorByDialog: [String: Int64] = [:]
    private var timelineHasMoreForwardByDialog: [String: Bool] = [:]
    private var readReceiptDrainRequested = false
    #if DEBUG
    private var demoLinesByDialog: [String: [Line]] = [:]
    private var temporaryPreviewAuthorizationGate: (@Sendable (URL) async -> Void)?
    private var mediaAccessRestoreAuthorizationGate: (@Sendable () async -> Void)?
    private var mediaAccessPostRestoreValidationGate: (@Sendable () async -> Void)?
    #endif

    let callCoordinator: CallCoordinator
    let groupCallCoordinator: GroupCallCoordinator
    let callPreferences: CallPrivacyPreferences
    let presenceCoordinator: PresenceCoordinator

    var capabilities: MessagingCapabilities {
        #if DEBUG
        if isDemoMode { return .demo.union(searchCapability) }
        #endif
        var serverCapabilities = negotiatedCapabilities
        if !WebRTCEngineFactory.isAvailable {
            serverCapabilities.subtract([.calls, .videoCalls])
        } else if !WebRTCEngineFactory.supportsCameraVideoProfile {
            serverCapabilities.remove(.videoCalls)
        }
        if !GroupCallEngineFactory.isAvailable {
            serverCapabilities.subtract([.groupCalls, .groupVideoCalls, .screenSharing])
        } else if !GroupCallEngineFactory.supportsScreenShare {
            serverCapabilities.remove(.screenSharing)
        }
        return serverCapabilities.union(searchCapability)
    }

    private func installAuthenticatedSession(_ session: StoredCloudSession) {
        // Only explicit authentication/restore entry points may lower the teardown fence.
        // Profile and other generic refreshes cannot resurrect a session during erasure.
        guard sessionClearBarrier == nil else { return }
        sessionTeardownActive = false
        storedSession = session
        Task {
            await SessionCredentialCoordinator.shared.install(
                session,
                config: api.config,
                tokenStore: tokenStore
            )
        }
    }

    var replicaSyncSnapshot: ReplicaSyncSnapshot {
        ReplicaSyncSnapshot(
            connectivity: replicaConnectivityState,
            updatePhase: replicaUpdatePhase,
            lastSuccessfulServerContact: lastSuccessfulServerContact
        )
    }

    var voiceRecordingLevel: Float { voiceRecorder.level }

    var canRequestCode: Bool {
        let digits = phone.filter(\.isNumber)
        let validLength = phone.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+992")
            ? digits.count == 12
            : (8...15).contains(digits.count)
        return !authRequestInFlight && resendSeconds == 0 && validLength
    }

    var canVerifyCode: Bool {
        !authVerifyInFlight
            && code.filter(\.isNumber).count == 6
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "toj" else { return }
        let components = [url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" }
        guard components.count == 2 else { return }
        if components[0].lowercased() == "user" {
            let username = components[1]
            Task { [weak self] in _ = await self?.openUsername(username) }
            return
        }
        guard components[0].lowercased() == "chat" else { return }
        let dialogId = components[1].lowercased()
        guard UUID(uuidString: dialogId) != nil || dialogId.hasPrefix("demo-") else { return }
        guard dialogs.contains(where: { $0.id.lowercased() == dialogId }) else {
            presentNotice(
                String(localized: "Chat unavailable"),
                message: String(localized: "This chat is not available for the current account.")
            )
            return
        }
        pendingDeepLinkDialogId = dialogs.first { $0.id.lowercased() == dialogId }?.id
    }

    func consumePendingDeepLink() {
        pendingDeepLinkDialogId = nil
    }

    var canVerifySecondFactor: Bool {
        guard twoFactorChallengeId != nil, !authVerifyInFlight else { return false }
        if usesTwoFactorRecovery {
            return twoFactorRecoveryCode.filter { $0.isLetter || $0.isNumber }.count == 16
                && twoFactorReplacementPassword.count >= 8
        }
        return !twoFactorPassword.isEmpty
    }

    init(
        config: CloudConfig = .current,
        api injectedAPI: CloudAPI? = nil,
        tokenStore: TokenStore = TokenStore(),
        pushCenter: PushRegistrationCenter = .shared,
        voipPushCenter: VoIPPushRegistrationCenter = .shared,
        callCoordinator: CallCoordinator = .shared,
        groupCallCoordinator: GroupCallCoordinator = .shared,
        callPreferences: CallPrivacyPreferences = .shared,
        localStore injectedLocalStore: CloudLocalStore? = nil,
        useDefaultLocalStore: Bool = true,
        mediaEngine injectedMediaEngine: CloudMediaTransferEngine? = nil,
        capabilityDefaults: UserDefaults = .standard
    ) {
        let resolvedAPI = injectedAPI ?? CloudAPI(config: config)
        self.api = resolvedAPI
        self.presenceCoordinator = PresenceCoordinator(api: resolvedAPI)
        self.tokenStore = tokenStore
        self.pushCenter = pushCenter
        self.voipPushCenter = voipPushCenter
        self.callCoordinator = callCoordinator
        self.groupCallCoordinator = groupCallCoordinator
        self.callPreferences = callPreferences
        self.mediaEngine = injectedMediaEngine ?? CloudMediaTransferEngine(config: config)
        self.opensDefaultLocalStore = useDefaultLocalStore && injectedLocalStore == nil
        self.capabilityDefaults = capabilityDefaults
        self.capabilityCacheKey = "toj.cloud.capabilities.\(config.baseURL.absoluteString)"
        let cached = capabilityDefaults.object(
            forKey: "toj.cloud.capabilities.\(config.baseURL.absoluteString)"
        ) as? NSNumber
        self.negotiatedCapabilities = cached.map {
            MessagingCapabilities(rawValue: $0.uint64Value)
                .subtracting([
                    .videoCalls, .savedMessages,
                    .groupCalls, .groupVideoCalls, .screenSharing,
                    .chatFolders, .scheduledDelivery, .linkPreviews, .abuseReports,
                    .presence, .profilePhotos,
                ])
        } ?? [.replies]
        self.localStore = injectedLocalStore
        voiceRecorder.onUnexpectedStop = { [weak self] in
            guard let self else { return }
            self.recordingTask?.cancel()
            self.recordingTask = nil
            self.restoreVoiceDraftComposer()
            self.presentNotice(
                "Recording canceled",
                message: "The microphone or audio route became unavailable. Nothing was sent."
            )
        }
        pushCenter.bind(
            tokenHandler: { [weak self] token, environment in
                await self?.uploadPushToken(token, environment: environment)
            },
            notificationHandler: { [weak self] in
                await self?.syncFromPush() ?? false
            }
        )
        voipPushCenter.bind { [weak self] token, environment in
            await self?.uploadVoIPPushToken(token, environment: environment)
        }
        credentialUpdateTask = Task { [weak self] in
            for await event in SessionCredentialCoordinator.shared.updates {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case let .updated(updated):
                    guard !self.sessionTeardownActive,
                          self.storedSession?.session.accountId == updated.session.accountId,
                          self.storedSession?.session.deviceId == updated.session.deviceId
                    else { continue }
                    self.storedSession = updated
                    await self.startHints(token: updated.session.token)
                case let .authenticationRequired(expired):
                    await self.pauseForExpiredSession(expired)
                case let .securityRevoked(revoked):
                    guard self.storedSession?.session.deviceId == revoked.session.deviceId else {
                        continue
                    }
                    await self.clearLocalSession(finalStatus: "Session ended for security")
                }
            }
        }
    }

    func start() async {
        await prepareForBackgroundRuntime()
        await activateForegroundServices()
    }

    /// Restores the encrypted replica and installs bounded background handlers without starting
    /// sockets, prompting for notifications, or running foreground hydration. UIApplicationDelegate
    /// calls this during a headless BGTask/URLSession launch; the UI calls `start()` on activation.
    func prepareForBackgroundRuntime() async {
        if localRestoreCompleted {
            await finishBackgroundRuntimePreparation()
            return
        }
        if let localRestoreTask {
            await localRestoreTask.value
            await finishBackgroundRuntimePreparation()
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLocalRestore()
        }
        localRestoreTask = task
        await task.value
        localRestoreTask = nil
        localRestoreCompleted = true
        await finishBackgroundRuntimePreparation()
    }

    private func finishBackgroundRuntimePreparation() async {
        if launchPhase == .localReady, storedSession != nil {
            await prepareBackgroundMediaRuntime()
        } else {
            BackgroundRuntimeCoordinator.shared.completePendingTasksWithNoData()
        }
    }

    private func performLocalRestore() async {
        let launchInterval = LocalFirstMetrics.begin("Local restore")
        defer { LocalFirstMetrics.end("Local restore", launchInterval) }
        launchPhase = .restoringLocal
        do {
            #if DEBUG
            if TelegramFastUITestFixture.enabled {
                try await installTelegramFastUITestFixture()
                return
            }
            #endif
            let pendingRevocations = try await tokenStore.loadPendingRevocations()
            let pendingLocalErasure = try await tokenStore.hasPendingLocalErasure()
            let pendingReauthentication = try await tokenStore
                .loadPendingReauthenticationAccountId()
            let savedSession = try await tokenStore.load()
            let launchAction = PendingRevocationLaunchPolicy.action(
                savedSession: savedSession,
                pendingRevocations: pendingRevocations,
                hasPendingLocalErasure: pendingLocalErasure,
                pendingReauthenticationAccountId: pendingReauthentication
            )
            if case .eraseLocalReplica = launchAction, !pendingLocalErasure {
                // Remote revocation can clear its own marker before the longer teardown reaches
                // disk. Persist destructive intent first so a crash in that window still erases
                // the replica on the next launch.
                let accountId = savedSession?.session.accountId
                    ?? pendingRevocations.first(where: \.eraseLocalReplicaOnLaunch)?
                        .localReplicaAccountId
                try await tokenStore.savePendingLocalErasure(accountId: accountId)
            } else if case let .requireAuthentication(localReplicaAccountId) = launchAction,
                      let accountId = localReplicaAccountId ?? savedSession?.session.accountId {
                // A revocation retry may clear its own token marker at any moment. Establish the
                // independent local-replica fence first so successful remote cleanup cannot make a
                // later launch forget that reauthentication is still required.
                try await tokenStore.savePendingReauthentication(accountId: accountId)
            }
            for pendingRevocation in pendingRevocations {
                Task { [weak self] in await self?.revokeSignedOutToken(pendingRevocation.token) }
            }
            switch launchAction {
            case .eraseLocalReplica:
                // Sign-out was interrupted. Restore only enough identity to erase its profile,
                // then finish deleting SQLCipher, its key, media, and Keychain session data.
                storedSession = savedSession
                await clearLocalSession(finalStatus: "Signed out")
                return
            case let .requireAuthentication(localReplicaAccountId):
                if let savedSession {
                    // Launch has not installed credentials or started account work yet. Remove only
                    // this stale session while retaining the independent replica-authentication
                    // marker; a different-account credential is also queued for remote cleanup.
                    if let localReplicaAccountId,
                       savedSession.session.accountId != localReplicaAccountId {
                        try await tokenStore.savePendingRevocationToken(
                            savedSession.session.token,
                            eraseLocalReplicaOnLaunch: false,
                            localReplicaAccountId: localReplicaAccountId
                        )
                        Task { [weak self] in
                            await self?.revokeSignedOutToken(savedSession.session.token)
                        }
                    }
                    try await tokenStore.clearSession(ifTokenMatches: savedSession.session.token)
                }
                expiredSessionAccountId = localReplicaAccountId
                    ?? savedSession?.session.accountId
                launchPhase = .localReady
                setReplicaSyncState(.sessionExpired)
                status = "Session expired. Sign in again to resume your saved chats."
                return
            case .restoreSavedSession:
                break
            }
            if let saved = savedSession {
                isSessionTeardownInProgress = false
                installAuthenticatedSession(saved)
                phone = saved.phone
                displayName = saved.displayName
                await loadProfileDetails()
                status = "Signed in"
                setReplicaSyncState(.checking)
                await afterSignIn()
            } else {
                status = "Signed out"
                launchPhase = .signedOut
            }
        } catch {
            status = "Session restore failed: \(error.localizedDescription)"
            setReplicaSyncState(.localFailure)
            launchPhase = storedSession == nil ? .signedOut : .recoveringStore
        }
    }

    func retryLocalRecovery() async {
        guard let saved = storedSession else {
            launchPhase = .signedOut
            return
        }
        launchPhase = .restoringLocal
        do {
            // A remote authenticated read is the safety gate: an unreadable replica is preserved
            // until we know its cloud source still exists and this session may rebuild it.
            _ = try await api.getState(token: saved.session.token)
            localStore = try await localStoreBootstrapper.quarantineAndOpenDefaultStore()
            backgroundMediaRuntimePrepared = false
            try await rebuildLocalReplica(token: saved.session.token)
            await afterSignIn()
            await prepareBackgroundMediaRuntime()
            await activateForegroundServices()
        } catch {
            status = "Recovery paused: \(error.localizedDescription)"
            setReplicaSyncState(Self.replicaFailureState(
                for: error,
                network: ReplicaNetworkMonitor.shared.snapshot()
            ))
            launchPhase = .recoveringStore
        }
    }

    func requestCode() async {
        guard canRequestCode else { return }
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        authRequestInFlight = true
        defer { authRequestInFlight = false }
        do {
            let response = try await api.startAuth(phone: trimmed)
            requestedCode = true
            if let devCode = response.code {
                code = devCode
            }
            startResendCountdown(response.retryAfter ?? 30)
            status = "Code requested"
        } catch {
            if let retryAfter = (error as? CloudAPIError)?.retryAfter {
                startResendCountdown(retryAfter)
            }
            status = "Code request failed: \(error.localizedDescription)"
        }
    }

    func verifyCode() async {
        guard canVerifyCode else { return }
        let trimmedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.filter(\.isNumber)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPhone.isEmpty, !trimmedCode.isEmpty else { return }

        authVerifyInFlight = true
        defer { authVerifyInFlight = false }
        do {
            let publicCapabilities = try await api.capabilities()
            let supportsV2 = publicCapabilities.capabilities.contains("auth_sessions_v2")
            if supportsV2 {
                let response = try await api.checkAuthV2(
                    phone: trimmedPhone,
                    code: trimmedCode,
                    displayName: name,
                    deviceName: UIDevice.current.name
                )
                if response.state == "two_factor_required", let challengeId = response.challengeId {
                    twoFactorChallengeId = challengeId
                    status = "Enter your two-step verification password"
                    return
                }
                guard let session = response.session else {
                    throw CloudAPIError(
                        status: -1,
                        message: "Invalid authentication response",
                        retryAfter: nil
                    )
                }
                await finishAuthentication(
                    session: session,
                    phone: trimmedPhone,
                    displayName: name
                )
            } else {
                let session = try await api.checkAuth(
                    phone: trimmedPhone,
                    code: trimmedCode,
                    displayName: name,
                    deviceName: UIDevice.current.name
                )
                await finishAuthentication(
                    session: session,
                    phone: trimmedPhone,
                    displayName: name
                )
            }
        } catch {
            status = "Sign in failed: \(error.localizedDescription)"
        }
    }

    func verifySecondFactor() async {
        guard canVerifySecondFactor, let challengeId = twoFactorChallengeId else { return }
        authVerifyInFlight = true
        defer { authVerifyInFlight = false }
        do {
            let response = try await api.completeTwoFactorLogin(
                challengeId: challengeId,
                password: usesTwoFactorRecovery ? nil : twoFactorPassword,
                recoveryCode: usesTwoFactorRecovery ? twoFactorRecoveryCode : nil,
                newPassword: usesTwoFactorRecovery ? twoFactorReplacementPassword : nil
            )
            recoveredTwoFactorCodes = response.recoveryCodes ?? []
            await finishAuthentication(
                session: response.session,
                phone: phone.trimmingCharacters(in: .whitespacesAndNewlines),
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            status = "Two-step verification failed: \(error.localizedDescription)"
        }
    }

    private func finishAuthentication(
        session: CloudSession,
        phone: String,
        displayName: String
    ) async {
        if let expiredSessionAccountId, expiredSessionAccountId != session.accountId {
            do {
                // The successful login already created a server device. Persist its revocation
                // token before showing a destructive local-replica choice so cancellation, loss
                // of network, or process death cannot strand an unreachable live session.
                try await tokenStore.savePendingRevocationToken(
                    session.token,
                    eraseLocalReplicaOnLaunch: false,
                    localReplicaAccountId: expiredSessionAccountId
                )
            } catch {
                _ = try? await api.revokeSession(token: session.token)
                status = "Sign in could not be staged safely: \(error.localizedDescription)"
                return
            }
            pendingDifferentAccountAuthentication = (session, phone, displayName)
            requiresDifferentAccountCleanupConfirmation = true
            status = "Confirm before replacing the saved chats from another account."
            return
        }
        let stored = StoredCloudSession(session: session, phone: phone, displayName: displayName)
        do {
            try await tokenStore.save(stored)
            do {
                try await tokenStore.clearPendingRevocationToken(ifMatches: session.token)
                try await tokenStore.markPendingRevocationsRemoteOnly(
                    localReplicaAccountId: session.accountId
                )
                try await tokenStore.clearPendingReauthentication()
            } catch {
                // Leave the durable revocation marker intact and remove the newly saved session.
                // On relaunch Toj will retry revocation instead of restoring ambiguous identity.
                try? await tokenStore.clearSession(ifTokenMatches: session.token)
                throw error
            }
            // Clear the in-memory replacement fence only after both the new credential and the
            // removal of its durable reauthentication marker have committed successfully.
            expiredSessionAccountId = nil
            sessionEpoch &+= 1
            sessionTearingDown = false
            isSessionTeardownInProgress = false
            accountSessionGeneration &+= 1
            installAuthenticatedSession(stored)
            profileDetails = Self.profileDetails(from: displayName)
            try? await tokenStore.saveProfile(profileDetails, accountId: session.accountId)
            resendTask?.cancel()
            resendTask = nil
            resendSeconds = 0
            twoFactorChallengeId = nil
            twoFactorPassword = ""
            twoFactorRecoveryCode = ""
            twoFactorReplacementPassword = ""
            usesTwoFactorRecovery = false
            status = "Signed in"
            setReplicaSyncState(.checking)
            await afterSignIn()
            await prepareBackgroundMediaRuntime()
            await activateForegroundServices()
        } catch {
            // Authentication already created a server-side device. If its durable local commit
            // fails, revoke that otherwise unreachable credential before allowing another retry.
            _ = try? await api.revokeSession(token: session.token)
            status = "Sign in failed: \(error.localizedDescription)"
        }
    }

    func cancelDifferentAccountSignIn() async {
        guard let pending = pendingDifferentAccountAuthentication else { return }
        pendingDifferentAccountAuthentication = nil
        requiresDifferentAccountCleanupConfirmation = false
        // Cancellation resolves only this staged token's relationship to the preserved replica.
        // Keep retrying its remote revoke without turning that cleanup into a second auth fence;
        // the independent reauthentication marker for the original account remains authoritative.
        try? await tokenStore.markPendingRevocationRemoteOnly(ifMatches: pending.session.token)
        await revokeSignedOutToken(pending.session.token)
        status = "Saved chats were kept. Sign in with the original account to resume."
    }

    func confirmDifferentAccountSignIn() async {
        guard let pending = pendingDifferentAccountAuthentication else { return }
        pendingDifferentAccountAuthentication = nil
        requiresDifferentAccountCleanupConfirmation = false
        let cleanupSucceeded = await clearLocalSession(
            finalStatus: "Previous account removed from this device"
        )
        guard cleanupSucceeded else {
            // Never install another account over a replica whose destructive cleanup was partial.
            // The revocation marker survives a transient network failure and is retried at launch.
            await revokeSignedOutToken(pending.session.token)
            status = "Could not safely replace the previous account. Restart Toj to finish cleanup."
            return
        }
        expiredSessionAccountId = nil
        await finishAuthentication(
            session: pending.session,
            phone: pending.phone,
            displayName: pending.displayName
        )
    }

    func dismissOperationNotice() {
        let terminal = pendingProductivityTerminalNotice.flatMap { pending in
            operationNotice?.id == pending.noticeId ? pending.failure : nil
        }
        operationNotice = nil
        if terminal != nil { pendingProductivityTerminalNotice = nil }
        guard let terminal, let context = currentAccountOperationContext() else { return }
        productivityTerminalAcknowledgementTask?.task.cancel()
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.productivityTerminalAcknowledgementTask?.id == id {
                    self.productivityTerminalAcknowledgementTask = nil
                }
            }
            await self.productivitySyncCoordinator.bind(context)
            guard self.isCurrentAccountOperation(context) else { return }
            try? await self.productivitySyncCoordinator.acknowledgeTerminalError(terminal)
            guard self.isCurrentAccountOperation(context) else { return }
            let report = await self.productivitySyncCoordinator.drain(api: self.api)
            await self.publishProductivityDrainReport(report, context: context)
        }
        productivityTerminalAcknowledgementTask = (id, task)
    }

    func resetAuthCode() {
        guard !authRequestInFlight, !authVerifyInFlight else { return }
        requestedCode = false
        code = ""
        twoFactorChallengeId = nil
        twoFactorPassword = ""
        twoFactorRecoveryCode = ""
        twoFactorReplacementPassword = ""
        usesTwoFactorRecovery = false
        status = "Signed out"
    }

    func loadProfileDetails() async {
        guard let saved = storedSession else { return }
        let generation = accountSessionGeneration
        let expectedStore = localStore
        do {
            let loaded = try await tokenStore.loadProfile(accountId: saved.session.accountId)
                ?? Self.profileDetails(from: saved.displayName)
            guard profileOperationIsCurrent(
                saved: saved, generation: generation, store: expectedStore
            ) else { return }
            profileDetails = loaded
        } catch {
            guard profileOperationIsCurrent(
                saved: saved, generation: generation, store: expectedStore
            ) else { return }
            profileDetails = Self.profileDetails(from: saved.displayName)
            status = "Could not load profile details"
        }
    }

    @discardableResult
    func saveProfileDetails(_ candidate: StoredProfileDetails) async -> Bool {
        guard let saved = storedSession, !profileSaveInFlight else { return false }
        if let username = Self.cleanedUsername(candidate.username),
           username.range(of: "^[a-z][a-z0-9_]{4,31}$", options: .regularExpression) == nil {
            status = "Username must start with a letter and contain 5–32 letters, numbers, or underscores"
            return false
        }
        let cleaned = StoredProfileDetails(
            username: Self.cleanedUsername(candidate.username),
            firstName: Self.cleanedProfileText(candidate.firstName, limit: 48),
            lastName: Self.cleanedProfileText(candidate.lastName, limit: 48),
            bio: Self.cleanedProfileText(candidate.bio, limit: 120, preservesNewlines: true),
            birthday: candidate.birthday,
            colorIndex: max(0, min(candidate.colorIndex, 7)),
            serverUpdatedAt: candidate.serverUpdatedAt,
            pendingSync: true
        )
        guard !cleaned.firstName.isEmpty else {
            status = "First name is required"
            return false
        }

        profileSaveInFlight = true
        defer { profileSaveInFlight = false }
        let generation = accountSessionGeneration
        let expectedStore = localStore
        let operationId = UUID()
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performProfileSave(
                cleaned,
                saved: saved,
                generation: generation,
                store: expectedStore
            )
        }
        profileSaveTasks[operationId] = task
        let result = await task.value
        profileSaveTasks.removeValue(forKey: operationId)
        return result
    }

    private func performProfileSave(
        _ cleaned: StoredProfileDetails,
        saved: StoredCloudSession,
        generation: UInt64,
        store expectedStore: CloudLocalStore?
    ) async -> Bool {
        let updatedSession = StoredCloudSession(
            session: saved.session,
            phone: saved.phone,
            displayName: cleaned.displayName
        )

        do {
            guard profileOperationIsCurrent(
                saved: saved, generation: generation, store: expectedStore
            ),
                  !Task.isCancelled else { return false }
            try await tokenStore.saveProfile(cleaned, accountId: saved.session.accountId)
            guard profileOperationIsCurrent(
                saved: saved, generation: generation, store: expectedStore
            ),
                  !Task.isCancelled else { return false }
            try await tokenStore.save(updatedSession)
        } catch {
            if profileOperationIsCurrent(
                saved: saved, generation: generation, store: expectedStore
            ) {
                status = "Could not save profile: \(error.localizedDescription)"
            }
            return false
        }

        guard profileOperationIsCurrent(
            saved: saved, generation: generation, store: expectedStore
        ),
              !Task.isCancelled else { return false }
        profileDetails = cleaned
        storedSession = updatedSession
        displayName = cleaned.displayName
        status = "Profile saved"

        #if DEBUG
        if isDemoMode { return true }
        #endif

        profileSyncTask?.cancel()
        let token = saved.session.token
        profileSyncTask = Task { [weak self] in
            await self?.uploadPendingProfile(
                cleaned,
                accountId: saved.session.accountId,
                deviceId: saved.session.deviceId,
                token: token,
                generation: generation,
                store: expectedStore
            )
        }
        return true
    }

    private func profileOperationIsCurrent(
        saved: StoredCloudSession,
        generation: UInt64,
        store expectedStore: CloudLocalStore?
    ) -> Bool {
        let storeMatches = switch (expectedStore, localStore) {
        case (nil, nil): true
        case let (expected?, current?): expected === current
        default: false
        }
        return !sessionTeardownActive
            && !isSessionTeardownInProgress
            && accountSessionGeneration == generation
            && storedSession?.session.accountId == saved.session.accountId
            && storedSession?.session.deviceId == saved.session.deviceId
            && storedSession?.session.token == saved.session.token
            && storeMatches
    }

    private func reconcileProfileWithServer() {
        guard let saved = storedSession else { return }
        #if DEBUG
        if isDemoMode { return }
        #endif
        profileSyncTask?.cancel()
        let local = profileDetails
        let generation = accountSessionGeneration
        let expectedStore = localStore
        profileSyncTask = Task { [weak self] in
            guard let self else { return }
            if local.needsServerSync {
                await self.uploadPendingProfile(
                    local,
                    accountId: saved.session.accountId,
                    deviceId: saved.session.deviceId,
                    token: saved.session.token,
                    generation: generation,
                    store: expectedStore
                )
                return
            }
            do {
                let profile = try await self.api.getProfile(token: saved.session.token)
                guard !Task.isCancelled else { return }
                await self.acceptCanonicalProfile(
                    profile,
                    accountId: saved.session.accountId,
                    deviceId: saved.session.deviceId,
                    token: saved.session.token,
                    generation: generation,
                    store: expectedStore
                )
            } catch {
                // Keep the encrypted local snapshot. Reconciliation runs again on the next launch.
            }
        }
    }

    private func uploadPendingProfile(
        _ local: StoredProfileDetails,
        accountId: String,
        deviceId: String,
        token: String,
        generation: UInt64,
        store expectedStore: CloudLocalStore?
    ) async {
        do {
            let profile = try await api.updateProfile(local, token: token)
            guard !Task.isCancelled,
                  accountSessionGeneration == generation,
                  storedSession?.session.accountId == accountId,
                  storedSession?.session.deviceId == deviceId,
                  storedSession?.session.token == token,
                  Self.store(expectedStore, matches: localStore) else { return }
            await acceptCanonicalProfile(
                profile,
                accountId: accountId,
                deviceId: deviceId,
                token: token,
                generation: generation,
                store: expectedStore
            )
            if accountSessionGeneration == generation,
               storedSession?.session.accountId == accountId,
               storedSession?.session.deviceId == deviceId,
               storedSession?.session.token == token,
               Self.store(expectedStore, matches: localStore) {
                status = "Profile updated everywhere"
            }
        } catch {
            guard !Task.isCancelled,
                  accountSessionGeneration == generation,
                  storedSession?.session.accountId == accountId,
                  storedSession?.session.deviceId == deviceId,
                  storedSession?.session.token == token,
                  Self.store(expectedStore, matches: localStore) else { return }
            status = "Profile saved offline — will sync when reconnected"
        }
    }

    private func acceptCanonicalProfile(
        _ profile: CloudProfile,
        accountId: String,
        deviceId: String,
        token: String,
        generation: UInt64,
        store expectedStore: CloudLocalStore?
    ) async {
        guard !sessionTeardownActive,
              let saved = storedSession,
              profile.accountId == accountId,
              saved.session.accountId == accountId,
              saved.session.deviceId == deviceId,
              saved.session.token == token,
              accountSessionGeneration == generation,
              Self.store(expectedStore, matches: localStore)
        else { return }
        let canonical: CloudProfile
        do {
            try await expectedStore?.saveProfile(profile)
            canonical = try await expectedStore?.profile(accountId: accountId) ?? profile
        } catch {
            status = "Profile updated, but local storage could not be refreshed"
            return
        }
        guard !sessionTeardownActive,
              accountSessionGeneration == generation,
              storedSession?.session.accountId == accountId,
              storedSession?.session.deviceId == deviceId,
              storedSession?.session.token == token,
              Self.store(expectedStore, matches: localStore),
              !Task.isCancelled
        else { return }
        let details = Self.profileDetails(from: canonical, pendingSync: false)
        let updatedSession = StoredCloudSession(
            session: saved.session,
            phone: saved.phone,
            displayName: details.displayName
        )
        do {
            try await tokenStore.saveProfile(details, accountId: saved.session.accountId)
        } catch {
            if accountSessionGeneration == generation,
               storedSession?.session.accountId == accountId,
               storedSession?.session.deviceId == deviceId,
               storedSession?.session.token == token,
               Self.store(expectedStore, matches: localStore) {
                status = "Profile updated, but local storage could not be refreshed"
            }
            return
        }
        guard !sessionTeardownActive,
              accountSessionGeneration == generation,
              storedSession?.session.accountId == saved.session.accountId,
              storedSession?.session.deviceId == deviceId,
              storedSession?.session.token == token,
              Self.store(expectedStore, matches: localStore),
              !Task.isCancelled
        else { return }
        profileDetails = details
        storedSession = updatedSession
        displayName = details.displayName
        let photoIdentityChanged = canonicalProfilePhoto?.id != canonical.photo?.id
        let replacedPhotoId = canonicalProfilePhoto?.id == canonical.photo?.id
            ? nil
            : canonicalProfilePhoto?.id
        canonicalProfilePhoto = canonical.photo
        profilePhotoRevision = canonical.photoRevision
        if let replacedPhotoId, let expectedStore {
            MediaPresentationCache.shared.revoke(mediaIds: [replacedPhotoId])
            await mediaEngine.clearMediaCache(mediaIds: [replacedPhotoId], localStore: expectedStore)
            guard !sessionTeardownActive,
                  accountSessionGeneration == generation,
                  storedSession?.session.accountId == accountId,
                  storedSession?.session.deviceId == deviceId,
                  storedSession?.session.token == token,
                  Self.store(expectedStore, matches: localStore)
            else { return }
        }

        let pending = try? await expectedStore?.pendingProfilePhotoMutation(accountId: accountId)
        guard !sessionTeardownActive,
              accountSessionGeneration == generation,
              storedSession?.session.accountId == accountId,
              storedSession?.session.deviceId == deviceId,
              storedSession?.session.token == token,
              Self.store(expectedStore, matches: localStore)
        else { return }
        guard pending == nil else {
            profilePhotoSyncState = pending?.state == "conflict" ? .conflict : .pending
            return
        }
        if let photo = canonical.photo {
            // Never present bytes for a different canonical media object if its replacement cannot
            // be fetched yet. A pending local mutation is handled above and deliberately keeps its
            // optimistic preview.
            if photoIdentityChanged { profilePhotoDisplayData = nil }
            if let bytes = try? await mediaEngine.thumbnail(
                media: photo,
                token: token,
                localStore: expectedStore
            ), accountSessionGeneration == generation,
               storedSession?.session.accountId == accountId,
               storedSession?.session.deviceId == deviceId,
               storedSession?.session.token == token,
               Self.store(expectedStore, matches: localStore) {
                profilePhotoDisplayData = bytes
                _ = await EncryptedProfilePhotoStore.persist(nil, accountId: accountId)
                guard !sessionTeardownActive,
                      accountSessionGeneration == generation,
                      storedSession?.session.accountId == accountId,
                      storedSession?.session.deviceId == deviceId,
                      storedSession?.session.token == token,
                      Self.store(expectedStore, matches: localStore)
                else { return }
            }
            guard !sessionTeardownActive,
                  accountSessionGeneration == generation,
                  storedSession?.session.accountId == accountId,
                  storedSession?.session.deviceId == deviceId,
                  storedSession?.session.token == token,
                  Self.store(expectedStore, matches: localStore)
            else { return }
            profilePhotoSyncState = .synced
        } else {
            let legacy = await EncryptedProfilePhotoStore.load(accountId: accountId)
            guard !sessionTeardownActive,
                  accountSessionGeneration == generation,
                  storedSession?.session.accountId == accountId,
                  storedSession?.session.deviceId == deviceId,
                  storedSession?.session.token == token,
                  Self.store(expectedStore, matches: localStore)
            else { return }
            profilePhotoDisplayData = legacy
            profilePhotoSyncState = capabilities.contains(.profilePhotos) && legacy != nil ? .pending : .localOnly
            if capabilities.contains(.profilePhotos), let legacy {
                await seedLegacyProfilePhotoIfNeeded(legacy, accountId: accountId)
            }
        }
    }

    @discardableResult
    func saveProfilePhoto(_ data: Data?, accountId: String) async -> Bool {
        guard let session = storedSession?.session, session.accountId == accountId else { return false }
        let generation = accountSessionGeneration
        if !capabilities.contains(.profilePhotos) {
            let stored = await EncryptedProfilePhotoStore.persist(data, accountId: accountId)
            let current = generation == accountSessionGeneration && storedSession?.session == session
            if stored, current {
                profilePhotoDisplayData = data
                profilePhotoSyncState = .localOnly
            }
            return stored && current
        }
        do {
            if let data {
                let photo = await Task.detached(priority: .userInitiated) {
                    SafeMediaImageDecoder.prepareProfilePhotoUpload(data)
                }.value
                guard generation == accountSessionGeneration,
                      storedSession?.session == session
                else { throw CancellationError() }
                guard let photo else {
                    throw CloudAppModelError.invalidMedia
                }
                let prepared = try await mediaEngine.prepare(
                    data: photo.data,
                    kind: "photo",
                    contentType: photo.contentType,
                    fileName: "profile-photo.\(photo.filenameExtension)",
                    width: photo.pixelWidth,
                    height: photo.pixelHeight,
                    thumbnail: photo.thumbnail
                )
                guard generation == accountSessionGeneration,
                      storedSession?.session == session
                else {
                    await mediaEngine.discardPrepared(prepared)
                    throw CancellationError()
                }
                _ = try await profilePhotoSyncCoordinator.stageSet(
                    prepared: prepared,
                    baseRevision: profilePhotoRevision
                )
            } else {
                _ = try await profilePhotoSyncCoordinator.stageRemoval(
                    baseRevision: profilePhotoRevision
                )
            }
            guard generation == accountSessionGeneration,
                  storedSession?.session == session
            else { throw CancellationError() }
            guard await EncryptedProfilePhotoStore.persist(data, accountId: accountId) else {
                guard generation == accountSessionGeneration,
                      storedSession?.session == session
                else { throw CancellationError() }
                await profilePhotoSyncCoordinator.discard()
                throw CloudAppModelError.localStoreUnavailable
            }
            guard generation == accountSessionGeneration,
                  storedSession?.session == session
            else { throw CancellationError() }
            profilePhotoDisplayData = data
            profilePhotoSyncState = .pending
            scheduleOutboxRetry()
            BackgroundRuntimeCoordinator.shared.scheduleProcessing()
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard generation == accountSessionGeneration,
                  storedSession?.session == session else { return false }
            profilePhotoSyncState = .failed(error.localizedDescription)
            return false
        }
    }

    func retryProfilePhoto() async {
        guard let session = storedSession?.session else { return }
        let generation = accountSessionGeneration
        if case .conflict = profilePhotoSyncState {
            do {
                let cloud = try await profilePhotoSyncCoordinator.retryMine()
                guard generation == accountSessionGeneration,
                      storedSession?.session == session else { return }
                canonicalProfilePhoto = cloud.photo
                profilePhotoRevision = cloud.photoRevision
            } catch is CancellationError {
                return
            } catch {
                guard generation == accountSessionGeneration,
                      storedSession?.session == session else { return }
                profilePhotoSyncState = .failed(error.localizedDescription)
                return
            }
        } else {
            do {
                try await profilePhotoSyncCoordinator.retryFailed()
                guard generation == accountSessionGeneration,
                      storedSession?.session == session else { return }
            } catch is CancellationError {
                return
            } catch {
                guard generation == accountSessionGeneration,
                      storedSession?.session == session else { return }
                profilePhotoSyncState = .failed(error.localizedDescription)
                return
            }
        }
        profilePhotoSyncState = .pending
        scheduleOutboxRetry()
    }

    func useCloudProfilePhoto() async {
        guard let session = storedSession?.session else { return }
        let generation = accountSessionGeneration
        let expectedStore = localStore
        do {
            let profile = try await profilePhotoSyncCoordinator.useCloudPhoto()
            guard generation == accountSessionGeneration,
                  storedSession?.session == session else { return }
            _ = await EncryptedProfilePhotoStore.persist(nil, accountId: session.accountId)
            guard generation == accountSessionGeneration,
                  storedSession?.session == session else { return }
            await acceptCanonicalProfile(
                profile,
                accountId: session.accountId,
                deviceId: session.deviceId,
                token: session.token,
                generation: generation,
                store: expectedStore
            )
        } catch is CancellationError {
            return
        } catch {
            guard generation == accountSessionGeneration,
                  storedSession?.session == session else { return }
            profilePhotoSyncState = .failed(error.localizedDescription)
        }
    }

    func discardPendingProfilePhoto() async {
        guard let session = storedSession?.session else { return }
        let generation = accountSessionGeneration
        let expectedStore = localStore
        await profilePhotoSyncCoordinator.discard()
        guard generation == accountSessionGeneration,
              storedSession?.session == session else { return }
        _ = await EncryptedProfilePhotoStore.persist(nil, accountId: session.accountId)
        guard generation == accountSessionGeneration,
              storedSession?.session == session else { return }
        do {
            let profile = try await api.getProfile(token: session.token)
            guard generation == accountSessionGeneration,
                  storedSession?.session == session else { return }
            await acceptCanonicalProfile(
                profile,
                accountId: session.accountId,
                deviceId: session.deviceId,
                token: session.token,
                generation: generation,
                store: expectedStore
            )
        } catch {
            guard generation == accountSessionGeneration,
                  storedSession?.session == session else { return }
            profilePhotoDisplayData = nil
            profilePhotoSyncState = .localOnly
        }
    }

    private func seedLegacyProfilePhotoIfNeeded(_ data: Data, accountId: String) async {
        guard let session = storedSession?.session, session.accountId == accountId else { return }
        let generation = accountSessionGeneration
        guard (try? await localStore?.pendingProfilePhotoMutation(accountId: accountId)) == nil,
              generation == accountSessionGeneration,
              storedSession?.session == session
        else { return }
        let photo = await Task.detached(priority: .utility) {
            SafeMediaImageDecoder.prepareProfilePhotoUpload(data)
        }.value
        guard generation == accountSessionGeneration,
              storedSession?.session == session,
              let photo,
              let prepared = try? await mediaEngine.prepare(
                data: photo.data,
                kind: "photo",
                contentType: photo.contentType,
                fileName: "profile-photo.\(photo.filenameExtension)",
                width: photo.pixelWidth,
                height: photo.pixelHeight,
                thumbnail: photo.thumbnail
              )
        else { return }
        guard generation == accountSessionGeneration,
              storedSession?.session == session
        else {
            await mediaEngine.discardPrepared(prepared)
            return
        }
        do {
            _ = try await profilePhotoSyncCoordinator.stageSet(
                prepared: prepared,
                baseRevision: profilePhotoRevision,
                source: "legacy"
            )
            guard generation == accountSessionGeneration,
                  storedSession?.session == session
            else { return }
            profilePhotoSyncState = .pending
            scheduleOutboxRetry()
        } catch {
            await mediaEngine.discardPrepared(prepared)
        }
    }

    private static func store(
        _ expected: CloudLocalStore?,
        matches current: CloudLocalStore?
    ) -> Bool {
        switch (expected, current) {
        case (nil, nil): true
        case let (expected?, current?): expected === current
        default: false
        }
    }

    func signOut() async {
        #if DEBUG
        if isDemoMode {
            leaveDemoMode()
            return
        }
        #endif
        beginSessionTeardown()
        let sessionToken = storedSession?.session.token
        if let sessionToken {
            // Save before clearing the active session. If the app is killed or offline, the next
            // launch still has enough information to revoke the server session.
            try? await tokenStore.savePendingRevocationToken(
                sessionToken,
                localReplicaAccountId: storedSession?.session.accountId
            )
        }
        await clearLocalSession(finalStatus: "Signed out")
        if let sessionToken {
            Task { [weak self] in await self?.revokeSignedOutToken(sessionToken) }
        }
    }

    func pendingDestructiveLogoutItemCount() async -> Int {
        (try? await localStore?.pendingDestructiveLogoutItemCount()) ?? 0
    }

    private func revokeSignedOutToken(_ token: String) async {
        do {
            _ = try await api.revokeSession(token: token)
            try await tokenStore.clearPendingRevocationToken(ifMatches: token)
        } catch {
            if revocationIsTerminal(error) {
                try? await tokenStore.clearPendingRevocationToken(ifMatches: token)
            }
        }
    }

    private func revocationIsTerminal(_ error: Error) -> Bool {
        guard let apiError = error as? CloudAPIError else { return false }
        return apiError.status == 401 || apiError.status == 404
    }

    func loadDevices() async {
        #if DEBUG
        if isDemoMode {
            devices = [
                CloudDevice(
                    id: "demo-device",
                    platform: "ios",
                    deviceName: UIDevice.current.name,
                    createdAt: Self.demoTimestamp(minutesAgo: 1_440),
                    lastSeenAt: Self.demoTimestamp(minutesAgo: 0),
                    current: true
                )
            ]
            return
        }
        #endif
        guard let token = storedSession?.session.token, !loadingDevices else { return }
        loadingDevices = true
        defer { loadingDevices = false }
        do {
            devices = try await api.listDevices(token: token)
            status = "Devices updated"
        } catch {
            status = "Could not load devices: \(error.localizedDescription)"
        }
    }

    func revokeDevice(_ device: CloudDevice) async {
        guard !device.current, let token = storedSession?.session.token else { return }
        do {
            _ = try await api.revokeDevice(id: device.id, token: token)
            devices.removeAll { $0.id == device.id }
            status = "Device signed out"
        } catch {
            status = "Could not revoke device: \(error.localizedDescription)"
        }
    }

    func loadTwoFactorStatus() async {
        guard let token = storedSession?.session.token else { return }
        do {
            let response = try await api.twoFactorStatus(token: token)
            twoFactorEnabled = response.enabled
            twoFactorRecoveryCodesRemaining = response.recoveryCodesRemaining
        } catch let error as CloudAPIError where error.status == 404 {
            twoFactorEnabled = false
            twoFactorRecoveryCodesRemaining = 0
        } catch {
            status = "Could not load two-step verification: \(error.localizedDescription)"
        }
    }

    func acknowledgeRecoveryCodes() {
        recoveredTwoFactorCodes = []
    }

    func requestSecurityChangeCode() async -> Bool {
        guard let token = storedSession?.session.token, !securityChangeInFlight else { return false }
        securityChangeInFlight = true
        defer { securityChangeInFlight = false }
        do {
            let response = try await api.startSecurityStepUp(token: token)
            securityCode = response.code ?? ""
            status = "Security code requested"
            return true
        } catch {
            status = "Could not request security code: \(error.localizedDescription)"
            return false
        }
    }

    func verifySecurityChangeCode() async -> Bool {
        guard let token = storedSession?.session.token,
              securityCode.filter(\.isNumber).count == 6,
              !securityChangeInFlight
        else { return false }
        securityChangeInFlight = true
        defer { securityChangeInFlight = false }
        do {
            let response = try await api.checkSecurityStepUp(
                code: securityCode.filter(\.isNumber),
                token: token
            )
            securityStepUpToken = response.stepUpToken
            return true
        } catch {
            status = "Security verification failed: \(error.localizedDescription)"
            return false
        }
    }

    func saveTwoFactor(password: String, currentCredential: String?) async -> Bool {
        guard let saved = storedSession,
              let stepUpToken = securityStepUpToken,
              !securityChangeInFlight
        else { return false }
        securityChangeInFlight = true
        defer { securityChangeInFlight = false }
        do {
            let response = try await api.configureTwoFactor(
                stepUpToken: stepUpToken,
                password: password,
                currentCredential: currentCredential,
                token: saved.session.token
            )
            let sessionInstalled = await applySecuritySession(
                response.session,
                replacing: saved
            )
            recoveredTwoFactorCodes = response.recoveryCodes ?? []
            twoFactorEnabled = true
            twoFactorRecoveryCodesRemaining = recoveredTwoFactorCodes.count
            securityStepUpToken = nil
            securityCode = ""
            status = sessionInstalled
                ? "Two-step verification updated"
                : "Two-step verification updated. Sign in again to resume your saved chats."
            return true
        } catch {
            status = "Could not update two-step verification: \(error.localizedDescription)"
            return false
        }
    }

    func disableTwoFactor(currentCredential: String) async -> Bool {
        guard let saved = storedSession,
              let stepUpToken = securityStepUpToken,
              !securityChangeInFlight
        else { return false }
        securityChangeInFlight = true
        defer { securityChangeInFlight = false }
        do {
            let response = try await api.disableTwoFactor(
                stepUpToken: stepUpToken,
                currentCredential: currentCredential,
                token: saved.session.token
            )
            let sessionInstalled = await applySecuritySession(
                response.session,
                replacing: saved
            )
            twoFactorEnabled = false
            twoFactorRecoveryCodesRemaining = 0
            recoveredTwoFactorCodes = []
            securityStepUpToken = nil
            securityCode = ""
            status = sessionInstalled
                ? "Two-step verification disabled"
                : "Two-step verification disabled. Sign in again to resume your saved chats."
            return true
        } catch {
            status = "Could not disable two-step verification: \(error.localizedDescription)"
            return false
        }
    }

    func regenerateTwoFactorRecoveryCodes(currentCredential: String) async -> Bool {
        guard let saved = storedSession,
              let stepUpToken = securityStepUpToken,
              !securityChangeInFlight
        else { return false }
        securityChangeInFlight = true
        defer { securityChangeInFlight = false }
        do {
            let response = try await api.regenerateTwoFactorRecoveryCodes(
                stepUpToken: stepUpToken,
                currentCredential: currentCredential,
                token: saved.session.token
            )
            let sessionInstalled = await applySecuritySession(
                response.session,
                replacing: saved
            )
            recoveredTwoFactorCodes = response.recoveryCodes ?? []
            twoFactorRecoveryCodesRemaining = recoveredTwoFactorCodes.count
            securityStepUpToken = nil
            securityCode = ""
            status = sessionInstalled
                ? "Recovery codes replaced"
                : "Recovery codes replaced. Sign in again to resume your saved chats."
            return true
        } catch {
            status = "Could not replace recovery codes: \(error.localizedDescription)"
            return false
        }
    }

    private func applySecuritySession(
        _ session: CloudSession,
        replacing saved: StoredCloudSession
    ) async -> Bool {
        guard canInstallReissuedSession(replacing: saved) else {
            await abandonReissuedSession(
                session.token,
                preservingLocalReplicaFor: saved.session.accountId
            )
            return false
        }
        let replacement = StoredCloudSession(
            session: session,
            phone: saved.phone,
            displayName: saved.displayName
        )
        do {
            try await tokenStore.save(replacement)
        } catch {
            // The server already committed the security change and superseded `saved`. Establish
            // the replica-authentication fence before remote cleanup can consume its own marker.
            try? await tokenStore.savePendingReauthentication(
                accountId: saved.session.accountId
            )
            await abandonReissuedSession(
                session.token,
                preservingLocalReplicaFor: saved.session.accountId
            )
            await pauseForExpiredSession(saved)
            return false
        }
        // Saving crosses an actor boundary. Logout, remote revocation, or account replacement may
        // have won while Keychain was writing; remove only this response and never resurrect it.
        guard canInstallReissuedSession(replacing: saved) else {
            try? await tokenStore.clearSession(ifTokenMatches: session.token)
            await abandonReissuedSession(
                session.token,
                preservingLocalReplicaFor: saved.session.accountId
            )
            return false
        }
        installAuthenticatedSession(replacement)
        await startHints(token: session.token)
        return true
    }

    private func canInstallReissuedSession(replacing saved: StoredCloudSession) -> Bool {
        !sessionTeardownActive
            && sessionClearBarrier == nil
            && storedSession?.session.accountId == saved.session.accountId
            && storedSession?.session.deviceId == saved.session.deviceId
            && storedSession?.session.token == saved.session.token
    }

    private func abandonReissuedSession(
        _ token: String,
        preservingLocalReplicaFor accountId: String
    ) async {
        do {
            try await tokenStore.savePendingRevocationToken(
                token,
                eraseLocalReplicaOnLaunch: false,
                localReplicaAccountId: accountId
            )
        } catch {
            // Keychain is already unavailable. A direct best-effort revoke is the only remaining
            // safe cleanup path; the replacement is never installed in memory.
            _ = try? await api.revokeSession(token: token)
            return
        }
        await revokeSignedOutToken(token)
    }

    func requestAccountDeletionCode() async -> Bool {
        #if DEBUG
        if isDemoMode {
            accountDeletionRequested = true
            accountDeletionCode = "123456"
            status = "Deletion code requested"
            return true
        }
        #endif
        guard let token = storedSession?.session.token, !accountDeletionInFlight else { return false }
        accountDeletionInFlight = true
        defer { accountDeletionInFlight = false }
        do {
            let response = try await api.startAccountDeletion(token: token)
            accountDeletionRequested = true
            accountDeletionCode = response.code ?? ""
            status = "Deletion code requested"
            return true
        } catch {
            status = "Could not request deletion code: \(error.localizedDescription)"
            return false
        }
    }

    func cancelAccountDeletion() {
        guard !accountDeletionInFlight else { return }
        accountDeletionRequested = false
        accountDeletionCode = ""
    }

    func deleteAccount() async -> Bool {
        #if DEBUG
        if isDemoMode {
            leaveDemoMode()
            return true
        }
        #endif
        guard let saved = storedSession, !accountDeletionInFlight else { return false }
        let digits = accountDeletionCode.filter(\.isNumber)
        guard digits.count == 6 else {
            status = "Enter the 6-digit deletion code"
            return false
        }
        accountDeletionInFlight = true
        defer { accountDeletionInFlight = false }
        // Persist intent before the network call. If the app is killed after the server commits,
        // launch will not restore a now-invalid session or leave the local replica visible.
        try? await tokenStore.savePendingRevocationToken(
            saved.session.token,
            localReplicaAccountId: saved.session.accountId
        )
        do {
            _ = try await api.deleteAccount(code: digits, token: saved.session.token)
            await clearLocalSession(finalStatus: "Account deleted")
            try? await tokenStore.clearPendingRevocationToken(ifMatches: saved.session.token)
            return true
        } catch {
            if let apiError = error as? CloudAPIError {
                if apiError.status == 401 || apiError.status == 403 {
                    await clearLocalSession(finalStatus: "Session ended")
                    try? await tokenStore.clearPendingRevocationToken(ifMatches: saved.session.token)
                    return true
                }
                // The server definitely rejected this request before deletion completed.
                try? await tokenStore.clearPendingRevocationToken(ifMatches: saved.session.token)
            }
            status = "Could not confirm account deletion: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    private func clearLocalSession(finalStatus: String) async -> Bool {
        if sessionClearBarrier != nil {
            return await withCheckedContinuation { continuation in
                sessionClearBarrier?.waiters.append(continuation)
            }
        }
        // This flag changes synchronously before the first suspension point. User actions cannot
        // enqueue new Saved/forward SQL while teardown is waiting on older work.
        sessionTeardownActive = true
        let id = UUID()
        sessionClearBarrier = SessionClearBarrier(id: id, waiters: [])
        let succeeded = await performClearLocalSession(finalStatus: finalStatus)
        if sessionClearBarrier?.id == id {
            let waiters = sessionClearBarrier?.waiters ?? []
            sessionClearBarrier = nil
            waiters.forEach { $0.resume(returning: succeeded) }
        }
        return succeeded
    }

    private func performClearLocalSession(finalStatus: String) async -> Bool {
        beginSessionTeardown()
        await SessionCredentialCoordinator.shared.clear()
        // Both session fences are entered before teardown's first suspension point. Draft/media
        // work validates the epoch; preference work validates the account generation.
        isSessionTeardownInProgress = true
        accountSessionGeneration &+= 1
        // Prevent an old ensure from publishing while its exact task is cancelled and awaited.
        savedMessagesSessionGeneration &+= 1
        savedMessagesCapabilityState = .unknown
        // Capture must be fenced before teardown reaches any unrelated actor or disk await.
        await groupCallCoordinator.unbind()
        let savedOperations = Array(trackedSavedOperations.values)
        trackedSavedOperations.removeAll()
        savedOperations.forEach { $0.cancel() }
        // Saved setup owns a nested, coalesced provisioning task inside the service actor. Reset
        // that exact task before awaiting the user-facing wrapper; otherwise an unstructured
        // network task that ignores parent cancellation could keep teardown waiting forever.
        await savedMessagesService.reset()
        await accessPurgeCoordinator.reset()
        await presenceCoordinator.reset(clearCacheValues: true)
        for operation in savedOperations { await operation.wait() }
        let accountId = storedSession?.session.accountId ?? expiredSessionAccountId
        await draftSyncCoordinator.suspendRetries()
        await profilePhotoSyncCoordinator.configure(store: nil, session: nil, enabled: false)
        var cleanupFailures: [String] = []
        do {
            try await tokenStore.savePendingLocalErasure(accountId: accountId)
        } catch {
            cleanupFailures.append(error.localizedDescription)
        }

        let composerTask = composerMediaTask
        let transferTasks = Array(mediaTransferTasks.values)
        let pendingDraftPersistenceTasks = Array(draftPersistenceTasks.values)
        let preferenceTasks = Array(preferenceMutationTasks.values)
        let pendingProfileSaveTasks = Array(profileSaveTasks.values)
        profileSaveTasks.removeAll()
        let pendingRetryTask = retryTask
        let terminalAcknowledgementTask = productivityTerminalAcknowledgementTask?.task
        productivityTerminalAcknowledgementTask = nil
        pendingProductivityTerminalNotice = nil
        // Fence find-in-chat publication immediately, then join its detached FTS child with the
        // rest of the SQLCipher readers before the replica is cleared or destroyed.
        inChatSearchGeneration &+= 1
        let pendingInChatSearchTask = inChatSearchTask
        inChatSearchTask = nil
        inChatSearch = nil
        focusedSearchMsgId = nil
        let backgroundTasks: [Task<Void, Never>] = [
            hintTask, networkObservationTask, memoryPressureTask,
            pendingRetryTask, resendTask, recordingTask,
            composerTask, profileSyncTask,
            profilePhotoMigrationTask,
            postSignInTask, postSyncWorkTask, historyHydrationTask, dialogObservationTask,
            openingAnchorHydrationTask,
            timelineObservationTask, draftObservationTask,
            viewportPersistenceTask, mediaDownloadTask,
            readReceiptRetryTask, replicaIntegrityTask, pendingInChatSearchTask,
            terminalAcknowledgementTask, credentialRefreshLoopTask,
        ].compactMap { $0 }
        backgroundTasks.forEach { $0.cancel() }
        transferTasks.forEach { $0.cancel() }
        preferenceTasks.forEach { $0.cancel() }
        pendingProfileSaveTasks.forEach { $0.cancel() }
        await dialogPreferencesCoordinator.cancelAndWait()
        await productivitySyncCoordinator.cancelAndWait()
        voiceRecorder.cancel()
        await hintSocket?.stop()
        hintSocket = nil
        await replicaSyncCoordinator.stop()
        await mediaPrefetchScheduler.stop()
        mediaSchedulerForegrounded = false
        await BackgroundRuntimeCoordinator.shared.removeWorkHandlersAndWait()
        // Search owns detached observation/drain work against SQLCipher. Quiesce and release that
        // exact account/store generation before either clearing rows or destroying the replica.
        await searchCoordinator?.cancelAndWait()
        searchCoordinator = nil
        for task in backgroundTasks { await task.value }
        for task in transferTasks { await task.value }
        for task in preferenceTasks { await task.value }
        for task in pendingProfileSaveTasks { _ = await task.value }
        // Draft mutations are intentionally not cancelled: every captured composer generation
        // reaches SQLCipher before logout destroys the account replica.
        for task in pendingDraftPersistenceTasks { await task.value }
        await draftSyncCoordinator.cancelAndWait()
        hintTask = nil
        networkObservationTask = nil
        memoryPressureTask = nil
        retryTask = nil
        resendTask = nil
        recordingTask = nil
        composerMediaTask = nil
        profileSyncTask = nil
        profilePhotoMigrationTask = nil
        postSignInTask = nil
        postSyncWorkTask = nil
        historyHydrationTask = nil
        openingAnchorHydrationTask = nil
        dialogObservationTask = nil
        timelineObservationTask = nil
        draftObservationTask = nil
        draftPersistenceTasks.removeAll()
        draftPersistenceGenerations.removeAll()
        minimumObservedDraftGenerations.removeAll()
        viewportPersistenceTask = nil
        mediaDownloadTask = nil
        readReceiptRetryTask = nil
        replicaIntegrityTask = nil
        credentialRefreshLoopTask = nil
        composerMediaOperationId = nil
        composerMediaDialogId = nil
        activeComposerTransferId = nil
        mediaTransferTasks.removeAll()
        mediaTransferDialogIds.removeAll()
        temporaryPreviewURLsByDialog.removeAll()
        dialogPresentationGenerations.removeAll()
        preferenceMutationTasks.removeAll()
        mediaTransfersInFlight.removeAll()
        mediaGroupSendsInFlight.removeAll()
        draftSendsInFlightByDialog.removeAll()
        messageMutationsInFlight.removeAll()
        mutationTargetsBeingQueued.removeAll()
        syncInFlight = false
        syncAgain = false
        appliedSyncBatches = 0
        lastForegroundSyncFailure = nil
        lastSuccessfulServerContact = nil
        retryInFlight = false

        await mediaEngine.destroyLocalStateForLogout()
        MediaPresentationCache.shared.resetForSession()
        backgroundMediaRuntimePrepared = false
        mediaCacheBytes = 0

        do {
            try await tokenStore.clearAllProfiles()
        } catch {
            cleanupFailures.append(error.localizedDescription)
        }

        if opensDefaultLocalStore {
            // Both references must be released before removing WAL/SHM and the SQLCipher key.
            localStore = nil
            do {
                try await localStoreBootstrapper.destroyDefaultMediaState()
            } catch {
                cleanupFailures.append(error.localizedDescription)
            }
            do {
                try await localStoreBootstrapper.destroyDefaultStore()
            } catch {
                cleanupFailures.append(error.localizedDescription)
            }
        } else if let accountId {
            do {
                try await localStore?.clearAccount(accountId: accountId)
            } catch {
                cleanupFailures.append(error.localizedDescription)
            }
        }

        do {
            try await tokenStore.clear()
        } catch {
            cleanupFailures.append(error.localizedDescription)
        }
        if cleanupFailures.isEmpty {
            do {
                // A queued token can outlive successful local cleanup while the device is offline.
                // Downgrade it to remote-only before clearing the crash marker so a later login is
                // never erased merely because that old server revocation still needs retrying.
                try await tokenStore.markPendingRevocationLocalErasureCompleted(
                    accountId: accountId
                )
                try await tokenStore.clearPendingReauthentication()
                try await tokenStore.clearPendingLocalErasure()
            } catch {
                cleanupFailures.append(error.localizedDescription)
            }
        }
        storedSession = nil
        expiredSessionAccountId = nil
        activeDialogId = nil
        dialogs = []
        chatFolders = []
        chatFolderCollectionRevision = 0
        scheduledDeliveries = []
        savedMessagesDialogId = nil
        savedMessagesSetupInFlight = false
        savedMessagesSetupFailure = nil
        lines = []
        loadedLocalMessages = []
        pendingVisibleReadMessages = []
        openingTimelineAnchor = .bottom
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = true
        timelineBeforeCount = 40
        timelineAfterCount = 79
        canLoadEarlier = false
        loadingEarlier = false
        canLoadLater = false
        loadingLater = false
        historyHasMoreByDialog = [:]
        timelineForwardCursorByDialog = [:]
        timelineHasMoreForwardByDialog = [:]
        currentDraft = nil
        draftMentionsByDialog = [:]
        transientUnderlyingDraftText = nil
        transientUnderlyingComposerMode = nil
        transientVoiceComposerMode = nil
        cachedLinesByDialog = [:]
        cachedLocalMessagesByDialog = [:]
        cachedLineDialogOrder = []
        cachedConversationCostByDialog = [:]
        devices = []
        loadingDevices = false
        uploadedPushRegistration = nil
        uploadedVoIPPushRegistration = nil
        uploadedGroupCallCapabilityRegistration = nil
        callCoordinator.unbind()
        pts = 0
        phone = "+992 "
        displayName = ""
        peerPhone = ""
        draft = ""
        requestedCode = false
        authRequestInFlight = false
        authVerifyInFlight = false
        resendSeconds = 0
        code = ""
        accountDeletionRequested = false
        accountDeletionInFlight = false
        accountDeletionCode = ""
        profileDetails = .empty
        profileSaveInFlight = false
        profilePhotoSyncState = .localOnly
        profilePhotoDisplayData = nil
        canonicalProfilePhoto = nil
        profilePhotoRevision = 0
        composerMode = .text
        operationNotice = nil
        pendingProductivityTerminalNotice = nil
        #if DEBUG
        demoLinesByDialog = [:]
        #endif
        launchPhase = .signedOut
        conversationOpenState = .loadingLocal
        setReplicaSyncState(.offline)
        status = cleanupFailures.isEmpty
            ? finalStatus
            : "Signed out; local cleanup needs another attempt"
        return cleanupFailures.isEmpty
    }

    /// Changes the session epoch synchronously, before logout's first suspension point. Every
    /// subsequently resumed operation must still match this epoch before touching store or UI.
    private func beginSessionTeardown() {
        guard !sessionTearingDown else { return }
        sessionTearingDown = true
        sessionEpoch &+= 1
        draftObservationTask?.cancel()
        timelineObservationTask?.cancel()
        dialogObservationTask?.cancel()
        composerMediaTask?.cancel()
        for task in mediaTransferTasks.values { task.cancel() }
        retryTask?.cancel()
        postSyncWorkTask?.cancel()
    }

    func refreshMediaCacheUsage() async {
        if let localStore {
            mediaCacheBytes = await mediaEngine.cacheUsageBytes(localStore: localStore)
        } else {
            mediaCacheBytes = await mediaEngine.cacheUsageBytes()
        }
    }

    func loadMediaPolicies() async {
        mediaAutoDownloadPolicy = await mediaEngine.currentAutoDownloadPolicy()
        mediaCachePolicy = await mediaEngine.currentCachePolicy()
    }

    func updateMediaAutoDownloadPolicy(_ policy: MediaAutoDownloadPolicy) async {
        do {
            try await mediaEngine.updateAutoDownloadPolicy(policy)
            mediaAutoDownloadPolicy = policy
        } catch {
            status = "Could not save automatic download settings"
        }
    }

    func updateMediaCachePolicy(_ policy: MediaCachePolicy) async {
        do {
            try await mediaEngine.updateCachePolicy(policy)
            mediaCachePolicy = policy
            await refreshMediaCacheUsage()
        } catch {
            status = "Could not save media cache settings"
        }
    }

    func clearMediaCache() async {
        guard !clearingMediaCache else { return }
        clearingMediaCache = true
        defer { clearingMediaCache = false }
        MediaPresentationCache.shared.removeAll()
        if let localStore {
            await mediaEngine.clearDownloadedCache(localStore: localStore)
        } else {
            await mediaEngine.clearDownloadedCache()
        }
        await refreshMediaCacheUsage()
        status = "Downloaded media cleared"
    }

    func clearMediaCache(kind: String) async {
        guard !clearingMediaCache, let localStore else { return }
        clearingMediaCache = true
        defer { clearingMediaCache = false }
        let mediaIds = (try? await localStore.mediaIds(kind: kind)) ?? []
        MediaPresentationCache.shared.invalidate(mediaIds: mediaIds)
        await mediaEngine.clearMediaCache(mediaIds: mediaIds, localStore: localStore)
        await refreshMediaCacheUsage()
        status = "Downloaded media cleared"
    }

    func clearMediaCache(dialogId: String) async {
        guard !clearingMediaCache, let localStore else { return }
        clearingMediaCache = true
        defer { clearingMediaCache = false }
        let mediaIds = (try? await localStore.mediaIds(dialogId: dialogId)) ?? []
        MediaPresentationCache.shared.invalidate(mediaIds: mediaIds)
        await mediaEngine.clearMediaCache(mediaIds: mediaIds, localStore: localStore)
        await refreshMediaCacheUsage()
        status = "Downloaded media cleared"
    }

    private func queueMediaDownloads(
        _ mediaItems: [CloudMedia],
        dialogId: String?,
        visible: Bool
    ) async {
        guard visible, !mediaItems.isEmpty, let localStore else { return }
        let snapshot = ReplicaNetworkMonitor.shared.snapshot()
        let network = snapshot.mediaNetworkClass
        let chat = if let dialogId {
            (try? await localStore.mediaChatClass(dialogId: dialogId)) ?? .privateChat
        } else {
            MediaChatClass.privateChat
        }

        for media in mediaItems {
            _ = await mediaEngine.enqueueAutoDownload(
                media: media,
                chat: chat,
                network: network,
                dialogId: dialogId,
                localStore: localStore,
                visible: visible
            )
        }
        scheduleMediaDownloadProcessing()
    }

    /// Telegram-style arrival prefetch: media referenced by newly written messages is queued for
    /// download immediately under the auto-download policy, so a chat can open with its media
    /// already on disk. The engine skips components that are already downloaded, so re-applying
    /// the same messages is cheap.
    private func enqueueArrivalMediaDownloads(_ messages: [CloudMessage], recentOnly: Bool = false) async {
        await enqueueArrivalMediaDownloads(
            messages.map { (media: $0.media, dialogId: $0.dialogId, state: $0.state, serverTs: $0.serverTs) },
            recentOnly: recentOnly
        )
    }

    private func enqueueArrivalMediaDownloads(window messages: [LocalMessage]) async {
        await enqueueArrivalMediaDownloads(
            messages.map { (media: $0.media, dialogId: $0.dialogId, state: $0.state, serverTs: $0.serverTs) },
            recentOnly: false
        )
    }

    private func enqueueArrivalMediaDownloads(
        _ candidates: [(media: CloudMedia?, dialogId: String, state: String, serverTs: String?)],
        recentOnly: Bool
    ) async {
        guard let localStore else { return }
        let snapshot = ReplicaNetworkMonitor.shared.snapshot()
        guard snapshot.allowsEssentialSync else { return }
        let network = snapshot.mediaNetworkClass
        let cutoff = recentOnly ? Date(timeIntervalSinceNow: -Self.arrivalPrefetchMaxAge) : nil
        var chatClassByDialog: [String: MediaChatClass] = [:]
        var enqueuedAny = false
        for candidate in candidates {
            guard let media = candidate.media, candidate.state == "visible" else { continue }
            if let cutoff {
                guard let serverTs = candidate.serverTs,
                      let timestamp = Self.serverTimestamp(serverTs),
                      timestamp >= cutoff else { continue }
            }
            let chat: MediaChatClass
            if let known = chatClassByDialog[candidate.dialogId] {
                chat = known
            } else {
                chat = (try? await localStore.mediaChatClass(dialogId: candidate.dialogId)) ?? .privateChat
                chatClassByDialog[candidate.dialogId] = chat
            }
            _ = await mediaEngine.enqueueAutoDownload(
                media: media,
                chat: chat,
                network: network,
                dialogId: candidate.dialogId,
                localStore: localStore
            )
            enqueuedAny = true
        }
        if enqueuedAny { scheduleMediaDownloadProcessing() }
    }

    nonisolated static let arrivalPrefetchMaxAge: TimeInterval = 30 * 24 * 60 * 60

    nonisolated static func serverTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private func scheduleMediaDownloadProcessing() {
        guard mediaDownloadTask == nil else { return }
        mediaDownloadTask = Task { [weak self] in
            guard let self else { return }
            let networkClass = ReplicaNetworkMonitor.shared.snapshot().networkClass
            await self.mediaPrefetchScheduler.wake(networkClass: networkClass)
            self.mediaDownloadTask = nil
        }
    }

    private func processMediaDownloadJobs(maximumJobs: Int) async {
        for _ in 0..<maximumJobs {
            guard await processOneMediaDownload(component: nil) else { break }
        }
        await refreshMediaCacheUsage()
        guard let localStore else { return }
        let remainingJobs = try? await localStore.mediaDownloadJobsReady(limit: 1)
        if remainingJobs?.isEmpty == false {
            BackgroundRuntimeCoordinator.shared.scheduleProcessing(
                earliestBeginDate: Date(timeIntervalSinceNow: 60)
            )
        } else if let nextRetry = try? await localStore.nextMediaDownloadRetryDate() {
            BackgroundRuntimeCoordinator.shared.scheduleProcessing(earliestBeginDate: nextRetry)
        }
    }

    private func processOneMediaDownload(component: MediaDownloadComponent?) async -> Bool {
        let networkSnapshot = ReplicaNetworkMonitor.shared.snapshot()
        guard networkSnapshot.allowsEssentialSync,
              let token = storedSession?.session.token,
              let localStore,
              !Task.isCancelled else { return false }
        guard let item = await mediaEngine.dequeueAutoDownload(
            localStore: localStore,
            component: component
        ) else { return false }
        let readyCount = (try? await localStore.mediaDownloadJobsReady(limit: 200).count) ?? 0
        LocalFirstMetrics.queueDepth(readyCount)
        let chat = if let dialogId = item.dialogId {
            (try? await localStore.mediaChatClass(dialogId: dialogId)) ?? .privateChat
        } else {
            MediaChatClass.privateChat
        }
        do {
            // Revalidate the live policy and path after the durable claim; scrolling, roaming, and
            // Low Data Mode can all change while a job waits in SQLCipher.
            let currentNetwork = ReplicaNetworkMonitor.shared.snapshot()
            try await mediaEngine.performAutoDownload(
                item,
                token: token,
                localStore: localStore,
                chat: chat,
                network: currentNetwork.mediaNetworkClass
            )
            if item.component == .thumbnail,
               item.media.kind == "photo" || item.media.kind == "video" {
                _ = await presentationImage(for: item.media, variant: .bubble720)
            } else if item.component == .fullMedia, item.media.kind == "photo" {
                _ = await presentationImage(for: item.media, variant: .screen2048)
            } else if item.component == .fullMedia, item.media.kind == "video" {
                _ = await presentationImage(for: item.media, variant: .videoPoster)
                await prewarmStreamingVideoAssetIfLocal(for: item.media)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            if await mediaEngine.areAutomaticDownloadsSuspendedForLowDisk(),
               operationNotice?.title != "Storage needed for media" {
                presentNotice(
                    "Storage needed for media",
                    message: "Toj kept your saved chats, but paused new automatic media downloads to preserve free space."
                )
            }
            if let nextRetry = try? await localStore.nextMediaDownloadRetryDate() {
                BackgroundRuntimeCoordinator.shared.scheduleProcessing(earliestBeginDate: nextRetry)
            }
            if case .authenticationRequired = cloudFailureDisposition(error) { return false }
            return true
        }
    }

    private func startResendCountdown(_ seconds: Int) {
        resendTask?.cancel()
        resendSeconds = max(0, seconds)
        guard resendSeconds > 0 else {
            resendTask = nil
            return
        }
        resendTask = Task { [weak self] in
            while let self, self.resendSeconds > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.resendSeconds -= 1
            }
            self?.resendTask = nil
        }
    }

    func openPeer() async -> String? {
        #if DEBUG
        if isDemoMode {
            let trimmed = peerPhone.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let dialogId = "demo-\(trimmed.filter(\.isNumber))"
            if !dialogs.contains(where: { $0.id == dialogId }) {
                dialogs.insert(Dialog(
                    id: dialogId,
                    title: trimmed,
                    subtitle: String(localized: "Demo conversation"),
                    updatedAt: Self.demoTimestamp(minutesAgo: 0),
                    isPending: false,
                    unreadCount: 0
                ), at: 0)
                demoLinesByDialog[dialogId] = [Line(
                    id: UUID().uuidString,
                    dialogId: dialogId,
                    msgId: 1,
                    clientMsgId: UUID().uuidString,
                    text: String(localized: "This chat is local to demo mode."),
                    mine: false,
                    delivery: .sent,
                    timestamp: Self.demoTimestamp(minutesAgo: 0)
                )]
            }
            peerPhone = ""
            await selectDialog(dialogId)
            status = "Chat ready"
            return dialogId
        }
        #endif
        guard let token = storedSession?.session.token else { return nil }
        let trimmed = peerPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        do {
            status = "Looking up contact"
            let found = try await api.lookupContact(phone: trimmed, token: token)
            guard let peerAccountId = found.accountId else {
                status = "No account found"
                return nil
            }
            let dialog = try await api.createDirectDialog(peerAccountId: peerAccountId, token: token)
            let title = displayTitle(found.displayName, fallback: trimmed)
            try await localStore?.upsertDialog(dialogId: dialog.dialogId, title: title)
            if let accountId = storedSession?.session.accountId {
                try await localStore?.saveMembers(dialogId: dialog.dialogId, members: [
                    BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 0),
                    BootstrapDialogMember(accountId: peerAccountId, role: "member", lastReadMsgId: 0)
                ])
            }
            if let profile = Self.cloudProfile(from: found) {
                try await localStore?.saveProfile(profile)
            }
            await refreshDialogs()
            await selectDialog(dialog.dialogId)
            status = "Chat ready"
            scheduleSync()
            return dialog.dialogId
        } catch {
            status = "Open chat failed: \(error.localizedDescription)"
            return nil
        }
    }

    func contactIdentity(phone: String) async throws -> ContactIdentity? {
        #if DEBUG
        if isDemoMode {
            let digits = phone.filter(\.isNumber)
            guard let last = digits.last?.wholeNumberValue, last.isMultiple(of: 2) else { return nil }
            return ContactIdentity(accountId: "demo-contact-\(digits)", displayName: phone)
        }
        #endif
        guard let token = storedSession?.session.token else { return nil }
        let found = try await api.lookupContact(phone: phone, token: token)
        guard let accountId = found.accountId else { return nil }
        return ContactIdentity(
            accountId: accountId,
            displayName: displayTitle(found.displayName, fallback: phone),
            bio: found.bio,
            birthday: found.birthday,
            colorIndex: found.colorIndex
        )
    }

    func openPeer(phone: String) async -> String? {
        peerPhone = phone
        return await openPeer()
    }

    @discardableResult
    func openUsername(_ value: String) async -> String? {
        guard let token = storedSession?.session.token else { return nil }
        do {
            status = "Looking up username"
            let found = try await api.lookupUsername(value, token: token)
            guard let peerAccountId = found.accountId else {
                presentNotice("Username unavailable", message: "No active account uses that username.")
                return nil
            }
            if peerAccountId == storedSession?.session.accountId {
                presentNotice("This is your profile", message: "Share this link so other people can find you.")
                return nil
            }
            let dialog = try await api.createDirectDialog(peerAccountId: peerAccountId, token: token)
            let title = displayTitle(found.displayName, fallback: "@\(value)")
            try await localStore?.upsertDialog(dialogId: dialog.dialogId, title: title)
            if let accountId = storedSession?.session.accountId {
                try await localStore?.saveMembers(dialogId: dialog.dialogId, members: [
                    BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 0),
                    BootstrapDialogMember(accountId: peerAccountId, role: "member", lastReadMsgId: 0)
                ])
            }
            if let profile = Self.cloudProfile(from: found) { try await localStore?.saveProfile(profile) }
            await refreshDialogs()
            await selectDialog(dialog.dialogId)
            pendingDeepLinkDialogId = dialog.dialogId
            scheduleSync()
            return dialog.dialogId
        } catch {
            presentNotice("Could not open profile", message: error.localizedDescription)
            return nil
        }
    }

    func createGroup(title: String, memberIds: [String], photoData: Data? = nil) async -> String? {
        guard capabilities.contains(.groups),
              let accountId = storedSession?.session.accountId,
              let localStore
        else { return nil }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMembers = Array(Set(memberIds.filter { $0 != accountId })).sorted()
        guard !normalizedTitle.isEmpty, normalizedTitle.count <= 128,
              normalizedTitle.lengthOfBytes(using: .utf8) <= 256,
              !normalizedMembers.isEmpty, normalizedMembers.count <= 199 else {
            presentNotice(
                "Group could not be created",
                message: "Choose at least one member and a group name up to 128 characters."
            )
            return nil
        }

        let groupId = UUID().uuidString.lowercased()
        do {
            let preparedPhoto: PreparedMediaUpload?
            if let photoData {
                guard let photo = SafeMediaImageDecoder.preparePhotoUpload(photoData) else {
                    presentNotice(
                        "Group photo could not be used",
                        message: "Choose a valid photo and try again."
                    )
                    return nil
                }
                preparedPhoto = try await mediaEngine.prepare(
                    data: photo.data,
                    kind: "photo",
                    contentType: photo.contentType,
                    fileName: "group-photo.\(photo.filenameExtension)",
                    width: photo.pixelWidth,
                    height: photo.pixelHeight,
                    thumbnail: photo.thumbnail
                )
            } else {
                preparedPhoto = nil
            }
            _ = try await localStore.createPendingGroup(
                groupId: groupId,
                title: normalizedTitle,
                memberIds: normalizedMembers,
                creatorAccountId: accountId,
                localPhotoReference: preparedPhoto?.encryptedSourcePath
            )
            if let preparedPhoto {
                try await localStore.insertMediaTransfer(
                    prepared: preparedPhoto,
                    dialogId: groupId,
                    clientMsgId: "group-photo:\(preparedPhoto.transferId)",
                    caption: "",
                    replyToMsgId: nil,
                    purpose: "group_photo"
                )
            }
            await refreshDialogs()
            scheduleOutboxRetry()
            return groupId
        } catch {
            presentNotice("Group could not be saved", message: error.localizedDescription)
            return nil
        }
    }

    func updateGroupPhoto(dialogId: String, data: Data) async -> Bool {
        guard let localStore else { return false }
        do {
            guard let photo = SafeMediaImageDecoder.preparePhotoUpload(data) else {
                throw CloudAppModelError.invalidMedia
            }
            let prepared = try await mediaEngine.prepare(
                data: photo.data,
                kind: "photo",
                contentType: photo.contentType,
                fileName: "group-photo.\(photo.filenameExtension)",
                width: photo.pixelWidth,
                height: photo.pixelHeight,
                thumbnail: photo.thumbnail
            )
            try await localStore.insertMediaTransfer(
                prepared: prepared,
                dialogId: dialogId,
                clientMsgId: "group-photo:\(prepared.transferId)",
                caption: "",
                replyToMsgId: nil,
                purpose: "group_photo"
            )
            scheduleOutboxRetry()
            return true
        } catch {
            presentNotice("Group photo was not changed", message: error.localizedDescription)
            return false
        }
    }

    func retryGroupCreation(dialogId: String) async {
        guard let localStore else { return }
        try? await localStore.retryFailedGroupCreation(groupId: dialogId)
        await refreshDialogs()
        scheduleOutboxRetry()
    }

    func loadGroupProfile(dialogId: String) async {
        guard capabilities.contains(.groups),
              let token = storedSession?.session.token,
              let localStore else { return }
        do {
            let envelope = try await api.group(id: dialogId, token: token)
            groupPermissionsByDialog[dialogId] = GroupPermissions(
                membersCanSend: envelope.group.membersCanSend ?? true,
                membersCanAddMembers: envelope.group.membersCanAddMembers ?? false,
                membersCanEditInfo: envelope.group.membersCanEditInfo ?? false
            )
            try await localStore.applyGroupEnvelope(envelope)
            var cursor: String?
            var collected: [CloudGroupMember] = []
            var profiles: [String: CloudProfile] = Dictionary(
                uniqueKeysWithValues: envelope.profiles.map { ($0.accountId, $0) }
            )
            repeat {
                let page = try await api.groupMembers(
                    id: dialogId,
                    cursor: cursor,
                    token: token
                )
                try await localStore.applyGroupMembersPage(page, generation: envelope.group.revision.description)
                collected.append(contentsOf: page.members)
                for profile in page.profiles { profiles[profile.accountId] = profile }
                cursor = page.hasMore ? page.nextCursor : nil
            } while cursor != nil
            groupMembersByDialog[dialogId] = collected.map { member in
                GroupMember(
                    accountId: member.accountId,
                    displayName: profiles[member.accountId]?.displayName ?? shortDialogId(member.accountId),
                    photo: profiles[member.accountId]?.photo,
                    role: member.role,
                    isActive: member.isActive
                )
            }
            await refreshDialogs()
        } catch {
            presentNotice("Group details unavailable", message: error.localizedDescription)
        }
    }

    private func groupCallParticipantName(accountId: String, dialogId: String) -> String {
        if accountId == storedSession?.session.accountId {
            return displayName.isEmpty ? String(localized: "You") : displayName
        }
        return groupMembersByDialog[dialogId]?
            .first(where: { $0.accountId == accountId })?
            .displayName ?? shortDialogId(accountId)
    }

    func groupMemberPhoto(accountId: String, dialogId: String) -> CloudMedia? {
        groupMembersByDialog[dialogId]?.first(where: { $0.accountId == accountId })?.photo
    }

    func updateGroupTitle(dialogId: String, title: String) async -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 128,
              normalized.lengthOfBytes(using: .utf8) <= 256 else { return false }
        return await submitGroupMutation(
            dialogId: dialogId,
            operation: "update_title",
            payload: GroupMutationPayload(title: normalized)
        )
    }

    func setGroupMuted(dialogId: String, muted: Bool) {
        guard !isSessionTeardownInProgress else { return }
        if capabilities.contains(.chatOrganization) {
            launchDialogPreferenceMutation(
                dialogId: dialogId,
                field: .muted,
                desiredValue: muted
            )
        } else if capabilities.contains(.groups) {
            launchLegacyGroupMute(dialogId: dialogId, muted: muted)
        }
    }

    func updateGroupPermissions(dialogId: String, permissions: GroupPermissions) async -> Bool {
        guard let token = storedSession?.session.token else { return false }
        do {
            let envelope = try await api.updateGroupPermissions(
                id: dialogId,
                membersCanSend: permissions.membersCanSend,
                membersCanAddMembers: permissions.membersCanAddMembers,
                membersCanEditInfo: permissions.membersCanEditInfo,
                clientMutationId: UUID().uuidString.lowercased(),
                token: token
            )
            try await localStore?.applyGroupEnvelope(envelope)
            groupPermissionsByDialog[dialogId] = GroupPermissions(
                membersCanSend: envelope.group.membersCanSend ?? permissions.membersCanSend,
                membersCanAddMembers: envelope.group.membersCanAddMembers ?? permissions.membersCanAddMembers,
                membersCanEditInfo: envelope.group.membersCanEditInfo ?? permissions.membersCanEditInfo
            )
            await refreshDialogs()
            return true
        } catch {
            presentNotice("Permissions were not changed", message: error.localizedDescription)
            return false
        }
    }

    func addGroupMembers(dialogId: String, accountIds: [String]) async -> Bool {
        let normalized = Array(Set(accountIds)).sorted()
        guard !normalized.isEmpty else { return false }
        return await submitGroupMutation(
            dialogId: dialogId,
            operation: "add_members",
            payload: GroupMutationPayload(memberIds: normalized)
        )
    }

    func removeGroupMember(dialogId: String, accountId: String) async -> Bool {
        await submitGroupMutation(
            dialogId: dialogId,
            operation: "remove_member",
            payload: GroupMutationPayload(accountId: accountId)
        )
    }

    func changeGroupMemberRole(
        dialogId: String,
        accountId: String,
        role: String
    ) async -> Bool {
        return await submitGroupMutation(
            dialogId: dialogId,
            operation: "change_role",
            payload: GroupMutationPayload(accountId: accountId, role: role)
        )
    }

    func transferGroupOwnership(dialogId: String, accountId: String) async -> Bool {
        await submitGroupMutation(
            dialogId: dialogId,
            operation: "transfer_owner",
            payload: GroupMutationPayload(accountId: accountId)
        )
    }

    func leaveGroup(dialogId: String) async -> Bool {
        await submitGroupMutation(
            dialogId: dialogId,
            operation: "leave",
            payload: GroupMutationPayload()
        )
    }

    private func submitGroupMutation(
        dialogId: String,
        operation: String,
        payload: GroupMutationPayload
    ) async -> Bool {
        if operation == "notifications", isSessionTeardownInProgress { return false }
        guard
            capabilities.contains(.groups),
            let localStore,
            let accountId = storedSession?.session.accountId
        else { return false }
        let generation = accountSessionGeneration
        do {
            let mutationId = UUID().uuidString.lowercased()
            let payloadJSON = String(
                data: try JSONEncoder().encode(payload),
                encoding: .utf8
            ) ?? "{}"
            try await localStore.enqueueGroupMutation(
                dialogId: dialogId,
                operation: operation,
                payloadJSON: payloadJSON,
                clientMutationId: mutationId,
                accountId: accountId
            )
            guard
                !Task.isCancelled,
                generation == accountSessionGeneration,
                storedSession?.session.accountId == accountId
            else { return false }
            await retryPendingGroupMutations()
            guard
                !Task.isCancelled,
                generation == accountSessionGeneration,
                storedSession?.session.accountId == accountId
            else { return false }
            scheduleOutboxRetry()
            return true
        } catch {
            presentNotice("Group change could not be saved", message: error.localizedDescription)
            return false
        }
    }

    func selectDialog(_ dialogId: String) async {
        if activeDialogId != dialogId || timelineObservationTask == nil {
            beginConversationSelection(dialogId)
        }
        guard activeDialogId == dialogId, conversationOpenState == .loadingLocal else { return }
        await withCheckedContinuation { continuation in
            guard activeDialogId == dialogId, conversationOpenState == .loadingLocal else {
                continuation.resume()
                return
            }
            conversationOpenWaiters[dialogId, default: []].append(continuation)
        }
    }

    /// Starts the encrypted local observation before the navigation animation begins. This method
    /// performs no network work and publishes an LRU hit in the same main-actor turn as the tap.
    func prepareConversationOpen(dialogId: String, focusMsgId: Int64? = nil) {
        if let focusMsgId {
            // Set before selection so `beginConversationSelection` can anchor on it instead of
            // resetting to the bottom.
            pendingFocusMsgId = focusMsgId
        }
        guard activeDialogId != dialogId || timelineObservationTask == nil else { return }
        beginConversationSelection(dialogId)
    }

    private func scheduleActiveDraftPersistence(
        reason: DraftSyncCoordinator.FlushReason = .idle
    ) {
        #if DEBUG
        if isDemoMode {
            guard
                !suppressDraftPersistence,
                let dialogId = activeDialogId,
                let index = dialogs.firstIndex(where: { $0.id == dialogId })
            else { return }
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            dialogs[index].draftPreview = trimmed.isEmpty ? nil : trimmed
            return
        }
        #endif
        guard
            !sessionTearingDown,
            !suppressDraftPersistence,
            let dialogId = activeDialogId,
            storedSession != nil
        else { return }
        if case .editing = composerMode { return }
        let generation = (draftPersistenceGenerations[dialogId] ?? 0) &+ 1
        draftPersistenceGenerations[dialogId] = generation
        let text = draft
        let reply = activeReplyDraftContext()
        let mentions = resolvedMentions(in: text, dialogId: dialogId)
        let previous = draftPersistenceTasks[dialogId]
        draftPersistenceTasks[dialogId] = Task { [weak self] in
            // Preserve every local generation in order. The SQL row/outbox entry is still
            // coalesced by dialog, so this durability guarantee never creates a network backlog.
            await previous?.value
            guard let self else { return }
            do {
                let saved = try await self.draftSyncCoordinator.mutate(
                    dialogId: dialogId,
                    text: text,
                    replyToMsgId: reply.0,
                    replyPreview: reply.1,
                    mentions: mentions,
                    reason: reason
                )
                guard !self.sessionTearingDown else { return }
                self.minimumObservedDraftGenerations[dialogId] = max(
                    self.minimumObservedDraftGenerations[dialogId] ?? 0,
                    saved.localGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                self.status = "Draft could not be saved locally: \(error.localizedDescription)"
            }
            if self.draftPersistenceGenerations[dialogId] == generation {
                self.draftPersistenceTasks[dialogId] = nil
            }
        }
    }

    private func activeReplyDraftContext() -> (Int64?, CloudDraftReplyPreview?) {
        guard case let .replying(messageId, preview) = composerMode,
              let line = lines.first(where: { $0.id == messageId }),
              let msgId = line.msgId
        else { return (nil, nil) }
        let sender = loadedLocalMessages.first(where: { $0.localId == messageId })?.senderAccountId ?? ""
        return (
            msgId,
            CloudDraftReplyPreview(
                msgId: msgId,
                senderAccountId: sender,
                text: preview,
                unavailable: false
            )
        )
    }

    private func startDraftObservation(dialogId: String) {
        draftObservationTask?.cancel()
        guard let localStore, let accountId = storedSession?.session.accountId else { return }
        draftObservationTask = Task { [weak self, localStore] in
            do {
                let values = await localStore.observeDraft(
                    accountId: accountId,
                    dialogId: dialogId
                )
                for try await observed in values {
                    try Task.checkCancellation()
                    guard let self, self.activeDialogId == dialogId else { return }
                    self.acceptObservedDraft(observed)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.activeDialogId == dialogId else { return }
                self.status = "Draft observation paused: \(error.localizedDescription)"
            }
        }
    }

    private func acceptObservedDraft(_ observed: LocalDraft?) {
        if let dialogId = activeDialogId,
           draftPersistenceTasks[dialogId] != nil {
            return
        }
        if let observed,
           observed.localGeneration < (minimumObservedDraftGenerations[observed.dialogId] ?? 0) {
            return
        }
        currentDraft = observed
        guard transientUnderlyingDraftText == nil, transientVoiceComposerMode == nil else { return }
        suppressDraftPersistence = true
        draft = observed?.state == "active" ? observed?.text ?? "" : ""
        if let observed, observed.state == "active",
           let reply = observed.replyPreview, let replyId = observed.replyToMsgId {
            composerMode = .replying(
                messageId: "\(observed.dialogId):\(replyId)",
                preview: reply.unavailable
                    ? String(localized: "Original message unavailable")
                    : reply.text
            )
        } else {
            composerMode = .text
        }
        suppressDraftPersistence = false
        guard let observed else { return }
        let nsText = observed.text as NSString
        draftMentionsByDialog[observed.dialogId] = observed.mentions.compactMap { mention in
            let range = NSRange(location: mention.offset, length: mention.length)
            guard NSMaxRange(range) <= nsText.length else { return nil }
            return DraftMention(
                accountId: mention.accountId,
                token: nsText.substring(with: range)
            )
        }
    }

    /// Consumed by the next `beginConversationSelection`, then cleared.
    private var pendingFocusMsgId: Int64?

    private func beginConversationSelection(_ dialogId: String) {
        if let previousDialogId = activeDialogId, previousDialogId != dialogId {
            presenceCoordinator.dialogDidChange(from: previousDialogId)
            conversationOpenStartedAt.removeValue(forKey: previousDialogId)
            finishConversationOpenWaiters(dialogId: previousDialogId)
            let pendingPersistence = draftPersistenceTasks[previousDialogId]
            Task { [draftSyncCoordinator] in
                await pendingPersistence?.value
                _ = await draftSyncCoordinator.flush(dialogId: previousDialogId, force: true)
            }
        }
        openingAnchorHydrationGeneration &+= 1
        openingAnchorHydrationTask?.cancel()
        openingAnchorHydrationTask = nil
        draftObservationTask?.cancel()
        draftObservationTask = nil
        activeDialogId = dialogId
        conversationOpenStartedAt[dialogId] = Date()
        dialogSelectionGeneration &+= 1
        currentDraft = nil
        suppressDraftPersistence = true
        draft = ""
        suppressDraftPersistence = false
        composerMode = .text
        // A search result opens *at* its message, so the window is centred rather than
        // bottom-weighted and the anchor is the target instead of the unread watermark.
        let focus = pendingFocusMsgId
        pendingFocusMsgId = nil
        timelineBeforeCount = focus == nil ? 40 : 40
        timelineAfterCount = focus == nil ? 79 : 40
        openingTimelineAnchor = focus.map { .saved(msgId: $0) } ?? .bottom
        focusedSearchMsgId = focus
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = focus == nil
        pendingVisibleReadMessages = []
        canLoadEarlier = false
        loadingEarlier = false
        canLoadLater = false
        loadingLater = false

        // Publish the in-memory LRU synchronously. Returning chats never wait for Keychain,
        // SQLCipher, anchor resolution, or any network operation before cached bubbles appear.
        let hasPreparedSnapshot = cachedLinesByDialog[dialogId] != nil
        lines = cachedLinesByDialog[dialogId] ?? []
        loadedLocalMessages = cachedLocalMessagesByDialog[dialogId] ?? []
        conversationOpenState = hasPreparedSnapshot ? .cached : .loadingLocal
        #if DEBUG
        if isDemoMode {
            let storedDraft = dialogs.first(where: { $0.id == dialogId })?.draftPreview ?? ""
            suppressDraftPersistence = true
            draft = storedDraft
            suppressDraftPersistence = false
            openingTimelineAnchor = .bottom
            timelineIsAtBottom = true
            timelineTopVisibleMsgId = nil
            lines = demoLinesByDialog[dialogId] ?? []
            canLoadEarlier = false
            dialogs = dialogs.map { dialog in
                guard dialog.id == dialogId, dialog.unreadCount > 0 else { return dialog }
                var updated = dialog
                updated.unreadCount = 0
                updated.mentionCount = 0
                return updated
            }
            conversationOpenState = lines.isEmpty ? .empty : .ready
            recordConversationLocalReady(dialogId: dialogId)
            finishConversationOpenWaiters(dialogId: dialogId)
            return
        }
        #endif
        startDraftObservation(dialogId: dialogId)
        startTimelineObservation(dialogId: dialogId)
        if dialogs.first(where: { $0.id == dialogId })?.type == "group",
           groupMembersByDialog[dialogId] == nil {
            Task { [weak self] in
                await self?.loadGroupProfile(dialogId: dialogId)
            }
        }
    }

    // MARK: - In-chat search

    /// Find-in-conversation state: the matches and where the user is within them.
    struct InChatSearchState: Equatable {
        var query: String = ""
        /// Newest first, matching how results are ordered everywhere else.
        var matches: [Int64] = []
        /// Index into `matches`, or nil before the first jump.
        var currentIndex: Int?

        var isEmpty: Bool { matches.isEmpty }

        /// "3 of 47", one-based for display.
        var positionLabel: String? {
            guard let currentIndex, !matches.isEmpty else { return nil }
            return String(
                format: String(localized: "%1$lld of %2$lld"),
                Int64(currentIndex + 1), Int64(matches.count)
            )
        }
    }

    static let inChatSearchDebounce = Duration.milliseconds(160)

    func openInChatSearch() {
        inChatSearchGeneration &+= 1
        inChatSearchTask?.cancel()
        inChatSearchTask = nil
        inChatSearch = InChatSearchState()
    }

    func closeInChatSearch() {
        inChatSearchGeneration &+= 1
        inChatSearchTask?.cancel()
        inChatSearchTask = nil
        inChatSearch = nil
        focusedSearchMsgId = nil
    }

    /// Debounces and re-runs the in-chat query, then jumps to the newest match.
    ///
    /// SQL/FTS work runs in a detached worker. Cancellation is propagated to that worker, and both
    /// result publication and navigation validate the generation, query, and dialog. A slow query
    /// can therefore do neither of the two harmful stale things: replace newer matches or jump the
    /// conversation after the user has typed again/closed search/switched chats.
    func updateInChatSearch(query: String) async {
        guard var state = inChatSearch, let dialogId = activeDialogId else { return }
        inChatSearchGeneration &+= 1
        let generation = inChatSearchGeneration
        inChatSearchTask?.cancel()
        state.query = query
        state.matches = []
        state.currentIndex = nil
        inChatSearch = state
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let localStore else {
            inChatSearchTask = nil
            return
        }

        let coordinator = searchCoordinator
        let task = Task { [weak self, localStore, coordinator] in
            do {
                try await Task.sleep(for: Self.inChatSearchDebounce)
                try Task.checkCancellation()
                await coordinator?.drainBeforeSearch()
                try Task.checkCancellation()

                let queryTask = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try await localStore.searchInDialog(dialogId, query: trimmed)
                }
                let matches = try await withTaskCancellationHandler {
                    try await queryTask.value
                } onCancel: {
                    queryTask.cancel()
                }
                try Task.checkCancellation()

                guard let self,
                      self.inChatSearchGeneration == generation,
                      self.activeDialogId == dialogId,
                      self.inChatSearch?.query == query
                else { return }
                self.inChatSearch?.matches = matches
                self.inChatSearch?.currentIndex = matches.isEmpty ? nil : 0
                if let first = matches.first {
                    await self.jumpToSearchMatch(
                        first, expectedSearchGeneration: generation
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.inChatSearchGeneration == generation,
                      self.activeDialogId == dialogId,
                      self.inChatSearch?.query == query
                else { return }
                self.inChatSearch?.matches = []
                self.inChatSearch?.currentIndex = nil
            }
        }
        inChatSearchTask = task
        await task.value
        if inChatSearchGeneration == generation { inChatSearchTask = nil }
    }

    /// Moves through matches. Wraps, because a find bar that dead-ends at the last match makes the
    /// user re-type to get back to the first.
    func stepInChatSearch(forward: Bool) async {
        guard var state = inChatSearch, !state.matches.isEmpty else { return }
        let generation = inChatSearchGeneration
        let count = state.matches.count
        let current = state.currentIndex ?? 0
        // `matches` is newest-first, so "next" walks toward older messages.
        let next = forward ? (current + 1) % count : (current - 1 + count) % count
        state.currentIndex = next
        inChatSearch = state
        await jumpToSearchMatch(
            state.matches[next], expectedSearchGeneration: generation
        )
    }

    /// Scrolls to a match, pulling the surrounding window from the server if it is not local yet.
    func jumpToSearchMatch(
        _ msgId: Int64, expectedSearchGeneration: UInt64? = nil
    ) async {
        guard let dialogId = activeDialogId else { return }
        if let expectedSearchGeneration {
            guard expectedSearchGeneration == inChatSearchGeneration,
                  inChatSearch != nil
            else { return }
        }
        focusedSearchMsgId = msgId

        let isLocal = loadedLocalMessages.contains { $0.msgId == msgId }
        if !isLocal {
            // The match is outside the loaded window. Hydrating first means the jump lands on the
            // message rather than on whatever happens to be loaded.
            await hydrateOpeningAnchor(dialogId: dialogId, candidateMsgId: msgId)
        }
        guard activeDialogId == dialogId else { return }
        if let expectedSearchGeneration {
            guard expectedSearchGeneration == inChatSearchGeneration,
                  inChatSearch != nil
            else { return }
        }
        openingTimelineAnchor = .saved(msgId: msgId)
        timelineIsAtBottom = false
    }

    /// Ends the flash. Called by the view once the animation completes so a later visit to the same
    /// conversation does not replay it.
    func clearSearchFocus() {
        focusedSearchMsgId = nil
    }

    // MARK: - Search lifecycle

    /// Points the search coordinator at the current account and store, replacing any predecessor.
    ///
    /// `cancelAndWait` before constructing the replacement is the load-bearing part: without it the
    /// outgoing generation's drain overlaps the incoming one's bootstrap, and both write.
    func refreshSearchCoordinator() async {
        guard let localStore, let accountId = storedSession?.session.accountId else {
            await searchCoordinator?.cancelAndWait()
            searchCoordinator = nil
            return
        }
        if let existing = searchCoordinator, existing.serves(accountId: accountId, store: localStore) {
            return
        }
        await searchCoordinator?.cancelAndWait()
        let coordinator = SearchCoordinator(store: localStore, accountId: accountId)
        searchCoordinator = coordinator
        await coordinator.start()
    }

    /// Binds and fully drains the coordinator, for tests that need a deterministic index.
    ///
    /// Production never waits on the index: `refreshSearchCoordinator` starts a background loop and
    /// returns. A test that asserted on search results without a settling point would be timing
    /// dependent, which is worse than slow.
    func refreshSearchCoordinatorForTesting() async {
        guard let localStore else { return }
        await searchCoordinator?.cancelAndWait()
        let accountId = storedSession?.session.accountId ?? "test-account"
        let coordinator = SearchCoordinator(store: localStore, accountId: accountId)
        searchCoordinator = coordinator
        await coordinator.start()
        try? await coordinator.waitUntilIdle()
    }

    func cancelSearchCoordinatorForTesting() async {
        await searchCoordinator?.cancelAndWait()
        searchCoordinator = nil
    }

    /// Search is available while the coordinator serves the current account/store generation.
    /// Unlike every other capability this is decided locally rather than advertised by the server.
    var searchCapability: MessagingCapabilities {
        guard let searchCoordinator, let localStore,
              let accountId = storedSession?.session.accountId,
              searchCoordinator.serves(accountId: accountId, store: localStore)
        else { return [] }
        return .localSearch
    }

    func retryConversationLocalLoad() {
        guard let activeDialogId else { return }
        conversationOpenState = cachedLinesByDialog[activeDialogId] == nil ? .loadingLocal : .cached
        startTimelineObservation(dialogId: activeDialogId)
    }

    func deselectDialog(_ dialogId: String) {
        guard activeDialogId == dialogId else { return }
        closeInChatSearch()
        conversationOpenStartedAt.removeValue(forKey: dialogId)
        finishConversationOpenWaiters(dialogId: dialogId)
        cacheCurrentLines(for: dialogId)
        draftObservationTask?.cancel()
        draftObservationTask = nil
        timelineObservationTask?.cancel()
        timelineObservationTask = nil
        viewportPersistenceTask?.cancel()
        viewportPersistenceTask = nil
        openingAnchorHydrationGeneration &+= 1
        openingAnchorHydrationTask?.cancel()
        openingAnchorHydrationTask = nil
        activeDialogId = nil
        conversationOpenState = .loadingLocal
        currentDraft = nil
        suppressDraftPersistence = true
        draft = ""
        suppressDraftPersistence = false
        composerMode = .text
        canLoadEarlier = false
        loadingEarlier = false
        canLoadLater = false
        loadingLater = false
        dialogSelectionGeneration &+= 1
        timelineLoadGeneration &+= 1
        pendingVisibleReadMessages = []
    }

    /// Captures the semantic anchor and visible-read watermark before navigation tears down the
    /// conversation. Unlike the regular viewport updates, this final write is not debounced.
    func flushAndDeselectDialog(_ dialogId: String) async {
        guard activeDialogId == dialogId else { return }
        await presenceCoordinator.stopLocalTyping(dialogId: dialogId)
        viewportPersistenceTask?.cancel()
        viewportPersistenceTask = nil
        let accountId = storedSession?.session.accountId
        let store = localStore
        let state = accountId.map {
            ChatViewportState(
                dialogId: dialogId,
                accountId: $0,
                topVisibleMsgId: timelineIsAtBottom ? nil : timelineTopVisibleMsgId,
                wasAtBottom: timelineIsAtBottom
            )
        }
        let visibleMessages = pendingVisibleReadMessages
        let pendingDraftPersistence = draftPersistenceTasks[dialogId]

        // Clear presentation state synchronously, before the first suspension point, so a quick
        // navigation into another conversation cannot be undone by this closing task.
        deselectDialog(dialogId)
        await pendingDraftPersistence?.value
        _ = await draftSyncCoordinator.flush(dialogId: dialogId, force: true)
        if let state, let store {
            try? await store.saveViewportState(state)
            await markReadIfNeeded(dialogId: dialogId, messages: visibleMessages)
        }
    }

    func jumpToLatest(_ dialogId: String) async {
        guard activeDialogId == dialogId else { return }
        openingAnchorHydrationGeneration &+= 1
        openingAnchorHydrationTask?.cancel()
        openingAnchorHydrationTask = nil
        openingTimelineAnchor = .bottom
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = true
        timelineBeforeCount = 40
        timelineAfterCount = 79
        await loadLocalLines(dialogId: dialogId)
    }

    private func startOpeningAnchorHydration(dialogId: String, candidateMsgId: Int64) {
        guard openingAnchorHydrationTask == nil else { return }
        openingAnchorHydrationGeneration &+= 1
        let generation = openingAnchorHydrationGeneration
        openingAnchorHydrationTask = Task { [weak self] in
            guard let self else { return }
            await self.hydrateOpeningAnchor(dialogId: dialogId, candidateMsgId: candidateMsgId)
            if self.openingAnchorHydrationGeneration == generation {
                self.openingAnchorHydrationTask = nil
            }
        }
    }

    /// A bootstrap intentionally carries only five recent messages. Fetch forward from the
    /// persisted read watermark so a large unread gap resolves to the real first unread without
    /// making the initial cached render wait for the network.
    private func hydrateOpeningAnchor(dialogId: String, candidateMsgId: Int64) async {
        guard let token = storedSession?.session.token,
              let accountId = storedSession?.session.accountId,
              let localStore else { return }
        var afterMsgId = max(0, candidateMsgId - 1)
        if timelineHasMoreForwardByDialog[dialogId] == true,
           let savedCursor = timelineForwardCursorByDialog[dialogId] {
            afterMsgId = max(afterMsgId, savedCursor)
        }
        var resolvedUnreadMsgId: Int64?
        var reachedEnd = false
        var pagesFetched = 0

        while true {
            if Task.isCancelled || activeDialogId != dialogId || storedSession?.session.token != token {
                return
            }
            do {
                let page = try await api.getHistory(
                    dialogId: dialogId,
                    beforeMsgId: nil,
                    afterMsgId: afterMsgId,
                    limit: TimelineWindow.initialLimit,
                    token: token
                )
                try await localStore.applyTargetedHistoryPage(page)
                timelineHasMoreForwardByDialog[dialogId] = page.hasMore
                if let next = page.nextAfterMsgId {
                    timelineForwardCursorByDialog[dialogId] = next
                }
                if case let .firstUnread(msgId) = try await localStore.resolveOpeningAnchor(
                    dialogId: dialogId,
                    accountId: accountId
                ) {
                    resolvedUnreadMsgId = msgId
                    break
                }
                guard page.hasMore,
                      let next = page.nextAfterMsgId,
                      next > afterMsgId else {
                    reachedEnd = true
                    break
                }
                afterMsgId = next
                pagesFetched += 1
                if pagesFetched.isMultiple(of: 24) {
                    // A very large unread gap must stay correct without monopolizing the executor.
                    await Task.yield()
                }
            } catch is CancellationError {
                return
            } catch {
                BackgroundRuntimeCoordinator.shared.scheduleProcessing()
                return
            }
        }

        guard activeDialogId == dialogId else { return }
        if let resolvedUnreadMsgId {
            openingTimelineAnchor = .firstUnread(msgId: resolvedUnreadMsgId)
            timelineTopVisibleMsgId = resolvedUnreadMsgId
            timelineIsAtBottom = false
        } else if reachedEnd {
            timelineHasMoreForwardByDialog[dialogId] = false
            openingTimelineAnchor = .bottom
            timelineTopVisibleMsgId = nil
            timelineIsAtBottom = true
        }
        await loadLocalLines(dialogId: dialogId)
    }

    func dialogs(matching query: String) -> [Dialog] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return dialogs.filter { !$0.isArchived } }
        return dialogs.filter {
            $0.title.localizedStandardContains(trimmed)
                || $0.subtitle.localizedStandardContains(trimmed)
        }
    }

    func dialogs(matching query: String, scope: SearchScope) -> [Dialog] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return dialogs.filter { !$0.isArchived } }

        switch scope {
        case .chats:
            return dialogs.filter {
                $0.title.localizedStandardContains(trimmed)
                    || $0.subtitle.localizedStandardContains(trimmed)
            }
        case .people:
            return dialogs.filter {
                $0.type == "direct"
                    && !$0.isArchived
                    && $0.title.localizedStandardContains(trimmed)
            }
        case .messages:
            #if DEBUG
            if isDemoMode {
                let matchingIds = Set(demoLinesByDialog.compactMap { dialogId, lines in
                    lines.contains(where: { $0.text.localizedStandardContains(trimmed) }) ? dialogId : nil
                })
                return dialogs.filter { matchingIds.contains($0.id) }
            }
            #endif
            return dialogs(matching: trimmed)
        case .media, .links, .files:
            #if DEBUG
            if isDemoMode {
                let matchingIds = Set(demoLinesByDialog.compactMap { dialogId, lines in
                    let matches = lines.contains { line in
                        guard let attachment = line.attachment else { return false }
                        let typeMatches: Bool
                        switch (scope, attachment) {
                        case (.media, .photo), (.media, .video), (.links, .link), (.files, .file): typeMatches = true
                        default: typeMatches = false
                        }
                        return typeMatches && (
                            attachment.title.localizedStandardContains(trimmed)
                                || line.text.localizedStandardContains(trimmed)
                        )
                    }
                    return matches ? dialogId : nil
                })
                return dialogs.filter { matchingIds.contains($0.id) }
            }
            #endif
            return []
        }
    }

    func loadEarlier() async {
        guard !loadingEarlier else { return }
        guard let dialogId = activeDialogId, let localStore else { return }
        let selectionGeneration = dialogSelectionGeneration
        let preservedAnchor = timelineTopVisibleMsgId
            ?? loadedLocalMessages.compactMap(\.msgId).min()

        loadingEarlier = true
        defer {
            if activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration {
                loadingEarlier = false
            }
        }

        do {
            let loadedOldest = loadedLocalMessages.compactMap(\.msgId).min()
            let storedOldest = try await localStore.oldestServerMsgId(dialogId: dialogId)
            guard activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration else {
                return
            }
            guard let beforeMsgId = loadedOldest ?? storedOldest else {
                canLoadEarlier = false
                historyHasMoreByDialog[dialogId] = false
                return
            }

            let earlierLocal = try await localStore.messages(
                dialogId: dialogId,
                limit: TimelineWindow.pageLimit,
                beforeMsgId: beforeMsgId
            )
            guard activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration else {
                return
            }
            if !earlierLocal.isEmpty {
                // Grow the window around the semantic viewport row; never replace it with the
                // page cursor. SwiftUI restores the same visible target after the prepend.
                timelineTopVisibleMsgId = preservedAnchor
                timelineIsAtBottom = false
                timelineBeforeCount = min(
                    TimelineWindow.maximumRetainedMessages - 1,
                    timelineBeforeCount + TimelineWindow.pageLimit
                )
                timelineAfterCount = min(
                    timelineAfterCount,
                    TimelineWindow.maximumRetainedMessages - timelineBeforeCount - 1
                )
                await loadLocalLines(dialogId: dialogId)
                status = "Earlier messages loaded"
                return
            }

            if let historyState = try await localStore.loadHistoryState(dialogId: dialogId),
               historyState.historyComplete {
                canLoadEarlier = false
                return
            }

            guard let token = storedSession?.session.token else {
                status = "Offline — cached history shown"
                return
            }

            let page = try await api.getHistory(
                dialogId: dialogId,
                beforeMsgId: beforeMsgId,
                limit: TimelineWindow.pageLimit,
                token: token
            )
            try await localStore.applyHistoryPage(page)
            await enqueueArrivalMediaDownloads(page.messages)
            guard activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration else {
                return
            }
            historyHasMoreByDialog[dialogId] = page.hasMore
            let currentState = try await localStore.loadHistoryState(dialogId: dialogId)
            try await localStore.saveHistoryState(
                DialogHistoryState(
                    dialogId: dialogId,
                    ceilingMsgId: currentState?.ceilingMsgId
                        ?? loadedLocalMessages.compactMap(\.msgId).max()
                        ?? 0,
                    nextBeforeMsgId: page.nextBeforeMsgId,
                    historyComplete: !page.hasMore
                )
            )
            guard activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration else {
                return
            }
            timelineTopVisibleMsgId = preservedAnchor
            timelineIsAtBottom = false
            timelineBeforeCount = min(
                TimelineWindow.maximumRetainedMessages - 1,
                timelineBeforeCount + TimelineWindow.pageLimit
            )
            timelineAfterCount = min(
                timelineAfterCount,
                TimelineWindow.maximumRetainedMessages - timelineBeforeCount - 1
            )
            await loadLocalLines(dialogId: dialogId)
            status = page.messages.isEmpty ? "No earlier messages" : "History loaded"
        } catch {
            if activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration {
                status = "History failed: \(error.localizedDescription)"
            }
        }
    }

    /// Extends a centered unread/saved window toward newer rows. Local pages are exposed first;
    /// when a targeted forward fetch reported another page, its keyset cursor resumes that fetch.
    func loadLater() async {
        guard !loadingLater, canLoadLater else { return }
        guard let dialogId = activeDialogId, let localStore else { return }
        let selectionGeneration = dialogSelectionGeneration
        loadingLater = true
        defer {
            if activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration {
                loadingLater = false
            }
        }

        do {
            let loadedNewest = loadedLocalMessages.compactMap(\.msgId).max()
            var forwardFetchAfterMsgId: Int64?
            if let loadedNewest {
                let newerLocal = try await localStore.messages(
                    dialogId: dialogId,
                    limit: 1,
                    afterMsgId: loadedNewest
                )
                guard activeDialogId == dialogId,
                      dialogSelectionGeneration == selectionGeneration else { return }
                if newerLocal.first?.msgId == loadedNewest + 1 {
                    timelineAfterCount = min(
                        TimelineWindow.maximumRetainedMessages - 1,
                        timelineAfterCount + TimelineWindow.pageLimit
                    )
                    timelineBeforeCount = min(
                        timelineBeforeCount,
                        TimelineWindow.maximumRetainedMessages - timelineAfterCount - 1
                    )
                    await loadLocalLines(dialogId: dialogId)
                    return
                }
                if newerLocal.first?.msgId != nil
                    || timelineHasMoreForwardByDialog[dialogId] == true {
                    // A non-contiguous newer local row is usually the five-message bootstrap
                    // preview. Fill the missing server range before it is allowed on screen.
                    forwardFetchAfterMsgId = loadedNewest
                }
            } else if timelineHasMoreForwardByDialog[dialogId] == true {
                forwardFetchAfterMsgId = timelineForwardCursorByDialog[dialogId]
            }

            guard let afterMsgId = forwardFetchAfterMsgId else {
                canLoadLater = false
                return
            }
            guard let token = storedSession?.session.token else { return }
            let page = try await api.getHistory(
                dialogId: dialogId,
                beforeMsgId: nil,
                afterMsgId: afterMsgId,
                limit: TimelineWindow.pageLimit,
                token: token
            )
            try await localStore.applyTargetedHistoryPage(page)
            guard activeDialogId == dialogId,
                  dialogSelectionGeneration == selectionGeneration else { return }
            timelineHasMoreForwardByDialog[dialogId] = page.hasMore
            if let next = page.nextAfterMsgId {
                timelineForwardCursorByDialog[dialogId] = next
            }
            timelineAfterCount = min(
                TimelineWindow.maximumRetainedMessages - 1,
                timelineAfterCount + TimelineWindow.pageLimit
            )
            timelineBeforeCount = min(
                timelineBeforeCount,
                TimelineWindow.maximumRetainedMessages - timelineAfterCount - 1
            )
            await loadLocalLines(dialogId: dialogId)
        } catch is CancellationError {
            return
        } catch {
            if activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration {
                status = "Newer history failed: \(error.localizedDescription)"
            }
        }
    }

    func dialogTitle(_ dialogId: String) -> String {
        dialogs.first(where: { $0.id == dialogId })?.title ?? shortDialogId(dialogId)
    }

    func typingSummary(dialogId: String) -> String? {
        guard let dialog = dialogs.first(where: { $0.id == dialogId }), dialog.type != "saved" else {
            return nil
        }
        let accountIds = presenceCoordinator.typingAccountIds(dialogId: dialogId)
        guard !accountIds.isEmpty else { return nil }
        if dialog.type == "direct" { return String(localized: "typing…") }
        let names = accountIds.map { accountId in
            groupMembersByDialog[dialogId]?
                .first(where: { $0.accountId == accountId })?.displayName
                ?? String(localized: "Someone")
        }
        if names.count == 1 {
            return String(format: String(localized: "%@ is typing…"), names[0])
        }
        if names.count == 2 {
            return String(format: String(localized: "%@ and %@ are typing…"), names[0], names[1])
        }
        return String(format: String(localized: "%lld people are typing…"), Int64(names.count))
    }

    func directPresenceSubtitle(dialogId: String) -> String {
        guard capabilities.contains(.presence),
              let peer = dialogs.first(where: { $0.id == dialogId })?.peerAccountId else {
            return String(localized: "status unavailable")
        }
        guard let presence = presenceCoordinator.presence(accountId: peer) else {
            return String(localized: "status unavailable")
        }
        if presence.online { return String(localized: "online") }
        return TojPresenceFormatting.lastSeen(presence.lastSeenAt)
    }

    func userEditedComposer(dialogId: String, text: String, focused: Bool) {
        presenceCoordinator.userEditedDraft(dialogId: dialogId, text: text, focused: focused)
    }

    func composerFocusChanged(dialogId: String, focused: Bool) {
        presenceCoordinator.composerFocusChanged(dialogId: dialogId, focused: focused, text: draft)
    }

    func stopTyping(dialogId: String) async {
        await presenceCoordinator.stopLocalTyping(dialogId: dialogId)
    }

    @discardableResult
    func ensureSavedMessages(presentsFailure: Bool = true) async -> String? {
        guard !sessionTeardownActive else { return nil }
        return await runTrackedSavedOperation {
            await self.ensureSavedMessagesCore(presentsFailure: presentsFailure)
        } ?? nil
    }

    private func ensureSavedMessagesCore(presentsFailure: Bool) async -> String? {
        guard
            !sessionTeardownActive,
            let accountId = storedSession?.session.accountId,
            let token = storedSession?.session.token,
            let localStore
        else { return nil }
        let generation = savedMessagesSessionGeneration
        guard isCurrentSavedMessagesSession(
            accountId: accountId,
            token: token,
            store: localStore,
            generation: generation
        ) else { return nil }
        if let savedMessagesDialogId {
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ) else { return nil }
            return savedMessagesDialogId
        }
        if let local = try? await savedMessagesService.localDialogId(
            store: localStore,
            accountId: accountId
        ) {
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ) else { return nil }
            savedMessagesDialogId = local
            savedMessagesSetupFailure = nil
            return local
        }
        guard savedMessagesCapabilityState != .unsupported else {
            savedMessagesSetupFailure = String(localized: "Unavailable on this server")
            return nil
        }

        savedMessagesSetupInFlight = true
        savedMessagesSetupFailure = nil
        defer {
            if savedMessagesSessionGeneration == generation {
                savedMessagesSetupInFlight = false
            }
        }
        do {
            let dialogId = try await savedMessagesService.ensure(
                api: api,
                store: localStore,
                accountId: accountId,
                token: token,
                generation: generation
            )
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ) else { return nil }
            savedMessagesDialogId = dialogId
            savedMessagesSetupFailure = nil
            await refreshDialogs()
            return dialogId
        } catch is CancellationError {
            return nil
        } catch {
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ) else { return nil }
            let message: String
            let apiStatus = (error as? CloudAPIError)?.status
            savedMessagesCapabilityState = savedMessagesCapabilityState.resolvingEnsureFailure(
                statusCode: apiStatus
            )
            if apiStatus == 404 {
                negotiatedCapabilities.remove(.savedMessages)
                message = String(localized: "Unavailable on this server")
            } else {
                switch cloudFailureDisposition(error) {
                case .transient:
                    message = String(localized: "Connect once to set up Saved Messages")
                case .authenticationRequired:
                    message = String(localized: "Sign in again to set up Saved Messages")
                case .unsupportedServer:
                    message = String(localized: "Unavailable on this server")
                case .permanent:
                    message = String(localized: "Saved Messages could not be set up")
                }
            }
            savedMessagesSetupFailure = message
            if presentsFailure {
                presentNotice(String(localized: "Saved Messages"), message: message)
            }
            return nil
        }
    }

    private func isCurrentSavedMessagesSession(
        accountId: String,
        token: String,
        store: CloudLocalStore,
        generation: UInt64
    ) -> Bool {
        !sessionTeardownActive
            && savedMessagesSessionGeneration == generation
            && storedSession?.session.accountId == accountId
            && storedSession?.session.token == token
            && localStore === store
    }

    func saveMessage(_ line: Line) async {
        guard !sessionTeardownActive else { return }
        _ = await runTrackedSavedOperation {
            await self.saveMessageCore(line)
        }
    }

    private func saveMessageCore(_ line: Line) async {
        guard
            !sessionTeardownActive,
            !line.isDeleted,
            line.msgId != nil,
            line.dialogId != savedMessagesDialogId,
            let targetDialogId = await ensureSavedMessagesCore(presentsFailure: true)
        else { return }
        await forwardMessageCore(line, to: targetDialogId)
        if status == "Forwarded" {
            status = String(localized: "Saved to Saved Messages")
        }
    }

    private func runTrackedSavedOperation<T: Sendable>(
        _ operation: @escaping @MainActor () async -> T
    ) async -> T? {
        guard !sessionTeardownActive else { return nil }
        let id = UUID()
        let task = Task { await operation() }
        trackedSavedOperations[id] = TrackedSavedOperation(
            cancel: { task.cancel() },
            wait: { _ = await task.result }
        )
        let result = await task.value
        trackedSavedOperations.removeValue(forKey: id)
        guard !sessionTeardownActive, !Task.isCancelled else { return nil }
        return result
    }

    func startVoiceCall(dialogId: String) async {
        #if DEBUG
        if isDemoMode {
            presentNotice("Voice calls", message: "Sign in to place a secure voice call.")
            return
        }
        #endif
        guard !groupCallCoordinator.hasActiveCall else {
            groupCallCoordinator.isPresented = true
            return
        }
        guard capabilities.contains(.calls) else {
            presentNotice("Voice calls unavailable", message: "This server has not enabled encrypted calling yet.")
            return
        }
        guard
            let accountId = storedSession?.session.accountId,
            let peerAccountId = try? await localStore?.peerAccountId(dialogId: dialogId, excluding: accountId)
        else {
            presentNotice("Call unavailable", message: "The other participant could not be verified.")
            return
        }
        await callCoordinator.startOutgoing(
            dialogId: dialogId,
            peerAccountId: peerAccountId,
            displayName: dialogTitle(dialogId),
            initialKind: .voice
        )
    }

    func startVideoCall(dialogId: String) async {
        #if DEBUG
        if isDemoMode {
            presentNotice("Video calls", message: "Sign in to place a secure video call.")
            return
        }
        #endif
        guard !groupCallCoordinator.hasActiveCall else {
            groupCallCoordinator.isPresented = true
            return
        }
        guard capabilities.contains(.videoCalls) else {
            presentNotice(
                "Video calls unavailable",
                message: "Encrypted video calling is not enabled for this account and device yet."
            )
            return
        }
        guard
            let accountId = storedSession?.session.accountId,
            let peerAccountId = try? await localStore?.peerAccountId(
                dialogId: dialogId,
                excluding: accountId
            )
        else {
            presentNotice("Call unavailable", message: "The other participant could not be verified.")
            return
        }
        await callCoordinator.startOutgoing(
            dialogId: dialogId,
            peerAccountId: peerAccountId,
            displayName: dialogTitle(dialogId),
            initialKind: .video
        )
    }

    func startGroupCall(dialogId: String, initialKind: GroupCallInitialKind) async {
        #if DEBUG
        if isDemoMode {
            presentNotice("Group calls", message: "Sign in to start an encrypted group call.")
            return
        }
        #endif
        guard !callCoordinator.state.isInProgress else {
            callCoordinator.isPresented = true
            return
        }
        guard dialogs.first(where: { $0.id == dialogId })?.type == "group" else { return }
        let required: MessagingCapabilities = initialKind == .video ? .groupVideoCalls : .groupCalls
        guard capabilities.contains(required) else {
            presentNotice(
                "Group calls unavailable",
                message: "Encrypted group calling has not been enabled for this account and device yet."
            )
            return
        }
        await groupCallCoordinator.start(
            dialogId: dialogId,
            title: dialogTitle(dialogId),
            initialKind: initialKind
        )
    }

    func joinGroupCall(dialogId: String) async {
        guard !callCoordinator.state.isInProgress else {
            callCoordinator.isPresented = true
            return
        }
        guard capabilities.contains(.groupCalls) else { return }
        await groupCallCoordinator.joinAvailableCall(
            dialogId: dialogId,
            title: dialogTitle(dialogId)
        )
    }

    func refreshGroupCall(dialogId: String) async {
        guard capabilities.contains(.groupCalls) else { return }
        await groupCallCoordinator.refreshActiveCall(dialogId: dialogId)
    }

    func blockPeer(dialogId: String) async -> Bool {
        #if DEBUG
        if isDemoMode { return false }
        #endif
        guard
            let session = storedSession?.session,
            let peer = try? await localStore?.peerAccountId(dialogId: dialogId, excluding: session.accountId)
        else { return false }
        do {
            _ = try await api.blockAccount(id: peer, token: session.token)
            return true
        } catch {
            presentNotice("Could not block account", message: error.localizedDescription)
            return false
        }
    }

    func submitAccountReport(
        dialogId: String,
        reason: AbuseReportReason,
        details: String?,
        clientReportId: UUID
    ) async -> AbuseReportSubmissionResult {
        guard capabilities.contains(.abuseReports) else {
            return .failed(String(localized: "Reporting is not available on this server yet."))
        }
        guard canShowAccountReport(dialogId: dialogId) else {
            return .failed(String(localized: "The account could not be verified."))
        }
        guard
            let session = storedSession?.session,
            let peer = try? await localStore?.peerAccountId(
                dialogId: dialogId,
                excluding: session.accountId
            )
        else {
            return .failed(String(localized: "The account could not be verified."))
        }
        return await submitAbuseReport(
            dialogId: dialogId,
            subject: .account(peer),
            reason: reason,
            details: details,
            clientReportId: clientReportId
        )
    }

    func submitMessageReport(
        _ line: Line,
        reason: AbuseReportReason,
        details: String?,
        clientReportId: UUID
    ) async -> AbuseReportSubmissionResult {
        guard
            Self.isReportable(line, capabilities: capabilities),
            let dialogId = line.dialogId,
            let msgId = line.msgId,
            let dialogType = dialogs.first(where: { $0.id == dialogId })?.type,
            dialogType == "direct" || dialogType == "group"
        else {
            return .failed(String(localized: "This message can no longer be reported."))
        }
        return await submitAbuseReport(
            dialogId: dialogId,
            subject: .message(msgId),
            reason: reason,
            details: details,
            clientReportId: clientReportId
        )
    }

    private func submitAbuseReport(
        dialogId: String,
        subject: CloudAbuseReportSubject,
        reason: AbuseReportReason,
        details: String?,
        clientReportId: UUID
    ) async -> AbuseReportSubmissionResult {
        guard capabilities.contains(.abuseReports) else {
            return .failed(String(localized: "Reporting is not available on this server yet."))
        }
        guard !isSessionTeardownInProgress, let session = storedSession?.session else {
            return .cancelled
        }
        let generation = accountSessionGeneration
        let accountId = session.accountId
        let token = session.token
        do {
            _ = try await api.submitAbuseReport(
                clientReportId: clientReportId,
                dialogId: dialogId,
                subject: subject,
                reason: reason,
                details: details,
                token: token
            )
            guard
                !Task.isCancelled,
                !isSessionTeardownInProgress,
                generation == accountSessionGeneration,
                storedSession?.session.accountId == accountId,
                storedSession?.session.token == token
            else {
                return .cancelled
            }
            return .submitted
        } catch is CancellationError {
            return .cancelled
        } catch {
            guard
                !isSessionTeardownInProgress,
                generation == accountSessionGeneration,
                storedSession?.session.accountId == accountId,
                storedSession?.session.token == token
            else {
                return .cancelled
            }
            if let apiError = error as? CloudAPIError,
               Self.shouldWithdrawAbuseReportCapability(after: apiError) {
                negotiatedCapabilities.remove(.abuseReports)
            }
            return .failed(error.localizedDescription)
        }
    }

    nonisolated static func shouldWithdrawAbuseReportCapability(
        after error: CloudAPIError
    ) -> Bool {
        error.code == "capability_unavailable"
            || (error.status == 404 && error.code == nil)
    }

    func sendDraft(silent: Bool = false, deliverAfter: Date? = nil) async {
        if let activeDialogId {
            await presenceCoordinator.stopLocalTyping(dialogId: activeDialogId)
        }
        let rawText = draft
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if case let .editing(messageId, _) = composerMode {
            guard !trimmedText.isEmpty else { return }
            #if DEBUG
            if isDemoMode {
                updateDemoMessage(messageId: messageId, text: trimmedText)
                restoreUnderlyingDraftComposer()
                return
            }
            #endif
            guard let line = lines.first(where: { $0.id == messageId }) else {
                status = "Message is no longer available"
                return
            }
            await edit(line, text: trimmedText)
            return
        }
        if currentDraft?.attachments.isEmpty == false {
            if let deliverAfter {
                await scheduleStagedDraft(deliverAt: deliverAfter, silent: silent)
                return
            }
            await sendStagedDraft(silent: silent)
            return
        }
        // A reply target can be saved before the user types, but it is not itself a message.
        // Keep that draft intact instead of enqueueing a request the server must reject.
        guard !trimmedText.isEmpty else { return }
        let replyPreview: String?
        let replyToMsgId: Int64?
        if case let .replying(messageId, preview) = composerMode {
            replyPreview = preview
            replyToMsgId = lines.first(where: { $0.id == messageId })?.msgId
                ?? currentDraft?.replyToMsgId
        } else {
            replyPreview = nil
            replyToMsgId = nil
        }
        let mentions = activeDialogId.map {
            resolvedMentions(in: rawText, dialogId: $0)
        } ?? []
        if let dialogId = activeDialogId {
            await draftPersistenceTasks[dialogId]?.value
        }
        if let activeDialogId {
            draftMentionsByDialog.removeValue(forKey: activeDialogId)
        }
        suppressDraftPersistence = true
        draft = ""
        suppressDraftPersistence = false
        composerMode = .text
        #if DEBUG
        if isDemoMode {
            sendDemo(rawText, replyPreview: replyPreview)
            return
        }
        #endif
        await send(
            rawText,
            replyToMsgId: replyToMsgId,
            mentions: mentions,
            silent: silent,
            deliverAfter: deliverAfter
        )
    }

    private func currentAccountOperationContext() -> AccountOperationContext? {
        guard !sessionTeardownActive,
              !isSessionTeardownInProgress,
              let session = storedSession?.session,
              let localStore else { return nil }
        return AccountOperationContext(
            accountId: session.accountId,
            deviceId: session.deviceId,
            token: session.token,
            generation: accountSessionGeneration,
            store: localStore
        )
    }

    private func isCurrentAccountOperation(_ context: AccountOperationContext) -> Bool {
        guard !sessionTeardownActive,
              !isSessionTeardownInProgress,
              accountSessionGeneration == context.generation,
              let session = storedSession?.session,
              let localStore else { return false }
        return session.accountId == context.accountId
            && session.deviceId == context.deviceId
            && session.token == context.token
            && localStore === context.store
    }

    func refreshCloudProductivity() async {
        guard let context = currentAccountOperationContext() else { return }
        await productivitySyncCoordinator.bind(context)
        if let cachedFolders = try? await context.store.effectiveChatFolderSnapshot(
            accountId: context.accountId
        ), isCurrentAccountOperation(context) {
            chatFolders = cachedFolders.folders.sorted { $0.position < $1.position }
            chatFolderCollectionRevision = cachedFolders.collectionRevision
        }
        if let cachedSchedules = try? await context.store.scheduledDeliveries(
            accountId: context.accountId
        ), isCurrentAccountOperation(context) {
            scheduledDeliveries = cachedSchedules.sorted { $0.deliverAt < $1.deliverAt }
        }
        if capabilities.contains(.chatFolders),
           let snapshot = try? await productivitySyncCoordinator.refreshFolders(api: api),
           isCurrentAccountOperation(context) {
            chatFolders = snapshot.folders.sorted { $0.position < $1.position }
            chatFolderCollectionRevision = snapshot.collectionRevision
        }
        if capabilities.contains(.scheduledDelivery) {
            _ = try? await productivitySyncCoordinator.refreshScheduledDeliveries(api: api)
            if isCurrentAccountOperation(context),
               let merged = try? await context.store.scheduledDeliveries(
                accountId: context.accountId
               ), isCurrentAccountOperation(context) {
                scheduledDeliveries = merged.sorted { $0.deliverAt < $1.deliverAt }
            }
        }
        guard isCurrentAccountOperation(context) else { return }
        let report = await productivitySyncCoordinator.drain(api: api)
        await publishProductivityDrainReport(report, context: context)
    }

    func dialog(_ dialog: Dialog, isIncludedIn folder: CloudChatFolder) -> Bool {
        let explicit = folder.rules.first { $0.dialogId == dialog.id }?.rule
        if explicit == "exclude" { return false }
        if explicit == "include" { return true }
        guard !dialog.isArchived || !folder.excludeArchived else { return false }
        if folder.excludeRead && dialog.unreadCount == 0 { return false }
        if folder.excludeMuted && dialog.isMuted { return false }
        return switch dialog.type {
        case "direct": folder.includeDirect
        case "group": folder.includeGroups
        case "saved": folder.includeSaved
        default: false
        }
    }

    func createChatFolder(
        title: String,
        icon: String = "folder",
        includeDirect: Bool = true,
        includeGroups: Bool = true,
        includeSaved: Bool = false,
        excludeRead: Bool = false,
        excludeMuted: Bool = false,
        excludeArchived: Bool = true,
        rules: [CloudChatFolderRule] = []
    ) async throws {
        guard let context = currentAccountOperationContext(), capabilities.contains(.chatFolders) else {
            throw CloudAPIError(status: 404, message: "Chat folders are unavailable", retryAfter: nil)
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let folder = CloudChatFolder(
            folderId: UUID().uuidString.lowercased(),
            title: title,
            icon: Self.semanticFolderIcon(icon),
            position: chatFolders.count,
            includeDirect: includeDirect,
            includeGroups: includeGroups,
            includeSaved: includeSaved,
            excludeRead: excludeRead,
            excludeMuted: excludeMuted,
            excludeArchived: excludeArchived,
            revision: 0,
            rules: rules,
            createdAt: now,
            updatedAt: now
        )
        await productivitySyncCoordinator.bind(context)
        guard isCurrentAccountOperation(context) else { return }
        let result: CloudChatFolderSnapshot
        do {
            result = try await productivitySyncCoordinator.stageChatFolderMutation(
                CloudFolderMutationIntent(
                    operation: .create,
                    folderId: folder.folderId,
                    folder: folder,
                    beforeFolderId: nil,
                    afterFolderId: nil
                )
            )
        } catch CloudProductivityRefreshError.sessionChanged { return }
        guard isCurrentAccountOperation(context) else { return }
        chatFolders = result.folders.sorted { $0.position < $1.position }
        chatFolderCollectionRevision = result.collectionRevision
        status = "Folder saved locally"
        scheduleOutboxRetry()
    }

    func updateChatFolder(
        _ folder: CloudChatFolder,
        title: String,
        icon: String,
        includeDirect: Bool,
        includeGroups: Bool,
        includeSaved: Bool,
        excludeRead: Bool,
        excludeMuted: Bool,
        excludeArchived: Bool,
        rules: [CloudChatFolderRule]
    ) async throws {
        guard let context = currentAccountOperationContext() else { return }
        let desired = CloudChatFolder(
            folderId: folder.folderId,
            title: title,
            icon: Self.semanticFolderIcon(icon),
            position: folder.position,
            includeDirect: includeDirect,
            includeGroups: includeGroups,
            includeSaved: includeSaved,
            excludeRead: excludeRead,
            excludeMuted: excludeMuted,
            excludeArchived: excludeArchived,
            revision: folder.revision,
            rules: rules,
            createdAt: folder.createdAt,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        await productivitySyncCoordinator.bind(context)
        guard isCurrentAccountOperation(context) else { return }
        let result: CloudChatFolderSnapshot
        do {
            result = try await productivitySyncCoordinator.stageChatFolderMutation(
                CloudFolderMutationIntent(
                    operation: .update,
                    folderId: folder.folderId,
                    folder: desired,
                    beforeFolderId: nil,
                    afterFolderId: nil
                )
            )
        } catch CloudProductivityRefreshError.sessionChanged { return }
        guard isCurrentAccountOperation(context) else { return }
        chatFolders = result.folders.sorted { $0.position < $1.position }
        chatFolderCollectionRevision = result.collectionRevision
        status = "Folder saved locally"
        scheduleOutboxRetry()
    }

    func deleteChatFolder(_ folder: CloudChatFolder) async throws {
        guard let context = currentAccountOperationContext() else { return }
        await productivitySyncCoordinator.bind(context)
        guard isCurrentAccountOperation(context) else { return }
        let result: CloudChatFolderSnapshot
        do {
            result = try await productivitySyncCoordinator.stageChatFolderMutation(
                CloudFolderMutationIntent(
                    operation: .delete,
                    folderId: folder.folderId,
                    folder: nil,
                    beforeFolderId: nil,
                    afterFolderId: nil
                )
            )
        } catch CloudProductivityRefreshError.sessionChanged { return }
        guard isCurrentAccountOperation(context) else { return }
        chatFolders = result.folders.sorted { $0.position < $1.position }
        chatFolderCollectionRevision = result.collectionRevision
        status = "Folder removed locally"
        scheduleOutboxRetry()
    }

    func moveChatFolder(
        _ folder: CloudChatFolder,
        before: CloudChatFolder? = nil,
        after: CloudChatFolder? = nil
    ) async throws {
        guard let context = currentAccountOperationContext() else { return }
        var desiredOrder = chatFolders.map(\.folderId)
        desiredOrder.removeAll { $0 == folder.folderId }
        if let before,
           let index = desiredOrder.firstIndex(of: before.folderId) {
            desiredOrder.insert(folder.folderId, at: index)
        } else if let after,
                  let index = desiredOrder.firstIndex(of: after.folderId) {
            desiredOrder.insert(folder.folderId, at: index + 1)
        }
        await productivitySyncCoordinator.bind(context)
        guard isCurrentAccountOperation(context) else { return }
        let result: CloudChatFolderSnapshot
        do {
            result = try await productivitySyncCoordinator.stageChatFolderMutation(
                CloudFolderMutationIntent(
                    operation: .move,
                    folderId: folder.folderId,
                    folder: nil,
                    beforeFolderId: before?.folderId,
                    afterFolderId: after?.folderId,
                    desiredOrder: desiredOrder
                )
            )
        } catch CloudProductivityRefreshError.sessionChanged { return }
        guard isCurrentAccountOperation(context) else { return }
        chatFolders = result.folders.sorted { $0.position < $1.position }
        chatFolderCollectionRevision = result.collectionRevision
        status = "Folder order saved locally"
        scheduleOutboxRetry()
    }

    func cancelScheduledDelivery(_ delivery: CloudScheduledDelivery) async throws {
        guard let context = currentAccountOperationContext() else { return }
        await productivitySyncCoordinator.bind(context)
        guard isCurrentAccountOperation(context) else { return }
        if delivery.revision == 0 {
            let effective: [CloudScheduledDelivery]?
            do {
                effective = try await productivitySyncCoordinator
                    .discardUnattemptedScheduledCreate(scheduleId: delivery.scheduleId)
            } catch CloudProductivityRefreshError.sessionChanged { return }
            if let effective {
                guard isCurrentAccountOperation(context) else { return }
                scheduledDeliveries = effective.sorted { $0.deliverAt < $1.deliverAt }
                return
            }
        }
        let merged: [CloudScheduledDelivery]
        do {
            merged = try await productivitySyncCoordinator.stageScheduledDeliveryMutation(
                CloudScheduledMutationIntent(
                    operation: .cancel,
                    scheduleId: delivery.scheduleId,
                    deliverAt: nil
                )
            )
        } catch CloudProductivityRefreshError.sessionChanged { return }
        guard isCurrentAccountOperation(context) else { return }
        scheduledDeliveries = merged.sorted { $0.deliverAt < $1.deliverAt }
        status = "Cancellation saved locally — it may still send until confirmed"
        scheduleOutboxRetry()
    }

    func rescheduleDelivery(_ delivery: CloudScheduledDelivery, to date: Date) async throws {
        guard let context = currentAccountOperationContext() else { return }
        await productivitySyncCoordinator.bind(context)
        guard isCurrentAccountOperation(context) else { return }
        let merged: [CloudScheduledDelivery]
        do {
            merged = try await productivitySyncCoordinator.stageScheduledDeliveryMutation(
                CloudScheduledMutationIntent(
                    operation: .reschedule,
                    scheduleId: delivery.scheduleId,
                    deliverAt: ISO8601DateFormatter().string(from: date)
                )
            )
        } catch CloudProductivityRefreshError.sessionChanged { return }
        guard isCurrentAccountOperation(context) else { return }
        scheduledDeliveries = merged.sorted { $0.deliverAt < $1.deliverAt }
        status = "New delivery time saved locally"
        scheduleOutboxRetry()
    }

    private static func semanticFolderIcon(_ icon: String) -> String {
        switch icon {
        case "person.2": "personal"
        case "message.badge": "unread"
        case "briefcase": "work"
        case "star": "favorite"
        default: icon
        }
    }

    private func sendStagedDraft(silent: Bool) async {
        guard
            let dialogId = activeDialogId,
            let accountId = storedSession?.session.accountId,
            let localStore
        else { return }
        await draftPersistenceTasks[dialogId]?.value
        guard let draft = try? await localStore.loadDraft(accountId: accountId, dialogId: dialogId),
              draft.state == "active",
              !draft.attachments.isEmpty else { return }
        guard draftSendsInFlightByDialog[dialogId] == nil else { return }
        draftSendsInFlightByDialog[dialogId] = draft.operationId
        defer {
            if draftSendsInFlightByDialog[dialogId] == draft.operationId {
                draftSendsInFlightByDialog[dialogId] = nil
            }
        }
        guard draft.attachments.allSatisfy({ $0.state == "ready" && $0.mediaId != nil }) else {
            presentNotice(
                "Attachments are still preparing",
                message: "Wait for every attachment to finish, or remove the failed item."
            )
            return
        }
        if draft.attachments.count > 1, !capabilities.contains(.mediaGroups) {
            presentNotice(
                "Grouped sending is unavailable",
                message: "Your draft is saved. It will not be split into separate messages."
            )
            return
        }
        openingTimelineAnchor = .bottom
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = true
        suppressDraftPersistence = true
        self.draft = ""
        suppressDraftPersistence = false
        composerMode = .text

        do {
            if draft.attachments.count == 1 {
                let transfer = try await localStore.consumeDraftAsSingleMedia(
                    accountId: accountId,
                    dialogId: dialogId,
                    operationId: draft.operationId,
                    silent: silent
                )
                await loadLocalLines(dialogId: dialogId)
                await refreshDialogs()
                Task { [weak self] in await self?.runMediaTransfer(transfer) }
                scheduleOutboxRetry()
            } else {
                let group = try await localStore.consumeDraftAsMediaGroup(
                    accountId: accountId,
                    dialogId: dialogId,
                    operationId: draft.operationId,
                    silent: silent
                )
                await loadLocalLines(dialogId: dialogId)
                await refreshDialogs()
                Task { [weak self] in await self?.processMediaGroupSend(group) }
                scheduleOutboxRetry()
            }
        } catch {
            suppressDraftPersistence = true
            self.draft = draft.text
            suppressDraftPersistence = false
            status = "Local send failed: \(error.localizedDescription)"
            presentNotice("Could not queue attachments", message: error.localizedDescription)
        }
    }

    private func scheduleStagedDraft(deliverAt: Date, silent: Bool) async {
        guard capabilities.contains(.scheduledDelivery) else {
            presentNotice(
                "Scheduled sending is unavailable",
                message: "Your attachment draft is still saved on this device."
            )
            return
        }
        guard deliverAt >= Date().addingTimeInterval(60) else {
            presentNotice("Choose a later time", message: "Scheduled delivery must be at least one minute away.")
            return
        }
        guard let dialogId = activeDialogId,
              let context = currentAccountOperationContext() else { return }
        let localStore = context.store
        await draftPersistenceTasks[dialogId]?.value
        guard isCurrentAccountOperation(context), activeDialogId == dialogId else { return }
        guard let stored = try? await localStore.loadDraft(
            accountId: context.accountId,
            dialogId: dialogId
        ), isCurrentAccountOperation(context), activeDialogId == dialogId,
           stored.state == "active", !stored.attachments.isEmpty else { return }
        let attachments = stored.attachments.sorted { $0.position < $1.position }
        guard attachments.allSatisfy({
            $0.state == "ready" && $0.mediaId != nil && $0.media != nil
        }) else {
            presentNotice(
                "Attachments are still preparing",
                message: "Wait for every attachment to finish before scheduling."
            )
            return
        }
        if attachments.count > 1,
           attachments.contains(where: { $0.media?.kind == "voice" }) {
            presentNotice(
                "Voice messages cannot be grouped",
                message: "Schedule the voice message by itself."
            )
            return
        }
        let items = attachments.enumerated().map { index, attachment in
            let body = index == 0 ? stored.text : ""
            return CloudScheduledItem(
                clientMsgId: UUID().uuidString.lowercased(),
                kind: attachment.media!.kind,
                body: body,
                replyToMsgId: index == 0 ? stored.replyToMsgId : nil,
                mediaId: attachment.mediaId,
                mentions: index == 0 ? stored.mentions : [],
                linkPreviewCandidate: index == 0 && capabilities.contains(.linkPreviews)
                    ? CloudLinkPreviewCandidate.first(in: body)
                    : nil
            )
        }
        let request = CloudScheduledCreateRequest(
            scheduleId: UUID().uuidString.lowercased(),
            clientMutationId: UUID().uuidString.lowercased(),
            dialogId: dialogId,
            deliverAt: ISO8601DateFormatter().string(from: deliverAt),
            silent: silent,
            reminder: dialogs.first(where: { $0.id == dialogId })?.type == "saved",
            items: items
        )
        do {
            await productivitySyncCoordinator.bind(context)
            guard isCurrentAccountOperation(context) else { return }
            let local = try await productivitySyncCoordinator.stageScheduledCreate(
                request,
                draftOperationId: stored.operationId
            )
            guard isCurrentAccountOperation(context), activeDialogId == dialogId else { return }
            suppressDraftPersistence = true
            draft = ""
            suppressDraftPersistence = false
            composerMode = .text
            scheduledDeliveries.removeAll { $0.scheduleId == local.scheduleId }
            scheduledDeliveries.append(local)
            scheduledDeliveries.sort { $0.deliverAt < $1.deliverAt }
            status = String(localized: "Waiting for connection — not scheduled yet")
            scheduleOutboxRetry()
        } catch {
            guard isCurrentAccountOperation(context) else { return }
            presentNotice("Attachments were not scheduled", message: error.localizedDescription)
        }
    }

    private func clearDraftAfterScheduledAcknowledgement(
        dialogId: String,
        operationId: String?,
        accountId: String,
        localStore: CloudLocalStore
    ) async {
        guard let operationId,
              let current = try? await localStore.loadDraft(accountId: accountId, dialogId: dialogId),
              current.operationId == operationId else { return }
        for attachment in current.attachments {
            let transfer: MediaTransferRecord?
            if let transferId = attachment.transferId {
                transfer = try? await localStore.mediaTransfer(id: transferId)
            } else {
                transfer = nil
            }
            if let transferId = try? await localStore.removeDraftAttachment(
                accountId: accountId,
                dialogId: dialogId,
                attachmentId: attachment.attachmentId
            ) {
                mediaTransferTasks[transferId]?.cancel()
            }
            if let transfer { await mediaEngine.discardTransfer(transfer) }
        }
        _ = try? await draftSyncCoordinator.mutate(
            dialogId: dialogId,
            text: "",
            replyToMsgId: nil,
            replyPreview: nil,
            mentions: [],
            reason: .attachmentChanged
        )
    }

    func insertMention(_ member: GroupMember) {
        guard let dialogId = activeDialogId,
              let range = activeMentionRange(in: draft) else { return }
        let token = "@\(member.displayName)"
        draft.replaceSubrange(range, with: "\(token) ")
        var mentions = draftMentionsByDialog[dialogId] ?? []
        mentions.removeAll { $0.accountId == member.accountId }
        mentions.append(DraftMention(accountId: member.accountId, token: token))
        draftMentionsByDialog[dialogId] = mentions
    }

    private func activeMentionRange(in text: String) -> Range<String.Index>? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let suffix = text[at...]
        guard !suffix.dropFirst().contains(where: \.isWhitespace) else { return nil }
        if at > text.startIndex {
            let previous = text[text.index(before: at)]
            guard previous.isWhitespace else { return nil }
        }
        return at..<text.endIndex
    }

    private func activeMentionQuery(in text: String) -> String? {
        guard let range = activeMentionRange(in: text) else { return nil }
        return String(text[range].dropFirst())
    }

    private func resolvedMentions(in text: String, dialogId: String) -> [CloudMention] {
        let nsText = text as NSString
        var seen = Set<String>()
        return (draftMentionsByDialog[dialogId] ?? []).compactMap { mention in
            guard seen.insert(mention.accountId).inserted else { return nil }
            let range = nsText.range(of: mention.token)
            guard range.location != NSNotFound, range.length > 1 else { return nil }
            return CloudMention(
                accountId: mention.accountId,
                offset: range.location,
                length: range.length
            )
        }
        .sorted { $0.offset < $1.offset }
    }

    func beginReply(to line: Line) {
        guard capabilities.contains(.replies), !line.isDeleted, line.msgId != nil else { return }
        composerMode = .replying(messageId: line.id, preview: line.text)
        scheduleActiveDraftPersistence(reason: .replyChanged)
    }

    func beginEditing(_ line: Line) {
        guard line.mine, !line.isDeleted, line.msgId != nil, capabilities.contains(.editing) else { return }
        transientUnderlyingDraftText = currentDraft?.state == "active" ? currentDraft?.text ?? "" : ""
        transientUnderlyingComposerMode = composerMode
        composerMode = .editing(messageId: line.id, original: line.text)
        suppressDraftPersistence = true
        draft = line.text
        suppressDraftPersistence = false
    }

    func cancelComposerMode() {
        if case .recording = composerMode {
            cancelVoiceRecording()
            return
        }
        if case .uploading = composerMode {
            if let transferId = activeComposerTransferId {
                mediaTransferTasks[transferId]?.cancel()
            }
            composerMediaTask?.cancel()
            composerMode = .text
            return
        }
        if case .editing = composerMode {
            restoreUnderlyingDraftComposer()
            return
        }
        composerMode = .text
        scheduleActiveDraftPersistence(reason: .replyChanged)
    }

    private func restoreUnderlyingDraftComposer() {
        let text = transientUnderlyingDraftText ?? (currentDraft?.state == "active" ? currentDraft?.text ?? "" : "")
        let mode = transientUnderlyingComposerMode ?? .text
        transientUnderlyingDraftText = nil
        transientUnderlyingComposerMode = nil
        suppressDraftPersistence = true
        draft = text
        composerMode = mode
        suppressDraftPersistence = false
    }

    func actions(for line: Line) -> [MessageAction] {
        if line.isDeleted { return [.inspect] }
        if line.pendingMutation != nil { return [.inspect] }
        var actions: [MessageAction] = line.text.isEmpty ? [] : [.copy]
        if capabilities.contains(.replies) { actions.insert(.reply, at: 0) }
        if line.msgId != nil, capabilities.contains(.reactions) { actions.insert(.react, at: min(1, actions.count)) }
        if line.mine, line.media == nil, capabilities.contains(.editing) { actions.append(.edit) }
        let sourceType = line.dialogId.flatMap { sourceId in
            dialogs.first(where: { $0.id == sourceId })?.type
        }
        let sourceIsSaved = sourceType == "saved"
        if line.msgId != nil,
           !sourceIsSaved,
           savedMessagesDialogId != nil || capabilities.contains(.savedMessages) {
            actions.append(.save)
        }
        if line.msgId != nil, capabilities.contains(.forwarding) { actions.append(.forward) }
        if line.mine, capabilities.contains(.deletion) { actions.append(.delete) }
        if (sourceType == "direct" || sourceType == "group"),
           Self.isReportable(line, capabilities: capabilities) {
            actions.append(.report)
        }
        if case .failed = line.delivery {
            actions.append(.retry)
            actions.append(.remove)
        }
        actions.append(.inspect)
        return actions
    }

    func canShowAccountReport(dialogId: String) -> Bool {
        Self.canReportAccount(
            dialogType: dialogs.first(where: { $0.id == dialogId })?.type,
            capabilities: capabilities
        )
    }

    nonisolated static func canReportAccount(
        dialogType: String?,
        capabilities: MessagingCapabilities
    ) -> Bool {
        capabilities.contains(.abuseReports) && dialogType == "direct"
    }

    nonisolated static func isReportable(
        _ line: Line,
        capabilities: MessagingCapabilities
    ) -> Bool {
        let serverAcknowledged: Bool
        switch line.delivery {
        case .sent, .seen:
            serverAcknowledged = true
        case .sending, .failed:
            serverAcknowledged = false
        }
        return capabilities.contains(.abuseReports)
            && !line.mine
            && line.kind != "service"
            && line.msgId != nil
            && serverAcknowledged
            && !line.isDeleted
            && line.pendingMutation == nil
    }

    func retryFailedMessage(_ line: Line) {
        guard case .failed = line.delivery else { return }
        Task { [weak self] in
            guard let self else { return }
            if let localStore = self.localStore {
                if let groupId = line.mediaGroupId {
                    try? await localStore.retryMediaGroupSend(clientGroupId: groupId)
                    if let dialogId = line.dialogId, self.activeDialogId == dialogId {
                        await self.loadLocalLines(dialogId: dialogId)
                    }
                    self.scheduleOutboxRetry()
                    return
                }
                try? await localStore.markRetrying(clientMsgId: line.clientMsgId)
                try? await localStore.markMediaRetrying(clientMsgId: line.clientMsgId)
                if let dialogId = line.dialogId, self.activeDialogId == dialogId {
                    await self.loadLocalLines(dialogId: dialogId)
                }
            }
            self.scheduleOutboxRetry()
        }
    }

    func removeFailedMessage(_ line: Line) {
        guard case .failed = line.delivery, !sessionTeardownActive else { return }
        Task { [weak self] in
            guard let self, !self.sessionTeardownActive, let localStore = self.localStore else {
                return
            }
            try? await localStore.removePendingOutboxMessage(clientMsgId: line.clientMsgId)
            if let dialogId = line.dialogId, self.activeDialogId == dialogId {
                await self.loadLocalLines(dialogId: dialogId)
            }
            await self.refreshDialogs()
        }
    }

    func removeFailedMedia(_ line: Line) {
        guard line.media != nil else { return }
        Task { [weak self] in
            guard let self, !self.sessionTeardownActive, let localStore else { return }
            if let groupId = line.mediaGroupId {
                let transfers = (try? await localStore.removeMediaGroupSend(
                    clientGroupId: groupId
                )) ?? []
                for transfer in transfers {
                    await mediaEngine.discardTransfer(transfer)
                }
                if let dialogId = line.dialogId, activeDialogId == dialogId {
                    await loadLocalLines(dialogId: dialogId)
                }
                await refreshDialogs()
                return
            }
            guard
                  let transfer = try? await localStore.mediaTransfer(clientMsgId: line.clientMsgId)
            else {
                try? await localStore.removePendingOutboxMessage(clientMsgId: line.clientMsgId)
                if let dialogId = line.dialogId, self.activeDialogId == dialogId {
                    await self.loadLocalLines(dialogId: dialogId)
                }
                await self.refreshDialogs()
                return
            }
            if let activeTask = mediaTransferTasks[transfer.transferId] {
                activeTask.cancel()
                await activeTask.value
                return
            }
            if let token = storedSession?.session.token {
                await cancelMediaTransfer(transfer, token: token)
            } else {
                try? await localStore.cancelMediaTransfer(
                    transferId: transfer.transferId, clientMsgId: transfer.clientMsgId
                )
                await mediaEngine.discardTransfer(transfer)
                if activeDialogId == transfer.dialogId { await loadLocalLines(dialogId: transfer.dialogId) }
            }
        }
    }

    func togglePinned(_ dialogId: String) {
        guard !isSessionTeardownInProgress else { return }
        guard capabilities.contains(.chatOrganization) else { return }
        #if DEBUG
        if isDemoMode {
            updateDialog(dialogId) {
                $0.isPinned.toggle()
                $0.pinnedAt = $0.isPinned ? CloudLocalStore.sqliteTimestamp(Date()) : nil
            }
            sortDialogsForPresentation()
            return
        }
        #endif
        launchDialogPreferenceMutation(dialogId: dialogId, field: .pinned)
    }

    func toggleMuted(_ dialogId: String) {
        guard !isSessionTeardownInProgress else { return }
        guard let dialog = dialogs.first(where: { $0.id == dialogId }) else { return }
        guard dialog.type != "saved" else { return }
        let supportsLegacyGroupMute = dialog.type == "group" && capabilities.contains(.groups)
        guard capabilities.contains(.chatOrganization) || supportsLegacyGroupMute else { return }
        #if DEBUG
        if isDemoMode {
            updateDialog(dialogId) {
                $0.isMuted.toggle()
                $0.notificationMode = $0.isMuted ? "muted" : "all"
            }
            return
        }
        #endif
        if !capabilities.contains(.chatOrganization), supportsLegacyGroupMute {
            launchLegacyGroupMute(dialogId: dialogId, muted: !dialog.isMuted)
            return
        }
        launchDialogPreferenceMutation(dialogId: dialogId, field: .muted)
    }

    func archive(_ dialogId: String) {
        guard !isSessionTeardownInProgress else { return }
        guard capabilities.contains(.chatOrganization) else { return }
        // Saved Messages is the permanent self-dialog. It can be pinned but is neither muted nor
        // archived; legacy local archived state is ignored by the forwarding picker.
        guard dialogs.first(where: { $0.id == dialogId })?.type != "saved" else { return }
        #if DEBUG
        if isDemoMode {
            updateDialog(dialogId) { $0.isArchived = true }
            return
        }
        #endif
        launchDialogPreferenceMutation(
            dialogId: dialogId,
            field: .archived,
            desiredValue: true
        )
    }

    func unarchive(_ dialogId: String) {
        guard !isSessionTeardownInProgress else { return }
        guard capabilities.contains(.chatOrganization) else { return }
        guard dialogs.first(where: { $0.id == dialogId })?.type != "saved" else { return }
        #if DEBUG
        if isDemoMode {
            updateDialog(dialogId) { $0.isArchived = false }
            return
        }
        #endif
        launchDialogPreferenceMutation(
            dialogId: dialogId,
            field: .archived,
            desiredValue: false
        )
    }

    /// Applies a chat-list action through the same durable local-first queues as a single-row
    /// action. The loop is serialized to keep preference ordering deterministic and to bound
    /// SQLCipher/network pressure when a user selects many chats.
    func performBulkDialogAction(
        _ action: BulkDialogAction,
        dialogIds: Set<String>
    ) async -> BulkDialogActionResult {
        guard !dialogIds.isEmpty, !isSessionTeardownInProgress else {
            return BulkDialogActionResult(changed: 0, skipped: dialogIds.count)
        }
        let selected = dialogs.filter { dialogIds.contains($0.id) }
        let missingCount = max(0, dialogIds.count - selected.count)

        #if DEBUG
        if isDemoMode {
            var changed = 0
            var skipped = missingCount
            for dialog in selected {
                if applyDemoBulkAction(action, dialogId: dialog.id) { changed += 1 }
                else { skipped += 1 }
            }
            sortDialogsForPresentation()
            return BulkDialogActionResult(changed: changed, skipped: skipped)
        }
        #endif

        guard
            let localStore,
            let accountId = storedSession?.session.accountId
        else {
            return BulkDialogActionResult(changed: 0, skipped: dialogIds.count)
        }
        let generation = accountSessionGeneration
        var changed = 0
        var skipped = missingCount
        var processed = 0

        for dialog in selected {
            guard
                !Task.isCancelled,
                !isSessionTeardownInProgress,
                generation == accountSessionGeneration,
                storedSession?.session.accountId == accountId
            else {
                skipped += selected.count - processed
                break
            }
            processed += 1

            switch action {
            case .markRead:
                guard dialog.type != "saved", dialog.unreadCount > 0, dialog.lastMsgId > 0 else {
                    skipped += 1
                    continue
                }
                do {
                    try await localStore.queueReadReceipt(
                        dialogId: dialog.id,
                        accountId: accountId,
                        maxReadMsgId: dialog.lastMsgId
                    )
                    changed += 1
                } catch {
                    skipped += 1
                }
            case let .pin(value):
                guard dialog.isPinned != value else { skipped += 1; continue }
                if await setDialogPreference(
                    dialogId: dialog.id,
                    field: .pinned,
                    desiredValue: value,
                    expectedAccountId: accountId,
                    sessionGeneration: generation
                ) { changed += 1 } else { skipped += 1 }
            case let .mute(value):
                guard dialog.type != "saved", dialog.isMuted != value else {
                    skipped += 1
                    continue
                }
                if await setDialogPreference(
                    dialogId: dialog.id,
                    field: .muted,
                    desiredValue: value,
                    expectedAccountId: accountId,
                    sessionGeneration: generation
                ) { changed += 1 } else { skipped += 1 }
            case let .archive(value):
                guard dialog.type != "saved", dialog.isArchived != value else {
                    skipped += 1
                    continue
                }
                if await setDialogPreference(
                    dialogId: dialog.id,
                    field: .archived,
                    desiredValue: value,
                    expectedAccountId: accountId,
                    sessionGeneration: generation
                ) { changed += 1 } else { skipped += 1 }
            }
        }

        if case .markRead = action, changed > 0 {
            await refreshDialogs()
            scheduleReadReceiptRetry()
        }
        return BulkDialogActionResult(changed: changed, skipped: skipped)
    }

    #if DEBUG
    private func applyDemoBulkAction(_ action: BulkDialogAction, dialogId: String) -> Bool {
        guard let index = dialogs.firstIndex(where: { $0.id == dialogId }) else { return false }
        switch action {
        case .markRead:
            guard dialogs[index].type != "saved", dialogs[index].unreadCount > 0 else { return false }
            dialogs[index].unreadCount = 0
        case let .pin(value):
            guard dialogs[index].isPinned != value else { return false }
            dialogs[index].isPinned = value
            dialogs[index].pinnedAt = value ? CloudLocalStore.sqliteTimestamp(Date()) : nil
        case let .mute(value):
            guard dialogs[index].type != "saved", dialogs[index].isMuted != value else { return false }
            dialogs[index].isMuted = value
            dialogs[index].notificationMode = value ? "muted" : "all"
        case let .archive(value):
            guard dialogs[index].type != "saved", dialogs[index].isArchived != value else { return false }
            dialogs[index].isArchived = value
        }
        return true
    }
    #endif

    private func launchDialogPreferenceMutation(
        dialogId: String,
        field: DialogPreferenceField,
        desiredValue: Bool? = nil
    ) {
        guard
            !isSessionTeardownInProgress,
            let accountId = storedSession?.session.accountId
        else { return }
        let generation = accountSessionGeneration
        let taskId = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.preferenceMutationTasks.removeValue(forKey: taskId) }
            _ = await self.setDialogPreference(
                dialogId: dialogId,
                field: field,
                desiredValue: desiredValue,
                expectedAccountId: accountId,
                sessionGeneration: generation
            )
        }
        preferenceMutationTasks[taskId] = task
    }

    private func launchLegacyGroupMute(dialogId: String, muted: Bool) {
        guard
            !isSessionTeardownInProgress,
            let accountId = storedSession?.session.accountId
        else { return }
        let generation = accountSessionGeneration
        let taskId = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.preferenceMutationTasks.removeValue(forKey: taskId) }
            guard
                !Task.isCancelled,
                self.accountSessionGeneration == generation,
                self.storedSession?.session.accountId == accountId
            else { return }
            _ = await self.submitGroupMutation(
                dialogId: dialogId,
                operation: "notifications",
                payload: GroupMutationPayload(mode: muted ? "muted" : "all")
            )
            guard
                !Task.isCancelled,
                self.accountSessionGeneration == generation,
                self.storedSession?.session.accountId == accountId
            else { return }
            await self.refreshDialogs()
        }
        preferenceMutationTasks[taskId] = task
    }

    nonisolated static func forwardingPickerDialogs(_ dialogs: [Dialog]) -> [Dialog] {
        dialogs
            .filter { $0.type == "saved" || !$0.isArchived }
            .sorted {
                if ($0.type == "saved") != ($1.type == "saved") {
                    return $0.type == "saved"
                }
                return $0.updatedAt > $1.updatedAt
            }
    }

    private func updateDialog(_ dialogId: String, mutation: (inout Dialog) -> Void) {
        guard let index = dialogs.firstIndex(where: { $0.id == dialogId }) else { return }
        mutation(&dialogs[index])
    }

    private func sortDialogsForPresentation() {
        dialogs.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.isPinned, $0.pinnedAt != $1.pinnedAt {
                return ($0.pinnedAt ?? "") > ($1.pinnedAt ?? "")
            }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id > $1.id
        }
    }

    @discardableResult
    private func setDialogPreference(
        dialogId: String,
        field: DialogPreferenceField,
        desiredValue: Bool? = nil,
        expectedAccountId: String? = nil,
        sessionGeneration: UInt64? = nil
    ) async -> Bool {
        guard !isSessionTeardownInProgress else { return false }
        guard capabilities.contains(.chatOrganization) else { return false }
        #if DEBUG
        if isDemoMode {
            updateDialog(dialogId) { dialog in
                let current: Bool
                switch field {
                case .pinned: current = dialog.isPinned
                case .muted: current = dialog.isMuted
                case .archived: current = dialog.isArchived
                }
                let value = desiredValue ?? !current
                switch field {
                case .pinned:
                    dialog.isPinned = value
                    dialog.pinnedAt = value ? CloudLocalStore.sqliteTimestamp(Date()) : nil
                case .muted:
                    dialog.isMuted = value
                    dialog.notificationMode = value ? "muted" : "all"
                case .archived:
                    dialog.isArchived = value
                }
            }
            sortDialogsForPresentation()
            return true
        }
        #endif
        guard
            let localStore,
            let accountId = storedSession?.session.accountId
        else { return false }
        let generation = sessionGeneration ?? accountSessionGeneration
        guard
            expectedAccountId == nil || expectedAccountId == accountId,
            generation == accountSessionGeneration
        else { return false }
        do {
            _ = try await dialogPreferencesCoordinator.queue(
                store: localStore,
                accountId: accountId,
                dialogId: dialogId,
                field: field,
                desiredValue: desiredValue
            )
            guard
                !Task.isCancelled,
                generation == accountSessionGeneration,
                storedSession?.session.accountId == accountId
            else { return false }
            // Observation publishes the SQLCipher overlay immediately; networking happens only
            // after the optimistic write has committed.
            await retryPendingDialogPreferences()
            scheduleOutboxRetry()
            return true
        } catch {
            presentNotice(
                String(localized: "Chat preference could not be saved"),
                message: error.localizedDescription
            )
            return false
        }
    }

    private func retryPendingDialogPreferences() async {
        guard !isSessionTeardownInProgress else { return }
        guard
            capabilities.contains(.chatOrganization),
            let localStore,
            let accountId = storedSession?.session.accountId,
            let token = storedSession?.session.token
        else { return }
        let generation = accountSessionGeneration
        do {
            let result = try await dialogPreferencesCoordinator.drain(
                store: localStore,
                accountId: accountId,
                token: token,
                serverAdvertisesFeature: true,
                sessionGeneration: generation
            )
            guard
                !Task.isCancelled,
                generation == accountSessionGeneration,
                storedSession?.session.accountId == accountId,
                storedSession?.session.token == token
            else { return }
            if result.acceptedCount > 0 {
                scheduleSync()
            }
            if let retryAfter = result.retryAfter {
                scheduleOutboxRetry(after: retryAfter)
                BackgroundRuntimeCoordinator.shared.scheduleAppRefresh(
                    earliestBeginDate: Date(timeIntervalSinceNow: retryAfter)
                )
            }
            if result.authenticationRequired {
                status = String(localized: "Chat preferences are saved and will sync after sign-in")
            }
            if result.capabilityRefreshRequired {
                await refreshServerCapabilities()
                guard
                    generation == accountSessionGeneration,
                    storedSession?.session.accountId == accountId
                else { return }
            }
            if let error = result.permanentErrors.first {
                await refreshDialogs()
                presentNotice(
                    String(localized: "Chat preference was not changed"),
                    message: error
                )
            }
        } catch is CancellationError {
            return
        } catch {
            status = String(
                format: String(localized: "Chat preference sync paused: %@"),
                error.localizedDescription
            )
        }
    }

    private func send(
        _ text: String,
        replyToMsgId: Int64? = nil,
        mentions: [CloudMention] = [],
        silent: Bool = false,
        deliverAfter: Date? = nil
    ) async {
        guard let token = storedSession?.session.token, let dialogId = activeDialogId else { return }
        let accountOperationContext = currentAccountOperationContext()
        openingTimelineAnchor = .bottom
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = true
        let clientMsgId = UUID().uuidString.lowercased()
        let attemptedDraft = try? await draftSyncCoordinator.currentDraft(dialogId: dialogId)
        let consumesCloudDraft = capabilities.contains(.cloudDrafts)
        let draftConsumeOperationId = attemptedDraft?.state == "active"
            ? attemptedDraft?.operationId
            : nil
        if let deliverAfter, deliverAfter > Date() {
            guard let context = accountOperationContext,
                  context.token == token,
                  isCurrentAccountOperation(context),
                  activeDialogId == dialogId else { return }
            guard capabilities.contains(.scheduledDelivery) else {
                suppressDraftPersistence = true
                draft = text
                suppressDraftPersistence = false
                presentNotice(
                    "Scheduled sending is unavailable",
                    message: "Your message was restored to the composer and was not queued locally."
                )
                return
            }
            let request = CloudScheduledCreateRequest(
                scheduleId: UUID().uuidString.lowercased(),
                clientMutationId: UUID().uuidString.lowercased(),
                dialogId: dialogId,
                deliverAt: ISO8601DateFormatter().string(from: deliverAfter),
                silent: silent,
                reminder: dialogs.first(where: { $0.id == dialogId })?.type == "saved",
                items: [CloudScheduledItem(
                    clientMsgId: clientMsgId,
                    kind: "text",
                    body: text,
                    replyToMsgId: replyToMsgId,
                    mediaId: nil,
                    mentions: mentions,
                    linkPreviewCandidate: capabilities.contains(.linkPreviews)
                        ? CloudLinkPreviewCandidate.first(in: text)
                        : nil
                )]
            )
            do {
                await productivitySyncCoordinator.bind(context)
                guard isCurrentAccountOperation(context), activeDialogId == dialogId else { return }
                let local = try await productivitySyncCoordinator.stageScheduledCreate(
                    request,
                    draftOperationId: attemptedDraft?.operationId
                )
                guard isCurrentAccountOperation(context), activeDialogId == dialogId else { return }
                scheduledDeliveries.removeAll { $0.scheduleId == local.scheduleId }
                scheduledDeliveries.append(local)
                scheduledDeliveries.sort { $0.deliverAt < $1.deliverAt }
                status = String(localized: "Waiting for connection — not scheduled yet")
                scheduleOutboxRetry()
            } catch {
                guard isCurrentAccountOperation(context), activeDialogId == dialogId else { return }
                suppressDraftPersistence = true
                draft = text
                suppressDraftPersistence = false
                presentNotice("Message was not scheduled", message: error.localizedDescription)
            }
            return
        }
        do {
            if let localStore, let accountId = storedSession?.session.accountId {
                _ = try await localStore.insertSending(
                    dialogId: dialogId,
                    clientMsgId: clientMsgId,
                    text: text,
                    senderAccountId: accountId,
                    replyToMsgId: replyToMsgId,
                    mentions: mentions,
                    draftConsumeOperationId: draftConsumeOperationId,
                    requiresCloudDraftSync: consumesCloudDraft,
                    silent: silent,
                    deliverAfter: deliverAfter
                )
                await loadLocalLines(dialogId: dialogId)
                await refreshDialogs()
            } else {
                lines.append(Line(
                    id: clientMsgId,
                    dialogId: dialogId,
                    msgId: nil,
                    clientMsgId: clientMsgId,
                    text: text,
                    mine: true,
                    delivery: .sending,
                    timestamp: nil,
                    replyToMsgId: replyToMsgId
                ))
            }
        } catch {
            status = "Local send failed: \(error.localizedDescription)"
            return
        }

        if consumesCloudDraft {
            let flushResult = await draftSyncCoordinator.flush(dialogId: dialogId)
            guard await acceptDraftFlushResult(flushResult) else {
                status = "Queued — waiting to sync draft"
                scheduleOutboxRetry(after: 1)
                return
            }
        }

        do {
            try await sendOutboxItem(
                PendingOutboxItem(
                    clientMsgId: clientMsgId,
                    dialogId: dialogId,
                    body: text,
                    replyToMsgId: replyToMsgId,
                    forwardedFromDialogId: nil,
                    forwardedFromMsgId: nil,
                    draftConsumeOperationId: consumesCloudDraft ? draftConsumeOperationId : nil,
                    silent: silent,
                    retryCount: 0,
                    nextRetryAt: nil
                ),
                token: token
            )
        } catch {
            if let apiError = error as? CloudAPIError,
               apiError.code == "invalid_reply_target",
               await recoverTextSendAfterInvalidReply(clientMsgId: clientMsgId) {
                return
            }
            if let localStore {
                let disposition = cloudOperationFailureDisposition(
                    error, serverAdvertisesFeature: capabilities.contains(.replies)
                )
                if case let .transient(retryAfter) = disposition {
                    let delay = retryAfter ?? retryDelay(forRetryCount: 1)
                    try? await localStore.markFailed(clientMsgId: clientMsgId, retryAfter: delay)
                    scheduleOutboxRetry(after: delay)
                    publishTransportFailure(error)
                } else {
                    try? await localStore.markFailed(clientMsgId: clientMsgId, terminal: true)
                    presentNotice("Message was not sent", message: error.localizedDescription)
                }
                await loadLocalLines(dialogId: dialogId)
                await refreshDialogs()
            } else {
                if let index = lines.firstIndex(where: { $0.clientMsgId == clientMsgId }) {
                    lines[index].delivery = .failed(error.localizedDescription)
                }
            }
            status = "Send failed: \(error.localizedDescription)"
        }
    }

    func sendMedia(
        data: Data, kind: String, contentType: String, fileName: String?,
        durationMs: Int64? = nil, width: Int? = nil, height: Int? = nil,
        thumbnail: Data? = nil
    ) async {
        composerMediaTask?.cancel()
        await composerMediaTask?.value
        guard !sessionTeardownActive, let dialogId = activeDialogId else { return }
        let operationId = UUID()
        composerMediaOperationId = operationId
        // Establish dialog ownership before the task can enter mediaEngine.prepare.
        composerMediaDialogId = dialogId
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performMediaSend(
                dialogId: dialogId,
                data: data, kind: kind, contentType: contentType, fileName: fileName,
                durationMs: durationMs, width: width, height: height, thumbnail: thumbnail
            )
        }
        composerMediaTask = task
        await task.value
        if composerMediaOperationId == operationId {
            composerMediaTask = nil
            composerMediaOperationId = nil
            composerMediaDialogId = nil
            activeComposerTransferId = nil
        }
    }

    /// Copies picker bytes into the protected encrypted media store before returning. Uploading is
    /// then detached from the picker lifecycle and capped at two concurrent draft transfers.
    func stageDraftMedia(
        data: Data,
        kind: String,
        contentType: String,
        fileName: String?,
        durationMs: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        thumbnail: Data? = nil
    ) async throws {
        guard
            !sessionTearingDown,
            let dialogId = activeDialogId,
            let accountId = storedSession?.session.accountId,
            let localStore
        else { throw CloudAppModelError.localStoreUnavailable }
        let epoch = sessionEpoch
        let mediaEngine = self.mediaEngine
        let groupsEnabled = capabilities.contains(.mediaGroups)
        let transfer = try await draftSyncCoordinator.withDialogStaging(dialogId: dialogId) {
            let existing = try await localStore.loadDraft(accountId: accountId, dialogId: dialogId)
            let position = existing?.attachments.count ?? 0
            guard position < 10 else { throw CloudAppModelError.tooManyDraftAttachments }
            guard position == 0 || groupsEnabled else {
                throw CloudAppModelError.mediaGroupsUnavailable
            }
            let prepared = try await mediaEngine.prepare(
                data: data,
                kind: kind,
                contentType: contentType,
                fileName: fileName,
                durationMs: durationMs,
                width: width,
                height: height,
                thumbnail: thumbnail
            )
            let attachmentId = UUID().uuidString.lowercased()
            var staged = false
            do {
                try Task.checkCancellation()
                _ = try await localStore.stageDraftAttachment(
                    prepared: prepared,
                    accountId: accountId,
                    dialogId: dialogId,
                    attachmentId: attachmentId,
                    position: position
                )
                staged = true
                try Task.checkCancellation()
                guard let transfer = try await localStore.mediaTransfer(id: prepared.transferId)
                else { throw CloudAppModelError.localStoreUnavailable }
                return transfer
            } catch {
                if staged {
                    _ = try? await localStore.removeDraftAttachment(
                        accountId: accountId,
                        dialogId: dialogId,
                        attachmentId: attachmentId
                    )
                }
                await mediaEngine.discardPrepared(prepared)
                throw error
            }
        }
        guard !sessionTearingDown, sessionEpoch == epoch else {
            throw CancellationError()
        }
        Task { [weak self] in
            guard let self, !self.sessionTearingDown, self.sessionEpoch == epoch else { return }
            await self.runMediaTransfer(transfer)
        }
        _ = await draftSyncCoordinator.flush(dialogId: dialogId)
    }

    func removeDraftAttachment(_ attachment: LocalDraftAttachment) {
        guard
            let dialogId = activeDialogId,
            let accountId = storedSession?.session.accountId,
            let localStore
        else { return }
        Task { [weak self] in
            guard let self else { return }
            let transfer: MediaTransferRecord?
            if let transferId = attachment.transferId {
                transfer = try? await localStore.mediaTransfer(id: transferId)
            } else {
                transfer = nil
            }
            if let transferId = try? await localStore.removeDraftAttachment(
                accountId: accountId,
                dialogId: dialogId,
                attachmentId: attachment.attachmentId
            ) {
                mediaTransferTasks[transferId]?.cancel()
                if let transfer, let token = storedSession?.session.token {
                    await mediaEngine.cancelUpload(transfer, token: token)
                    await mediaEngine.discardTransfer(transfer)
                } else if let transfer {
                    await mediaEngine.discardTransfer(transfer)
                }
            }
            _ = await draftSyncCoordinator.flush(dialogId: dialogId)
        }
    }

    func moveDraftAttachment(_ attachmentId: String, by offset: Int) {
        guard
            let dialogId = activeDialogId,
            let accountId = storedSession?.session.accountId,
            let localStore,
            let draft = currentDraft
        else { return }
        var ids = draft.attachments.sorted { $0.position < $1.position }.map(\.attachmentId)
        guard let oldIndex = ids.firstIndex(of: attachmentId) else { return }
        let newIndex = max(0, min(ids.count - 1, oldIndex + offset))
        guard newIndex != oldIndex else { return }
        let moving = ids.remove(at: oldIndex)
        ids.insert(moving, at: newIndex)
        Task { [weak self] in
            guard let self else { return }
            try? await localStore.reorderDraftAttachments(
                accountId: accountId,
                dialogId: dialogId,
                attachmentIds: ids
            )
            _ = await draftSyncCoordinator.flush(dialogId: dialogId)
        }
    }

    func moveDraftAttachment(_ attachmentId: String, before targetId: String) {
        guard
            attachmentId != targetId,
            let dialogId = activeDialogId,
            let accountId = storedSession?.session.accountId,
            let localStore,
            let draft = currentDraft
        else { return }
        var ids = draft.attachments.sorted { $0.position < $1.position }.map(\.attachmentId)
        guard let movingIndex = ids.firstIndex(of: attachmentId) else { return }
        let moving = ids.remove(at: movingIndex)
        guard let targetIndex = ids.firstIndex(of: targetId) else { return }
        ids.insert(moving, at: targetIndex)
        Task { [weak self] in
            guard let self else { return }
            try? await localStore.reorderDraftAttachments(
                accountId: accountId,
                dialogId: dialogId,
                attachmentIds: ids
            )
            _ = await draftSyncCoordinator.flush(dialogId: dialogId)
        }
    }

    func retryDraftAttachment(_ attachment: LocalDraftAttachment) {
        guard let transferId = attachment.transferId, let localStore else { return }
        Task { [weak self] in
            guard let self,
                  let transfer = try? await localStore.retryDraftAttachment(transferId: transferId)
            else { return }
            await runMediaTransfer(transfer)
        }
    }

    private func performMediaSend(
        dialogId: String,
        data: Data, kind: String, contentType: String, fileName: String?,
        durationMs: Int64?, width: Int?, height: Int?, thumbnail: Data?
    ) async {
        guard
            !sessionTeardownActive,
            let accountId = storedSession?.session.accountId,
            let localStore
        else { return }
        openingTimelineAnchor = .bottom
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = true
        // Voice recording is a transient buffer layered over the cloud draft. It never consumes
        // or reuses the draft text as a caption.
        let caption = kind == "voice"
            ? ""
            : draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let replyToMsgId: Int64?
        if case let .replying(messageId, _) = composerMode {
            replyToMsgId = lines.first(where: { $0.id == messageId })?.msgId
        } else { replyToMsgId = nil }
        let clientMsgId = UUID().uuidString.lowercased()
        let presentation = Self.demoAttachment(
            kind: kind, fileName: fileName, byteSize: Int64(data.count), durationMs: durationMs
        )
        var unpersistedPreparation: PreparedMediaUpload?
        var persistedTransfer: MediaTransferRecord?
        var transferPersisted = false
        do {
            composerMode = .uploading(presentation, progress: 0)
            let prepared = try await mediaEngine.prepare(
                data: data, kind: kind, contentType: contentType, fileName: fileName,
                durationMs: durationMs, width: width, height: height, thumbnail: thumbnail
            )
            unpersistedPreparation = prepared
            try await localStore.insertMediaTransfer(
                prepared: prepared, dialogId: dialogId, clientMsgId: clientMsgId,
                caption: caption, replyToMsgId: replyToMsgId
            )
            transferPersisted = true
            unpersistedPreparation = nil
            guard let transfer = try await localStore.mediaTransfer(id: prepared.transferId) else {
                throw CloudAppModelError.localStoreUnavailable
            }
            persistedTransfer = transfer
            activeComposerTransferId = transfer.transferId
            try await localStore.insertSendingMedia(transfer, senderAccountId: accountId)
            lines.append(Line(
                id: "transfer:\(prepared.transferId)", dialogId: dialogId, msgId: nil,
                clientMsgId: clientMsgId, senderAccountId: accountId, text: caption,
                mine: true, delivery: .sending, timestamp: nil,
                media: transfer.media, transferProgress: 0, transferStage: .preparing
            ))
            await runMediaTransfer(transfer)
        } catch is CancellationError {
            if let unpersistedPreparation { await mediaEngine.discardPrepared(unpersistedPreparation) }
            if let persistedTransfer, let token = storedSession?.session.token {
                await cancelMediaTransfer(persistedTransfer, token: token)
            }
            composerMode = .text
        } catch {
            if let unpersistedPreparation { await mediaEngine.discardPrepared(unpersistedPreparation) }
            if transferPersisted { scheduleOutboxRetry() }
            composerMode = .text
            status = "Media send failed: \(error.localizedDescription)"
            presentNotice("Could not prepare attachment", message: error.localizedDescription)
        }
    }

    func beginVoiceRecording() async {
        #if DEBUG
        if isDemoMode { beginDemoRecording(); return }
        #endif
        do {
            transientVoiceComposerMode = composerMode
            try await voiceRecorder.start()
            composerMode = .recording(elapsedSeconds: 0)
            recordingTask?.cancel()
            recordingTask = Task { [weak self] in
                while let self, !Task.isCancelled, self.voiceRecorder.isRecording {
                    self.composerMode = .recording(elapsedSeconds: self.voiceRecorder.elapsedSeconds)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        } catch {
            status = error.localizedDescription
            restoreVoiceDraftComposer()
            let denied = (error as? VoiceRecorderError) == .permissionDenied
            presentNotice(
                denied ? "Microphone access is off" : "Could not record",
                message: error.localizedDescription,
                opensSettings: denied
            )
        }
    }

    func finishVoiceRecording() async {
        #if DEBUG
        if isDemoMode { finishDemoRecording(); return }
        #endif
        recordingTask?.cancel()
        recordingTask = nil
        do {
            let result = try await voiceRecorder.finish()
            composerMode = transientVoiceComposerMode ?? .text
            await sendMedia(
                data: result.data, kind: "voice", contentType: "audio/mp4",
                fileName: "Voice message.m4a", durationMs: result.durationMs
            )
            restoreVoiceDraftComposer()
        } catch VoiceRecorderError.tooShort {
            status = "Recording canceled"
            restoreVoiceDraftComposer()
        } catch {
            status = error.localizedDescription
            restoreVoiceDraftComposer()
            presentNotice("Voice message was not sent", message: error.localizedDescription)
        }
    }

    func cancelVoiceRecording() {
        recordingTask?.cancel()
        recordingTask = nil
        voiceRecorder.cancel()
        restoreVoiceDraftComposer()
    }

    private func restoreVoiceDraftComposer() {
        composerMode = transientVoiceComposerMode ?? .text
        transientVoiceComposerMode = nil
    }

    func thumbnailData(for media: CloudMedia) async -> Data? {
        #if DEBUG
        if isDemoMode { return demoMediaBytes(for: media, thumbnail: true) }
        #endif
        guard let token = storedSession?.session.token,
              await restoreMediaAccessIfAuthorized(mediaId: media.id) != nil
        else { return nil }
        let state = await mediaEngine.mediaDownloadState(mediaId: media.id, expectedSize: media.byteSize)
        LocalFirstMetrics.cacheResult(hit: state?.hasThumbnail == true, thumbnail: true)
        return try? await mediaEngine.thumbnail(
            media: media,
            token: token,
            localStore: localStore
        )
    }

    private func restoreMediaAccessIfAuthorized(
        mediaId: String,
        dialogId: String? = nil
    ) async -> MediaPresentationAuthorization? {
        guard !sessionTeardownActive, let localStore else { return nil }
        guard let authorization = try? await localStore.mediaPresentationAuthorization(
            mediaId: mediaId,
            dialogId: dialogId
        ) else { return nil }
        #if DEBUG
        await mediaAccessRestoreAuthorizationGate?()
        #endif
        let lease: MediaAccessRestoreLease
        do {
            lease = try await mediaEngine.restoreAuthorizedAccess(mediaId: mediaId)
        } catch {
            return nil
        }
        #if DEBUG
        await mediaAccessPostRestoreValidationGate?()
        #endif
        if !sessionTeardownActive,
           (try? await localStore.validatesMediaPresentationAuthorization(
            authorization
           )) == true {
            MediaPresentationCache.shared.restore(mediaIds: [mediaId])
            return authorization
        }

        // The exact dialog authorization was stale. Keep the global fence open only when a
        // separately revalidated SQLCipher reference proves that another dialog (or a newer group
        // grant) currently owns this media. Otherwise roll back this exact unfencing generation;
        // rollback fences first and removes any bytes written during the brief unfenced window.
        if !sessionTeardownActive,
           let currentAuthorization = try? await localStore.mediaPresentationAuthorization(
            mediaId: mediaId
           ),
           (try? await localStore.validatesMediaPresentationAuthorization(
            currentAuthorization
           )) == true {
            MediaPresentationCache.shared.restore(mediaIds: [mediaId])
            return nil
        }
        _ = await rollbackUnauthorizedMediaPresentation(lease, mediaId: mediaId)
        return nil
    }

    @discardableResult
    private func rollbackUnauthorizedMediaPresentation(
        _ lease: MediaAccessRestoreLease,
        mediaId: String
    ) async -> Bool {
        guard (try? await mediaEngine.rollbackUnauthorizedAccess(lease)) == true else {
            return false
        }
        MediaPresentationCache.shared.revoke(mediaIds: [mediaId])
        return true
    }

    func presentationImage(
        for media: CloudMedia,
        variant requestedVariant: MediaPresentationVariant
    ) async -> UIImage? {
        let interval = LocalFirstMetrics.begin("Media ready")
        defer { LocalFirstMetrics.end("Media ready", interval) }
        let variant: MediaPresentationVariant = media.kind == "video"
            && requestedVariant == .bubble720 ? .videoPoster : requestedVariant
        let key = MediaPresentationKey(mediaId: media.id, variant: variant)
        #if DEBUG
        if isDemoMode {
            let demoData = demoMediaBytes(for: media, thumbnail: variant != .screen2048)
            return await MediaPresentationCache.shared.image(for: key) {
                guard let data = demoData else { return nil }
                return await Task.detached(priority: .userInitiated) {
                    SafeMediaImageDecoder.decode(data, maxPixelSize: variant.maximumPixelSize)
                }.value
            }
        }
        #endif

        guard await restoreMediaAccessIfAuthorized(mediaId: media.id) != nil else {
            return nil
        }
        let engine = mediaEngine
        let store = localStore
        let token = storedSession?.session.token
        return await MediaPresentationCache.shared.image(for: key) {
            let durable = await engine.representation(
                media: media,
                variant: variant,
                localStore: store
            )
            let source: Data?
            if let durable {
                LocalFirstMetrics.presentationCacheTier("encrypted-representation")
                source = durable
            } else {
                guard let token else { return nil }
                switch variant {
                case .bubble720, .videoPoster:
                    if media.hasThumbnail {
                        source = try? await engine.thumbnail(
                            media: media,
                            token: token,
                            localStore: store
                        )
                    } else {
                        let state = await engine.mediaDownloadState(
                            mediaId: media.id,
                            expectedSize: media.byteSize
                        )
                        guard state?.isComplete == true else { return nil }
                        source = try? await engine.data(
                            media: media,
                            token: token,
                            localStore: store,
                            priority: .automatic
                        )
                    }
                case .screen2048:
                    source = try? await engine.data(
                        media: media,
                        token: token,
                        localStore: store,
                        priority: .userInitiated
                    )
                }
            }
            guard let source else { return nil }
            let decoded = await Task.detached(priority: .userInitiated) {
                SafeMediaImageDecoder.decode(source, maxPixelSize: variant.maximumPixelSize)
            }.value
            guard let decoded else { return nil }
            if durable == nil {
                let representation = await Task.detached(priority: .utility) {
                    decoded.image.jpegData(compressionQuality: variant == .screen2048 ? 0.9 : 0.82)
                }.value
                if let representation {
                    await engine.storeRepresentation(
                        representation,
                        media: media,
                        variant: variant,
                        localStore: store
                    )
                }
            }
            return decoded
        }
    }

    func mediaAvailability(
        for media: CloudMedia,
        variant: MediaPresentationVariant
    ) async -> MediaAvailability {
        guard await restoreMediaAccessIfAuthorized(mediaId: media.id) != nil else {
            return .failed
        }
        let key = MediaPresentationKey(mediaId: media.id, variant: variant)
        if MediaPresentationCache.shared.contains(key) { return .decoded }
        if await mediaEngine.representation(media: media, variant: variant, localStore: localStore) != nil {
            return .localRepresentation
        }
        guard let state = await mediaEngine.mediaDownloadState(
            mediaId: media.id,
            expectedSize: media.byteSize
        ) else { return .remote }
        if state.isComplete { return .localComplete }
        if state.cachedBytes > 0 {
            return .partial(progress: min(1, Double(state.cachedBytes) / Double(max(1, media.byteSize))))
        }
        if state.hasThumbnail { return .localRepresentation }
        return .remote
    }

    func mediaData(
        for media: CloudMedia,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> Data {
        #if DEBUG
        if isDemoMode {
            // Staged progress so the viewer's download ring is demonstrable.
            await progress(0.4)
            try? await Task.sleep(for: .milliseconds(220))
            await progress(0.85)
            try? await Task.sleep(for: .milliseconds(180))
            await progress(1)
            return demoMediaBytes(for: media, thumbnail: false) ?? Data()
        }
        #endif
        guard let token = storedSession?.session.token,
              await restoreMediaAccessIfAuthorized(mediaId: media.id) != nil
        else {
            throw CloudAPIError(status: 401, message: "Sign in required", retryAfter: nil)
        }
        let state = await mediaEngine.mediaDownloadState(mediaId: media.id, expectedSize: media.byteSize)
        LocalFirstMetrics.cacheResult(hit: state?.isComplete == true, thumbnail: false)
        return try await mediaEngine.data(
            media: media,
            token: token,
            localStore: localStore,
            priority: .userInitiated,
            progress: progress
        )
    }

    /// A streaming asset that plays this media progressively (chunk-by-chunk) instead of requiring a
    /// full download first. Returns `nil` until there is a session token. Retain the owner while playing.
    func streamingVideoAsset(for media: CloudMedia) async -> StreamingMediaAsset? {
        guard await restoreMediaAccessIfAuthorized(mediaId: media.id) != nil else {
            return nil
        }
        if let prepared = MediaPresentationCache.shared.takePreparedVideoAsset(mediaId: media.id) {
            return prepared
        }
        guard let token = storedSession?.session.token else { return nil }
        return mediaEngine.makeStreamingAsset(
            media: media,
            token: token,
            localStore: localStore
        )
    }

    private func prewarmStreamingVideoAssetIfLocal(for media: CloudMedia) async {
        guard media.kind == "video",
              await restoreMediaAccessIfAuthorized(mediaId: media.id) != nil,
              !MediaPresentationCache.shared.hasPreparedVideoAsset(mediaId: media.id),
              let token = storedSession?.session.token,
              await mediaEngine.mediaDownloadState(
                mediaId: media.id,
                expectedSize: media.byteSize
              )?.isComplete == true else { return }
        let asset = mediaEngine.makeStreamingAsset(
            media: media,
            token: token,
            localStore: localStore,
            startsAccessImmediately: false
        )
        MediaPresentationCache.shared.storePreparedVideoAsset(asset, mediaId: media.id)
    }

    @discardableResult
    func transferTemporaryMediaURL(
        data: Data,
        fileExtension: String?,
        mediaId: String,
        dialogId: String,
        transferOwnership: @escaping @MainActor @Sendable (URL) -> Bool
    ) async throws -> Bool {
        let accountId = storedSession?.session.accountId
        let token = storedSession?.session.token
        let generation = savedMessagesSessionGeneration
        let store = localStore
        let presentationGeneration = dialogPresentationGenerations[dialogId, default: 0]
        #if DEBUG
        let permitsDemoMedia = isDemoMode
        #else
        let permitsDemoMedia = false
        #endif
        guard !sessionTeardownActive,
              permitsDemoMedia || (accountId != nil && token != nil && store != nil)
        else {
            throw CloudLocalStoreAccessError.revoked
        }
        let authorization: MediaPresentationAuthorization?
        #if DEBUG
        if permitsDemoMedia {
            authorization = nil
        } else {
            authorization = try await store?.mediaPresentationAuthorization(
                mediaId: mediaId,
                dialogId: dialogId
            )
        }
        #else
        authorization = try await store?.mediaPresentationAuthorization(
            mediaId: mediaId,
            dialogId: dialogId
        )
        #endif
        guard permitsDemoMedia || authorization != nil else {
            throw CloudLocalStoreAccessError.revoked
        }
        return try await mediaEngine.temporaryPreview(
            data: data,
            fileExtension: fileExtension
        ) { [weak self, store] url in
            guard !Task.isCancelled else { return false }
            #if DEBUG
            await self?.temporaryPreviewAuthorizationGate?(url)
            #endif
            if !permitsDemoMedia {
                guard let store, let authorization,
                      (try? await store.validatesMediaPresentationAuthorization(
                        authorization
                      )) == true
                else { return false }
            }
            return await MainActor.run {
                guard let self,
                      !Task.isCancelled,
                      !self.sessionTeardownActive,
                      self.savedMessagesSessionGeneration == generation,
                      self.storedSession?.session.accountId == accountId,
                      self.storedSession?.session.token == token,
                      self.localStore === store || permitsDemoMedia,
                      self.dialogPresentationGenerations[dialogId, default: 0]
                        == presentationGeneration
                else { return false }
                self.temporaryPreviewURLsByDialog[dialogId, default: []].insert(url)
                let transferred = transferOwnership(url)
                if !transferred {
                    self.temporaryPreviewURLsByDialog[dialogId]?.remove(url)
                    if self.temporaryPreviewURLsByDialog[dialogId]?.isEmpty == true {
                        self.temporaryPreviewURLsByDialog[dialogId] = nil
                    }
                }
                return transferred
            }
        }
    }

    func removeTemporaryMediaURL(_ url: URL) async {
        for dialogId in Array(temporaryPreviewURLsByDialog.keys) {
            temporaryPreviewURLsByDialog[dialogId]?.remove(url)
            if temporaryPreviewURLsByDialog[dialogId]?.isEmpty == true {
                temporaryPreviewURLsByDialog[dialogId] = nil
            }
        }
        await mediaEngine.removeTemporaryPreview(url)
    }

    private func afterSignIn() async {
        guard
            let token = storedSession?.session.token,
            let accountId = storedSession?.session.accountId
        else { return }
        do {
            guard let restoredStore = try await ensureLocalStore() else {
                throw CloudAppModelError.localStoreUnavailable
            }
            try await drainAccessPurges(
                store: restoredStore,
                accountId: accountId,
                token: token,
                generation: savedMessagesSessionGeneration
            )
            let launchSnapshot = try await restoredStore.loadLaunchSnapshot(accountId: accountId)
            await draftSyncCoordinator.configure(
                store: restoredStore,
                session: storedSession?.session,
                cloudEnabled: negotiatedCapabilities.contains(.cloudDrafts)
            )
            await profilePhotoSyncCoordinator.configure(
                store: restoredStore,
                session: storedSession?.session,
                enabled: negotiatedCapabilities.contains(.profilePhotos)
            )

            // Publish the complete cached launch state in one main-actor turn.
            pts = launchSnapshot.pts
            acceptObservedDialogs(launchSnapshot.dialogs)
            activeDialogId = nil
            lines = []
            canLoadEarlier = false
            launchPhase = .localReady
            status = "Ready"
            startDialogObservation(accountId: accountId)
            startNetworkObservation()
            startMemoryPressureObservation()
            EncryptedProfilePhotoStore.beginAuthenticatedSession()
            profilePhotoMigrationTask?.cancel()
            profilePhotoMigrationTask = Task.detached(priority: .utility) {
                guard !Task.isCancelled else { return }
                _ = EncryptedProfilePhotoStore.migrateLegacySynchronously(accountId: accountId)
            }
        } catch {
            pts = 0
            status = "Local store unavailable: \(error.localizedDescription)"
            setReplicaSyncState(.localFailure)
            launchPhase = .recoveringStore
            return
        }
        if let session = storedSession?.session {
            callCoordinator.configure(api: api, session: session) { [weak self] dialogId, _ in
                self?.dialogTitle(dialogId) ?? String(localized: "Toj caller")
            }
            groupCallCoordinator.configure(
                api: api,
                session: session,
                screenSharingNegotiated: { [weak self] in
                    self?.negotiatedCapabilities.contains(.screenSharing) == true
                }
            ) { [weak self] accountId, dialogId in
                self?.groupCallParticipantName(accountId: accountId, dialogId: dialogId)
                    ?? String(accountId.prefix(8))
            }
        }
        await refreshMediaCacheUsage()
        // Bind search at local-ready time, not only when the UI happens to open the Search tab.
        // This makes the local capability truthful and lets the existing background runtime service
        // queue and maintenance work even when the user never visits search.
        await refreshSearchCoordinator()
        installBackgroundWorkHandlers()
        if let localStore {
            startReplicaIntegrityVerification(store: localStore, accountId: accountId)
            _ = try? await localStore.drainPendingPurges()
        }
        scheduleOutboxRetry()
    }

    private func drainAccessPurges(
        store: CloudLocalStore,
        accountId: String,
        token: String,
        generation: UInt64
    ) async throws {
        let scope = AccessPurgeScope(
            accountId: accountId,
            token: token,
            generation: generation,
            store: store
        )
        _ = try await accessPurgeCoordinator.drain(
            scope: scope,
            store: store,
            mediaEngine: mediaEngine,
            isCurrent: { [weak self, store] in
                guard let self else { return false }
                return !self.sessionTeardownActive
                    && self.savedMessagesSessionGeneration == generation
                    && self.storedSession?.session.accountId == accountId
                    && self.storedSession?.session.token == token
                    && self.localStore === store
            },
            invalidatePresentation: { [weak self] job in
                guard let self else { return }
                await self.invalidatePresentationForAccessPurge(job)
            }
        )
        if mediaSchedulerForegrounded {
            await mediaPrefetchScheduler.update(
                networkClass: ReplicaNetworkMonitor.shared.snapshot().networkClass,
                foregrounded: true
            )
        }
    }

    private func invalidatePresentationForAccessPurge(_ job: AccessPurgeJob) async {
        let dialogId = job.dialogId
        dialogPresentationGenerations[dialogId, default: 0] &+= 1
        let temporaryURLs = temporaryPreviewURLsByDialog.removeValue(forKey: dialogId) ?? []
        for url in temporaryURLs {
            await mediaEngine.removeTemporaryPreview(url)
        }
        // Shared media remains valid in a forwarded copy. Only globally orphaned media receives a
        // process-wide presentation tombstone.
        MediaPresentationCache.shared.revoke(mediaIds: job.purgeMediaIds)

        let transferIds = Set(mediaTransferDialogIds.compactMap { transferId, taskDialogId in
            taskDialogId == dialogId ? transferId : nil
        })
        let cancellableTasks = transferIds.compactMap { mediaTransferTasks[$0] }
        cancellableTasks.forEach { $0.cancel() }
        let cancelsActiveConversationWork = activeDialogId == dialogId
        if cancelsActiveConversationWork {
            mediaDownloadTask?.cancel()
            historyHydrationTask?.cancel()
        }
        let cancelsComposer = composerMediaDialogId == dialogId
            || activeComposerTransferId.map(transferIds.contains) == true
        if cancelsComposer { composerMediaTask?.cancel() }
        for task in cancellableTasks { await task.value }
        for transferId in transferIds {
            mediaTransferTasks[transferId] = nil
            mediaTransferDialogIds[transferId] = nil
            mediaTransfersInFlight.remove(transferId)
        }
        if cancelsActiveConversationWork {
            await mediaDownloadTask?.value
            await historyHydrationTask?.value
            mediaDownloadTask = nil
            historyHydrationTask = nil
        }
        if cancelsComposer {
            await composerMediaTask?.value
            composerMediaTask = nil
            composerMediaDialogId = nil
            activeComposerTransferId = nil
            composerMediaOperationId = nil
        }

        cachedLinesByDialog[dialogId] = nil
        cachedLocalMessagesByDialog[dialogId] = nil
        cachedConversationCostByDialog[dialogId] = nil
        cachedLineDialogOrder.removeAll { $0 == dialogId }
        timelineForwardCursorByDialog[dialogId] = nil
        conversationOpenWaiters[dialogId]?.forEach { $0.resume() }
        conversationOpenWaiters[dialogId] = nil
        conversationOpenStartedAt[dialogId] = nil
        dialogs.removeAll { $0.id == dialogId }
        if savedMessagesDialogId == dialogId { savedMessagesDialogId = nil }
        if activeDialogId == dialogId {
            activeDialogId = nil
            lines = []
            loadedLocalMessages = []
            pendingVisibleReadMessages = []
            canLoadEarlier = false
        }
    }

    #if DEBUG
    func testTrackMediaTransferTask(
        transferId: String,
        dialogId: String,
        task: Task<Void, Never>
    ) {
        mediaTransferTasks[transferId] = task
        mediaTransferDialogIds[transferId] = dialogId
        mediaTransfersInFlight.insert(transferId)
    }

    func testTrackComposerPreparation(dialogId: String, task: Task<Void, Never>) {
        composerMediaTask = task
        composerMediaDialogId = dialogId
        composerMediaOperationId = UUID()
    }

    func testInvalidatePresentationForAccessPurge(_ job: AccessPurgeJob) async {
        await invalidatePresentationForAccessPurge(job)
    }

    func testHasTrackedMediaTransfer(_ transferId: String) -> Bool {
        mediaTransferTasks[transferId] != nil
    }

    func testCancelTrackedMediaTransfer(_ transferId: String) async {
        guard let task = mediaTransferTasks.removeValue(forKey: transferId) else { return }
        mediaTransferDialogIds[transferId] = nil
        mediaTransfersInFlight.remove(transferId)
        task.cancel()
        await task.value
    }

    func testClearLocalSession() async {
        await clearLocalSession(finalStatus: "Test session cleared")
    }

    func testHasSessionClearBarrier() -> Bool {
        sessionClearBarrier != nil
    }

    func testInstallAuthenticatedSession(_ session: StoredCloudSession) {
        installAuthenticatedSession(session)
    }

    func testAcceptCanonicalProfile(_ profile: CloudProfile, token: String) async {
        guard let session = storedSession?.session else { return }
        await acceptCanonicalProfile(
            profile,
            accountId: session.accountId,
            deviceId: session.deviceId,
            token: token,
            generation: accountSessionGeneration,
            store: localStore
        )
    }

    func testHandleRevokedSessionHint(deviceId: String? = nil) async {
        await scheduleSessionClearFromRevokedHint(deviceId: deviceId)?.value
    }

    func testHandleRevokedSessionHintFromHintTask(deviceId: String? = nil) async {
        var teardownTask: Task<Void, Never>?
        let task = Task { @MainActor [weak self] in
            teardownTask = self?.scheduleSessionClearFromRevokedHint(deviceId: deviceId)
        }
        hintTask = task
        await task.value
        await teardownTask?.value
    }

    func testSetTemporaryPreviewAuthorizationGate(
        _ gate: (@Sendable (URL) async -> Void)?
    ) {
        temporaryPreviewAuthorizationGate = gate
    }

    func testSetMediaAccessRestoreAuthorizationGate(
        _ gate: (@Sendable () async -> Void)?
    ) {
        mediaAccessRestoreAuthorizationGate = gate
    }

    func testSetMediaAccessPostRestoreValidationGate(
        _ gate: (@Sendable () async -> Void)?
    ) {
        mediaAccessPostRestoreValidationGate = gate
    }

    func testRestoreMediaAccessIfAuthorized(
        mediaId: String,
        dialogId: String? = nil
    ) async -> MediaPresentationAuthorization? {
        await restoreMediaAccessIfAuthorized(mediaId: mediaId, dialogId: dialogId)
    }

    func testRollbackUnauthorizedMediaPresentation(
        _ lease: MediaAccessRestoreLease,
        mediaId: String
    ) async -> Bool {
        await rollbackUnauthorizedMediaPresentation(lease, mediaId: mediaId)
    }
    #endif

    private func startReplicaIntegrityVerification(store: CloudLocalStore, accountId: String) {
        replicaIntegrityTask?.cancel()
        replicaIntegrityTask = Task { [weak self, store] in
            do {
                // Let the cached list and first interaction win disk bandwidth. This check is
                // important, but it is not part of the launch critical path.
                try await Task.sleep(for: .seconds(2))
                try await store.verifyIntegrity()
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.storedSession?.session.accountId == accountId,
                      let currentStore = self.localStore,
                      currentStore === store
                else { return }
                self.postSignInTask?.cancel()
                self.postSyncWorkTask?.cancel()
                await self.replicaSyncCoordinator.invalidate()
                self.historyHydrationTask?.cancel()
                self.mediaDownloadTask?.cancel()
                self.dialogObservationTask?.cancel()
                self.timelineObservationTask?.cancel()
                await self.hintSocket?.stop()
                self.hintSocket = nil
                await BackgroundRuntimeCoordinator.shared.removeWorkHandlersAndWait()
                self.setReplicaSyncState(.localFailure)
                self.launchPhase = .recoveringStore
                self.status = "Local store integrity check failed; cached files were preserved for recovery"
            }
        }
    }

    func activateForegroundServices() async {
        mediaSchedulerForegrounded = true
        await mediaPrefetchScheduler.update(
            networkClass: ReplicaNetworkMonitor.shared.snapshot().networkClass,
            foregrounded: true
        )
        guard launchPhase == .localReady, storedSession != nil else { return }
        #if DEBUG
        if TelegramFastUITestFixture.enabled {
            // The fixture token is deliberately non-routable. Keep deterministic UI scenarios
            // behind the same online-service boundary as before credential refresh was added, or
            // its expected presence state is immediately replaced by a transport failure.
            await startOnlineServices()
            return
        }
        #endif
        await prepareCurrentCredentials()
        guard launchPhase == .localReady, storedSession != nil else { return }
        startCredentialRefreshLoopIfNeeded()
        guard postSignInTask == nil else { return }
        postSignInTask = Task { [weak self] in
            guard let self else { return }
            await self.startOnlineServices()
            self.postSignInTask = nil
        }
    }

    private func startCredentialRefreshLoopIfNeeded() {
        guard credentialRefreshLoopTask == nil else { return }
        credentialRefreshLoopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self.prepareCurrentCredentials()
            }
        }
    }

    private func prepareCurrentCredentials() async {
        guard let saved = storedSession, !sessionTeardownActive else { return }
        do {
            if saved.session.tokenVersion < 2 {
                let capabilities = try await api.capabilities(token: saved.session.token)
                guard capabilities.capabilities.contains("auth_sessions_v2") else { return }
                let upgraded = try await api.upgradeSession(token: saved.session.token)
                let installed = await applySecuritySession(upgraded, replacing: saved)
                if !installed, storedSession == nil {
                    status = "Session upgraded. Sign in again to resume your saved chats."
                }
            } else {
                _ = try await SessionCredentialCoordinator.shared.refreshIfNeeded(
                    matching: saved.session.token
                )
            }
        } catch let error as CloudAPIError {
            switch error.code {
            case "session_expired":
                await pauseForExpiredSession(saved)
            case "device_revoked", "refresh_reuse_detected":
                await clearLocalSession(finalStatus: "Session ended for security")
            default:
                publishTransportFailure(error)
            }
        } catch {
            publishTransportFailure(error)
        }
    }

    private func pauseForExpiredSession(_ saved: StoredCloudSession) async {
        guard storedSession?.session.deviceId == saved.session.deviceId else { return }
        expiredSessionAccountId = saved.session.accountId
        // Save the local-replica identity before removing the expired credential. If Keychain is
        // unavailable, retain the old session item as a conservative identity fallback on launch.
        let reauthenticationMarkerSaved: Bool
        do {
            try await tokenStore.savePendingReauthentication(accountId: saved.session.accountId)
            reauthenticationMarkerSaved = true
        } catch {
            reauthenticationMarkerSaved = false
        }
        accountSessionGeneration &+= 1
        savedMessagesSessionGeneration &+= 1
        let cloudTasks: [Task<Void, Never>] = [
            postSignInTask, postSyncWorkTask, historyHydrationTask, mediaDownloadTask,
            readReceiptRetryTask, retryTask, resendTask, profileSyncTask,
            composerMediaTask,
        ].compactMap { $0 }
        let transfers = Array(mediaTransferTasks.values)
        let preferences = Array(preferenceMutationTasks.values)
        cloudTasks.forEach { $0.cancel() }
        transfers.forEach { $0.cancel() }
        preferences.forEach { $0.cancel() }
        credentialRefreshLoopTask?.cancel()
        credentialRefreshLoopTask = nil
        hintTask?.cancel()
        hintTask = nil
        storedSession = nil
        await draftSyncCoordinator.suspendRetries()
        await dialogPreferencesCoordinator.cancelAndWait()
        await hintSocket?.stop()
        hintSocket = nil
        await replicaSyncCoordinator.stop()
        await mediaPrefetchScheduler.stop()
        await BackgroundRuntimeCoordinator.shared.removeWorkHandlersAndWait()
        for task in cloudTasks { await task.value }
        for task in transfers { await task.value }
        for task in preferences { await task.value }
        postSignInTask = nil
        postSyncWorkTask = nil
        historyHydrationTask = nil
        mediaDownloadTask = nil
        readReceiptRetryTask = nil
        retryTask = nil
        resendTask = nil
        profileSyncTask = nil
        composerMediaTask = nil
        mediaTransferTasks.removeAll()
        mediaTransferDialogIds.removeAll()
        preferenceMutationTasks.removeAll()
        await SessionCredentialCoordinator.shared.clear()
        if reauthenticationMarkerSaved {
            try? await tokenStore.clearSession(ifTokenMatches: saved.session.token)
        }
        launchPhase = .localReady
        setReplicaSyncState(.sessionExpired)
        status = "Session expired. Sign in again to resume your saved chats."
    }

    func setForegroundActive(_ isActive: Bool) async {
        await presenceCoordinator.setForegroundActive(isActive)
        mediaSchedulerForegrounded = isActive
        await mediaPrefetchScheduler.update(
            networkClass: ReplicaNetworkMonitor.shared.snapshot().networkClass,
            foregrounded: isActive
        )
        if isActive {
            await draftSyncCoordinator.resumeRetries()
            scheduleMediaDownloadProcessing()
        } else {
            for task in Array(draftPersistenceTasks.values) {
                await task.value
            }
            await draftSyncCoordinator.flushAll(reason: .background)
        }
    }

    private func prepareBackgroundMediaRuntime() async {
        guard
            !backgroundMediaRuntimePrepared,
            launchPhase == .localReady,
            storedSession != nil,
            let localStore
        else { return }
        backgroundMediaRuntimePrepared = true
        do {
            try await mediaEngine.warmCache(localStore: localStore)
        } catch {
            // Media is evictable and must never block the encrypted text replica. Leave this false
            // so the foreground activation or a later background wake can retry initialization.
            backgroundMediaRuntimePrepared = false
        }
    }

    private func ensureLocalStore() async throws -> CloudLocalStore? {
        if let localStore { return localStore }
        guard opensDefaultLocalStore else { return nil }
        let interval = LocalFirstMetrics.begin("Database open")
        defer { LocalFirstMetrics.end("Database open", interval) }
        let store = try await localStoreBootstrapper.openDefaultStore()
        localStore = store
        return store
    }

    private func startOnlineServices() async {
        guard launchPhase == .localReady, storedSession != nil else { return }
        #if DEBUG
        if TelegramFastUITestFixture.enabled {
            if TelegramFastUITestFixture.presenceScenario == nil {
                setReplicaSyncState(.offline)
                status = "Offline fixture — showing saved chats"
            }
            return
        }
        #endif
        await resume()
        // Registration can prompt, so connection checking must already be in flight. Everything
        // that can compete with opening a cached chat is deferred until the difference pass wins.
        await pushCenter.requestAuthorization()
    }

    #if DEBUG
    private func installTelegramFastUITestFixture() async throws {
        if TelegramFastUITestFixture.resetsStorage {
            try? await tokenStore.clear()
            try TelegramFastUITestFixture.reset()
        }
        let fixtureSession = TelegramFastUITestFixture.session
        // The deterministic fixture is reinstalled on every UI-test process launch. Avoid a
        // Keychain dependency so unsigned simulator verification can exercise the encrypted
        // replica and presentation without failing on errSecMissingEntitlement.
        isSessionTeardownInProgress = false
        installAuthenticatedSession(fixtureSession)
        phone = fixtureSession.phone
        displayName = fixtureSession.displayName
        profileDetails = StoredProfileDetails(
            firstName: "UI",
            lastName: "Fixture",
            bio: "Encrypted offline test profile",
            birthday: nil,
            colorIndex: 3
        )
        negotiatedCapabilities = .demo
        guard let store = try await ensureLocalStore() else {
            throw CloudAppModelError.localStoreUnavailable
        }
        try await TelegramFastUITestFixture.install(into: store)
        await afterSignIn()
        if let scenario = TelegramFastUITestFixture.presenceScenario {
            if scenario == "unsupported" {
                negotiatedCapabilities.remove(.presence)
                await presenceCoordinator.configure(
                    store: store, session: fixtureSession.session, enabled: false
                )
            } else {
                await presenceCoordinator.configure(
                    store: store, session: fixtureSession.session, enabled: true
                )
                presenceCoordinator.enableFixturesForTesting()
                await presenceCoordinator.handle(PresenceUpdateHint(
                    type: "presence_update",
                    accountId: TelegramFastUITestFixture.peerAccountId,
                    online: true,
                    lastSeenAt: nil,
                    revision: 1
                ))
                if scenario == "typing" {
                    // Keep the deterministic fixture alive across slow hosted UI automation.
                    // Production typing leases still use the short server-provided expiry.
                    presenceCoordinator.handle(TypingUpdateHint(
                        type: "typing_update",
                        dialogId: TelegramFastUITestFixture.primaryDialogId,
                        actorAccountId: TelegramFastUITestFixture.peerAccountId,
                        typingSessionId: "00000000-0000-4000-8000-000000000701",
                        active: true,
                        expiresInMs: 30_000
                    ))
                }
            }
            if scenario == "offline_override" {
                setReplicaSyncState(.offline)
                status = "Offline fixture — showing saved chats"
            } else {
                setReplicaSyncState(.ready)
                status = "Ready"
            }
        } else {
            setReplicaSyncState(.offline)
            status = "Offline fixture — showing saved chats"
        }
    }
    #endif

    private func installBackgroundWorkHandlers() {
        BackgroundRuntimeCoordinator.shared.installWorkHandlers(
            appRefresh: { [weak self] context in
                guard let self else { return .noData }
                do {
                    try context.checkCancellation()
                    let previousPts = await self.pts
                    await self.runCoordinatedSync(trigger: .background)
                    try context.checkCancellation()
                    await self.retryPendingOutbox()
                    try context.checkCancellation()
                    await self.retryPendingDialogPreferences()
                    try context.checkCancellation()
                    await self.retryPendingMessageMutations()
                    try context.checkCancellation()
                    await self.retryPendingReadReceipts()
                    return await self.pts > previousPts ? .completed : .noData
                } catch {
                    return .retry
                }
            },
            processing: { [weak self] context in
                guard let self else { return .noData }
                do {
                    try context.checkCancellation()
                    await self.runCoordinatedSync(trigger: .background)
                    try context.checkCancellation()
                    await self.resumeHistoryHydration()
                    try context.checkCancellation()
                    await self.retryPendingDialogPreferences()
                    try context.checkCancellation()
                    await self.retryPendingReadReceipts()
                    try context.checkCancellation()
                    await self.processMediaDownloadJobs(maximumJobs: 12)
                    try context.checkCancellation()
                    if let coordinator = await self.searchCoordinator {
                        await coordinator.runScheduledMaintenance()
                    }
                    try context.checkCancellation()
                    if let localStore = await self.localStore {
                        await self.mediaEngine.enforceCachePolicy(localStore: localStore)
                    } else {
                        await self.mediaEngine.enforceCachePolicy()
                    }
                    try context.checkCancellation()
                    await self.refreshMediaCacheUsage()
                    return .completed
                } catch {
                    return .retry
                }
            },
            // Search maintenance is local and useful offline. Network-backed work already checks
            // connectivity and remains resumable, so the shared processing task need not require a
            // network before iOS will launch it.
            processingRequiresNetworkConnectivity: false
        )
        BackgroundRuntimeCoordinator.shared.schedulePendingWork()
    }

    private func startDialogObservation(accountId: String) {
        dialogObservationTask?.cancel()
        guard let localStore else { return }
        dialogObservationTask = Task { [weak self, localStore] in
            do {
                let values = await localStore.observeDialogs(accountId: accountId)
                for try await localDialogs in values {
                    try Task.checkCancellation()
                    guard let self, self.storedSession?.session.accountId == accountId else { return }
                    self.acceptObservedDialogs(localDialogs)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.storedSession?.session.accountId == accountId else { return }
                self.status = "Dialog observation paused: \(error.localizedDescription)"
            }
        }
    }

    private func startTimelineObservation(dialogId: String) {
        timelineObservationTask?.cancel()
        guard let localStore else {
            conversationOpenState = .failedLocal
            conversationOpenStartedAt.removeValue(forKey: dialogId)
            finishConversationOpenWaiters(dialogId: dialogId)
            return
        }
        timelineObservationTask = Task { [weak self, localStore] in
            do {
                let values = await localStore.observeConversation(dialogId: dialogId, window: .initial)
                for try await snapshot in values {
                    try Task.checkCancellation()
                    guard let self, self.activeDialogId == dialogId else { return }
                    await self.loadLocalLines(dialogId: dialogId, observedSnapshot: snapshot)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.activeDialogId == dialogId else { return }
                self.conversationOpenState = .failedLocal
                self.status = "Timeline observation paused: \(error.localizedDescription)"
                self.conversationOpenStartedAt.removeValue(forKey: dialogId)
                self.finishConversationOpenWaiters(dialogId: dialogId)
            }
        }
    }

    private func startMemoryPressureObservation() {
        guard memoryPressureTask == nil else { return }
        memoryPressureTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didReceiveMemoryWarningNotification
            ) {
                guard let self, !Task.isCancelled else { return }
                self.purgePreparedConversations()
                MediaPresentationCache.shared.removeAll()
            }
        }
    }

    private func acceptObservedDialogs(_ localDialogs: [LocalDialog]) {
        let previous = Dictionary(uniqueKeysWithValues: dialogs.map { ($0.id, $0) })
        dialogs = localDialogs.map { local in
            var resolved = dialog(from: local)
            let trimmedDraft = local.draftText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedDraft.isEmpty {
                resolved.draftPreview = trimmedDraft
            } else if local.draftAttachmentCount > 0 {
                resolved.draftPreview = String(
                    localized: "\(local.draftAttachmentCount) attachments"
                )
            } else if local.hasDraftReply {
                resolved.draftPreview = String(localized: "Reply draft")
            }
            return resolved
        }
        savedMessagesDialogId = localDialogs.first(where: { $0.type == "saved" })?.dialogId
        let directPeers = dialogs.compactMap { dialog in
            dialog.type == "direct" ? dialog.peerAccountId : nil
        }
        Task { [weak self] in
            await self?.presenceCoordinator.updateDirectPeers(directPeers)
        }
        sortDialogsForPresentation()
        if let activeDialogId,
           let removedType = previous[activeDialogId]?.type,
           removedType == "group" || removedType == "saved",
           !dialogs.contains(where: { $0.id == activeDialogId }) {
            self.activeDialogId = nil
            lines = []
            presentNotice(
                removedType == "saved"
                    ? String(localized: "Saved Messages access ended")
                    : String(localized: "Group access ended"),
                message: removedType == "saved"
                    ? String(localized: "The unauthorized Saved Messages offline copy was removed.")
                    : String(localized: "You are no longer a member of this group. Its offline copy was removed.")
            )
        }
    }

    func updateTimelineViewport(
        dialogId: String,
        visibleLineIds: [String],
        isAtBottom: Bool
    ) {
        guard activeDialogId == dialogId else { return }
        let visibleIds = Set(visibleLineIds)
        let topVisibleMsgId = lines.first(where: { visibleIds.contains($0.id) })?.msgId
        timelineTopVisibleMsgId = isAtBottom ? nil : topVisibleMsgId
        timelineIsAtBottom = isAtBottom

        let visibleMessages = loadedLocalMessages.filter { visibleIds.contains($0.localId) }
        pendingVisibleReadMessages = visibleMessages
        let visibleMedia = visibleMessages.compactMap(\.media)
        if !visibleMedia.isEmpty {
            Task { [weak self] in
                guard let self, self.activeDialogId == dialogId else { return }
                await self.queueMediaDownloads(visibleMedia, dialogId: dialogId, visible: true)
                for media in visibleMedia where media.kind == "video" {
                    await self.prewarmStreamingVideoAssetIfLocal(for: media)
                }
            }
        }
        viewportPersistenceTask?.cancel()
        viewportPersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self,
                  self.activeDialogId == dialogId,
                  let accountId = self.storedSession?.session.accountId,
                  let localStore = self.localStore else { return }
            let state = ChatViewportState(
                dialogId: dialogId,
                accountId: accountId,
                topVisibleMsgId: topVisibleMsgId,
                wasAtBottom: isAtBottom
            )
            try? await localStore.saveViewportState(state)
            await self.markReadIfNeeded(dialogId: dialogId, messages: visibleMessages)
        }
    }

    private func resumeHistoryHydration() async {
        if let historyHydrationTask {
            await withTaskCancellationHandler {
                await historyHydrationTask.value
            } onCancel: {
                historyHydrationTask.cancel()
            }
            return
        }
        guard let token = storedSession?.session.token, localStore != nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.hydrateHistoryPages(token: token)
        }
        historyHydrationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        historyHydrationTask = nil
    }

    private func hydrateHistoryPages(token: String) async {
        let interval = LocalFirstMetrics.begin("History hydration")
        defer { LocalFirstMetrics.end("History hydration", interval) }
        guard let localStore else { return }
        var pagesSinceYield = 0

        while !Task.isCancelled, storedSession?.session.token == token {
            let activeId = activeDialogId
            let unreadIds = Set(dialogs.lazy.filter { $0.unreadCount > 0 }.map(\.id))
            var priorityIds: [String] = []
            if let activeId { priorityIds.append(activeId) }
            priorityIds.append(contentsOf: dialogs.lazy.filter { $0.unreadCount > 0 }.prefix(199).map(\.id))
            let ready: [DialogHistoryState]
            do {
                let general = try await localStore.historyStatesReady(limit: 100)
                let priority = try await localStore.historyStatesReady(dialogIds: priorityIds)
                ready = Array(Dictionary(
                    (general + priority).map { ($0.dialogId, $0) },
                    uniquingKeysWith: { _, newer in newer }
                ).values)
            } catch {
                return
            }
            guard !ready.isEmpty else { return }

            let network = ReplicaNetworkMonitor.shared.snapshot()
            guard network.allowsEssentialSync else { return }
            let recency = Dictionary(uniqueKeysWithValues: dialogs.enumerated().map { ($0.element.id, $0.offset) })
            let eligible = network.allowsDiscretionaryHydration
                ? ready
                : ready.filter { $0.dialogId == activeId || unreadIds.contains($0.dialogId) }
            if eligible.isEmpty {
                BackgroundRuntimeCoordinator.shared.scheduleProcessing()
                return
            }
            let prioritized = eligible.sorted { lhs, rhs in
                let lhsTier = lhs.dialogId == activeId ? 0 : (unreadIds.contains(lhs.dialogId) ? 1 : 2)
                let rhsTier = rhs.dialogId == activeId ? 0 : (unreadIds.contains(rhs.dialogId) ? 1 : 2)
                if lhsTier != rhsTier { return lhsTier < rhsTier }
                return (recency[lhs.dialogId] ?? .max) < (recency[rhs.dialogId] ?? .max)
            }

            var madeProgress = false
            for state in prioritized {
                if Task.isCancelled || storedSession?.session.token != token { return }
                let beforeMsgId = state.nextBeforeMsgId ?? max(1, state.ceilingMsgId + 1)
                do {
                    let page = try await api.getHistory(
                        dialogId: state.dialogId,
                        beforeMsgId: beforeMsgId,
                        limit: 100,
                        token: token
                    )
                    try await localStore.applyHistoryPage(page)
                    await enqueueArrivalMediaDownloads(page.messages, recentOnly: true)
                    pagesSinceYield += 1
                    madeProgress = true
                } catch is CancellationError {
                    return
                } catch {
                    let delay = retryDelay(forRetryCount: state.retryCount + 1)
                    try? await localStore.markHistoryHydrationFailed(
                        dialogId: state.dialogId,
                        retryAfter: delay
                    )
                    BackgroundRuntimeCoordinator.shared.scheduleProcessing()
                    BackgroundRuntimeCoordinator.shared.scheduleAppRefresh(
                        earliestBeginDate: Date(timeIntervalSinceNow: delay)
                    )
                    if case .authenticationRequired = cloudFailureDisposition(error) { return }
                }
            }
            if !madeProgress { break }
            // Keep long backfills cooperative without imposing a global page cap. The persisted
            // cursor makes every yield/termination resumable.
            if pagesSinceYield >= 24 {
                pagesSinceYield = 0
                await Task.yield()
            }
        }

        if !Task.isCancelled,
           (try? await localStore.historyStatesReady(limit: 1).isEmpty) == false {
            BackgroundRuntimeCoordinator.shared.scheduleProcessing()
        }
    }

    private func refreshServerCapabilities() async {
        guard !isSessionTeardownInProgress else { return }
        let accountId = storedSession?.session.accountId
        let token = storedSession?.session.token
        let savedGeneration = savedMessagesSessionGeneration
        let generation = accountSessionGeneration
        let previouslyHadCloudDrafts = negotiatedCapabilities.contains(.cloudDrafts)
        do {
            let response = try await api.capabilities(token: token)
            guard
                !Task.isCancelled,
                savedMessagesSessionGeneration == savedGeneration,
                generation == accountSessionGeneration,
                accountId == storedSession?.session.accountId,
                token == storedSession?.session.token
            else { return }
            var resolved: MessagingCapabilities = []
            let advertised = Set(response.capabilities)
            if advertised.contains("core_text") || advertised.contains("replies") {
                resolved.insert(.replies)
            }
            if advertised.contains("message_mutations") {
                resolved.formUnion([.editing, .deletion])
            }
            if advertised.contains("reactions") { resolved.insert(.reactions) }
            if advertised.contains("forwarding") { resolved.insert(.forwarding) }
            if advertised.contains("media_uploads") { resolved.insert(.media) }
            if advertised.contains("media_multipart_v2"), resolved.contains(.media) {
                resolved.insert(.multipartMedia)
            }
            if advertised.contains("voice_notes"), resolved.contains(.media) {
                resolved.insert(.voiceNotes)
            }
            if advertised.contains("profiles") { resolved.insert(.profiles) }
            if advertised.contains("groups_v1") { resolved.insert(.groups) }
            savedMessagesCapabilityState = .advertised(in: advertised)
            if savedMessagesCapabilityState == .supported {
                resolved.insert(.savedMessages)
            }
            if advertised.contains("cloud_drafts_v1") { resolved.insert(.cloudDrafts) }
            if advertised.contains("media_groups_v1"), resolved.contains(.media) {
                resolved.insert(.mediaGroups)
            }
            if advertised.contains("dialog_preferences_v1") {
                resolved.formUnion([.chatOrganization, .dialogPreferences])
            }
            if advertised.contains("chat_folders_v1") { resolved.insert(.chatFolders) }
            if advertised.contains("scheduled_delivery_v1") { resolved.insert(.scheduledDelivery) }
            if advertised.contains("link_previews_v1") { resolved.insert(.linkPreviews) }
            if advertised.contains("abuse_reports_v1") { resolved.insert(.abuseReports) }
            if advertised.contains("voice_calls_v1"), WebRTCEngineFactory.isAvailable {
                resolved.insert(.calls)
            }
            if advertised.contains("video_calls_v1"), WebRTCEngineFactory.supportsCameraVideoProfile {
                resolved.insert(.videoCalls)
            }
            if advertised.contains("group_calls_v1"), GroupCallEngineFactory.isAvailable {
                resolved.insert(.groupCalls)
            }
            if advertised.contains("group_video_calls_v1"), resolved.contains(.groupCalls) {
                resolved.insert(.groupVideoCalls)
            }
            if advertised.contains("screen_sharing_v1"),
               resolved.contains(.groupCalls),
               GroupCallEngineFactory.supportsScreenShare {
                resolved.insert(.screenSharing)
            }
            if advertised.contains("presence_v1") { resolved.insert(.presence) }
            if advertised.contains("profile_photos_v1"), resolved.contains(.media) {
                resolved.insert(.profilePhotos)
            }
            negotiatedCapabilities = resolved
            await profilePhotoSyncCoordinator.configure(
                store: localStore,
                session: storedSession?.session,
                enabled: resolved.contains(.profilePhotos)
            )
            await presenceCoordinator.configure(
                store: localStore,
                session: storedSession?.session,
                enabled: resolved.contains(.presence)
            )
            await draftSyncCoordinator.configure(
                store: localStore,
                session: storedSession?.session,
                cloudEnabled: resolved.contains(.cloudDrafts)
            )
            if !previouslyHadCloudDrafts,
               resolved.contains(.cloudDrafts),
               let token = storedSession?.session.token {
                // Difference deliberately advances across killed draft events without payloads.
                // A replacement bootstrap is therefore required to recover the current shadows.
                Task { [weak self] in
                    guard let self else { return }
                    try? await self.rebuildLocalReplica(token: token)
                    self.scheduleOutboxRetry()
                }
            }
            // Account-scoped rollout bits must not leak between sign-ins through the server-wide
            // capability cache. A locally materialized Saved Messages row still opens offline.
            capabilityDefaults.set(
                Int(resolved.subtracting([
                    .videoCalls, .savedMessages, .chatFolders, .scheduledDelivery, .linkPreviews,
                    .abuseReports,
                    .presence, .profilePhotos,
                ]).rawValue),
                forKey: capabilityCacheKey
            )
            if resolved.contains(.savedMessages) {
                _ = await ensureSavedMessages(presentsFailure: false)
            }
            await refreshCloudProductivity()
            if let localStore, let accountId = storedSession?.session.accountId {
                if resolved.contains(.chatOrganization) {
                    let reactivated = (try? await localStore
                        .reactivateDormantDialogPreferences(accountId: accountId)) ?? 0
                    guard
                        !Task.isCancelled,
                        !isSessionTeardownInProgress,
                        generation == accountSessionGeneration,
                        accountId == storedSession?.session.accountId
                    else { return }
                    if reactivated > 0 {
                        await retryPendingDialogPreferences()
                    }
                } else if resolved.contains(.groups) {
                    let moved = (try? await localStore.movePendingGroupMutesToLegacy(
                        accountId: accountId
                    )) ?? 0
                    guard
                        !Task.isCancelled,
                        !isSessionTeardownInProgress,
                        generation == accountSessionGeneration,
                        accountId == storedSession?.session.accountId
                    else { return }
                    if moved > 0 {
                        await retryPendingGroupMutations()
                    }
                }
            }
        } catch let error as CloudAPIError where error.status == 404 {
            guard
                !Task.isCancelled,
                savedMessagesSessionGeneration == savedGeneration,
                generation == accountSessionGeneration,
                accountId == storedSession?.session.accountId,
                token == storedSession?.session.token
            else { return }
            negotiatedCapabilities = [.replies]
            savedMessagesCapabilityState = .unsupported
            await draftSyncCoordinator.configure(
                store: localStore,
                session: storedSession?.session,
                cloudEnabled: false
            )
            await presenceCoordinator.configure(
                store: localStore,
                session: storedSession?.session,
                enabled: false
            )
            await profilePhotoSyncCoordinator.configure(
                store: localStore,
                session: storedSession?.session,
                enabled: false
            )
            capabilityDefaults.set(Int(MessagingCapabilities.replies.rawValue), forKey: capabilityCacheKey)
        } catch {
            // Keep the last successfully negotiated set when the server cannot be reached.
        }
    }

    private func acceptDraftFlushResult(
        _ result: DraftSyncCoordinator.FlushResult
    ) async -> Bool {
        switch result {
        case .synced:
            return true
        case .unsupported:
            // Withdraw the lane in the same main-actor turn. Durable dependencies remain queued
            // and excluded from retry timing until a later capability refresh re-enables them.
            negotiatedCapabilities.remove(.cloudDrafts)
            await draftSyncCoordinator.configure(
                store: localStore,
                session: storedSession?.session,
                cloudEnabled: false
            )
            Task { [weak self] in await self?.refreshServerCapabilities() }
            return false
        case .retryable, .suspended:
            return false
        case .terminal:
            return false
        }
    }

    private func setReplicaSyncState(_ state: ReplicaSyncState) {
        replicaSyncState = state
        switch state {
        case .checking:
            replicaConnectivityState = .checking
            replicaUpdatePhase = .checkingRemoteState
            connectionViewState = .connecting
        case .updating:
            replicaConnectivityState = .reachable
            replicaUpdatePhase = .catchingUp(appliedBatches: appliedSyncBatches)
            connectionViewState = .connecting
        case .ready:
            replicaConnectivityState = .reachable
            replicaUpdatePhase = .upToDate
            connectionViewState = .live
        case .offline:
            replicaConnectivityState = .offline
            replicaUpdatePhase = .idle
            connectionViewState = .offline
        case .connectionSlow:
            replicaConnectivityState = .checking
            replicaUpdatePhase = .stalled(reason: .slowConnection)
            connectionViewState = .connecting
        case .serverUnavailable:
            replicaConnectivityState = .serverUnavailable
            replicaUpdatePhase = .stalled(reason: .serverUnavailable)
            connectionViewState = .connecting
        case .sessionExpired:
            replicaConnectivityState = .sessionExpired
            replicaUpdatePhase = .idle
            connectionViewState = .connecting
        case .protocolFailure:
            replicaConnectivityState = .reachable
            replicaUpdatePhase = .stalled(reason: .protocolFailure)
            connectionViewState = .connecting
        case .localFailure:
            replicaUpdatePhase = .stalled(reason: .localReplicaFailure)
            connectionViewState = .connecting
        case .configurationError:
            replicaConnectivityState = .configurationError
            replicaUpdatePhase = .stalled(reason: .configuration)
            connectionViewState = .connecting
        }
    }

    private func startNetworkObservation() {
        networkObservationTask?.cancel()
        networkObservationTask = Task { [weak self] in
            var previous = ReplicaNetworkClass.unknown
            for await snapshot in ReplicaNetworkMonitor.shared.updates() {
                guard let self, !Task.isCancelled else { return }
                await self.mediaPrefetchScheduler.update(
                    networkClass: snapshot.networkClass,
                    foregrounded: self.mediaSchedulerForegrounded
                )
                let recovered = previous == .offline && snapshot.networkClass != .offline
                previous = snapshot.networkClass
                if snapshot.networkClass == .offline {
                    self.scheduleOfflineStatePaint()
                    continue
                }
                self.cancelOfflineStatePaint()
                guard recovered else { continue }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled,
                      ReplicaNetworkMonitor.shared.snapshot().networkClass != .offline else { continue }
                await self.replicaSyncCoordinator.trigger(.pathRecovery)
                self.scheduleMediaDownloadProcessing()
                await self.resumeHistoryHydration()
            }
        }
    }

    /// Interface handoffs (Wi-Fi ↔ cellular) report sub-second unsatisfied paths. Painting the
    /// offline banner is debounced so only a real outage is announced; sync and media gating read
    /// live snapshots and are unaffected by the delay.
    private func scheduleOfflineStatePaint() {
        guard offlinePaintTask == nil else { return }
        offlinePaintTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled else { return }
            self.offlinePaintTask = nil
            guard ReplicaNetworkMonitor.shared.snapshot().networkClass == .offline else { return }
            self.setReplicaSyncState(.offline)
            self.status = String(localized: "Offline. Showing downloaded conversations.")
        }
    }

    private func cancelOfflineStatePaint() {
        offlinePaintTask?.cancel()
        offlinePaintTask = nil
    }

    nonisolated static func replicaFailureState(
        for error: Error,
        network: ReplicaNetworkSnapshot
    ) -> ReplicaSyncState {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return .checking
        }
        if network.networkClass == .offline { return .offline }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
                return .offline
            case .timedOut:
                return .connectionSlow
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .networkConnectionLost, .badServerResponse:
                return .serverUnavailable
            default:
                return .serverUnavailable
            }
        }
        if let apiError = error as? CloudAPIError {
            switch apiError.status {
            case 401, 403: return .sessionExpired
            case 408, 429, 500...599: return .serverUnavailable
            default: return .protocolFailure
            }
        }
        if error is DecodingError { return .protocolFailure }
        return .localFailure
    }

    private func publishTransportFailure(_ error: Error) {
        let failure = Self.replicaFailureState(
            for: error,
            network: ReplicaNetworkMonitor.shared.snapshot()
        )
        switch failure {
        case .offline, .connectionSlow, .serverUnavailable, .sessionExpired:
            setReplicaSyncState(failure)
        case .checking, .updating, .ready, .protocolFailure, .localFailure, .configurationError:
            break
        }
    }

    private func presentNotice(_ title: String, message: String, opensSettings: Bool = false) {
        if let pending = pendingProductivityTerminalNotice,
           operationNotice?.id == pending.noticeId {
            // A higher-priority notice may replace this alert, but the journal error stays
            // unacknowledged and will be offered again by the next productivity drain.
            pendingProductivityTerminalNotice = nil
        }
        operationNotice = Notice(title: title, message: message, opensSettings: opensSettings)
    }

    private func uploadPushToken(_ deviceToken: String, environment: String) async {
        guard let token = storedSession?.session.token else { return }
        let registration = "\(environment):\(deviceToken)"
        guard uploadedPushRegistration != registration else { return }
        do {
            _ = try await api.registerPushToken(deviceToken, environment: environment, token: token)
            guard storedSession?.session.token == token else {
                // Registration and sign-out can overlap at an await point. If sign-out won the
                // race, undo this late registration so the signed-out device receives no alerts.
                _ = try? await api.unregisterPushToken(token: token)
                return
            }
            uploadedPushRegistration = registration
        } catch {
            // Token registration is retried when APNs rotates the token or on the next app launch.
            status = "Push registration failed: \(error.localizedDescription)"
        }
    }

    private func uploadVoIPPushToken(_ deviceToken: String?, environment: String) async {
        guard let token = storedSession?.session.token else { return }
        guard let deviceToken, callCoordinator.canRegisterForIncomingCalls else {
            // Token rotation and permission changes can race the normal resume path. Always clear
            // the server registration when this installation cannot answer; otherwise a later
            // PushKit callback could silently make a microphone-denied device callable again.
            _ = try? await api.unregisterVoIPPushToken(token: token)
            uploadedVoIPPushRegistration = nil
            return
        }
        let capabilities = WebRTCEngineFactory.deviceCapabilities
        let groupCapabilities = GroupCallEngineFactory.deviceCapabilities
        let registration = [
            environment,
            deviceToken,
            capabilities.supportedCallProtocolVersions.map(String.init).joined(separator: ","),
            capabilities.supportedCallMediaProfileVersions.map(String.init).joined(separator: ","),
            String(capabilities.callViewVersion),
            groupCapabilities.supportedGroupCallVersions.map(String.init).joined(separator: ","),
            String(groupCapabilities.groupCallViewVersion),
            String(groupCapabilities.supportsGroupScreenShare),
        ].joined(separator: ":")
        guard uploadedVoIPPushRegistration != registration else { return }
        do {
            _ = try await api.registerVoIPPushToken(
                deviceToken,
                environment: environment,
                token: token,
                capabilities: capabilities,
                groupCapabilities: groupCapabilities
            )
            guard storedSession?.session.token == token,
                  callCoordinator.canRegisterForIncomingCalls else {
                _ = try? await api.unregisterVoIPPushToken(token: token)
                uploadedVoIPPushRegistration = nil
                return
            }
            uploadedVoIPPushRegistration = registration
        } catch {
            status = "Call push registration failed: \(error.localizedDescription)"
        }
    }

    private func syncGroupCallCapabilities() async {
        guard let token = storedSession?.session.token else { return }
        let capabilities = GroupCallEngineFactory.deviceCapabilities
        let registration = [
            capabilities.supportedGroupCallVersions.map(String.init).joined(separator: ","),
            String(capabilities.groupCallViewVersion),
            String(capabilities.supportsGroupScreenShare),
        ].joined(separator: ":")
        guard uploadedGroupCallCapabilityRegistration != registration else { return }
        do {
            _ = try await api.registerGroupCallCapabilities(capabilities, token: token)
            guard storedSession?.session.token == token else { return }
            uploadedGroupCallCapabilityRegistration = registration
        } catch {
            // Capability registration is retried on foreground and post-sync. Until then the
            // backend treats this device as legacy and will not admit it to a group media room.
            status = "Group call registration failed: \(error.localizedDescription)"
        }
    }

    private func syncFromPush() async -> Bool {
        let previousPts = pts
        await runCoordinatedSync(trigger: .push)
        return pts > previousPts
    }

    func resume() async {
        #if DEBUG
        if isDemoMode { return }
        #endif
        guard let token = storedSession?.session.token else { return }
        setReplicaSyncState(.checking)
        status = "Checking connection"
        pushCenter.refreshRegistration()
        await syncGroupCallCapabilities()
        if capabilities.contains(.calls) {
            await syncVoIPCallingAvailability()
        }
        await startHints(token: token)
        scheduleSync(trigger: .foreground)
        scheduleOutboxRetry()
    }

    func retryReplicaSync() {
        #if DEBUG
        if isDemoMode { return }
        #endif
        guard launchPhase == .localReady, storedSession?.session.token != nil else { return }
        setReplicaSyncState(.checking)
        status = "Checking connection"
        scheduleSync(trigger: .manualRetry)
    }

    private func syncVoIPCallingAvailability() async {
        guard let token = storedSession?.session.token else { return }
        if callCoordinator.canRegisterForIncomingCalls {
            voipPushCenter.refreshRegistration()
        } else {
            _ = try? await api.unregisterVoIPPushToken(token: token)
            uploadedVoIPPushRegistration = nil
        }
    }

    private func startHints(token: String) async {
        // The socket is long-lived: it survives sync passes and reconnects itself with jittered
        // backoff. Only a token change (or an explicit stop) replaces it — cycling it on every
        // sync pass would burn round-trips and drop hints raised during each teardown window.
        if hintSocketToken == token, hintSocket != nil, hintTask?.isCancelled == false { return }
        hintTask?.cancel()
        await hintSocket?.stop()

        let socket = CloudHintSocket(url: api.config.wsURL(), token: token)
        hintSocket = socket
        hintSocketToken = token
        await presenceCoordinator.attach(socket: socket)
        hintTask = Task { [weak self, socket] in
            await socket.start()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self, socket] in
                    for await event in socket.events {
                        guard let self,
                              !Task.isCancelled,
                              await self.isCurrentHintSocket(socket, token: token)
                        else { return }
                        switch event {
                        case .sync(let hint):
                            // The payload carries the account cursor; skip the probe entirely when
                            // the local replica is already at (or past) it.
                            let localPts = await self.pts
                            guard hint.pts > localPts else { continue }
                            await self.replicaSyncCoordinator.trigger(.hint)
                        case .call(let hint):
                            await self.callCoordinator.handle(hint)
                        case .groupCall(let hint):
                            await self.groupCallCoordinator.handle(hint)
                        case .sessionRevoked:
                            // Routed through the dedicated lossless control stream below.
                            continue
                        case .presence(let hint):
                            await self.presenceCoordinator.handle(hint)
                        case .presenceVisibility(let hint):
                            await self.presenceCoordinator.handle(hint)
                        case .typing(let hint):
                            await self.presenceCoordinator.handle(hint)
                        }
                    }
                }
                group.addTask { [weak self, socket] in
                    for await hint in socket.revocations {
                        guard let self,
                              !Task.isCancelled,
                              await self.isCurrentHintSocket(socket, token: token)
                        else { return }
                        guard await self.scheduleSessionClearFromRevokedHint(
                            deviceId: hint.deviceId
                        ) != nil else { continue }
                        // Teardown runs outside this exact hintTask so it can cancel and await all
                        // socket loops without ever awaiting itself.
                        return
                    }
                }
                group.addTask { [weak self, socket] in
                    var hasConnected = false
                    for await state in socket.states {
                        guard let self,
                              !Task.isCancelled,
                              await self.isCurrentHintSocket(socket, token: token)
                        else { return }
                        await self.presenceCoordinator.transportChanged(state)
                        guard state == .connected else { continue }
                        if hasConnected {
                            await self.replicaSyncCoordinator.trigger(.socketReconnect)
                            await self.callCoordinator.reconcileActiveCalls()
                            await self.groupCallCoordinator.reconcileAfterSocketReconnect()
                        }
                        hasConnected = true
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func isCurrentHintSocket(_ socket: CloudHintSocket, token: String) -> Bool {
        hintSocket === socket
            && hintSocketToken == token
            && storedSession?.session.token == token
            && !sessionTeardownActive
    }

    @discardableResult
    private func scheduleSessionClearFromRevokedHint(
        deviceId: String?
    ) -> Task<Void, Never>? {
        let applies = deviceId == nil || deviceId == storedSession?.session.deviceId
        guard applies else { return nil }
        return Task { [weak self] in
            await self?.clearLocalSession(finalStatus: "Session ended")
        }
    }

    private func scheduleSync(trigger: ReplicaSyncTrigger = .hint) {
        Task { [replicaSyncCoordinator] in
            await replicaSyncCoordinator.trigger(trigger)
        }
    }

    /// Runs one coordinated sync pass and waits for the coordinator to drain. Every sync entry
    /// point funnels through the coordinator (here or via `scheduleSync`) so passes are
    /// serialized and an overlap can never be misreported as a network failure.
    private func runCoordinatedSync(trigger: ReplicaSyncTrigger) async {
        await replicaSyncCoordinator.trigger(trigger)
        await replicaSyncCoordinator.waitUntilIdle()
    }

    /// A cancelled or replaced attempt can return without publishing a state. Once the coordinator
    /// drains, a pill still stuck on progress means no pass owns it — retrigger once so the state
    /// always settles to ready or a retryable failure.
    private func settleReplicaSyncStateAfterAttempt() {
        Task { [weak self] in
            guard let self else { return }
            await self.replicaSyncCoordinator.waitUntilIdle()
            guard self.replicaSyncState.showsProgress,
                  self.storedSession?.session.token != nil else { return }
            await self.replicaSyncCoordinator.trigger(.hint)
        }
    }

    private func runForegroundSyncAttempt(generation: UInt64) async {
        guard let token = storedSession?.session.token else { return }
        if let issue = api.config.validationIssue() {
            setReplicaSyncState(.configurationError)
            status = issue.message
            return
        }
        let initialNetwork = ReplicaNetworkMonitor.shared.snapshot()
        if initialNetwork.networkClass == .offline {
            setReplicaSyncState(.offline)
            status = String(localized: "Offline. Showing downloaded conversations.")
            return
        }
        let api = api
        let timeout = Self.foregroundSyncTimeoutSeconds
        let probeInterval = LocalFirstMetrics.begin("Sync probe")
        let deadline = await ReplicaDeadline.run(for: .seconds(timeout)) { [api, token, initialNetwork] in
            do {
                let state = try await api.getState(token: token)
                try Task.checkCancellation()
                return ReplicaStateProbeOutcome.succeeded(state)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(Self.replicaFailureState(for: error, network: initialNetwork))
            }
        }
        let outcome: ReplicaStateProbeOutcome = switch deadline {
        case .value(let value): value
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        }
        LocalFirstMetrics.end("Sync probe", probeInterval)

        guard await replicaSyncCoordinator.isCurrent(generation),
              storedSession?.session.token == token else { return }
        switch outcome {
        case .succeeded(let remoteState):
            lastSuccessfulServerContact = Date()
            if remoteState.pts < pts {
                setReplicaSyncState(.protocolFailure)
                status = String(localized: "Server update state moved backwards. Showing the offline copy.")
                return
            }
            let replicaInitialized = if let localStore,
                                        let accountId = storedSession?.session.accountId {
                (try? await localStore.isReplicaInitialized(accountId: accountId)) == true
            } else {
                false
            }
            guard await replicaSyncCoordinator.isCurrent(generation),
                  storedSession?.session.token == token else { return }
            if replicaInitialized, remoteState.pts == pts {
                setReplicaSyncState(.ready)
                status = "Chats are up to date"
                schedulePostSyncWork(token: token)
                return
            }
            appliedSyncBatches = 0
            lastForegroundSyncFailure = nil
            await markReplicaUpdating(generation: generation, token: token)
            let succeeded = await syncNow(publishesConnectionState: false)
            guard await replicaSyncCoordinator.isCurrent(generation),
                  storedSession?.session.token == token,
                  !Task.isCancelled else { return }
            guard succeeded else {
                let failure = lastForegroundSyncFailure ?? .serverUnavailable
                setReplicaSyncState(failure)
                status = failure.title
                return
            }
            setReplicaSyncState(.ready)
            status = "Chats are up to date"
            schedulePostSyncWork(token: token)
        case .failed(let failure):
            setReplicaSyncState(failure)
            status = failure.title
        case .timedOut:
            setReplicaSyncState(.connectionSlow)
            status = String(localized: "Connection is slow. Showing the offline copy.")
        case .cancelled:
            return
        }
    }

    private func markReplicaUpdating(generation: UInt64, token: String) async {
        guard await replicaSyncCoordinator.isCurrent(generation),
              storedSession?.session.token == token else { return }
        setReplicaSyncState(.updating)
        status = "Updating chats"
    }

    private func stopHints() async {
        hintTask?.cancel()
        hintTask = nil
        await hintSocket?.stop()
        hintSocket = nil
        hintSocketToken = nil
        await presenceCoordinator.attach(socket: nil)
    }

    private func schedulePostSyncWork(token: String) {
        postSyncWorkTask?.cancel()
        postSyncWorkTask = Task(priority: .utility) { [weak self] in
            do {
                // Let the freshly updated list and the user's first chat tap get main-thread and
                // SQLCipher priority before discretionary reconciliation starts.
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self, self.storedSession?.session.token == token else { return }
            await self.syncGroupCallCapabilities()
            // Group-call advertisement is device-scoped. Register the upgraded binary first so
            // this same refresh can observe the capability instead of waiting for another launch.
            await self.refreshServerCapabilities()
            if self.capabilities.contains(.calls) {
                await self.syncVoIPCallingAvailability()
            }
            self.reconcileProfileWithServer()
            await self.refreshMediaCacheUsage()
            await self.loadMediaPolicies()
            await self.retryPendingMessageMutations()
            await self.retryPendingGroupMutations()
            await self.retryPendingDialogPreferences()
            await self.retryPendingReadReceipts()
            await self.retryMediaTransfers()
            self.scheduleMediaDownloadProcessing()
            self.scheduleOutboxRetry()
            await self.resumeHistoryHydration()
            if self.storedSession?.session.token == token {
                self.postSyncWorkTask = nil
            }
        }
    }

    private func scheduleOutboxRetry(after delay: TimeInterval = 0) {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
            }

            await self?.retryPendingOutbox()
            let nextDelay = await self?.nextOutboxRetryDelay()
            await MainActor.run {
                self?.retryTask = nil
            }
            if let nextDelay {
                await MainActor.run {
                    self?.scheduleOutboxRetry(after: nextDelay)
                }
            }
        }
    }

    @discardableResult
    private func syncNow(publishesConnectionState: Bool = true) async -> Bool {
        let syncInterval = LocalFirstMetrics.begin("Difference sync")
        defer { LocalFirstMetrics.end("Difference sync", syncInterval) }
        guard let token = storedSession?.session.token else { return false }
        if syncInFlight {
            // Every entry point funnels through ReplicaSyncCoordinator, so overlap indicates a
            // programming error — never a network failure. Ask the active pass to loop once more
            // rather than misreporting the connection state.
            assertionFailure("syncNow is expected to run only via ReplicaSyncCoordinator")
            syncAgain = true
            return false
        }

        syncInFlight = true
        defer { syncInFlight = false }

        repeat {
            syncAgain = false
            do {
                if let localStore,
                   let accountId = storedSession?.session.accountId,
                   !(try await localStore.isReplicaInitialized(accountId: accountId)) {
                    // A new device has no meaningful difference cursor yet. Bootstrap first even
                    // when the server could technically return a small difference from PTS zero.
                    // Returning devices skip this path and render their encrypted replica instantly.
                    try await rebuildLocalReplica(token: token)
                }
                var response = try await fetchDifferencePage(token: token)
                while true {
                    if response.kind == "difference_too_long" {
                        try await rebuildLocalReplica(token: token)
                        response = try await fetchDifferencePage(token: token)
                        continue
                    }
                    try await applyDifferencePage(response)
                    pts = response.state.pts
                    appliedSyncBatches += 1
                    if !publishesConnectionState {
                        setReplicaSyncState(.updating)
                    }
                    if response.kind != "difference_slice" { break }
                    response = try await fetchDifferencePage(token: token)
                }
                if publishesConnectionState {
                    setReplicaSyncState(.ready)
                    status = "Chats are up to date"
                    schedulePostSyncWork(token: token)
                }
            } catch {
                if Task.isCancelled
                    || (error as? URLError)?.code == .cancelled {
                    return false
                }
                status = "Sync failed: \(error.localizedDescription)"
                let failure = Self.replicaFailureState(
                    for: error,
                    network: ReplicaNetworkMonitor.shared.snapshot()
                )
                lastForegroundSyncFailure = failure
                if publishesConnectionState {
                    setReplicaSyncState(failure)
                }
                return false
            }
        } while syncAgain
        return true
    }

    private func fetchDifferencePage(token: String) async throws -> DifferenceResponse {
        let interval = LocalFirstMetrics.begin("Sync difference page")
        defer { LocalFirstMetrics.end("Sync difference page", interval) }
        let limits = Self.differenceRequestLimits(
            for: ReplicaNetworkMonitor.shared.snapshot()
        )
        return try await api.getDifference(
            sincePts: pts,
            maxEvents: limits.maxEvents,
            maxBytes: limits.maxBytes,
            token: token
        )
    }

    private func applyDifferencePage(_ response: DifferenceResponse) async throws {
        let interval = LocalFirstMetrics.begin("Sync apply page")
        defer { LocalFirstMetrics.end("Sync apply page", interval) }
        try await apply(response)
    }

    nonisolated static func differenceRequestLimits(
        for network: ReplicaNetworkSnapshot
    ) -> (maxEvents: Int, maxBytes: Int) {
        switch network.networkClass {
        case .wifi:
            (200, 256 * 1_024)
        case .cellular:
            (100, 128 * 1_024)
        case .unknown, .offline, .constrained, .roaming:
            (50, 64 * 1_024)
        }
    }

    private func apply(_ difference: DifferenceResponse) async throws {
        if difference.kind == "difference_too_long" {
            throw CloudAppModelError.bootstrapRequired
        }

        if let localStore, let accountId = storedSession?.session.accountId {
            var scheduleAcknowledgements: [PendingScheduledCreate] = []
            for update in difference.updates ?? [] {
                guard update.type.hasPrefix("scheduled."),
                      let scheduleId = update.scheduledDelivery?.scheduleId,
                      let pending = try? await localStore.pendingScheduledCreate(
                        scheduleId: scheduleId,
                        accountId: accountId
                      ) else { continue }
                scheduleAcknowledgements.append(pending)
            }
            try await localStore.applyDifference(difference, accountId: accountId)
            for pending in scheduleAcknowledgements {
                await clearDraftAfterScheduledAcknowledgement(
                    dialogId: pending.request.dialogId,
                    operationId: pending.draftOperationId,
                    accountId: accountId,
                    localStore: localStore
                )
            }
            let updateTypes = Set((difference.updates ?? []).map(\.type))
            if updateTypes.contains("chat_folders.updated") {
                let snapshot = try await localStore.effectiveChatFolderSnapshot(accountId: accountId)
                chatFolders = snapshot.folders.sorted { $0.position < $1.position }
                chatFolderCollectionRevision = snapshot.collectionRevision
            }
            if !updateTypes.isDisjoint(with: [
                "scheduled.created", "scheduled.updated", "scheduled.canceled", "scheduled.failed",
            ]) {
                scheduledDeliveries = try await localStore.scheduledDeliveries(accountId: accountId)
                    .sorted { $0.deliverAt < $1.deliverAt }
            }
            let revokedDialogIds = Set(
                (difference.updates ?? []).compactMap { update in
                    update.type == "dialog.access_revoked" ? update.dialogId : nil
                }
            )
            if !revokedDialogIds.isEmpty {
                await cancelMediaTransfers(forRevokedDialogs: revokedDialogIds)
                if let token = storedSession?.session.token {
                    try await drainAccessPurges(
                        store: localStore,
                        accountId: accountId,
                        token: token,
                        generation: savedMessagesSessionGeneration
                    )
                }
            }
            if !profileDetails.needsServerSync,
               let session = storedSession?.session,
               let ownProfile = (difference.updates ?? []).reversed().compactMap({ update in
                   Self.cloudProfile(from: update, ownAccountId: accountId)
               }).first {
                await acceptCanonicalProfile(
                    ownProfile,
                    accountId: accountId,
                    deviceId: session.deviceId,
                    token: session.token,
                    generation: accountSessionGeneration,
                    store: localStore
                )
            }
            await enqueueArrivalMediaDownloads((difference.updates ?? []).compactMap { update -> CloudMessage? in
                guard update.type == "message.new" || update.type == "message.edited" else { return nil }
                return update.message
            })
            // Dialog and active-timeline observations publish this transaction once. Explicitly
            // querying both again here caused online-only reload storms during chat opening.
        } else {
            for update in difference.updates ?? [] {
                guard ["message.new", "message.edited", "message.deleted", "reaction.updated"].contains(update.type),
                      let message = update.message else { continue }
                upsert(message)
            }
        }
    }

    private func rebuildLocalReplica(token: String) async throws {
        guard let accountId = storedSession?.session.accountId else { return }
        guard let localStore else {
            throw CloudAppModelError.localStoreUnavailable
        }

        status = "Rebuilding local cache"
        func downloadPages(bootstrapToken: String, startingAt initialCursor: String?) async throws {
            var cursor = initialCursor
            while true {
                try Task.checkCancellation()
                let page = try await api.getBootstrapDialogs(
                    bootstrapToken: bootstrapToken,
                    cursor: cursor,
                    limit: 20,
                    previewMessages: 5,
                    token: token
                )
                try await localStore.applyBootstrapPage(page)
                await enqueueArrivalMediaDownloads(page.dialogs.flatMap(\.messages), recentOnly: true)
                guard page.hasMore else { return }
                guard let nextCursor = page.nextCursor else {
                    throw CloudAppModelError.invalidBootstrapCursor
                }
                cursor = nextCursor
            }
        }

        var bootstrapToken: String
        var snapshotPts: Int64
        var startingCursor: String?
        let savedState = try await localStore.loadBootstrapState(accountId: accountId)
        let hasPublishedDialogs = try await localStore.latestDialogId() != nil
        let bootstrapMode = savedState?.mode ?? (hasPublishedDialogs ? .replacement : .initial)
        if let saved = savedState,
           saved.status == "in_progress", let savedToken = saved.token {
            bootstrapToken = savedToken
            snapshotPts = saved.snapshotPts
            startingCursor = saved.nextCursor
        } else {
            let bootstrap = try await api.startBootstrap(token: token)
            bootstrapToken = bootstrap.token
            snapshotPts = bootstrap.state.pts
            startingCursor = nil
            try await localStore.beginBootstrap(
                accountId: accountId,
                token: bootstrapToken,
                snapshotPts: snapshotPts,
                mode: bootstrapMode
            )
        }

        do {
            try await downloadPages(bootstrapToken: bootstrapToken, startingAt: startingCursor)
        } catch let error as CloudAPIError
            where error.status == 400 && error.message.localizedCaseInsensitiveContains("bootstrap") {
            let bootstrap = try await api.startBootstrap(token: token)
            bootstrapToken = bootstrap.token
            snapshotPts = bootstrap.state.pts
            startingCursor = nil
            try await localStore.beginBootstrap(
                accountId: accountId,
                token: bootstrapToken,
                snapshotPts: snapshotPts,
                mode: bootstrapMode
            )
            try await downloadPages(bootstrapToken: bootstrapToken, startingAt: nil)
        }

        try await localStore.finishBootstrap(accountId: accountId, pts: snapshotPts)
        pts = snapshotPts
        BackgroundRuntimeCoordinator.shared.scheduleProcessing()
    }

    private func refreshDialogs() async {
        let interval = LocalFirstMetrics.begin("Dialog query")
        defer { LocalFirstMetrics.end("Dialog query", interval) }
        guard let localStore, let accountId = storedSession?.session.accountId else { return }
        do {
            let localDialogs = try await localStore.dialogs(accountId: accountId)
            acceptObservedDialogs(localDialogs)
        } catch {
            status = "Dialog load failed: \(error.localizedDescription)"
        }
    }

    private func cacheCurrentLines(for dialogId: String) {
        cachedLinesByDialog[dialogId] = lines
        cachedLocalMessagesByDialog[dialogId] = loadedLocalMessages
        cachedConversationCostByDialog[dialogId] = Self.preparedConversationCost(
            lines: lines,
            messages: loadedLocalMessages
        )
        cachedLineDialogOrder.removeAll { $0 == dialogId }
        cachedLineDialogOrder.append(dialogId)
        while cachedLineDialogOrder.count > 12
            || cachedConversationCostByDialog.values.reduce(0, +) > 8 * 1_024 * 1_024 {
            let evicted = cachedLineDialogOrder.removeFirst()
            cachedLinesByDialog.removeValue(forKey: evicted)
            cachedLocalMessagesByDialog.removeValue(forKey: evicted)
            cachedConversationCostByDialog.removeValue(forKey: evicted)
        }
    }

    private func purgePreparedConversations() {
        guard let activeDialogId,
              let activeLines = cachedLinesByDialog[activeDialogId],
              let activeMessages = cachedLocalMessagesByDialog[activeDialogId] else {
            cachedLinesByDialog.removeAll(keepingCapacity: true)
            cachedLocalMessagesByDialog.removeAll(keepingCapacity: true)
            cachedLineDialogOrder.removeAll(keepingCapacity: true)
            cachedConversationCostByDialog.removeAll(keepingCapacity: true)
            return
        }
        cachedLinesByDialog = [activeDialogId: activeLines]
        cachedLocalMessagesByDialog = [activeDialogId: activeMessages]
        cachedLineDialogOrder = [activeDialogId]
        cachedConversationCostByDialog = [
            activeDialogId: Self.preparedConversationCost(lines: activeLines, messages: activeMessages)
        ]
    }

    nonisolated private static func preparedConversationCost(
        lines: [Line],
        messages: [LocalMessage]
    ) -> Int {
        let lineStrings = lines.reduce(0) {
            $0 + $1.text.utf8.count + ($1.replyPreview?.utf8.count ?? 0) + 192
        }
        let messageStrings = messages.reduce(0) {
            $0 + $1.text.utf8.count + $1.clientMsgId.utf8.count + 160
        }
        return lineStrings + messageStrings
    }

    private func loadLocalLines(
        dialogId: String,
        observedSnapshot: ConversationLocalSnapshot? = nil
    ) async {
        let timelineInterval = LocalFirstMetrics.begin("Timeline query")
        defer { LocalFirstMetrics.end("Timeline query", timelineInterval) }
        guard let localStore, activeDialogId == dialogId else { return }
        timelineLoadGeneration &+= 1
        let loadGeneration = timelineLoadGeneration
        let selectionGeneration = dialogSelectionGeneration
        do {
            let conversationSnapshot: ConversationLocalSnapshot
            let centeredAnchorMsgId = timelineIsAtBottom ? nil : timelineTopVisibleMsgId
            if let observedSnapshot, centeredAnchorMsgId == nil {
                conversationSnapshot = observedSnapshot
            } else if let anchorMsgId = centeredAnchorMsgId {
                let base = try await localStore.conversationSnapshot(
                    dialogId: dialogId,
                    window: .initial
                )
                let centeredTimeline = try await localStore.timelineWindow(
                    dialogId: dialogId,
                    anchorMsgId: anchorMsgId,
                    beforeCount: timelineBeforeCount,
                    afterCount: timelineAfterCount
                )
                conversationSnapshot = ConversationLocalSnapshot(
                    timeline: centeredTimeline,
                    mutations: base.mutations,
                    transfers: base.transfers,
                    peerReadMsgId: base.peerReadMsgId,
                    historyState: base.historyState
                )
            } else {
                conversationSnapshot = try await localStore.conversationSnapshot(
                    dialogId: dialogId,
                    window: .initial
                )
            }
            let snapshot = conversationSnapshot.timeline
            // Sparse bootstrap previews can sit thousands of IDs ahead of a hydrated unread page.
            // Never render that hole as if the rows were adjacent; expose only the contiguous run
            // around the semantic anchor and let `loadLater` fill the missing keyset pages.
            let messages = centeredAnchorMsgId.map {
                Self.contiguousTimelineSlice(snapshot.messages, anchorMsgId: $0)
            } ?? snapshot.messages
            let rawOldest = snapshot.messages.compactMap(\.msgId).min()
            let rawNewest = snapshot.messages.compactMap(\.msgId).max()
            let displayOldest = messages.compactMap(\.msgId).min()
            let displayNewest = messages.compactMap(\.msgId).max()
            let trimmedEarlierRows = rawOldest != nil && rawOldest != displayOldest
            let trimmedLaterRows = rawNewest != nil && rawNewest != displayNewest
            let mutations = conversationSnapshot.mutations
            let transfers = conversationSnapshot.transfers
            let transfersByClientMessage = Dictionary(
                transfers.map { ($0.clientMsgId, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            let mutationsByMessage = Dictionary(
                mutations.map { ($0.msgId, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            let peerReadMsgId = conversationSnapshot.peerReadMsgId
            let messagesById = Dictionary(uniqueKeysWithValues: messages.compactMap { message in
                message.msgId.map { ($0, message) }
            })
            var preparedLines = messages.compactMap { message -> Line? in
                let mutation = message.msgId.flatMap { mutationsByMessage[$0] }
                guard Self.shouldDisplayInTimeline(
                    messageState: message.state,
                    pendingMutationOperation: mutation?.operation
                ) else { return nil }
                let replyPreview = message.replyToMsgId.map { targetId in
                    guard let target = messagesById[targetId] else { return String(localized: "Earlier message") }
                    return target.state == "deleted_for_all" ? String(localized: "Earlier message") : target.text
                }
                return line(
                    from: message,
                    peerReadMsgId: peerReadMsgId,
                    replyPreview: replyPreview,
                    mutation: mutation,
                    mediaTransfer: transfersByClientMessage[message.clientMsgId]
                )
            }
            let presentationInputs = preparedLines.map {
                TimelinePresentationInput(
                    id: $0.id,
                    mine: $0.mine,
                    senderId: $0.senderAccountId,
                    timestamp: $0.timestamp
                )
            }
            let presentation = await Task.detached(priority: .userInitiated) {
                TimelinePresentationBuilder.build(presentationInputs)
            }.value
            let presentationByID = Dictionary(uniqueKeysWithValues: presentation.map { ($0.id, $0) })
            for index in preparedLines.indices {
                guard let metadata = presentationByID[preparedLines[index].id] else { continue }
                preparedLines[index].presentationDayLabel = metadata.dayLabel
                preparedLines[index].presentationTimestampLabel = metadata.timestampLabel
                preparedLines[index].presentationMediaTimestampLabel = metadata.mediaTimestampLabel
                preparedLines[index].presentationIsFirstInGroup = metadata.isFirstInGroup
                preparedLines[index].presentationIsLastInGroup = metadata.isLastInGroup
            }
            let historyState = conversationSnapshot.historyState
            guard activeDialogId == dialogId,
                  dialogSelectionGeneration == selectionGeneration,
                  timelineLoadGeneration == loadGeneration else { return }

            loadedLocalMessages = messages
            lines = preparedLines
            conversationOpenState = preparedLines.isEmpty ? .empty : .ready
            recordConversationLocalReady(dialogId: dialogId)
            canLoadLater = snapshot.hasLaterLocalMessages
                || trimmedLaterRows
                || timelineHasMoreForwardByDialog[dialogId] == true
            canLoadEarlier = snapshot.hasEarlierLocalMessages
                || trimmedEarlierRows
                || historyState.map { !$0.historyComplete } == true
                || (snapshot.oldestServerMsgId != nil && historyState == nil)
            cacheCurrentLines(for: dialogId)
            finishConversationOpenWaiters(dialogId: dialogId)
            if openPrefetchGeneration != selectionGeneration {
                openPrefetchGeneration = selectionGeneration
                await enqueueArrivalMediaDownloads(window: messages)
            }
        } catch {
            if activeDialogId == dialogId,
               dialogSelectionGeneration == selectionGeneration,
               timelineLoadGeneration == loadGeneration {
                conversationOpenState = .failedLocal
                status = "Local load failed: \(error.localizedDescription)"
                conversationOpenStartedAt.removeValue(forKey: dialogId)
                finishConversationOpenWaiters(dialogId: dialogId)
            }
        }
    }

    private func finishConversationOpenWaiters(dialogId: String) {
        let waiters = conversationOpenWaiters.removeValue(forKey: dialogId) ?? []
        waiters.forEach { $0.resume() }
    }

    private func recordConversationLocalReady(dialogId: String) {
        guard let startedAt = conversationOpenStartedAt.removeValue(forKey: dialogId) else { return }
        LocalFirstMetrics.duration("Chat tap to local snapshot", since: startedAt)
    }

    nonisolated static func shouldDisplayInTimeline(
        messageState: String,
        pendingMutationOperation: String?
    ) -> Bool {
        messageState != "deleted_for_all" && pendingMutationOperation != "delete"
    }

    nonisolated static func contiguousTimelineSlice(
        _ messages: [LocalMessage],
        anchorMsgId: Int64
    ) -> [LocalMessage] {
        guard let anchorIndex = messages.firstIndex(where: { $0.msgId == anchorMsgId }) else {
            return messages
        }
        var lowerBound = anchorIndex
        while lowerBound > messages.startIndex {
            let previousIndex = messages.index(before: lowerBound)
            guard let previous = messages[previousIndex].msgId,
                  let current = messages[lowerBound].msgId,
                  previous + 1 == current else { break }
            lowerBound = previousIndex
        }
        var upperBound = anchorIndex
        while upperBound < messages.index(before: messages.endIndex) {
            let nextIndex = messages.index(after: upperBound)
            guard let current = messages[upperBound].msgId,
                  let next = messages[nextIndex].msgId,
                  current + 1 == next else { break }
            upperBound = nextIndex
        }
        return Array(messages[lowerBound...upperBound])
    }

    private func line(
        from message: LocalMessage,
        peerReadMsgId: Int64,
        replyPreview: String?,
        mutation: PendingMessageMutation? = nil,
        mediaTransfer: MediaTransferRecord? = nil
    ) -> Line {
        let senderIsCurrentAccount = message.senderAccountId == storedSession?.session.accountId
        let mine = message.kind == "service"
            ? VoiceCallServicePresentation.callerIsCurrentAccount(
                body: message.text,
                currentAccountId: storedSession?.session.accountId
            ) ?? senderIsCurrentAccount
            : senderIsCurrentAccount
        let deliveryState: Line.Delivery
        if let mediaTransfer, mediaTransfer.terminal {
            deliveryState = .failed(mediaTransfer.lastError ?? String(localized: "Attachment failed"))
        } else if mutation != nil {
            deliveryState = .sending
        } else if mine, let msgId = message.msgId, msgId <= peerReadMsgId {
            deliveryState = .seen
        } else {
            deliveryState = delivery(from: message.localState)
        }
        var reactions = message.reactions
        if mutation?.operation == "reaction", let accountId = storedSession?.session.accountId {
            reactions.removeAll { $0.accountId == accountId }
            if let emoji = mutation?.emoji {
                reactions.append(CloudReaction(accountId: accountId, emoji: emoji))
            }
        }
        let presentedText: String
        if mutation?.operation == "edit", let body = mutation?.body {
            presentedText = body
        } else {
            presentedText = message.text
        }
        return Line(
            id: message.localId,
            dialogId: message.dialogId,
            msgId: message.msgId,
            clientMsgId: message.clientMsgId,
            senderAccountId: message.senderAccountId,
            senderDisplayName: message.senderDisplayName,
            text: presentedText,
            kind: message.kind,
            serviceType: message.serviceType,
            serviceData: message.serviceData,
            linkPreview: message.linkPreview,
            mine: mine,
            delivery: deliveryState,
            timestamp: message.serverTs,
            replyToMsgId: message.replyToMsgId,
            replyPreview: replyPreview,
            reactions: Self.reactionBadges(reactions),
            myReaction: reactions.first(where: { $0.accountId == storedSession?.session.accountId })?.emoji,
            forwardedFromAccountId: message.forwardedFromAccountId,
            forwardedFromDialogId: message.forwardedFromDialogId,
            forwardedFromMsgId: message.forwardedFromMsgId,
            isForwarded: message.isForwarded,
            editVersion: message.editVersion,
            isEdited: (message.editVersion > 0 || mutation?.operation == "edit") && message.state == "visible",
            isDeleted: message.state == "deleted_for_all",
            media: message.media,
            mediaGroupId: message.mediaGroupId,
            mediaGroupIndex: message.mediaGroupIndex,
            mediaGroupCount: message.mediaGroupCount,
            transferProgress: mediaTransfer.map {
                $0.state == "ready_to_send" ? 1 : Double($0.uploadOffset) / Double(max(1, $0.byteSize))
            },
            transferStage: mediaTransfer.map {
                if $0.state == "ready_to_send" { return .finalizing }
                if $0.retryCount > 0 || $0.lastError != nil { return .retrying }
                if $0.uploadOffset == 0 { return .preparing }
                return .uploading
            },
            transferError: mediaTransfer?.lastError,
            pendingMutation: mutation
        )
    }

    private func dialog(from local: LocalDialog) -> Dialog {
        let isSavedMessages = local.type == "saved"
        let title = isSavedMessages
            ? String(localized: "Saved Messages")
            : displayTitle(local.title, fallback: shortDialogId(local.dialogId))
        let lastText = local.lastText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewKind = ChatListPreviewKind(messageKind: local.lastKind)
        let subtitle: String
        if local.lastKind == "service", let lastText, !lastText.isEmpty {
            subtitle = VoiceCallServicePresentation.parse(
                body: lastText,
                callerIsCurrentAccount: local.lastSenderAccountId == storedSession?.session.accountId,
                currentAccountId: storedSession?.session.accountId
            ).title
        } else if let lastText, !lastText.isEmpty {
            subtitle = lastText
        } else if local.lastState == "visible" {
            subtitle = previewKind.title.isEmpty ? String(localized: "Attachment") : previewKind.title
        } else {
            subtitle = "No messages yet"
        }
        return Dialog(
            id: local.dialogId,
            title: title,
            photo: local.photo,
            type: local.type,
            subtitle: subtitle,
            updatedAt: local.lastServerTs ?? local.updatedAt,
            isPending: local.lastLocalState == "sending" || local.accessState == "pending",
            unreadCount: isSavedMessages ? 0 : local.unreadCount,
            isPinned: local.isPinned,
            pinnedAt: local.pinnedAt,
            isMuted: isSavedMessages ? false : local.isMuted,
            isArchived: isSavedMessages ? false : local.isArchived,
            mentionCount: isSavedMessages ? 0 : local.mentionCount,
            previewKind: previewKind,
            lastMessageMine: local.lastSenderAccountId == storedSession?.session.accountId,
            peerAccountId: local.peerAccountId,
            peerBio: local.peerBio,
            peerBirthday: local.peerBirthday,
            profileColorIndex: local.peerColorIndex,
            memberCount: local.memberCount,
            selfRole: local.selfRole,
            notificationMode: isSavedMessages ? "all" : local.notificationMode,
            accessState: local.accessState,
            lastMsgId: local.lastMsgId
        )
    }

    private func displayTitle(_ candidate: String?, fallback: String) -> String {
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func profileDetails(from displayName: String) -> StoredProfileDetails {
        let parts = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return StoredProfileDetails(
            username: nil,
            firstName: parts.first ?? "",
            lastName: parts.dropFirst().joined(separator: " "),
            bio: "",
            birthday: nil,
            colorIndex: 0
        )
    }

    private static func profileDetails(
        from profile: CloudProfile,
        pendingSync: Bool
    ) -> StoredProfileDetails {
        StoredProfileDetails(
            username: profile.username,
            firstName: profile.firstName,
            lastName: profile.lastName,
            bio: profile.bio,
            birthday: profile.birthday.flatMap(profileDate),
            colorIndex: profile.colorIndex,
            serverUpdatedAt: profile.updatedAt,
            pendingSync: pendingSync
        )
    }

    private static func profileDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func cloudProfile(from contact: ContactLookupResponse) -> CloudProfile? {
        guard
            let accountId = contact.accountId,
            let firstName = contact.firstName,
            let lastName = contact.lastName,
            let displayName = contact.displayName,
            let bio = contact.bio,
            let colorIndex = contact.colorIndex,
            let updatedAt = contact.updatedAt
        else { return nil }
        return CloudProfile(
            accountId: accountId, username: contact.username, firstName: firstName, lastName: lastName,
            displayName: displayName, bio: bio, birthday: contact.birthday,
            colorIndex: colorIndex, photo: contact.photo,
            photoRevision: contact.photoRevision ?? 0, updatedAt: updatedAt
        )
    }

    private static func cloudProfile(from update: CloudUpdate, ownAccountId: String) -> CloudProfile? {
        guard
            update.type == "profile.updated",
            update.subjectAccountId == ownAccountId,
            let firstName = update.firstName,
            let lastName = update.lastName,
            let displayName = update.displayName,
            let bio = update.bio,
            let colorIndex = update.colorIndex,
            let updatedAt = update.profileUpdatedAt
        else { return nil }
        return CloudProfile(
            accountId: ownAccountId, username: update.username, firstName: firstName, lastName: lastName,
            displayName: displayName, bio: bio, birthday: update.birthday,
            colorIndex: colorIndex, photo: update.photo,
            photoRevision: update.photoRevision ?? 0, updatedAt: updatedAt
        )
    }

    private static func cleanedProfileText(
        _ value: String,
        limit: Int,
        preservesNewlines: Bool = false
    ) -> String {
        let normalized = preservesNewlines
            ? value.replacingOccurrences(of: "\r\n", with: "\n")
            : value.replacingOccurrences(of: "\n", with: " ")
        return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanedUsername(_ value: String?) -> String? {
        let cleaned = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        return cleaned.isEmpty ? nil : String(cleaned.prefix(32))
    }

    private func shortDialogId(_ dialogId: String) -> String {
        String(dialogId.prefix(8))
    }

    private func delivery(from localState: String) -> Line.Delivery {
        switch localState {
        case "sending": return .sending
        case "failed": return .failed("failed")
        default: return .sent
        }
    }

    private func markReadIfNeeded(dialogId: String, messages: [LocalMessage]) async {
        guard let accountId = storedSession?.session.accountId, let localStore else { return }
        guard dialogs.first(where: { $0.id == dialogId })?.type != "saved" else { return }
        guard let maxMsgId = messages.compactMap(\.msgId).max() else { return }

        do {
            let current = try await localStore.maxReadMsgId(dialogId: dialogId, accountId: accountId)
            guard maxMsgId > current else { return }
            try await localStore.queueReadReceipt(
                dialogId: dialogId,
                accountId: accountId,
                maxReadMsgId: maxMsgId
            )
            await refreshDialogs()
            scheduleReadReceiptRetry()
        } catch {
            status = "Could not save read position"
        }
    }

    private func scheduleReadReceiptRetry() {
        guard readReceiptRetryTask == nil else {
            // A receipt can be queued after the active drain captured its database snapshot. Keep
            // the task alive for another pass so that receipt cannot be stranded until relaunch.
            readReceiptDrainRequested = true
            return
        }
        readReceiptDrainRequested = true
        readReceiptRetryTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.readReceiptDrainRequested = false
                await self.retryPendingReadReceipts()
                if !self.readReceiptDrainRequested,
                   let localStore = self.localStore,
                   let remaining = try? await localStore.pendingReadReceiptsReady(limit: 1),
                   !remaining.isEmpty {
                    self.readReceiptDrainRequested = true
                }
            } while !Task.isCancelled && self.readReceiptDrainRequested
            self.readReceiptRetryTask = nil
        }
    }

    private func retryPendingReadReceipts() async {
        guard let token = storedSession?.session.token,
              let accountId = storedSession?.session.accountId,
              let localStore else { return }
        let receipts: [PendingReadReceipt]
        do {
            receipts = try await localStore.pendingReadReceiptsReady()
        } catch {
            return
        }

        for receipt in receipts where receipt.accountId == accountId {
            if Task.isCancelled || storedSession?.session.token != token { return }
            do {
                let response = try await api.markRead(
                    dialogId: receipt.dialogId,
                    maxReadMsgId: receipt.maxReadMsgId,
                    token: token
                )
                try await localStore.markRead(
                    dialogId: response.dialogId,
                    accountId: accountId,
                    maxReadMsgId: response.maxReadMsgId,
                    exactUnreadCount: response.unreadCount
                )
                if response.maxReadMsgId >= receipt.maxReadMsgId {
                    try await localStore.completeReadReceipt(
                        dialogId: receipt.dialogId,
                        accountId: accountId,
                        acknowledgedMsgId: response.maxReadMsgId
                    )
                } else {
                    try await localStore.failReadReceipt(
                        dialogId: receipt.dialogId,
                    accountId: accountId,
                    retryAfter: 5,
                    error: "partial acknowledgement",
                    attemptedMsgId: receipt.maxReadMsgId
                )
                }
            } catch is CancellationError {
                return
            } catch {
                if case .authenticationRequired = cloudFailureDisposition(error) { return }
                let retryAfter: TimeInterval
                if case let .transient(serverRetry) = cloudFailureDisposition(error) {
                    retryAfter = serverRetry ?? retryDelay(forRetryCount: receipt.retryCount + 1)
                } else {
                    retryAfter = retryDelay(forRetryCount: receipt.retryCount + 1)
                }
                try? await localStore.failReadReceipt(
                    dialogId: receipt.dialogId,
                    accountId: accountId,
                    retryAfter: retryAfter,
                    error: error.localizedDescription,
                    attemptedMsgId: receipt.maxReadMsgId
                )
                BackgroundRuntimeCoordinator.shared.scheduleAppRefresh(
                    earliestBeginDate: Date(timeIntervalSinceNow: retryAfter)
                )
            }
        }
    }

    private func retryPendingProfilePhotoCommit() async {
        guard capabilities.contains(.profilePhotos) else { return }
        await handleProfilePhotoCommitResult(await profilePhotoSyncCoordinator.commitReady())
    }

    private func handleProfilePhotoCommitResult(_ result: ProfilePhotoCommitResult) async {
        switch result {
        case .idle, .cancelled:
            return
        case let .committed(profile):
            guard let session = storedSession?.session,
                  session.accountId == profile.accountId else { return }
            let generation = accountSessionGeneration
            let expectedStore = localStore
            let token = session.token
            await acceptCanonicalProfile(
                profile,
                accountId: session.accountId,
                deviceId: session.deviceId,
                token: token,
                generation: generation,
                store: expectedStore
            )
            guard generation == accountSessionGeneration,
                  storedSession?.session == session,
                  Self.store(expectedStore, matches: localStore),
                  await profilePhotoSyncCoordinator.pending() == nil
            else { return }
            profilePhotoSyncState = .synced
            status = "Profile photo updated everywhere"
            scheduleSync()
        case let .superseded(profile):
            // The response is still canonical server state, but a newer local intent owns the
            // optimistic overlay and its pending status.
            guard let session = storedSession?.session,
                  session.accountId == profile.accountId else { return }
            let generation = accountSessionGeneration
            let expectedStore = localStore
            await acceptCanonicalProfile(
                profile,
                accountId: session.accountId,
                deviceId: session.deviceId,
                token: session.token,
                generation: generation,
                store: expectedStore
            )
            guard generation == accountSessionGeneration,
                  storedSession?.session == session,
                  Self.store(expectedStore, matches: localStore) else { return }
            scheduleOutboxRetry()
        case let .retrying(message, delay):
            profilePhotoSyncState = .failed(message)
            scheduleOutboxRetry(after: delay)
            BackgroundRuntimeCoordinator.shared.scheduleAppRefresh(
                earliestBeginDate: Date(timeIntervalSinceNow: delay)
            )
        case let .failed(message):
            profilePhotoSyncState = .failed(message)
        case .conflict:
            profilePhotoSyncState = .conflict
        }
    }

    private func retryPendingOutbox() async {
        guard !retryInFlight else { return }
        guard let context = currentAccountOperationContext() else { return }
        let token = context.token
        let localStore = context.store

        retryInFlight = true
        outboxDrainHalted = false
        defer { retryInFlight = false }

        do {
            await productivitySyncCoordinator.bind(context)
            let preCreateReport = await productivitySyncCoordinator.drain(api: api)
            await publishProductivityDrainReport(preCreateReport, context: context)
            guard isCurrentAccountOperation(context) else { return }
            await retryPendingScheduledCreates(context: context)
            guard !outboxDrainHalted, isCurrentAccountOperation(context) else { return }
            // A successful replay can turn an uncertain local create into a canonical schedule.
            // Drain again so its queued cancellation wins immediately in the same retry pass.
            let postCreateReport = await productivitySyncCoordinator.drain(api: api)
            await publishProductivityDrainReport(postCreateReport, context: context)
            guard isCurrentAccountOperation(context) else { return }
            await retryPendingProfilePhotoCommit()
            guard !outboxDrainHalted, isCurrentAccountOperation(context) else { return }
            await retryPendingGroupCreations(token: token, localStore: localStore)
            guard !outboxDrainHalted else { return }
            await retryPendingGroupMutations()
            guard !outboxDrainHalted else { return }
            await retryPendingDialogPreferences()
            guard !outboxDrainHalted else { return }
            let items = try await localStore.pendingOutboxReady(
                includeCloudDraftDependencies: capabilities.contains(.cloudDrafts)
            )
            for item in items {
                try Task.checkCancellation()
                if item.draftConsumeOperationId != nil {
                    let result = await draftSyncCoordinator.flush(
                        dialogId: item.dialogId,
                        force: true
                    )
                    guard await acceptDraftFlushResult(result) else {
                        return
                    }
                }
                try await localStore.markRetrying(clientMsgId: item.clientMsgId)
                if activeDialogId == item.dialogId {
                    await loadLocalLines(dialogId: item.dialogId)
                }
                await refreshDialogs()

                do {
                    try await sendOutboxItem(item, token: token)
                } catch {
                    if let apiError = error as? CloudAPIError,
                       apiError.code == "invalid_reply_target",
                       await recoverTextSendAfterInvalidReply(clientMsgId: item.clientMsgId) {
                        continue
                    }
                    let disposition = cloudOperationFailureDisposition(
                        error, serverAdvertisesFeature: capabilities.contains(.replies)
                    )
                    if case let .transient(retryAfter) = disposition {
                        let delay = retryAfter ?? retryDelay(forRetryCount: item.retryCount + 1)
                        try? await localStore.markFailed(clientMsgId: item.clientMsgId, retryAfter: delay)
                        publishTransportFailure(error)
                        return
                    } else if case .authenticationRequired = disposition {
                        try? await localStore.markFailed(
                            clientMsgId: item.clientMsgId,
                            retryAfter: 30
                        )
                        return
                    } else {
                        try? await localStore.markFailed(clientMsgId: item.clientMsgId, terminal: true)
                        presentNotice("Message was not sent", message: error.localizedDescription)
                    }
                    if activeDialogId == item.dialogId {
                        await loadLocalLines(dialogId: item.dialogId)
                    }
                    await refreshDialogs()
                }
            }
        } catch {
            status = "Outbox retry failed: \(error.localizedDescription)"
            return
        }
        await retryMediaTransfers()
        guard !outboxDrainHalted else { return }
        await retryPendingMediaGroups()
    }

    private func publishProductivityDrainReport(
        _ report: CloudProductivityDrainReport,
        context: AccountOperationContext
    ) async {
        guard isCurrentAccountOperation(context) else { return }
        if report.foldersChanged,
           let snapshot = try? await context.store.effectiveChatFolderSnapshot(
            accountId: context.accountId
           ), isCurrentAccountOperation(context) {
            chatFolders = snapshot.folders.sorted { $0.position < $1.position }
            chatFolderCollectionRevision = snapshot.collectionRevision
        }
        if report.schedulesChanged,
           let deliveries = try? await context.store.scheduledDeliveries(
            accountId: context.accountId
           ), isCurrentAccountOperation(context) {
            scheduledDeliveries = deliveries.sorted { $0.deliverAt < $1.deliverAt }
        }
        if pendingProductivityTerminalNotice == nil,
           let failure = report.terminalErrors.first,
           isCurrentAccountOperation(context) {
            let notice = Notice(
                title: "A saved change could not be synced",
                message: failure.message
            )
            pendingProductivityTerminalNotice = (notice.id, failure)
            operationNotice = notice
        } else if pendingProductivityTerminalNotice == nil,
                  operationNotice == nil,
                  let message = report.errors.first,
                  isCurrentAccountOperation(context) {
            presentNotice("A saved change could not be synced", message: message)
        }
    }

    private func retryPendingScheduledCreates(
        context: AccountOperationContext
    ) async {
        guard capabilities.contains(.scheduledDelivery),
              isCurrentAccountOperation(context) else { return }
        let accountId = context.accountId
        let token = context.token
        let localStore = context.store
        let pending: [PendingScheduledCreate]
        do {
            pending = try await localStore.pendingScheduledCreatesReady(accountId: accountId)
            guard isCurrentAccountOperation(context) else { return }
        } catch {
            guard isCurrentAccountOperation(context) else { return }
            status = "Scheduled messages paused: \(error.localizedDescription)"
            return
        }
        for item in pending {
            guard !Task.isCancelled,
                  isCurrentAccountOperation(context) else { return }
            let wasPreviouslyAttempted = item.attemptedAt != nil
            do {
                // Persist this before the HTTP commit point. A later local cancel may discard only
                // creates that are known never to have reached the network.
                try await localStore.markScheduledCreateAttempted(
                    scheduleId: item.request.scheduleId,
                    accountId: accountId
                )
                guard isCurrentAccountOperation(context) else { return }
                let response = try await api.createScheduledDelivery(
                    persistedBody: item.requestData,
                    token: token
                )
                guard isCurrentAccountOperation(context) else { return }
                try await localStore.acknowledgeScheduledCreate(response, accountId: accountId)
                guard isCurrentAccountOperation(context) else { return }
                await clearDraftAfterScheduledAcknowledgement(
                    dialogId: item.request.dialogId,
                    operationId: item.draftOperationId,
                    accountId: accountId,
                    localStore: localStore
                )
                guard isCurrentAccountOperation(context) else { return }
                scheduledDeliveries.removeAll {
                    $0.scheduleId == response.scheduledDelivery.scheduleId
                }
                scheduledDeliveries.append(response.scheduledDelivery)
                scheduledDeliveries.sort { $0.deliverAt < $1.deliverAt }
                status = String(localized: "Message scheduled on server")
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentAccountOperation(context) else { return }
                let disposition = cloudOperationFailureDisposition(
                    error,
                    serverAdvertisesFeature: capabilities.contains(.scheduledDelivery)
                )
                switch disposition {
                case let .transient(retryAfter):
                    outboxDrainHalted = true
                    let delay = retryAfter ?? retryDelay(forRetryCount: item.retryCount + 1)
                    try? await localStore.deferScheduledCreate(
                        scheduleId: item.request.scheduleId,
                        accountId: accountId,
                        after: delay,
                        error: error.localizedDescription
                    )
                    guard isCurrentAccountOperation(context) else { return }
                    status = String(localized: "Waiting for connection — not scheduled yet")
                    publishTransportFailure(error)
                case .authenticationRequired:
                    outboxDrainHalted = true
                    try? await localStore.deferScheduledCreate(
                        scheduleId: item.request.scheduleId,
                        accountId: accountId,
                        after: 30,
                        error: "Sign in required"
                    )
                    guard isCurrentAccountOperation(context) else { return }
                case .unsupportedServer:
                    // A mixed-version node or disabled route cannot prove that an earlier attempt
                    // did not commit. Keep replaying the original bytes so cancellation can resolve
                    // the accepted schedule instead of orphaning it.
                    outboxDrainHalted = true
                    try? await localStore.deferScheduledCreate(
                        scheduleId: item.request.scheduleId,
                        accountId: accountId,
                        after: 300,
                        error: error.localizedDescription
                    )
                    guard isCurrentAccountOperation(context) else { return }
                    status = String(localized: "Scheduled-message sync is waiting for server support")
                case .permanent:
                    if cloudScheduledCreateCanTerminalizePermanentFailure(
                        wasPreviouslyAttempted: wasPreviouslyAttempted
                    ) {
                        try? await localStore.deferScheduledCreate(
                            scheduleId: item.request.scheduleId,
                            accountId: accountId,
                            after: 0,
                            error: error.localizedDescription,
                            terminal: true
                        )
                        guard isCurrentAccountOperation(context) else { return }
                        presentNotice(
                            "Message was not scheduled",
                            message: "The saved draft was kept. \(error.localizedDescription)"
                        )
                    } else {
                        outboxDrainHalted = true
                        try? await localStore.deferScheduledCreate(
                            scheduleId: item.request.scheduleId,
                            accountId: accountId,
                            after: 300,
                            error: error.localizedDescription
                        )
                        guard isCurrentAccountOperation(context) else { return }
                        status = String(
                            localized: "Scheduled-message sync is waiting for server reconciliation"
                        )
                    }
                }
                if outboxDrainHalted { return }
            }
        }
    }

    private func retryPendingGroupCreations(token: String, localStore: CloudLocalStore) async {
        guard capabilities.contains(.groups) else { return }
        let creations: [PendingGroupCreation]
        do {
            creations = try await localStore.pendingGroupCreationsReady()
        } catch {
            status = "Group retry paused: \(error.localizedDescription)"
            return
        }

        for creation in creations {
            if Task.isCancelled || storedSession?.session.token != token { return }
            do {
                try await localStore.markGroupCreating(groupId: creation.groupId)
                let envelope = try await api.createGroup(
                    id: creation.groupId,
                    title: creation.title,
                    memberIds: creation.memberIds,
                    token: token
                )
                try await localStore.applyGroupEnvelope(envelope)
                if activeDialogId == creation.groupId {
                    await loadLocalLines(dialogId: creation.groupId)
                }
                await refreshDialogs()
                scheduleSync()
            } catch is CancellationError {
                return
            } catch {
                let disposition = cloudOperationFailureDisposition(
                    error,
                    serverAdvertisesFeature: capabilities.contains(.groups)
                )
                switch disposition {
                case let .transient(retryAfter):
                    outboxDrainHalted = true
                    let delay = retryAfter ?? retryDelay(forRetryCount: creation.retryCount + 1)
                    try? await localStore.retryGroupCreation(
                        groupId: creation.groupId,
                        after: delay,
                        error: error.localizedDescription
                    )
                    publishTransportFailure(error)
                case .authenticationRequired:
                    outboxDrainHalted = true
                    try? await localStore.retryGroupCreation(
                        groupId: creation.groupId,
                        after: 30,
                        error: "Sign in required"
                    )
                case .unsupportedServer, .permanent:
                    try? await localStore.failGroupCreation(
                        groupId: creation.groupId,
                        error: error.localizedDescription
                    )
                    presentNotice(
                        "Group was not created",
                        message: "Your draft is saved. Open it and choose Retry when you are ready."
                    )
                }
                await refreshDialogs()
                if outboxDrainHalted { return }
            }
        }
    }

    private func retryPendingGroupMutations() async {
        guard capabilities.contains(.groups),
              !isSessionTeardownInProgress,
              let accountId = storedSession?.session.accountId,
              let token = storedSession?.session.token,
              let localStore else { return }
        let generation = accountSessionGeneration
        let mutations: [PendingGroupMutation]
        do {
            mutations = try await localStore.pendingGroupMutationsReady()
        } catch {
            status = "Group changes paused: \(error.localizedDescription)"
            return
        }
        for mutation in mutations {
            if Task.isCancelled
                || isSessionTeardownInProgress
                || accountSessionGeneration != generation
                || storedSession?.session.accountId != accountId
                || storedSession?.session.token != token {
                return
            }
            do {
                guard
                    let data = mutation.payloadJSON.data(using: .utf8),
                    let payload = try? JSONDecoder().decode(GroupMutationPayload.self, from: data)
                else { throw CloudAppModelError.invalidGroupMutation }
                try await localStore.markGroupMutationAttempted(
                    clientMutationId: mutation.clientMutationId
                )
                guard
                    !Task.isCancelled,
                    !isSessionTeardownInProgress,
                    accountSessionGeneration == generation,
                    storedSession?.session.accountId == accountId,
                    storedSession?.session.token == token
                else { return }
                let envelope: CloudGroupEnvelope?
                switch mutation.operation {
                case "update_title":
                    guard let title = payload.title else { throw CloudAppModelError.invalidGroupMutation }
                    envelope = try await api.updateGroup(
                        id: mutation.dialogId,
                        title: title,
                        clientMutationId: mutation.clientMutationId,
                        token: token
                    )
                case "notifications":
                    guard let mode = payload.mode else { throw CloudAppModelError.invalidGroupMutation }
                    envelope = try await api.updateGroupNotifications(
                        id: mutation.dialogId,
                        mode: mode,
                        clientMutationId: mutation.clientMutationId,
                        token: token
                    )
                case "add_members":
                    guard let memberIds = payload.memberIds else {
                        throw CloudAppModelError.invalidGroupMutation
                    }
                    envelope = try await api.addGroupMembers(
                        id: mutation.dialogId,
                        memberIds: memberIds,
                        clientMutationId: mutation.clientMutationId,
                        token: token
                    )
                case "remove_member":
                    guard let accountId = payload.accountId else {
                        throw CloudAppModelError.invalidGroupMutation
                    }
                    envelope = try await api.removeGroupMember(
                        groupId: mutation.dialogId,
                        accountId: accountId,
                        clientMutationId: mutation.clientMutationId,
                        token: token
                    )
                case "change_role":
                    guard let accountId = payload.accountId, let role = payload.role else {
                        throw CloudAppModelError.invalidGroupMutation
                    }
                    envelope = try await api.changeGroupMemberRole(
                        groupId: mutation.dialogId,
                        accountId: accountId,
                        role: role,
                        clientMutationId: mutation.clientMutationId,
                        token: token
                    )
                case "transfer_owner":
                    guard let accountId = payload.accountId else {
                        throw CloudAppModelError.invalidGroupMutation
                    }
                    envelope = try await api.transferGroupOwner(
                        id: mutation.dialogId,
                        accountId: accountId,
                        clientMutationId: mutation.clientMutationId,
                        token: token
                    )
                case "leave":
                    _ = try await api.leaveGroup(
                        id: mutation.dialogId,
                        successorAccountId: payload.successorAccountId,
                        clientMutationId: mutation.clientMutationId,
                        token: token
                    )
                    envelope = nil
                default:
                    throw CloudAppModelError.invalidGroupMutation
                }
                guard
                    !Task.isCancelled,
                    !isSessionTeardownInProgress,
                    accountSessionGeneration == generation,
                    storedSession?.session.accountId == accountId,
                    storedSession?.session.token == token
                else { return }
                if let envelope {
                    try await localStore.applyGroupEnvelope(envelope)
                }
                try await localStore.completeGroupMutation(
                    clientMutationId: mutation.clientMutationId
                )
                if mutation.operation == "leave", activeDialogId == mutation.dialogId {
                    activeDialogId = nil
                    lines = []
                }
                await refreshDialogs()
                scheduleSync()
            } catch is CancellationError {
                return
            } catch {
                guard
                    !Task.isCancelled,
                    !isSessionTeardownInProgress,
                    accountSessionGeneration == generation,
                    storedSession?.session.accountId == accountId,
                    storedSession?.session.token == token
                else { return }
                if let apiError = error as? CloudAPIError, apiError.status == 410 {
                    try? await localStore.revokeGroupAccess(
                        dialogId: mutation.dialogId,
                        reason: "You no longer have access to this group."
                    )
                    await cancelMediaTransfers(forRevokedDialogs: [mutation.dialogId])
                }
                let disposition = cloudOperationFailureDisposition(
                    error,
                    serverAdvertisesFeature: capabilities.contains(.groups)
                )
                switch disposition {
                case let .transient(retryAfter):
                    outboxDrainHalted = true
                    let delay = retryAfter ?? retryDelay(forRetryCount: mutation.retryCount + 1)
                    try? await localStore.failGroupMutation(
                        clientMutationId: mutation.clientMutationId,
                        retryAfter: delay,
                        error: error.localizedDescription,
                        terminal: false
                    )
                    publishTransportFailure(error)
                    await refreshDialogs()
                    return
                case .authenticationRequired:
                    outboxDrainHalted = true
                    try? await localStore.failGroupMutation(
                        clientMutationId: mutation.clientMutationId,
                        retryAfter: 30,
                        error: "Sign in required",
                        terminal: false
                    )
                    await refreshDialogs()
                    return
                case .unsupportedServer, .permanent:
                    try? await localStore.failGroupMutation(
                        clientMutationId: mutation.clientMutationId,
                        retryAfter: nil,
                        error: error.localizedDescription,
                        terminal: true
                    )
                    presentNotice("Group change failed", message: error.localizedDescription)
                }
                await refreshDialogs()
                if outboxDrainHalted { return }
            }
        }
    }

    private func retryPendingMediaGroups() async {
        guard let localStore else { return }
        do {
            await reconcileMediaGroupCleanups(localStore: localStore)
            guard capabilities.contains(.mediaGroups) else { return }
            for group in try await localStore.pendingMediaGroupSendsReady() {
                try Task.checkCancellation()
                guard await processMediaGroupSend(group) else { break }
            }
        } catch is CancellationError {
            return
        } catch {
            status = "Grouped send retry failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func processMediaGroupSend(_ group: PendingMediaGroupSend) async -> Bool {
        guard !mediaGroupSendsInFlight.contains(group.clientGroupId) else { return false }
        guard
            capabilities.contains(.mediaGroups),
            let token = storedSession?.session.token,
            let accountId = storedSession?.session.accountId,
            accountId == group.accountId,
            let localStore
        else { return false }
        mediaGroupSendsInFlight.insert(group.clientGroupId)
        defer { mediaGroupSendsInFlight.remove(group.clientGroupId) }
        do {
            if let operationId = group.draftConsumeOperationId {
                guard capabilities.contains(.cloudDrafts) else {
                    await refreshServerCapabilities()
                    return false
                }
                let result = await draftSyncCoordinator.flushDependency(operationId: operationId)
                guard await acceptDraftFlushResult(result) else {
                    scheduleOutboxRetry(after: 2)
                    return false
                }
            }
            let response = try await api.sendMediaGroup(
                dialogId: group.dialogId,
                clientGroupId: group.clientGroupId,
                items: group.payload.items.map {
                    MediaGroupItemRequest(clientMsgId: $0.clientMsgId, mediaId: $0.mediaId)
                },
                caption: group.payload.caption,
                replyToMsgId: group.payload.replyToMsgId,
                mentions: group.payload.mentions,
                draftConsumeOperationId: capabilities.contains(.cloudDrafts)
                    ? group.draftConsumeOperationId
                    : nil,
                silent: group.payload.silent,
                token: token
            )
            try await localStore.completeMediaGroupSend(
                response,
                senderAccountId: accountId,
                attemptedOperationId: group.draftConsumeOperationId
            )
            await reconcileMediaGroupCleanups(localStore: localStore)
            if activeDialogId == group.dialogId { await loadLocalLines(dialogId: group.dialogId) }
            await refreshDialogs()
            scheduleSync()
            status = response.duplicate ? "Grouped send confirmed" : "Sent"
            return true
        } catch is CancellationError {
            return false
        } catch {
            if let apiError = error as? CloudAPIError, apiError.code == "invalid_reply_target" {
                if (try? await localStore.restoreMediaGroupAsDraftWithoutReply(group)) != nil {
                    _ = await draftSyncCoordinator.flush(dialogId: group.dialogId)
                    if activeDialogId == group.dialogId {
                        await loadLocalLines(dialogId: group.dialogId)
                    }
                    await refreshDialogs()
                    presentNotice(
                        "Original message unavailable",
                        message: "The reply was removed. Every attachment is still in your draft."
                    )
                }
                return true
            }
            let disposition = cloudOperationFailureDisposition(
                error,
                serverAdvertisesFeature: capabilities.contains(.mediaGroups)
            )
            switch disposition {
            case let .transient(retryAfter):
                let delay = retryAfter ?? retryDelay(forRetryCount: group.retryCount + 1)
                try? await localStore.markMediaGroupSendFailed(
                    clientGroupId: group.clientGroupId,
                    error: error.localizedDescription,
                    retryAfter: delay,
                    terminal: false
                )
                publishTransportFailure(error)
                scheduleOutboxRetry(after: delay)
            case .authenticationRequired:
                try? await localStore.markMediaGroupSendFailed(
                    clientGroupId: group.clientGroupId,
                    error: "Sign in required",
                    retryAfter: 30,
                    terminal: false
                )
            case .unsupportedServer:
                await refreshServerCapabilities()
                return false
            case .permanent:
                try? await localStore.markMediaGroupSendFailed(
                    clientGroupId: group.clientGroupId,
                    error: error.localizedDescription,
                    retryAfter: nil,
                    terminal: true
                )
                presentNotice("Grouped message was not sent", message: error.localizedDescription)
            }
            if activeDialogId == group.dialogId { await loadLocalLines(dialogId: group.dialogId) }
            await refreshDialogs()
            return false
        }
    }

    private func reconcileMediaGroupCleanups(localStore: CloudLocalStore) async {
        let cleanups = (try? await localStore.pendingMediaGroupCleanups()) ?? []
        for cleanup in cleanups {
            if Task.isCancelled { return }
            let transfers = (try? await localStore.mediaTransfers(ids: cleanup.transferIds)) ?? []
            for transfer in transfers {
                let promoted = await mediaEngine.finishUpload(transfer, localStore: localStore)
                if !promoted { await mediaEngine.discardTransfer(transfer) }
            }
            try? await localStore.finalizeMediaGroupCleanup(cleanup)
        }
    }

    private func retryMediaTransfers() async {
        guard let localStore else { return }
        do {
            for transfer in try await localStore.mediaTransfersReady(
                includeCloudDraftDependencies: capabilities.contains(.cloudDrafts)
            ) {
                try Task.checkCancellation()
                await runMediaTransfer(transfer)
                if outboxDrainHalted { return }
            }
        } catch is CancellationError {
            return
        } catch {
            status = "Media retry failed: \(error.localizedDescription)"
        }
    }

    private func runMediaTransfer(_ transfer: MediaTransferRecord) async {
        if let existing = mediaTransferTasks[transfer.transferId] {
            await existing.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.processMediaTransfer(transfer)
        }
        mediaTransferTasks[transfer.transferId] = task
        mediaTransferDialogIds[transfer.transferId] = transfer.dialogId
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        mediaTransferTasks.removeValue(forKey: transfer.transferId)
        mediaTransferDialogIds.removeValue(forKey: transfer.transferId)
    }

    private func processMediaTransfer(_ initial: MediaTransferRecord) async {
        guard !mediaTransfersInFlight.contains(initial.transferId) else { return }
        guard
            let token = storedSession?.session.token,
            let accountId = storedSession?.session.accountId,
            let localStore
        else { return }
        let generation = savedMessagesSessionGeneration
        guard isCurrentSavedMessagesSession(
            accountId: accountId,
            token: token,
            store: localStore,
            generation: generation
        ), (try? await localStore.isDialogAccessRevoked(dialogId: initial.dialogId)) == false
        else { return }
        mediaTransfersInFlight.insert(initial.transferId)
        defer { mediaTransfersInFlight.remove(initial.transferId) }
        do {
            try Task.checkCancellation()
            let mediaId: String
            var draftReadyCommitted = false
            if initial.state == "ready_to_send", let existing = initial.mediaId {
                mediaId = existing
            } else {
                let useMultipartV2 = capabilities.contains(.multipartMedia)
                let upload: @Sendable () async throws -> String = { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.mediaEngine.upload(
                        transfer: initial, token: token, localStore: localStore,
                        useMultipartV2: useMultipartV2,
                        progress: { [weak self] progress in
                            if initial.purpose == "draft" {
                                try? await localStore.updateDraftAttachment(
                                    transferId: initial.transferId,
                                    mediaId: nil,
                                    state: "uploading",
                                    progress: progress,
                                    error: nil
                                )
                            } else {
                                await MainActor.run {
                                    guard let self else { return }
                                    if let index = self.lines.firstIndex(
                                        where: { $0.clientMsgId == initial.clientMsgId }
                                    ) {
                                        self.lines[index].transferProgress = progress
                                        self.lines[index].transferStage =
                                            progress >= 0.97 ? .finalizing : .uploading
                                    }
                                    if self.activeDialogId == initial.dialogId {
                                        self.composerMode = .uploading(
                                            Self.demoAttachment(
                                                kind: initial.kind,
                                                fileName: initial.fileName,
                                                byteSize: initial.byteSize,
                                                durationMs: initial.durationMs
                                            ),
                                            progress: progress
                                        )
                                    }
                                }
                            }
                        }
                    )
                }
                if initial.purpose == "draft" {
                    mediaId = try await draftSyncCoordinator.withAttachmentUploadPermit(upload)
                } else {
                    mediaId = try await upload()
                }
                if initial.purpose == "draft" {
                    // This single SQLCipher transaction marks both the transfer and attachment
                    // ready and rewrites the coalesced draft mutation. There is no crash boundary
                    // where a reopened transfer is ready while its draft chip remains uploading.
                    try await localStore.updateDraftAttachment(
                        transferId: initial.transferId,
                        mediaId: mediaId,
                        state: "ready",
                        progress: 1,
                        error: nil
                    )
                    draftReadyCommitted = true
                } else {
                    try await localStore.updateMediaTransfer(
                        transferId: initial.transferId, mediaId: mediaId,
                        uploadOffset: initial.byteSize, state: "ready_to_send", error: nil
                    )
                }
            }
            guard let ready = try await localStore.mediaTransfer(id: initial.transferId) else {
                throw CloudAppModelError.localStoreUnavailable
            }
            if ready.purpose == "profile_photo" {
                try await profilePhotoSyncCoordinator.markUploaded(
                    transferId: ready.transferId,
                    mediaId: mediaId
                )
                await handleProfilePhotoCommitResult(
                    await profilePhotoSyncCoordinator.commitReady()
                )
                return
            }
            if ready.purpose == "draft" {
                if !draftReadyCommitted {
                    // Repairs a row persisted by an older build at the former two-transaction
                    // boundary, while using the same atomic operation for all new completions.
                    try await localStore.updateDraftAttachment(
                        transferId: ready.transferId,
                        mediaId: mediaId,
                        state: "ready",
                        progress: 1,
                        error: nil
                    )
                }
                _ = await draftSyncCoordinator.flush(dialogId: ready.dialogId)
                status = "Attachment ready"
                return
            }
            if ready.purpose == "group_send" {
                scheduleOutboxRetry()
                return
            }
            if ready.purpose == "group_photo" {
                let envelope = try await api.updateGroup(
                    id: ready.dialogId,
                    photoMediaId: mediaId,
                    clientMutationId: ready.transferId,
                    token: token
                )
                try Task.checkCancellation()
                guard
                    isCurrentSavedMessagesSession(
                        accountId: accountId,
                        token: token,
                        store: localStore,
                        generation: generation
                    ),
                    (try? await localStore.isDialogAccessRevoked(
                        dialogId: ready.dialogId
                    )) == false
                else { throw CancellationError() }
                try await localStore.applyGroupEnvelope(envelope)
                let promotedToCache = await mediaEngine.finishUpload(ready, localStore: localStore)
                try await localStore.completeMediaTransfer(transferId: ready.transferId)
                if !promotedToCache {
                    await mediaEngine.discardTransfer(ready)
                }
                await refreshDialogs()
                if activeDialogId == ready.dialogId {
                    await loadGroupProfile(dialogId: ready.dialogId)
                }
                scheduleSync()
                status = "Group photo updated"
                return
            }
            if let operationId = ready.draftOperationId {
                guard capabilities.contains(.cloudDrafts) else {
                    await refreshServerCapabilities()
                    return
                }
                let result = await draftSyncCoordinator.flushDependency(operationId: operationId)
                guard await acceptDraftFlushResult(result) else {
                    scheduleOutboxRetry(after: 2)
                    return
                }
            }
            try await localStore.insertSendingMedia(ready, senderAccountId: accountId)
            if activeDialogId == ready.dialogId { await loadLocalLines(dialogId: ready.dialogId) }
            try Task.checkCancellation()
            guard
                isCurrentSavedMessagesSession(
                    accountId: accountId,
                    token: token,
                    store: localStore,
                    generation: generation
                ),
                (try? await localStore.isDialogAccessRevoked(dialogId: ready.dialogId)) == false
            else { throw CancellationError() }
            // Once the idempotent send request begins it is the commit point. Hide the upload cancel
            // control so the UI never promises cancellation after the server may have committed.
            if activeComposerTransferId == ready.transferId {
                activeComposerTransferId = nil
                if case .uploading = composerMode { composerMode = .text }
            }
            let response = try await api.sendMediaMessage(
                dialogId: ready.dialogId, clientMsgId: ready.clientMsgId,
                body: ready.caption, mediaId: mediaId, replyToMsgId: ready.replyToMsgId,
                mentions: ready.mentions,
                draftConsumeOperationId: capabilities.contains(.cloudDrafts)
                    ? ready.draftOperationId
                    : nil,
                silent: ready.silent,
                token: token
            )
            try Task.checkCancellation()
            guard
                isCurrentSavedMessagesSession(
                    accountId: accountId,
                    token: token,
                    store: localStore,
                    generation: generation
                ),
                (try? await localStore.isDialogAccessRevoked(dialogId: ready.dialogId)) == false
            else { throw CancellationError() }
            try await localStore.markSent(response, senderAccountId: accountId)
            let promotedToCache = await mediaEngine.finishUpload(ready, localStore: localStore)
            try await localStore.completeMediaTransfer(transferId: ready.transferId)
            if !promotedToCache {
                await mediaEngine.discardTransfer(ready)
            }
            if activeDialogId == ready.dialogId, case .uploading = composerMode { composerMode = .text }
            if activeDialogId == ready.dialogId { await loadLocalLines(dialogId: ready.dialogId) }
            await refreshDialogs()
            scheduleSync()
            status = "Sent"
        } catch is CancellationError {
            let current = (try? await localStore.mediaTransfer(id: initial.transferId)) ?? initial
            await cancelMediaTransfer(current, token: token)
            if activeDialogId == initial.dialogId, case .uploading = composerMode { composerMode = .text }
        } catch {
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ), (try? await localStore.isDialogAccessRevoked(dialogId: initial.dialogId)) == false
            else { return }
            let current = try? await localStore.mediaTransfer(id: initial.transferId)
            if activeDialogId == initial.dialogId, case .uploading = composerMode { composerMode = .text }
            if initial.purpose == "profile_photo" {
                let disposition = cloudOperationFailureDisposition(
                    error,
                    serverAdvertisesFeature: capabilities.contains(.profilePhotos)
                )
                switch disposition {
                case let .transient(retryAfter):
                    let delay = retryAfter ?? retryDelay(forRetryCount: initial.retryCount + 1)
                    try? await localStore.updateMediaTransfer(
                        transferId: initial.transferId,
                        mediaId: current?.mediaId,
                        uploadOffset: current?.uploadOffset ?? initial.uploadOffset,
                        state: current?.mediaId == nil ? "pending" : "uploading",
                        error: error.localizedDescription,
                        retryAfter: delay
                    )
                    guard let mutation = try? await localStore.pendingProfilePhotoMutation(
                        accountId: accountId
                    ), mutation.transferId == initial.transferId else { return }
                    let failed = try? await localStore.failProfilePhotoUpload(
                        accountId: accountId,
                        clientMutationId: mutation.clientMutationId,
                        error: error.localizedDescription,
                        retryAfter: delay
                    )
                    guard failed == true else { return }
                    profilePhotoSyncState = .failed(error.localizedDescription)
                    scheduleOutboxRetry(after: delay)
                case .authenticationRequired:
                    return
                case .unsupportedServer:
                    await refreshServerCapabilities()
                    profilePhotoSyncState = .localOnly
                case .permanent:
                    try? await localStore.markMediaTerminal(
                        clientMsgId: initial.clientMsgId,
                        error: error.localizedDescription
                    )
                    guard let mutation = try? await localStore.pendingProfilePhotoMutation(
                        accountId: accountId
                    ), mutation.transferId == initial.transferId else { return }
                    let failed = try? await localStore.failProfilePhotoMutation(
                        accountId: accountId,
                        clientMutationId: mutation.clientMutationId,
                        error: error.localizedDescription,
                        retryAfter: nil,
                        terminal: true
                    )
                    guard failed == true else { return }
                    profilePhotoSyncState = .failed(error.localizedDescription)
                }
                return
            }
            if let apiError = error as? CloudAPIError,
               apiError.code == "invalid_reply_target",
               let current,
               current.draftOperationId != nil,
               (try? await localStore.restoreSingleMediaAsDraftWithoutReply(
                   current,
                   accountId: accountId
               )) != nil {
                _ = await draftSyncCoordinator.flush(dialogId: current.dialogId)
                if activeDialogId == current.dialogId {
                    await loadLocalLines(dialogId: current.dialogId)
                }
                await refreshDialogs()
                presentNotice(
                    "Original message unavailable",
                    message: "The reply was removed. Your attachment and caption are still in your draft."
                )
                return
            }
            if initial.purpose == "draft" {
                let disposition = cloudOperationFailureDisposition(
                    error,
                    serverAdvertisesFeature: capabilities.contains(.media)
                )
                switch disposition {
                case let .transient(retryAfter):
                    outboxDrainHalted = true
                    let delay = retryAfter ?? retryDelay(forRetryCount: initial.retryCount + 1)
                    try? await localStore.updateDraftAttachment(
                        transferId: initial.transferId,
                        mediaId: current?.mediaId,
                        state: "failed",
                        progress: current.map {
                            Double($0.uploadOffset) / Double(max(1, $0.byteSize))
                        } ?? 0,
                        error: error.localizedDescription,
                        retryAfter: delay
                    )
                    scheduleOutboxRetry(after: delay)
                case .authenticationRequired:
                    outboxDrainHalted = true
                    try? await localStore.updateDraftAttachment(
                        transferId: initial.transferId,
                        mediaId: current?.mediaId,
                        state: "failed",
                        progress: current.map {
                            Double($0.uploadOffset) / Double(max(1, $0.byteSize))
                        } ?? 0,
                        error: "Sign in required",
                        retryAfter: 30
                    )
                case .unsupportedServer:
                    outboxDrainHalted = true
                    await refreshServerCapabilities()
                    scheduleOutboxRetry(after: 30)
                case .permanent:
                    try? await localStore.updateDraftAttachment(
                        transferId: initial.transferId,
                        mediaId: current?.mediaId,
                        state: "terminal",
                        progress: 0,
                        error: error.localizedDescription
                    )
                }
                status = "Draft attachment upload failed: \(error.localizedDescription)"
                return
            }
            switch cloudOperationFailureDisposition(
                error, serverAdvertisesFeature: capabilities.contains(.media)
            ) {
            case let .transient(retryAfter):
                outboxDrainHalted = true
                let delay = retryAfter ?? retryDelay(forRetryCount: initial.retryCount + 1)
                try? await localStore.updateMediaTransfer(
                    transferId: initial.transferId, mediaId: current?.mediaId,
                    uploadOffset: current?.uploadOffset ?? initial.uploadOffset,
                    state: current?.mediaId == nil ? "pending" : "uploading",
                    error: error.localizedDescription, retryAfter: delay
                )
                publishTransportFailure(error)
                status = "Attachment queued for retry"
                scheduleOutboxRetry(after: delay)
            case .unsupportedServer:
                outboxDrainHalted = true
                await refreshServerCapabilities()
                scheduleOutboxRetry(after: 30)
            case .authenticationRequired:
                outboxDrainHalted = true
                try? await localStore.updateMediaTransfer(
                    transferId: initial.transferId,
                    mediaId: current?.mediaId,
                    uploadOffset: current?.uploadOffset ?? initial.uploadOffset,
                    state: current?.mediaId == nil ? "pending" : "ready_to_send",
                    error: "Sign in required",
                    retryAfter: 30
                )
            case .permanent:
                try? await localStore.markMediaTerminal(
                    clientMsgId: initial.clientMsgId, error: error.localizedDescription
                )
                presentNotice("Attachment was not sent", message: error.localizedDescription)
            }
            if activeDialogId == initial.dialogId { await loadLocalLines(dialogId: initial.dialogId) }
            await refreshDialogs()
        }
    }

    private func cancelMediaTransfer(_ transfer: MediaTransferRecord, token: String) async {
        await mediaEngine.cancelUpload(transfer, token: token)
        try? await localStore?.cancelMediaTransfer(
            transferId: transfer.transferId, clientMsgId: transfer.clientMsgId
        )
        lines.removeAll { $0.clientMsgId == transfer.clientMsgId }
        if activeDialogId == transfer.dialogId { await loadLocalLines(dialogId: transfer.dialogId) }
        await refreshDialogs()
    }

    private func recoverTextSendAfterInvalidReply(clientMsgId: String) async -> Bool {
        guard
            let accountId = storedSession?.session.accountId,
            let localStore,
            let outcome = try? await localStore.recoverTextSendAfterInvalidReply(
                clientMsgId: clientMsgId,
                accountId: accountId
            )
        else { return false }
        let dialogId: String
        let message: String
        switch outcome {
        case let .restoredDraft(restoredDialogId):
            dialogId = restoredDialogId
            _ = await draftSyncCoordinator.flush(dialogId: dialogId)
            message = "The reply was removed. Your draft is still here—review it and try again."
        case let .keptFailedMessage(failedDialogId):
            dialogId = failedDialogId
            message = "The reply was removed. Your newer draft was kept, and the failed message is ready to retry."
        }
        if activeDialogId == dialogId {
            await loadLocalLines(dialogId: dialogId)
        }
        await refreshDialogs()
        presentNotice("Original message unavailable", message: message)
        return true
    }

    private func cancelMediaTransfers(forRevokedDialogs dialogIds: Set<String>) async {
        guard let localStore else { return }
        for dialogId in dialogIds.sorted() {
            let transfers = (try? await localStore.mediaTransfers(dialogId: dialogId)) ?? []
            for transfer in transfers {
                if let activeTask = mediaTransferTasks[transfer.transferId] {
                    activeTask.cancel()
                    await activeTask.value
                } else if let token = storedSession?.session.token {
                    await cancelMediaTransfer(transfer, token: token)
                } else {
                    try? await localStore.cancelMediaTransfer(
                        transferId: transfer.transferId,
                        clientMsgId: transfer.clientMsgId
                    )
                    await mediaEngine.discardTransfer(transfer)
                }
            }
        }
    }

    private static func demoAttachment(
        kind: String, fileName: String?, byteSize: Int64, durationMs: Int64?
    ) -> DemoAttachment {
        let duration = durationMs.map {
            let seconds = max(0, $0 / 1_000)
            return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
        } ?? ""
        switch kind {
        case "photo": return .photo(name: fileName ?? String(localized: "Photo"))
        case "video": return .video(name: fileName ?? String(localized: "Video"), duration: duration)
        case "voice": return .voice(duration: duration.isEmpty ? "0:00" : duration)
        default: return .file(
            name: fileName ?? String(localized: "File"),
            size: ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
        )
        }
    }

    private func sendOutboxItem(_ item: PendingOutboxItem, token: String) async throws {
        let response: SendMessageResponse
        if let sourceDialogId = item.forwardedFromDialogId, let sourceMsgId = item.forwardedFromMsgId {
            response = try await api.forwardMessage(
                dialogId: item.dialogId,
                clientMsgId: item.clientMsgId,
                sourceDialogId: sourceDialogId,
                sourceMsgId: sourceMsgId,
                token: token
            )
        } else {
            response = try await api.sendMessage(
                dialogId: item.dialogId,
                clientMsgId: item.clientMsgId,
                body: item.body,
                replyToMsgId: item.replyToMsgId,
                mentions: item.mentions,
                draftConsumeOperationId: capabilities.contains(.cloudDrafts)
                    ? item.draftConsumeOperationId
                    : nil,
                silent: item.silent,
                token: token
            )
        }

        if let localStore, let accountId = storedSession?.session.accountId {
            try await localStore.markSent(response, senderAccountId: accountId)
            if activeDialogId == response.dialogId {
                await loadLocalLines(dialogId: response.dialogId)
            }
            await refreshDialogs()
        } else if let index = lines.firstIndex(where: { $0.clientMsgId == item.clientMsgId }) {
            lines[index].dialogId = response.dialogId
            lines[index].msgId = response.msgId
            lines[index].delivery = .sent
        }

        status = response.duplicate ? "Send confirmed" : "Sent"
        scheduleSync()
    }

    private func nextOutboxRetryDelay() async -> TimeInterval? {
        guard let localStore else { return nil }
        let groupDelay = try? await localStore.nextPendingGroupCreationDelay()
        let textDelay = try? await localStore.nextPendingOutboxDelay(
            includeCloudDraftDependencies: capabilities.contains(.cloudDrafts)
        )
        let mediaDelay = try? await localStore.nextMediaTransferDelay(
            includeCloudDraftDependencies: capabilities.contains(.cloudDrafts)
        )
        let mediaGroupDelay = capabilities.contains(.mediaGroups)
            ? try? await localStore.nextMediaGroupSendDelay()
            : nil
        let mutationDelay = try? await localStore.nextMessageMutationDelay()
        let groupMutationDelay = try? await localStore.nextPendingGroupMutationDelay()
        let scheduledCreateDelay: TimeInterval?
        let productivityDelay: TimeInterval?
        if let accountId = storedSession?.session.accountId {
            if capabilities.contains(.scheduledDelivery) {
                let storedDelay = try? await localStore.nextScheduledCreateRetryDelay(
                    accountId: accountId
                )
                scheduledCreateDelay = cloudScheduledCreateRetryDelay(
                    storedDelay,
                    serverAdvertisesFeature: true
                )
            } else {
                // Dormant durable creates are reactivated by the next capability refresh. They must
                // not schedule a zero-delay outbox loop while the route is intentionally absent.
                scheduledCreateDelay = cloudScheduledCreateRetryDelay(
                    nil,
                    serverAdvertisesFeature: false
                )
            }
            productivityDelay = try? await localStore.nextProductivityMutationRetryDelay(
                accountId: accountId
            )
        } else {
            scheduledCreateDelay = nil
            productivityDelay = nil
        }
        var preferenceDelay: TimeInterval?
        if capabilities.contains(.chatOrganization),
           let accountId = storedSession?.session.accountId {
            preferenceDelay = try? await localStore.nextDialogPreferenceRetryDelay(
                accountId: accountId
            )
            if preferenceDelay == 0,
               await dialogPreferencesCoordinator.hasActiveDrain {
                // A rapid coalesced toggle can become ready while the prior HTTP request is still
                // in flight. Avoid a zero-delay retry loop; the active drain will pick it up.
                preferenceDelay = 1
            }
        } else {
            preferenceDelay = nil
        }
        return [
            groupDelay, groupMutationDelay, preferenceDelay,
            scheduledCreateDelay, productivityDelay,
            textDelay, mediaDelay, mediaGroupDelay, mutationDelay,
        ].compactMap { $0 }.min()
    }

    private func retryDelay(forRetryCount retryCount: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, retryCount - 1))))
    }

    private func upsert(_ message: CloudMessage) {
        if message.state == "deleted_for_all" {
            lines.removeAll {
                $0.clientMsgId == message.clientMsgId
                    || ($0.dialogId == message.dialogId && $0.msgId == message.msgId)
            }
            return
        }
        let mine = message.senderAccountId == storedSession?.session.accountId
        if let index = lines.firstIndex(where: { $0.clientMsgId == message.clientMsgId }) {
            lines[index].dialogId = message.dialogId
            lines[index].msgId = message.msgId
            lines[index].senderAccountId = message.senderAccountId
            lines[index].senderDisplayName = nil
            lines[index].kind = message.kind
            lines[index].serviceType = message.serviceType
            lines[index].serviceData = message.serviceData
            lines[index].text = message.text
            lines[index].replyToMsgId = message.replyToMsgId
            lines[index].reactions = Self.reactionBadges(message.reactions)
            lines[index].myReaction = message.reactions.first(where: { $0.accountId == storedSession?.session.accountId })?.emoji
            lines[index].forwardedFromAccountId = message.forwardedFromAccountId
            lines[index].forwardedFromDialogId = message.forwardedFromDialogId
            lines[index].forwardedFromMsgId = message.forwardedFromMsgId
            lines[index].isForwarded = message.isForwarded
            lines[index].editVersion = message.editVersion
            lines[index].isEdited = message.editVersion > 0 && message.state == "visible"
            lines[index].isDeleted = message.state == "deleted_for_all"
            lines[index].media = message.media
            lines[index].mediaGroupId = message.mediaGroupId
            lines[index].mediaGroupIndex = message.mediaGroupIndex
            lines[index].mediaGroupCount = message.mediaGroupCount
            lines[index].mine = mine
            lines[index].delivery = .sent
            lines[index].timestamp = message.serverTs
            return
        }
        lines.append(Line(
            id: message.id,
            dialogId: message.dialogId,
            msgId: message.msgId,
            clientMsgId: message.clientMsgId,
            senderAccountId: message.senderAccountId,
            text: message.text,
            kind: message.kind,
            serviceType: message.serviceType,
            serviceData: message.serviceData,
            mine: mine,
            delivery: .sent,
            timestamp: message.serverTs,
            replyToMsgId: message.replyToMsgId,
            reactions: Self.reactionBadges(message.reactions),
            myReaction: message.reactions.first(where: { $0.accountId == storedSession?.session.accountId })?.emoji,
            forwardedFromAccountId: message.forwardedFromAccountId,
            forwardedFromDialogId: message.forwardedFromDialogId,
            forwardedFromMsgId: message.forwardedFromMsgId,
            isForwarded: message.isForwarded,
            editVersion: message.editVersion,
            isEdited: message.editVersion > 0 && message.state == "visible",
            isDeleted: message.state == "deleted_for_all",
            media: message.media,
            mediaGroupId: message.mediaGroupId,
            mediaGroupIndex: message.mediaGroupIndex,
            mediaGroupCount: message.mediaGroupCount
        ))
        lines.sort {
            switch ($0.msgId, $1.msgId) {
            case let (lhs?, rhs?): return lhs < rhs
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return $0.id < $1.id
            }
        }
    }

    private func edit(_ line: Line, text: String) async {
        guard
            let localStore,
            let dialogId = line.dialogId,
            let msgId = line.msgId
        else { return }
        let targetKey = "\(dialogId):\(msgId)"
        guard mutationTargetsBeingQueued.insert(targetKey).inserted else { return }
        defer { mutationTargetsBeingQueued.remove(targetKey) }
        do {
            let mutationId = UUID().uuidString.lowercased()
            try await localStore.enqueueMessageMutation(
                clientMutationId: mutationId,
                operation: "edit",
                dialogId: dialogId,
                msgId: msgId,
                body: text,
                expectedEditVersion: line.editVersion
            )
            restoreUnderlyingDraftComposer()
            await loadLocalLines(dialogId: dialogId)
            await processMessageMutation(PendingMessageMutation(
                clientMutationId: mutationId, operation: "edit", dialogId: dialogId,
                msgId: msgId, body: text, expectedEditVersion: line.editVersion,
                emoji: nil, retryCount: 0, nextRetryAt: nil, lastError: nil
            ))
        } catch {
            status = "Edit failed: \(error.localizedDescription)"
            presentNotice("Could not edit message", message: error.localizedDescription)
        }
    }

    func deleteMessage(_ line: Line) async {
        #if DEBUG
        if isDemoMode {
            deleteDemoMessage(line.id)
            return
        }
        #endif
        guard
            let localStore,
            line.mine,
            !line.isDeleted,
            let dialogId = line.dialogId,
            let msgId = line.msgId
        else { return }
        let targetKey = "\(dialogId):\(msgId)"
        guard mutationTargetsBeingQueued.insert(targetKey).inserted else { return }
        defer { mutationTargetsBeingQueued.remove(targetKey) }
        do {
            let mutationId = UUID().uuidString.lowercased()
            try await localStore.enqueueMessageMutation(
                clientMutationId: mutationId, operation: "delete",
                dialogId: dialogId, msgId: msgId
            )
            await loadLocalLines(dialogId: dialogId)
            await processMessageMutation(PendingMessageMutation(
                clientMutationId: mutationId, operation: "delete", dialogId: dialogId,
                msgId: msgId, body: nil, expectedEditVersion: nil, emoji: nil,
                retryCount: 0, nextRetryAt: nil, lastError: nil
            ))
        } catch {
            status = "Delete failed: \(error.localizedDescription)"
            presentNotice("Could not delete message", message: error.localizedDescription)
        }
    }

    func reactToMessage(_ line: Line, reaction: String = "❤️") async {
        #if DEBUG
        if isDemoMode {
            reactToDemoMessage(line.id, reaction: reaction)
            return
        }
        #endif
        guard
            let localStore,
            !line.isDeleted,
            let dialogId = line.dialogId,
            let msgId = line.msgId
        else { return }
        let targetKey = "\(dialogId):\(msgId)"
        guard mutationTargetsBeingQueued.insert(targetKey).inserted else { return }
        defer { mutationTargetsBeingQueued.remove(targetKey) }
        let desiredReaction: String? = line.myReaction == reaction ? nil : reaction
        do {
            let mutationId = UUID().uuidString.lowercased()
            try await localStore.enqueueMessageMutation(
                clientMutationId: mutationId, operation: "reaction",
                dialogId: dialogId, msgId: msgId, emoji: desiredReaction
            )
            await loadLocalLines(dialogId: dialogId)
            await processMessageMutation(PendingMessageMutation(
                clientMutationId: mutationId, operation: "reaction", dialogId: dialogId,
                msgId: msgId, body: nil, expectedEditVersion: nil, emoji: desiredReaction,
                retryCount: 0, nextRetryAt: nil, lastError: nil
            ))
        } catch {
            status = "Reaction failed: \(error.localizedDescription)"
            presentNotice("Could not update reaction", message: error.localizedDescription)
        }
    }

    func forwardMessage(_ line: Line, to targetDialogId: String) async {
        guard !sessionTeardownActive else { return }
        _ = await runTrackedSavedOperation {
            await self.forwardMessageCore(line, to: targetDialogId)
        }
    }

    private func forwardMessageCore(_ line: Line, to targetDialogId: String) async {
        #if DEBUG
        if isDemoMode {
            status = "Forwarded"
            return
        }
        #endif
        guard
            !sessionTeardownActive,
            !line.isDeleted,
            let token = storedSession?.session.token,
            let accountId = storedSession?.session.accountId,
            let localStore,
            let sourceDialogId = line.dialogId,
            let sourceMsgId = line.msgId
        else { return }
        let generation = savedMessagesSessionGeneration
        guard isCurrentSavedMessagesSession(
            accountId: accountId,
            token: token,
            store: localStore,
            generation: generation
        ) else { return }
        let clientMsgId = UUID().uuidString.lowercased()
        do {
            _ = try await localStore.insertSending(
                dialogId: targetDialogId,
                clientMsgId: clientMsgId,
                text: line.text,
                senderAccountId: accountId,
                forwardedFromAccountId: line.senderAccountId,
                forwardedFromDialogId: sourceDialogId,
                forwardedFromMsgId: sourceMsgId,
                kind: line.kind,
                media: line.media
            )
            try Task.checkCancellation()
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ) else { throw CancellationError() }
            await refreshDialogs()
            let response = try await api.forwardMessage(
                dialogId: targetDialogId,
                clientMsgId: clientMsgId,
                sourceDialogId: sourceDialogId,
                sourceMsgId: sourceMsgId,
                token: token
            )
            try Task.checkCancellation()
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ) else { throw CancellationError() }
            try await localStore.markSent(response, senderAccountId: accountId)
            if activeDialogId == response.dialogId {
                await loadLocalLines(dialogId: response.dialogId)
            }
            await refreshDialogs()
            scheduleSync()
            status = "Forwarded"
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ) else { return }
            let disposition = cloudOperationFailureDisposition(
                error,
                serverAdvertisesFeature: capabilities.contains(.forwarding)
            )
            switch disposition {
            case let .transient(retryAfter):
                let delay = retryAfter ?? retryDelay(forRetryCount: 1)
                try? await localStore.markFailed(clientMsgId: clientMsgId, retryAfter: delay)
                await refreshDialogs()
                scheduleOutboxRetry(after: delay)
                publishTransportFailure(error)
            case .authenticationRequired, .unsupportedServer, .permanent:
                // Source deletion/inaccessibility is permanent. Keep one terminal bubble with an
                // explicit atomic Remove action instead of retrying forever.
                try? await localStore.markFailed(clientMsgId: clientMsgId, terminal: true)
                await refreshDialogs()
            }
            status = "Forward failed: \(error.localizedDescription)"
        }
    }

    private static func reactionBadges(_ reactions: [CloudReaction]) -> [String] {
        let grouped = Dictionary(grouping: reactions, by: \.emoji)
        return grouped.keys.sorted().map { emoji in
            let count = grouped[emoji]?.count ?? 0
            return count > 1 ? "\(emoji) \(count)" : emoji
        }
    }

    private func retryPendingMessageMutations() async {
        guard let localStore else { return }
        do {
            for mutation in try await localStore.pendingMessageMutationsReady() {
                try Task.checkCancellation()
                await processMessageMutation(mutation)
            }
        } catch is CancellationError {
            return
        } catch {
            presentNotice("Could not resume message changes", message: error.localizedDescription)
        }
    }

    private func processMessageMutation(_ mutation: PendingMessageMutation) async {
        guard !messageMutationsInFlight.contains(mutation.clientMutationId) else { return }
        guard
            let token = storedSession?.session.token,
            let accountId = storedSession?.session.accountId,
            let localStore
        else { return }
        let generation = savedMessagesSessionGeneration
        guard isCurrentSavedMessagesSession(
            accountId: accountId,
            token: token,
            store: localStore,
            generation: generation
        ), (try? await localStore.isDialogAccessRevoked(dialogId: mutation.dialogId)) == false
        else { return }
        messageMutationsInFlight.insert(mutation.clientMutationId)
        defer { messageMutationsInFlight.remove(mutation.clientMutationId) }

        do {
            let response: MessageMutationResponse
            switch mutation.operation {
            case "edit":
                guard let body = mutation.body, let expected = mutation.expectedEditVersion else {
                    throw CloudAppModelError.localStoreUnavailable
                }
                response = try await api.editMessage(
                    dialogId: mutation.dialogId,
                    msgId: mutation.msgId,
                    clientMutationId: mutation.clientMutationId,
                    expectedEditVersion: expected,
                    body: body,
                    token: token
                )
            case "delete":
                response = try await api.deleteMessage(
                    dialogId: mutation.dialogId,
                    msgId: mutation.msgId,
                    clientMutationId: mutation.clientMutationId,
                    token: token
                )
            case "reaction":
                response = try await api.setReaction(
                    dialogId: mutation.dialogId,
                    msgId: mutation.msgId,
                    clientMutationId: mutation.clientMutationId,
                    emoji: mutation.emoji,
                    token: token
                )
            default:
                throw CloudAppModelError.localStoreUnavailable
            }

            try Task.checkCancellation()
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ), (try? await localStore.isDialogAccessRevoked(dialogId: mutation.dialogId)) == false
            else { return }
            try await localStore.applyMessageMutation(response)
            try await localStore.completeMessageMutation(clientMutationId: mutation.clientMutationId)
            if activeDialogId == mutation.dialogId { await loadLocalLines(dialogId: mutation.dialogId) }
            await refreshDialogs()
            setReplicaSyncState(.ready)
            status = response.duplicate ? "Change confirmed" : "Updated"
            scheduleSync()
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentSavedMessagesSession(
                accountId: accountId,
                token: token,
                store: localStore,
                generation: generation
            ), (try? await localStore.isDialogAccessRevoked(dialogId: mutation.dialogId)) == false
            else { return }
            if let apiError = error as? CloudAPIError, apiError.status == 409 {
                try? await localStore.completeMessageMutation(clientMutationId: mutation.clientMutationId)
                await runCoordinatedSync(trigger: .hint)
                if mutation.operation == "edit", let body = mutation.body {
                    draft = body
                    if let current = lines.first(where: { $0.msgId == mutation.msgId }) {
                        composerMode = .editing(messageId: current.id, original: current.text)
                    }
                }
                presentNotice(
                    "Message changed on another device",
                    message: mutation.operation == "edit"
                        ? "The latest message was loaded and your edit was restored. Review it and send again."
                        : "The latest message state has been loaded."
                )
                return
            }

            let featureIsAdvertised: Bool = switch mutation.operation {
            case "reaction": capabilities.contains(.reactions)
            default: capabilities.contains(.editing) || capabilities.contains(.deletion)
            }
            switch cloudOperationFailureDisposition(
                error, serverAdvertisesFeature: featureIsAdvertised
            ) {
            case let .transient(retryAfter):
                let delay = retryAfter ?? retryDelay(forRetryCount: mutation.retryCount + 1)
                try? await localStore.markMessageMutationFailed(
                    clientMutationId: mutation.clientMutationId,
                    error: error.localizedDescription,
                    retryAfter: delay,
                    terminal: false
                )
                publishTransportFailure(error)
                if activeDialogId == mutation.dialogId { await loadLocalLines(dialogId: mutation.dialogId) }
                scheduleOutboxRetry(after: delay)
            case .unsupportedServer:
                try? await localStore.completeMessageMutation(clientMutationId: mutation.clientMutationId)
                await refreshServerCapabilities()
                if activeDialogId == mutation.dialogId { await loadLocalLines(dialogId: mutation.dialogId) }
                presentNotice("Server upgrade required", message: "This server does not support that message action yet.")
            case .authenticationRequired:
                try? await localStore.completeMessageMutation(clientMutationId: mutation.clientMutationId)
                if activeDialogId == mutation.dialogId { await loadLocalLines(dialogId: mutation.dialogId) }
                presentNotice("Sign in again", message: "Your session ended before the message could be changed.")
            case .permanent:
                try? await localStore.completeMessageMutation(clientMutationId: mutation.clientMutationId)
                if activeDialogId == mutation.dialogId { await loadLocalLines(dialogId: mutation.dialogId) }
                presentNotice("Message was not changed", message: error.localizedDescription)
            }
        }
    }

    #if DEBUG
    func beginSessionTeardownForTesting() {
        isSessionTeardownInProgress = true
        accountSessionGeneration &+= 1
    }

    func enterDemoMode() {
        isDemoMode = true
        isSessionTeardownInProgress = false
        accountSessionGeneration &+= 1
        installAuthenticatedSession(StoredCloudSession(
            session: CloudSession(accountId: "debug-demo-account", deviceId: "debug-demo-device", token: "debug-demo-token"),
            phone: "+992 00 000 00 00",
            displayName: "Меҳмон"
        ))
        status = "Demo mode"
        launchPhase = .localReady
        profileDetails = Self.profileDetails(from: "Меҳмон")
        setReplicaSyncState(.ready)
        activeDialogId = nil
        draft = ""
        peerPhone = ""
        lines = []
        canLoadEarlier = false

        dialogs = [
            Dialog(id: "demo-mehrona", title: "Меҳрона", subtitle: "Шоми Душанбе", updatedAt: Self.demoTimestamp(minutesAgo: 2), isPending: false, unreadCount: 2, isPinned: true, mentionCount: 1, previewKind: .photo),
            Dialog(id: "demo-firooz", title: "Фирӯз", subtitle: "Документы получил, спасибо", updatedAt: Self.demoTimestamp(minutesAgo: 23), isPending: false, unreadCount: 4, isMuted: true, previewKind: .file),
            Dialog(id: "demo-madina", title: "Мадина", subtitle: "Дар роҳам", updatedAt: Self.demoTimestamp(minutesAgo: 1_480), isPending: false, unreadCount: 0, draftPreview: "Пас аз даҳ дақиқа…"),
            Dialog(id: "demo-aziz", title: "Азиз", subtitle: "Созвонимся вечером?", updatedAt: Self.demoTimestamp(minutesAgo: 2_920), isPending: false, unreadCount: 0, lastMessageMine: true),
        ]
        demoLinesByDialog = [
            "demo-mehrona": [
                demoLine(dialogId: "demo-mehrona", messageId: 1, text: "Салом! Пагоҳ вақт дорӣ?", mine: false, minutesAgo: 1_565),
                demoLine(dialogId: "demo-mehrona", messageId: 2, text: "Салом 👋 Бале, баъди соати ҳафт.", mine: true, minutesAgo: 1_562, delivery: .seen),
                demoLine(dialogId: "demo-mehrona", messageId: 3, text: "Агар хоҳӣ, дар маркази шаҳр вомехӯрем.", mine: true, minutesAgo: 1_561, delivery: .seen),
                Line(id: "demo-mehrona-4", dialogId: "demo-mehrona", msgId: 4, clientMsgId: "demo-mehrona-4", text: "Зӯр! То пагоҳ 🎉", mine: false, delivery: .sent, timestamp: Self.demoTimestamp(minutesAgo: 1_558), reactions: ["🔥"], myReaction: "🔥"),
                demoLine(dialogId: "demo-mehrona", messageId: 5, text: "Имрӯз соати чанд вомехӯрем?", mine: false, minutesAgo: 9),
                Line(id: "demo-mehrona-6", dialogId: "demo-mehrona", msgId: 6, clientMsgId: "demo-mehrona-6", text: "Соати ҳафт мешавад?", mine: true, delivery: .seen, timestamp: Self.demoTimestamp(minutesAgo: 7), replyToMsgId: 5, replyPreview: "Имрӯз соати чанд вомехӯрем?", reactions: ["❤️"]),
                demoLine(dialogId: "demo-mehrona", messageId: 7, text: "Олично. Тогда до вечера.", mine: false, minutesAgo: 4),
                Line(id: "demo-mehrona-8", dialogId: "demo-mehrona", msgId: 8, clientMsgId: "demo-mehrona-8", text: "Шоми Душанбе", mine: false, delivery: .sent, timestamp: Self.demoTimestamp(minutesAgo: 1), attachment: .photo(name: "Шоми Душанбе")),
            ],
            "demo-firooz": [
                demoLine(dialogId: "demo-firooz", messageId: 1, text: "Салом, файлҳоро фиристодам.", mine: true, minutesAgo: 31, delivery: .seen),
                demoLine(dialogId: "demo-firooz", messageId: 2, text: "Документы получил, спасибо", mine: false, minutesAgo: 23),
                Line(id: "demo-firooz-3", dialogId: "demo-firooz", msgId: 3, clientMsgId: "demo-firooz-3", text: "Toj product brief", mine: false, delivery: .sent, timestamp: Self.demoTimestamp(minutesAgo: 22), attachment: .file(name: "Toj-Brief.pdf", size: "2.4 MB")),
            ],
            "demo-madina": [
                demoLine(dialogId: "demo-madina", messageId: 1, text: "Кай мерасӣ?", mine: true, minutesAgo: 1_490, delivery: .seen),
                demoLine(dialogId: "demo-madina", messageId: 2, text: "Дар роҳам", mine: false, minutesAgo: 1_480),
            ],
            "demo-aziz": [
                demoLine(dialogId: "demo-aziz", messageId: 1, text: "Созвонимся вечером?", mine: false, minutesAgo: 2_920),
            ],
        ]
        demoLinesByDialog = demoLinesByDialog.mapValues(Self.applyingPresentation)
    }

    private func leaveDemoMode() {
        isDemoMode = false
        isSessionTeardownInProgress = true
        accountSessionGeneration &+= 1
        storedSession = nil
        activeDialogId = nil
        dialogs = []
        savedMessagesDialogId = nil
        savedMessagesSetupFailure = nil
        lines = []
        devices = []
        demoLinesByDialog = [:]
        requestedCode = false
        accountDeletionRequested = false
        accountDeletionCode = ""
        status = "Signed out"
        launchPhase = .signedOut
    }

    private func sendDemo(_ text: String, replyPreview: String? = nil, attachment: DemoAttachment? = nil) {
        guard let dialogId = activeDialogId else { return }
        openingTimelineAnchor = .bottom
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = true
        let lineId = UUID().uuidString
        let nextMessageId = (demoLinesByDialog[dialogId]?.compactMap(\.msgId).max() ?? 0) + 1
        let line = Line(
            id: lineId,
            dialogId: dialogId,
            msgId: nextMessageId,
            clientMsgId: lineId,
            text: text,
            mine: true,
            delivery: .sent,
            timestamp: Self.demoTimestamp(minutesAgo: 0),
            replyPreview: replyPreview,
            attachment: attachment
        )
        demoLinesByDialog[dialogId, default: []].append(line)
        demoLinesByDialog[dialogId] = Self.applyingPresentation(demoLinesByDialog[dialogId] ?? [])
        lines = demoLinesByDialog[dialogId] ?? []
        dialogs = dialogs.map { dialog in
            guard dialog.id == dialogId else { return dialog }
            var updated = dialog
            updated.subtitle = text
            updated.updatedAt = Self.demoTimestamp(minutesAgo: 0)
            updated.isPending = false
            updated.unreadCount = 0
            updated.draftPreview = nil
            updated.previewKind = attachment?.chatListPreviewKind ?? .text
            updated.lastMessageMine = true
            return updated
        }

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, self.isDemoMode, self.activeDialogId == dialogId else { return }
            if let index = self.lines.firstIndex(where: { $0.id == lineId }) {
                self.lines[index].delivery = .seen
                self.demoLinesByDialog[dialogId] = self.lines
            }
        }
    }

    func reactToDemoMessage(_ lineId: String, reaction: String = "❤️") {
        guard isDemoMode, let dialogId = activeDialogId,
              let index = lines.firstIndex(where: { $0.id == lineId }) else { return }
        if lines[index].reactions.contains(reaction) {
            lines[index].reactions.removeAll(where: { $0 == reaction })
        } else {
            lines[index].reactions.append(reaction)
        }
        demoLinesByDialog[dialogId] = lines
    }

    func deleteDemoMessage(_ lineId: String) {
        guard isDemoMode, let dialogId = activeDialogId else { return }
        lines.removeAll(where: { $0.id == lineId })
        lines = Self.applyingPresentation(lines)
        demoLinesByDialog[dialogId] = lines
    }

    func sendDemoAttachment(_ attachment: DemoAttachment, caption: String = "") {
        guard isDemoMode else { return }
        sendDemo(caption.isEmpty ? attachment.title : caption, attachment: attachment)
        composerMode = .text
    }

    func beginDemoRecording() {
        guard isDemoMode, capabilities.contains(.voiceNotes) else { return }
        composerMode = .recording(elapsedSeconds: 0)
    }

    func finishDemoRecording() {
        guard isDemoMode else { return }
        sendDemo(String(localized: "Voice message"), attachment: .voice(duration: "0:08"))
        composerMode = .text
    }

    private func updateDemoMessage(messageId: String, text: String) {
        guard let dialogId = activeDialogId,
              let index = lines.firstIndex(where: { $0.id == messageId }) else { return }
        lines[index].text = text
        lines[index].isEdited = true
        lines = Self.applyingPresentation(lines)
        demoLinesByDialog[dialogId] = lines
    }

    private func demoLine(
        dialogId: String,
        messageId: Int64,
        text: String,
        mine: Bool,
        minutesAgo: Int,
        delivery: Line.Delivery = .sent
    ) -> Line {
        Line(
            id: "\(dialogId)-\(messageId)",
            dialogId: dialogId,
            msgId: messageId,
            clientMsgId: "\(dialogId)-\(messageId)",
            text: text,
            mine: mine,
            delivery: delivery,
            timestamp: Self.demoTimestamp(minutesAgo: minutesAgo)
        )
    }

    private static func demoTimestamp(minutesAgo: Int) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval(-minutesAgo * 60)))
    }

    private static func applyingPresentation(_ source: [Line]) -> [Line] {
        var result = source
        let inputs = source.map {
            TimelinePresentationInput(
                id: $0.id,
                mine: $0.mine,
                senderId: $0.senderAccountId,
                timestamp: $0.timestamp
            )
        }
        let metadata = Dictionary(uniqueKeysWithValues: TimelinePresentationBuilder.build(inputs).map {
            ($0.id, $0)
        })
        for index in result.indices {
            guard let value = metadata[result[index].id] else { continue }
            result[index].presentationDayLabel = value.dayLabel
            result[index].presentationTimestampLabel = value.timestampLabel
            result[index].presentationMediaTimestampLabel = value.mediaTimestampLabel
            result[index].presentationIsFirstInGroup = value.isFirstInGroup
            result[index].presentationIsLastInGroup = value.isLastInGroup
        }
        return result
    }

    private func demoMediaBytes(for media: CloudMedia, thumbnail: Bool) -> Data? {
        guard media.kind == "photo" || thumbnail else { return nil }

        let side: CGFloat = thumbnail ? 320 : 1_200
        let size = CGSize(width: side, height: side * 0.72)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let bounds = CGRect(origin: .zero, size: size)
            UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1).setFill()
            context.fill(bounds)

            let accent = UIColor(red: 0.84, green: 0.66, blue: 0.21, alpha: 1)
            accent.withAlphaComponent(0.18).setFill()
            context.cgContext.fillEllipse(in: bounds.insetBy(dx: side * 0.16, dy: side * 0.05))

            let symbolName = media.kind == "video" ? "play.fill" : "photo.fill"
            let configuration = UIImage.SymbolConfiguration(pointSize: side * 0.14, weight: .medium)
            let symbol = UIImage(systemName: symbolName, withConfiguration: configuration)?
                .withTintColor(accent, renderingMode: .alwaysOriginal)
            symbol?.draw(at: CGPoint(x: bounds.midX - side * 0.07, y: bounds.midY - side * 0.07))
        }
        return image.jpegData(compressionQuality: thumbnail ? 0.72 : 0.88)
    }
    #endif

    #if !DEBUG
    func reactToDemoMessage(_ lineId: String, reaction: String = "❤️") {}
    func deleteDemoMessage(_ lineId: String) {}
    func sendDemoAttachment(_ attachment: DemoAttachment, caption: String = "") {}
    func beginDemoRecording() {}
    func finishDemoRecording() {}
    #endif
}

private actor CloudLocalStoreBootstrapper {
    private var store: CloudLocalStore?

    func openDefaultStore() throws -> CloudLocalStore {
        if let store { return store }
        let opened = try CloudLocalStore.default()
        store = opened
        return opened
    }

    func quarantineAndOpenDefaultStore() throws -> CloudLocalStore {
        _ = try CloudLocalStore.quarantineDefaultStore()
        let opened = try CloudLocalStore.default()
        store = opened
        return opened
    }

    func destroyDefaultStore() throws {
        store = nil
        try CloudLocalStore.destroyDefaultStore()
    }

    /// Verifies explicit logout at the filesystem boundary even if cache cleanup encountered a
    /// partially initialized index. Only Toj-owned cache, profile-photo, resume, and preview paths
    /// are touched; this runs before the shared SQLCipher/profile-photo key is destroyed.
    func destroyDefaultMediaState() throws {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let tojSupport = support.appending(path: "Toj", directoryHint: .isDirectory)
        let urls = [
            tojSupport.appending(path: "media", directoryHint: .isDirectory),
            tojSupport.appending(path: "background-media-jobs.json"),
            fileManager.temporaryDirectory.appending(
                path: "TojMediaPreviews",
                directoryHint: .isDirectory
            ),
        ]
        var firstError: Error?
        do {
            try EncryptedProfilePhotoStore.destroyAllSynchronously()
        } catch {
            firstError = error
        }
        for url in urls where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}

private enum CloudAppModelError: LocalizedError {
    case bootstrapRequired
    case localStoreUnavailable
    case invalidBootstrapCursor
    case invalidMedia
    case invalidGroupMutation
    case tooManyDraftAttachments
    case mediaGroupsUnavailable

    var errorDescription: String? {
        switch self {
        case .bootstrapRequired:
            return "Bootstrap required"
        case .localStoreUnavailable:
            return "Encrypted local database is unavailable"
        case .invalidBootstrapCursor:
            return "Server returned an incomplete bootstrap page"
        case .invalidMedia:
            return "The selected media could not be prepared"
        case .invalidGroupMutation:
            return "The saved group change is invalid"
        case .tooManyDraftAttachments:
            return "A draft can contain at most 10 attachments"
        case .mediaGroupsUnavailable:
            return "This server cannot send multiple attachments as one group yet"
        }
    }
}
