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

nonisolated enum ReplicaStateProbeOutcome: Sendable {
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

    struct DraftMention: Equatable, Sendable {
        let accountId: String
        let token: String
    }

    struct GroupMutationPayload: Codable, Sendable {
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

    var storedSession: StoredCloudSession? {
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
    var launchPhase: LaunchPhase = .restoringLocal
    var status = "Starting"
    var operationNotice: Notice?
    var connectionViewState: ReplicaConnectionState = .connecting
    var replicaSyncState: ReplicaSyncState = .checking
    var replicaConnectivityState: ReplicaConnectivityState = .unknown
    var replicaUpdatePhase: ReplicaUpdatePhase = .idle
    var lastSuccessfulServerContact: Date?
    var requestedCode = false
    /// How the user wants their code delivered. They choose; the server never substitutes, so a tap
    /// here is the consent — which is why a picker is safe where a server-side fallback was not.
    enum OTPChannel: String, CaseIterable, Identifiable, Sendable {
        case whatsapp, telegram, sms
        var id: String { rawValue }

        /// Cost-ascending. A free choice does not optimise spend on its own, so the cheap channels
        /// are simply the obvious ones: SMS costs ~20-60x either alternative and is the only one
        /// that reaches everybody, so it belongs last rather than removed.
        static let displayOrder: [OTPChannel] = [.whatsapp, .telegram, .sms]

        var capabilityName: String { "otp_channel_\(rawValue)" }

        var title: String {
            switch self {
            case .whatsapp: "WhatsApp"
            case .telegram: "Telegram"
            case .sms: "SMS"
            }
        }
    }

    /// Only what the server says it can actually send on, so the picker never offers a dead button.
    private(set) var availableOTPChannels: [OTPChannel] = []
    var selectedOTPChannel: OTPChannel?

    /// Cheapest-first, and never a channel the server did not advertise.
    var orderedOTPChannels: [OTPChannel] {
        OTPChannel.displayOrder.filter { availableOTPChannels.contains($0) }
    }

    func applyOTPChannels(_ capabilities: [String]) {
        let advertised = OTPChannel.allCases.filter { capabilities.contains($0.capabilityName) }
        availableOTPChannels = advertised
        if let selected = selectedOTPChannel, advertised.contains(selected) { return }
        selectedOTPChannel = OTPChannel.displayOrder.first { advertised.contains($0) }
    }
    var authRequestInFlight = false
    var authVerifyInFlight = false
    var twoFactorChallengeId: String?
    var recoveredTwoFactorCodes: [String] = []
    var twoFactorEnabled = false
    var twoFactorRecoveryCodesRemaining = 0
    var securityChangeInFlight = false
    var securityStepUpToken: String?
    var requiresDifferentAccountCleanupConfirmation = false
    var resendSeconds = 0
    /// The OTP request budget answers an exhausted quota with a full day; counting that down one
    /// second at a time would park the resend button for 24 hours instead of letting the user ask
    /// again and see the real answer.
    static let maxResendCountdownSeconds = 3600
    /// The unit choice lives here so it stays testable; the view keeps both literal interpolations
    /// so the string catalog can continue to extract and translate them.
    enum ResendCountdown: Equatable { case seconds(Int), minutes(Int) }
    var resendCountdown: ResendCountdown {
        resendSeconds >= 60 ? .minutes((resendSeconds + 59) / 60) : .seconds(resendSeconds)
    }
    var activeDialogId: String?
    var pendingDeepLinkDialogId: String?
    var conversationOpenState: ConversationOpenState = .loadingLocal
    var dialogs: [Dialog] = []
    var chatFolders: [CloudChatFolder] = []
    var chatFolderCollectionRevision: Int64 = 0
    var scheduledDeliveries: [CloudScheduledDelivery] = []
    var savedMessagesDialogId: String?
    var savedMessagesSetupInFlight = false
    var savedMessagesSetupFailure: String?
    var savedMessagesCapabilityState: SavedMessagesCapabilityState = .unknown
    var groupMembersByDialog: [String: [GroupMember]] = [:]
    var groupPermissionsByDialog: [String: GroupPermissions] = [:]
    var lines: [Line] = []
    var openingTimelineAnchor: TimelineAnchor = .bottom
    var canLoadEarlier = false
    var loadingEarlier = false
    var canLoadLater = false
    var loadingLater = false
    var devices: [CloudDevice] = []
    var loadingDevices = false
    var accountDeletionRequested = false
    var accountDeletionInFlight = false
    var mediaCacheBytes: Int64 = 0
    var mediaAutoDownloadPolicy: MediaAutoDownloadPolicy = .default
    var mediaCachePolicy: MediaCachePolicy = .default
    var clearingMediaCache = false
    var composerMode: ComposerMode = .text
    var currentDraft: LocalDraft?
    var profileDetails: StoredProfileDetails = .empty
    var profileSaveInFlight = false
    var profilePhotoSyncState: ProfilePhotoSyncState = .localOnly
    var profilePhotoDisplayData: Data?
    var canonicalProfilePhoto: CloudMedia?
    var profilePhotoRevision: Int64 = 0
    #if DEBUG
    var isDemoMode = false
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

    var draftMentionsByDialog: [String: [DraftMention]] = [:]

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

    let api: CloudAPI
    let savedMessagesService = SavedMessagesService()
    let tokenStore: TokenStore
    var localStore: CloudLocalStore?

    /// Owns the search index's lifecycle. Deliberately a separate actor rather than more methods
    /// here: none of it needs the main actor, and this type is large enough.
    ///
    /// Scoped to an account *and* a store instance, so recovering a quarantined replica — which
    /// produces a new store for the same account — replaces the coordinator rather than letting the
    /// old one keep writing to a database nobody is reading.
    var searchCoordinator: SearchCoordinator?

    /// The store the search screen queries. Exposed rather than routing every search through this
    /// type, which is large enough already.
    var searchStore: CloudLocalStore? { localStore }
    let localStoreBootstrapper = CloudLocalStoreBootstrapper()
    let opensDefaultLocalStore: Bool
    let pushCenter: PushRegistrationCenter
    let voipPushCenter: VoIPPushRegistrationCenter
    let mediaEngine: CloudMediaTransferEngine
    let accessPurgeCoordinator = AccessPurgeCoordinator()
    let capabilityDefaults: UserDefaults
    let capabilityCacheKey: String
    var negotiatedCapabilities: MessagingCapabilities
    @ObservationIgnored lazy var mediaPrefetchScheduler = MediaPrefetchScheduler { [weak self] lane in
        guard let self else { return false }
        return await self.processOneMediaDownload(component: lane.component)
    }
    @ObservationIgnored lazy var replicaSyncCoordinator = ReplicaSyncCoordinator { [weak self] generation in
        guard let self else { return }
        await self.runForegroundSyncAttempt(generation: generation)
        self.settleReplicaSyncStateAfterAttempt()
    }
    @ObservationIgnored lazy var draftSyncCoordinator = DraftSyncCoordinator(api: api)
    @ObservationIgnored lazy var dialogPreferencesCoordinator =
        DialogPreferencesCoordinator(api: api)
    @ObservationIgnored let productivitySyncCoordinator =
        CloudProductivitySyncCoordinator()
    @ObservationIgnored lazy var profilePhotoSyncCoordinator =
        ProfilePhotoSyncCoordinator(api: api, mediaEngine: mediaEngine)
    let voiceRecorder = VoiceNoteRecorder()
    var pts: Int64 = 0
    var hintSocket: CloudHintSocket?
    var hintSocketToken: String?
    var hintTask: Task<Void, Never>?
    var networkObservationTask: Task<Void, Never>?
    var offlinePaintTask: Task<Void, Never>?
    var memoryPressureTask: Task<Void, Never>?
    var retryTask: Task<Void, Never>?
    var resendTask: Task<Void, Never>?
    var recordingTask: Task<Void, Never>?
    var composerMediaTask: Task<Void, Never>?
    var profileSyncTask: Task<Void, Never>?
    var profileSaveTasks: [UUID: Task<Bool, Never>] = [:]
    var productivityTerminalAcknowledgementTask: (id: UUID, task: Task<Void, Never>)?
    var pendingProductivityTerminalNotice: (
        noticeId: UUID,
        failure: CloudProductivityTerminalError
    )?
    var profilePhotoMigrationTask: Task<Void, Never>?
    var postSignInTask: Task<Void, Never>?
    var postSyncWorkTask: Task<Void, Never>?
    var historyHydrationTask: Task<Void, Never>?
    var openingAnchorHydrationTask: Task<Void, Never>?
    var dialogObservationTask: Task<Void, Never>?
    var draftObservationTask: Task<Void, Never>?
    var draftPersistenceTasks: [String: Task<Void, Never>] = [:]
    var timelineObservationTask: Task<Void, Never>?
    var viewportPersistenceTask: Task<Void, Never>?
    var mediaDownloadTask: Task<Void, Never>?
    var readReceiptRetryTask: Task<Void, Never>?
    var replicaIntegrityTask: Task<Void, Never>?
    var localRestoreTask: Task<Void, Never>?
    private var credentialUpdateTask: Task<Void, Never>?
    var credentialRefreshLoopTask: Task<Void, Never>?
    var expiredSessionAccountId: String?
    var pendingDifferentAccountAuthentication: (
        session: CloudSession,
        phone: String,
        displayName: String
    )?
    var localRestoreCompleted = false
    var backgroundMediaRuntimePrepared = false
    var mediaSchedulerForegrounded = false
    var composerMediaOperationId: UUID?
    var composerMediaDialogId: String?
    var activeComposerTransferId: String?
    var temporaryPreviewURLsByDialog: [String: Set<URL>] = [:]
    var dialogPresentationGenerations: [String: UInt64] = [:]
    var mediaTransferTasks: [String: Task<Void, Never>] = [:]
    var mediaTransferDialogIds: [String: String] = [:]
    var preferenceMutationTasks: [UUID: Task<Void, Never>] = [:]
    var accountSessionGeneration: UInt64 = 1
    var isSessionTeardownInProgress = false
    var syncInFlight = false
    var syncAgain = false
    var retryInFlight = false
    var outboxDrainHalted = false
    var mediaTransfersInFlight: Set<String> = []
    var mediaGroupSendsInFlight: Set<String> = []
    var draftSendsInFlightByDialog: [String: String] = [:]
    var messageMutationsInFlight: Set<String> = []
    var mutationTargetsBeingQueued: Set<String> = []
    var uploadedPushRegistration: String?
    var uploadedVoIPPushRegistration: String?
    var uploadedGroupCallCapabilityRegistration: String?
    var historyHasMoreByDialog: [String: Bool] = [:]
    var draftPersistenceGenerations: [String: UInt64] = [:]
    var minimumObservedDraftGenerations: [String: Int64] = [:]
    var sessionEpoch: UInt64 = 0
    var sessionTearingDown = false
    var suppressDraftPersistence = false
    var transientUnderlyingDraftText: String?
    var transientUnderlyingComposerMode: ComposerMode?
    var transientVoiceComposerMode: ComposerMode?
    var cachedLinesByDialog: [String: [Line]] = [:]
    var cachedLocalMessagesByDialog: [String: [LocalMessage]] = [:]
    var cachedLineDialogOrder: [String] = []
    var cachedConversationCostByDialog: [String: Int] = [:]
    var conversationOpenWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    var conversationOpenStartedAt: [String: Date] = [:]
    var loadedLocalMessages: [LocalMessage] = []
    var timelineTopVisibleMsgId: Int64?
    var timelineIsAtBottom = true
    var pendingVisibleReadMessages: [LocalMessage] = []
    /// Message the timeline should open on and briefly flash, set when a search result is tapped.
    ///
    /// Cleared once the flash finishes so returning to the same conversation later does not replay
    /// it — a highlight that reappears without a search behind it reads as a bug.
    var focusedSearchMsgId: Int64?

    /// In-chat find state. `nil` when the bar is closed.
    var inChatSearch: InChatSearchState?
    var inChatSearchTask: Task<Void, Never>?
    var inChatSearchGeneration: UInt64 = 0

    var timelineBeforeCount = 40
    var timelineAfterCount = 79
    var dialogSelectionGeneration: UInt64 = 0
    var timelineLoadGeneration: UInt64 = 0
    var openingAnchorHydrationGeneration: UInt64 = 0
    var openPrefetchGeneration: UInt64 = 0
    var savedMessagesSessionGeneration: UInt64 = 0
    var sessionTeardownActive = false
    struct TrackedSavedOperation {
        let cancel: () -> Void
        let wait: () async -> Void
    }
    struct SessionClearBarrier {
        let id: UUID
        var waiters: [CheckedContinuation<Bool, Never>]
    }
    var trackedSavedOperations: [UUID: TrackedSavedOperation] = [:]
    var sessionClearBarrier: SessionClearBarrier?
    var appliedSyncBatches = 0
    var lastForegroundSyncFailure: ReplicaSyncState?
    var timelineForwardCursorByDialog: [String: Int64] = [:]
    var timelineHasMoreForwardByDialog: [String: Bool] = [:]
    var readReceiptDrainRequested = false
    #if DEBUG
    var demoLinesByDialog: [String: [Line]] = [:]
    var temporaryPreviewAuthorizationGate: (@Sendable (URL) async -> Void)?
    var mediaAccessRestoreAuthorizationGate: (@Sendable () async -> Void)?
    var mediaAccessPostRestoreValidationGate: (@Sendable () async -> Void)?
    #endif

    /// Consumed by the next `beginConversationSelection`, then cleared.
    var pendingFocusMsgId: Int64?

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

    func installAuthenticatedSession(_ session: StoredCloudSession) {
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
}

actor CloudLocalStoreBootstrapper {
    var store: CloudLocalStore?

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

enum CloudAppModelError: LocalizedError {
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
