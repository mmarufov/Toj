import AVFoundation
import CallKit
import Foundation
import Observation
import UIKit

nonisolated enum CallServerEndReasonPolicy {
    static func resolve(_ raw: String?) -> CallEndReason {
        switch raw {
        case "declined": .declined
        case "cancelled", "caller_cancelled": .cancelled
        case "busy": .busy
        case "unanswered", "expired": .unanswered
        case "answered_elsewhere": .answeredElsewhere
        case "network_lost": .networkLost
        case "security_error": .securityError
        default: .remoteEnded
        }
    }
}

nonisolated enum CallLifecycleProjectionPolicy {
    static func terminalReason(
        view: CloudCallViewKind?,
        state: String,
        endReason: String?
    ) -> CallEndReason? {
        guard view == .lifecycle, state == "ended" else { return nil }
        return CallServerEndReasonPolicy.resolve(endReason)
    }
}

nonisolated enum CallSignalDescriptionPolicy {
    static func accepts(kind: CallSignalKind, descriptionType: CallSDPType) -> Bool {
        switch kind {
        case .offer, .iceRestart:
            descriptionType == .offer
        case .answer:
            descriptionType == .answer
        case .iceCandidate, .hangup, .control:
            false
        }
    }
}

@MainActor
@Observable
final class CallCoordinator {
    static let shared = CallCoordinator()

    private(set) var state: CallState = .idle
    private(set) var direction: CallDirection?
    private(set) var endReason: CallEndReason?
    private(set) var activeCallId: UUID?
    private(set) var peerName = String(localized: "Toj caller")
    private(set) var isMuted = false
    private(set) var isSpeakerEnabled = false
    private(set) var audioRouteName = String(localized: "iPhone")
    private(set) var securityEmojis: [String] = []
    private(set) var securityVerified = false
    private(set) var connectedAt: Date?
    private(set) var failureMessage: String?
    private(set) var initialKind: CallInitialKind = .voice
    private(set) var selectedMediaProfile: UInt16?
    private(set) var isCameraEnabled = false
    private(set) var localVideoState: CallVideoEffectiveState = .inactive
    private(set) var remoteVideoState: CallVideoEffectiveState = .inactive
    private(set) var remoteVideoPauseReason: CallVideoGenericPauseReason?
    private(set) var localVideoRenderer: CallVideoRendererHandle?
    private(set) var remoteVideoRenderer: CallVideoRendererHandle?
    private(set) var pictureInPictureVideoRenderer: CallVideoRendererHandle?
    private(set) var remoteVideoTrackAvailable = false
    private(set) var videoQualityTier: CallVideoQualityTier = .high
    private(set) var videoIsAutomaticallyPaused = false
    private(set) var hasVideoExperience = false
    var activeDialogId: String? { runtime?.dialogId }
    var isPresented = false

    var hasCall: Bool { state != .idle }
    var canVerifySecurity: Bool { securityEmojis.count == 4 && state == .active }
    var isVideoMediaAvailable: Bool {
        selectedMediaProfile == CallMediaProfileVersion.cameraVideo
    }
    var isUsingFrontCamera: Bool { preferredCameraPosition == .front }
    var cameraNeedsSettings: Bool {
        permissions.cameraPermission == .denied || permissions.cameraPermission == .restricted
    }
    var canOfferAudioFallback: Bool { state == .ended && audioFallback != nil }

    @ObservationIgnored private var machine = CallStateMachine()
    @ObservationIgnored private let callKit: any CallKitControlling
    @ObservationIgnored private let preferences: CallPrivacyPreferences
    @ObservationIgnored private let engineFactory: @MainActor @Sendable () -> any WebRTCEngine
    @ObservationIgnored private let permissions: any CallPermissionProviding
    @ObservationIgnored private let sceneLifecycle: any CallSceneLifecycleProviding
    @ObservationIgnored private let networkPath: any CallNetworkPathProviding
    @ObservationIgnored private let clock: any CallClock
    @ObservationIgnored private var api: (any CallAPITransport)?
    @ObservationIgnored private var session: CloudSession?
    @ObservationIgnored private var peerNameProvider: ((String, String) -> String)?
    @ObservationIgnored private var runtime: Runtime?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var engineTask: Task<Void, Never>?
    @ObservationIgnored private var candidateFlushTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var ringDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var keyExchangeDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var connectionDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var turnRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var reportedIncomingCallIds: Set<UUID> = []
    @ObservationIgnored private var deferredGlareInvitations: [UUID: VoIPPushInvitation] = [:]
    @ObservationIgnored private var reconcileTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var reconcileTaskTokens: [UUID: UUID] = [:]
    @ObservationIgnored private var reconcilesPending: Set<UUID> = []
    @ObservationIgnored private var callKitAudioActive = false
    @ObservationIgnored private var videoReducer = CallVideoStateReducer()
    @ObservationIgnored private var videoQuality = CallVideoQualityReducer()
    @ObservationIgnored let pictureInPicture = TojVideoPictureInPictureController()
    @ObservationIgnored private var qualityTask: Task<Void, Never>?
    @ObservationIgnored private var userSelectedAudioRoute = false
    @ObservationIgnored private var preferredCameraPosition: CallCameraPosition = .front
    @ObservationIgnored private var audioFallback: AudioFallback?

    private struct AudioFallback {
        let dialogId: String
        let peerAccountId: String
        let displayName: String
    }

    nonisolated struct CallWirePayload: Codable, Sendable {
        let description: CallSessionDescription?
        let candidate: CallICECandidate?
        let control: CallControlAction?
        let mediaState: CallMediaStateUpdateV1?

        init(
            description: CallSessionDescription?,
            candidate: CallICECandidate?,
            control: CallControlAction? = nil,
            mediaState: CallMediaStateUpdateV1? = nil
        ) {
            self.description = description
            self.candidate = candidate
            self.control = control
            self.mediaState = mediaState
        }
    }

    nonisolated enum CallControlAction: String, Codable, Sendable {
        case requestICERestart = "request_ice_restart"
    }

    struct DecryptedSignal {
        let kind: CallSignalKind
        let payload: CallWirePayload
    }

    final class Runtime {
        let id: UUID
        let direction: CallDirection
        let privacyMode: CallPrivacyMode
        let initialKind: CallInitialKind
        var dialogId: String
        var peerAccountId: String
        var snapshot: CloudCallSnapshot?
        var engine: (any WebRTCEngine)?
        var keyPair: CallEphemeralKeyPair?
        var localMaterial: CallKeyMaterialV1?
        var context: CallHandshakeContextV1?
        var callerCommitment: Data?
        var calleeCommitment: Data?
        var cipher: CallCipherSession?
        var processedEventSequence: Int64 = 0
        var localRevealSent = false
        var localConfirmationSent = false
        var calleeConfirmation: Data?
        var callerConfirmation: Data?
        var pendingCandidates: [CallICECandidate] = []
        var pendingRemoteCandidates: [CallICECandidate] = []
        var decryptedSignals: [Int64: DecryptedSignal] = [:]
        var mediaStarted = false
        var signalingReadyForCandidates = false
        var remoteDescriptionInstalled = false
        var selectedMediaProfile: UInt16?
        var mediaProfileConfigured = false
        var localNextMediaRevision: UInt64 = 1
        var remoteHighestMediaRevision: UInt64 = 0
        var peerMaximumReceiveTier: CallVideoQualityTier = .high
        var lastSentMediaState: CallMediaStateUpdateV1?
        var lastNetworkPath: ReplicaNetworkSnapshot?
        var lastMaximumVideoFramesPerSecond: Int?
        var cameraGeneration: UInt64 = 0
        var cameraApplyGeneration: UInt64 = 0
        var owningSceneIdentifier: String?
        var iceRestartInFlight = false
        let signalOutbox = OrderedCallSignalOutbox()

        // Telemetry accounting. All values feed pinned buckets; none are ever persisted or logged raw.
        var answeredAt: Date?
        var recoveryStartedAt: Date?
        var recoveryCount = 0
        var maxRecoverySeconds: Double?
        var telemetryReported = false
        var role: CallRole { direction == .outgoing ? .caller : .callee }

        init(
            id: UUID,
            direction: CallDirection,
            privacyMode: CallPrivacyMode,
            initialKind: CallInitialKind,
            dialogId: String,
            peerAccountId: String
        ) {
            self.id = id
            self.direction = direction
            self.privacyMode = privacyMode
            self.initialKind = initialKind
            self.dialogId = dialogId
            self.peerAccountId = peerAccountId
        }
    }

    init(
        callKit: any CallKitControlling = CallKitAdapter.shared,
        preferences: CallPrivacyPreferences = .shared,
        permissions: any CallPermissionProviding = SystemCallPermissionProvider(),
        sceneLifecycle: any CallSceneLifecycleProviding = SystemCallSceneLifecycleProvider(),
        networkPath: any CallNetworkPathProviding = ReplicaNetworkMonitor.shared,
        clock: any CallClock = SystemCallClock(),
        engineFactory: @escaping @MainActor @Sendable () -> any WebRTCEngine = { WebRTCEngineFactory.production() }
    ) {
        self.callKit = callKit
        self.preferences = preferences
        self.permissions = permissions
        self.sceneLifecycle = sceneLifecycle
        self.networkPath = networkPath
        self.clock = clock
        self.engineFactory = engineFactory

        callKit.onStart = { [weak self] id in Task { await self?.beginOutgoing(id) } }
        callKit.onAnswer = { [weak self] id in
            guard let self else { return false }
            return await self.answerIncoming(id)
        }
        callKit.onEnd = { [weak self] id in Task { await self?.handleSystemEnd(id) } }
        callKit.onMuteChanged = { [weak self] id, muted in
            Task { await self?.setMutedFromSystem(id: id, muted: muted) }
        }
        callKit.onAudioActivated = { [weak self] in
            self?.callKitAudioActive = true
            guard let engine = self?.runtime?.engine else { return }
            Task { await engine.setAudioSessionActive(true) }
        }
        callKit.onAudioDeactivated = { [weak self] in
            self?.callKitAudioActive = false
            guard let engine = self?.runtime?.engine else { return }
            Task { await engine.setAudioSessionActive(false) }
        }
        callKit.onReset = { [weak self] in Task { await self?.terminate(.failed, reportCallKit: false) } }
        callKit.callAudioSession.onRouteChanged = { [weak self] in self?.refreshAudioRoute() }
        callKit.callAudioSession.onMediaServicesReset = { [weak self] in
            guard let self, self.callKitAudioActive, let engine = self.runtime?.engine else { return }
            Task {
                await engine.setAudioSessionActive(true)
                await self.recoverMediaIfNeeded()
            }
        }
    }

    func configure(
        api: any CallAPITransport,
        session: CloudSession,
        peerNameProvider: @escaping (String, String) -> String
    ) {
        self.api = api
        self.session = session
        self.peerNameProvider = peerNameProvider
        Task { await reconcileActiveCalls() }
    }

    func unbind() {
        let api = self.api
        let session = self.session
        let callId = activeCallId
        self.api = nil
        self.session = nil
        peerNameProvider = nil
        Task {
            await terminate(.cancelled, reportCallKit: true)
            if let api, let session, let callId {
                _ = try? await api.endCall(
                    id: callId.uuidString.lowercased(),
                    reason: "session_ended",
                    token: session.token
                )
            }
        }
    }

    func startOutgoing(
        dialogId: String,
        peerAccountId: String,
        displayName: String,
        initialKind: CallInitialKind = .voice
    ) async {
        guard api != nil, let session, state == .idle || state == .ended else { return }
        if state == .ended { reset() }
        audioFallback = nil
        let microphoneIsAllowed = await microphoneAllowed()
        guard self.session == session, api != nil else { return }
        guard microphoneIsAllowed else {
            try? transition(.startOutgoing)
            peerName = displayName
            isPresented = true
            failureMessage = String(localized: "Microphone access is required for voice calls.")
            await terminate(.permissionDenied, reportCallKit: false)
            return
        }
        if initialKind == .video {
            guard WebRTCEngineFactory.supportsCameraVideoProfile else {
                await presentVideoPreflightFailure(
                    String(localized: "Video calling is unavailable on this build. You can still place an audio call."),
                    reason: .failed,
                    dialogId: dialogId,
                    peerAccountId: peerAccountId,
                    displayName: displayName
                )
                return
            }
            guard await cameraAllowedForOutgoing() else {
                await presentVideoPreflightFailure(
                    String(localized: "Camera access is required to start a video call. You can still place an audio call."),
                    reason: .permissionDenied,
                    dialogId: dialogId,
                    peerAccountId: peerAccountId,
                    displayName: displayName
                )
                return
            }
        }

        do {
            try transition(.startOutgoing)
            isPresented = true
            peerName = displayName
            failureMessage = nil
            self.initialKind = initialKind
            hasVideoExperience = initialKind == .video
            isCameraEnabled = initialKind == .video

            let id = UUID()
            let engine = engineFactory()
            let mediaIdentity = try await engine.prepareLocalIdentity()
            guard
                self.session == session,
                api != nil,
                state == .preparing,
                runtime == nil
            else {
                await engine.stop()
                return
            }
            let pair = CallEphemeralKeyPair()
            let material = try CallCrypto.keyMaterial(
                keyPair: pair,
                dtlsFingerprintSHA256: mediaIdentity.dtlsFingerprintSHA256
            )
            let context = CallHandshakeContextV1(
                identity: CallIdentity(
                    callId: id.uuidString.lowercased(),
                    dialogId: dialogId,
                    caller: CallParty(accountId: session.accountId, deviceId: session.deviceId),
                    calleeAccountId: peerAccountId
                ),
                offeredProtocolVersions: CallProtocolVersion.supported,
                offeredMediaProfileVersions: initialKind == .video
                    ? [CallMediaProfileVersion.cameraVideo]
                    : WebRTCEngineFactory.deviceCapabilities.supportedCallMediaProfileVersions
            )
            let commitment = try CallProtocolV1.callerCommitment(context: context, material: material)
            let runtime = Runtime(
                id: id,
                direction: .outgoing,
                privacyMode: preferences.mode,
                initialKind: initialKind,
                dialogId: dialogId,
                peerAccountId: peerAccountId
            )
            runtime.engine = engine
            runtime.keyPair = pair
            runtime.localMaterial = material
            runtime.context = context
            runtime.callerCommitment = commitment
            runtime.cameraGeneration = videoReducer.beginRuntime(
                initialCameraIntent: initialKind == .video
            )
            self.runtime = runtime
            activeCallId = id
            startEngineEvents(engine, runtime: runtime)
            try await callKit.requestOutgoing(
                callId: id,
                peerAccountId: peerAccountId,
                displayName: displayName,
                initialKind: initialKind
            )
            guard self.session == session, self.runtime === runtime else {
                try? await callKit.requestEnd(callId: id)
                await engine.stop()
                return
            }
        } catch {
            failureMessage = friendly(error)
            await terminate(.failed, reportCallKit: true)
        }
    }

    /// Called directly from PushKit. Reporting CallKit is completed before any server fetch.
    func receiveVoIPPush(_ invitation: VoIPPushInvitation) async {
        if reportedIncomingCallIds.contains(invitation.callId) {
            Task { await reconcile(callId: invitation.callId) }
            return
        }
        if state == .ended { reset() }
        if let expiresAt = invitation.expiresAt, expiresAt <= clock.now {
            reportedIncomingCallIds.insert(invitation.callId)
            do {
                try await callKit.reportIncoming(
                    callId: invitation.callId,
                    callerAccountId: invitation.callerAccountId,
                    displayName: String(localized: "Toj caller"),
                    initialKind: invitation.initialKind
                )
                callKit.reportEnded(callId: invitation.callId, reason: .unanswered)
            } catch {}
            return
        }
        if let activeCallId, activeCallId != invitation.callId {
            if let runtime, CallGlarePolicy.pushDisposition(
                activeCallId: activeCallId,
                incomingCallId: invitation.callId,
                activeDirection: runtime.direction,
                activePeerAccountId: runtime.peerAccountId,
                incomingCallerAccountId: invitation.callerAccountId,
                activeCallReachedServer: runtime.snapshot != nil
            ) == .deferForServerWinner {
                deferredGlareInvitations[invitation.callId] = invitation
                reportedIncomingCallIds.insert(invitation.callId)
                try? await callKit.reportIncoming(
                    callId: invitation.callId,
                    callerAccountId: invitation.callerAccountId,
                    displayName: peerName,
                    initialKind: invitation.initialKind
                )
                return
            }
            reportedIncomingCallIds.insert(invitation.callId)
            try? await callKit.reportIncoming(
                callId: invitation.callId,
                callerAccountId: invitation.callerAccountId,
                displayName: String(localized: "Toj caller"),
                initialKind: invitation.initialKind
            )
            callKit.reportEnded(callId: invitation.callId, reason: .unanswered)
            if let api, let session {
                Task {
                    _ = try? await api.declineCall(
                        id: invitation.callId.uuidString.lowercased(),
                        reason: "busy",
                        token: session.token
                    )
                }
            }
            return
        }
        if runtime == nil {
            try? transition(.receiveIncoming)
            let incoming = Runtime(
                id: invitation.callId,
                direction: .incoming,
                privacyMode: preferences.mode,
                initialKind: invitation.initialKind,
                dialogId: "",
                peerAccountId: invitation.callerAccountId
            )
            runtime = incoming
            initialKind = invitation.initialKind
            hasVideoExperience = invitation.initialKind == .video
            isCameraEnabled = false
            incoming.cameraGeneration = videoReducer.beginRuntime(
                initialCameraIntent: false
            )
            activeCallId = invitation.callId
            direction = .incoming
            peerName = String(localized: "Toj caller")
            scheduleRingDeadline(
                for: incoming,
                deadline: invitation.expiresAt ?? clock.now.addingTimeInterval(30)
            )
        }
        do {
            reportedIncomingCallIds.insert(invitation.callId)
            try await callKit.reportIncoming(
                callId: invitation.callId,
                callerAccountId: invitation.callerAccountId,
                displayName: peerName,
                initialKind: invitation.initialKind
            )
            Task { await reconcile(callId: invitation.callId) }
        } catch {
            await terminate(.failed, reportCallKit: false)
        }
    }

    func receiveInvalidVoIPPush() async {
        let id = UUID()
        do {
            try await callKit.reportIncoming(
                callId: id,
                callerAccountId: "unknown",
                displayName: String(localized: "Toj caller"),
                initialKind: .voice
            )
            callKit.reportEnded(callId: id, reason: .failed)
        } catch {}
    }

    func handle(_ hint: CallHint) async {
        guard let id = UUID(uuidString: hint.callId) else { return }
        await reconcile(callId: id)
    }

    func reconcileActiveCalls() async {
        guard let api, let session else { return }
        do {
            let response = try await api.activeCalls(token: session.token)
            try Task.checkCancellation()
            guard self.session == session, self.api != nil else { return }
            for call in response.calls {
                try Task.checkCancellation()
                guard self.session == session, self.api != nil else { return }
                guard let id = UUID(uuidString: call.id) else { continue }
                if runtime == nil, call.calleeAccountId == session.accountId, call.state == "requested" {
                    await receiveVoIPPush(VoIPPushInvitation(
                        callId: id,
                        callerAccountId: call.callerAccountId,
                        initialKind: call.initialKind ?? .voice,
                        expiresAt: nil
                    ))
                }
                let belongsToThisDevice =
                    (call.callerAccountId == session.accountId && call.callerDeviceId == session.deviceId)
                    || (call.calleeAccountId == session.accountId && call.acceptedDeviceId == session.deviceId)
                if runtime == nil, belongsToThisDevice, call.state != "requested" {
                    _ = try? await api.endCall(id: call.id, reason: "failed", token: session.token)
                    continue
                }
                await reconcile(callId: id)
            }
        } catch {
            // WebSocket hints and PushKit will retry. Never end a call for a transient snapshot error.
        }
    }

    func present() { isPresented = true }
    func minimize() { if state != .ended { isPresented = false } }
    func markSecurityVerified() { if canVerifySecurity { securityVerified = true } }

    func requestEnd() async {
        guard let activeCallId else { return }
        do { try await callKit.requestEnd(callId: activeCallId) }
        catch { await handleSystemEnd(activeCallId) }
    }

    func toggleMute() async {
        guard let activeCallId else { return }
        try? await callKit.requestMute(callId: activeCallId, muted: !isMuted)
    }

    func toggleSpeaker() async {
        let enabled = !isSpeakerEnabled
        userSelectedAudioRoute = true
        do {
            try callKit.callAudioSession.setSpeakerEnabled(enabled)
            isSpeakerEnabled = enabled
            if let engine = runtime?.engine {
                try await engine.setPreferredAudioRoute(enabled ? .speaker : .builtInReceiver)
            }
        } catch {
            failureMessage = String(localized: "The selected audio route is unavailable.")
        }
    }

    func markAudioRouteSelectionIntent() {
        userSelectedAudioRoute = true
    }

    func toggleCamera() async {
        guard let runtime, runtime.selectedMediaProfile == CallMediaProfileVersion.cameraVideo else {
            failureMessage = String(localized: "Video is unavailable for this call.")
            return
        }
        let wantsCamera = !isCameraEnabled
        if wantsCamera {
            let status = permissions.cameraPermission
            if status == .notDetermined {
                // Never surface a system camera prompt from a killed, locked, or background answer.
                guard callOwningSceneIsForeground(runtime) else { return }
                let allowed = await permissions.requestCameraAccess()
                guard self.runtime === runtime else { return }
                videoReducer.setPermission(
                    allowed ? .authorized : .denied,
                    generation: runtime.cameraGeneration
                )
                if !allowed {
                    failureMessage = String(localized: "Camera access is off. Enable it in Settings to use video.")
                    return
                }
            } else if status != .authorized {
                videoReducer.setPermission(cameraPermissionState(), generation: runtime.cameraGeneration)
                failureMessage = String(localized: "Camera access is off. Enable it in Settings to use video.")
                return
            }
        }
        failureMessage = nil
        isCameraEnabled = wantsCamera
        videoReducer.setUserWantsCamera(wantsCamera, generation: runtime.cameraGeneration)
        if wantsCamera {
            videoReducer.retryCaptureAfterRuntimeFailure(generation: runtime.cameraGeneration)
            hasVideoExperience = true
            videoQuality.resetBaselines()
            callKit.updateHasVideo(callId: runtime.id, hasVideo: true)
            try? callKit.callAudioSession.setVideoMode(true)
            let route = callKit.callAudioSession.currentRoute
            if !userSelectedAudioRoute,
               CallKitVideoContract.shouldAutoEnableSpeaker(for: route) {
                try? callKit.callAudioSession.setSpeakerEnabled(true)
                isSpeakerEnabled = true
            }
        }
        await applyVideoCaptureDecision(runtime: runtime)
        try? await sendMediaState(runtime: runtime)
    }

    func switchCamera() async {
        guard let runtime, isCameraEnabled, let engine = runtime.engine else { return }
        preferredCameraPosition = preferredCameraPosition == .front ? .back : .front
        videoReducer.setPreferredCameraPosition(preferredCameraPosition, generation: runtime.cameraGeneration)
        do {
            try await engine.switchCamera(to: preferredCameraPosition)
            videoQuality.resetBaselines()
            try? await sendMediaState(runtime: runtime, force: true)
        } catch {
            failureMessage = String(localized: "The selected camera is unavailable.")
        }
    }

    func updateVideoScene(
        sceneIdentifier: String,
        isForeground: Bool,
        pictureInPictureIsActive: Bool
    ) async {
        guard let runtime else { return }
        if runtime.owningSceneIdentifier == nil {
            runtime.owningSceneIdentifier = sceneIdentifier
        }
        guard runtime.owningSceneIdentifier == sceneIdentifier else { return }
        let backgroundCameraIsAvailable = await runtime.engine?.supportsBackgroundCameraAccess() ?? false
        guard self.runtime === runtime,
              runtime.owningSceneIdentifier == sceneIdentifier else { return }
        videoReducer.setScene(
            foreground: isForeground && sceneLifecycle.isForeground(sceneIdentifier: sceneIdentifier),
            pictureInPicture: pictureInPictureIsActive,
            backgroundCameraAvailable: backgroundCameraIsAvailable,
            generation: runtime.cameraGeneration
        )
        await applyVideoCaptureDecision(runtime: runtime)
        try? await sendMediaState(runtime: runtime)
    }

    func dismissEnded() {
        guard state == .ended else { return }
        isPresented = false
        reset()
    }

    func startAudioFallback() async {
        guard state == .ended, let fallback = audioFallback else { return }
        reset()
        await startOutgoing(
            dialogId: fallback.dialogId,
            peerAccountId: fallback.peerAccountId,
            displayName: fallback.displayName,
            initialKind: .voice
        )
    }

    /// Register incoming-call delivery before the first call without presenting a microphone
    /// permission prompt during sign-in. A previously denied installation cannot answer, so it
    /// stays unregistered until the user re-enables microphone access in Settings.
    var canRegisterForIncomingCalls: Bool {
        !permissions.microphonePermissionDenied
    }
}

private extension CallCoordinator {
    func transition(_ event: CallEvent) throws {
        try machine.handle(event)
        state = machine.state
        direction = machine.direction
        endReason = machine.endReason
    }

    func createCallReliably(
        api: any CallAPITransport,
        session: CloudSession,
        runtime: Runtime,
        context: CallHandshakeContextV1,
        commitment: Data
    ) async throws -> CloudCallSnapshot {
        let callId = runtime.id.uuidString.lowercased()
        let body = CreateCloudCallRequest(
            callId: callId,
            dialogId: runtime.dialogId,
            callerCommitment: commitment.base64EncodedString(),
            supportedProtocolVersions: context.offeredProtocolVersions.map(Int.init),
            offeredMediaProfileVersions: context.offeredMediaProfileVersions.map(Int.init)
        )
        var retry = 0
        while true {
            try Task.checkCancellation()
            guard self.runtime === runtime, self.session == session else {
                _ = try? await api.cancelCall(id: callId, reason: "cancelled", token: session.token)
                throw CancellationError()
            }
            do {
                let created = try await api.createCall(body, token: session.token).call
                finishDeferredGlareInvitations(api: api, session: session)
                return created
            } catch {
                if let apiError = error as? CloudAPIError,
                   apiError.code == "busy",
                   let existingCallId = apiError.existingCallId {
                    await pivotOutgoingGlare(
                        existingCallId: existingCallId,
                        runtime: runtime,
                        api: api,
                        session: session
                    )
                    throw CancellationError()
                }
                if let existing = try? await api.call(id: callId, token: session.token).call {
                    guard
                        existing.dialogId == body.dialogId,
                        existing.callerAccountId == session.accountId,
                        existing.callerDeviceId == session.deviceId,
                        existing.callerCommitment == body.callerCommitment,
                        existing.offeredProtocolVersions == body.supportedProtocolVersions,
                        existing.offeredMediaProfileVersions == body.offeredMediaProfileVersions
                    else { throw CallProtocolError.invalidCommitment }
                    guard existing.state != "ended" else {
                        throw CloudAPIError(
                            status: 410,
                            message: "Call ended",
                            retryAfter: nil,
                            code: "expired"
                        )
                    }
                    return existing
                }
                guard case .transient(let retryAfter) = cloudFailureDisposition(error), retry < 2 else {
                    throw error
                }
                let delay = retryAfter ?? (0.5 * pow(2, Double(retry)))
                guard delay <= 2 else { throw error }
                retry += 1
                try await clock.sleep(for: .seconds(delay))
            }
        }
    }

    func finishDeferredGlareInvitations(api: any CallAPITransport, session: CloudSession) {
        let deferred = deferredGlareInvitations.values
        deferredGlareInvitations.removeAll()
        for invitation in deferred {
            callKit.reportEnded(callId: invitation.callId, reason: .unanswered)
            Task {
                _ = try? await api.declineCall(
                    id: invitation.callId.uuidString.lowercased(),
                    reason: "busy",
                    token: session.token
                )
            }
        }
    }

    func pivotOutgoingGlare(
        existingCallId: String,
        runtime: Runtime,
        api: any CallAPITransport,
        session: CloudSession
    ) async {
        guard self.runtime === runtime,
              self.session == session,
              let callId = UUID(uuidString: existingCallId) else { return }
        let pivotSource = CallGlarePolicy.pivotSource(
            existingCallId: callId,
            deferredInvitationIds: Set(deferredGlareInvitations.keys)
        )
        let invitation = deferredGlareInvitations.removeValue(forKey: callId)
        let fallbackCaller = invitation?.callerAccountId ?? runtime.peerAccountId
        await terminate(.busy, reportCallKit: true)
        reset()
        if pivotSource == .alreadyReportedInvitation {
            await reconcile(callId: callId)
        } else {
            await receiveVoIPPush(VoIPPushInvitation(
                callId: callId,
                callerAccountId: fallbackCaller,
                initialKind: invitation?.initialKind ?? runtime.initialKind,
                expiresAt: nil
            ))
        }
    }

    func acceptCallReliably(
        api: any CallAPITransport,
        session: CloudSession,
        runtime: Runtime,
        body: AcceptCloudCallRequest
    ) async throws -> CloudCallSnapshot {
        let callId = runtime.id.uuidString.lowercased()
        var retry = 0
        while true {
            try Task.checkCancellation()
            guard self.runtime === runtime, self.session == session else { throw CancellationError() }
            do {
                return try await api.acceptCall(id: callId, body: body, token: session.token).call
            } catch {
                if let existing = try? await api.call(id: callId, token: session.token).call,
                   existing.acceptedDeviceId == session.deviceId,
                   existing.calleeCommitment == body.calleeCommitment,
                   existing.protocolVersion == body.protocolVersion,
                   existing.mediaProfileVersion == body.selectedMediaProfileVersion {
                    guard existing.state != "ended" else {
                        throw CloudAPIError(
                            status: 410,
                            message: "Call ended",
                            retryAfter: nil,
                            code: "expired"
                        )
                    }
                    return existing
                }
                guard case .transient(let retryAfter) = cloudFailureDisposition(error), retry < 2 else {
                    throw error
                }
                let delay = retryAfter ?? (0.5 * pow(2, Double(retry)))
                guard delay <= 2 else { throw error }
                retry += 1
                try await clock.sleep(for: .seconds(delay))
            }
        }
    }

    func beginOutgoing(_ id: UUID) async {
        guard
            let api, let session, let runtime,
            runtime.id == id,
            let context = runtime.context,
            let commitment = runtime.callerCommitment
        else { return }
        do {
            let snapshot = try await createCallReliably(
                api: api,
                session: session,
                runtime: runtime,
                context: context,
                commitment: commitment
            )
            guard self.runtime === runtime, self.session == session else {
                // A local end can race ahead of a slow create and observe 404. Fence a create
                // that committed afterward so the recipient never keeps ringing a ghost call.
                _ = try? await api.cancelCall(
                    id: id.uuidString.lowercased(),
                    reason: "cancelled",
                    token: session.token
                )
                return
            }
            runtime.snapshot = snapshot
            try transition(.outgoingStarted)
            scheduleRingDeadline(for: runtime, expiresAt: snapshot.expiresAt)
            try await installICE(for: runtime)
            startPolling(callId: id)
            await reconcile(callId: id)
        } catch {
            guard self.runtime === runtime, self.session == session else { return }
            if runtime.initialKind == .video,
               (error as? CloudAPIError)?.code == "video_unavailable" {
                audioFallback = AudioFallback(
                    dialogId: runtime.dialogId,
                    peerAccountId: runtime.peerAccountId,
                    displayName: peerName
                )
            }
            failureMessage = friendly(error)
            await terminate(callEndReason(error), reportCallKit: true)
        }
    }

    func answerIncoming(_ id: UUID) async -> Bool {
        guard await waitForConfiguration() else {
            failureMessage = String(localized: "Secure calling could not finish starting.")
            await terminate(.failed, reportCallKit: true)
            return false
        }
        guard !Task.isCancelled else { return false }
        await reconcile(callId: id)
        guard !Task.isCancelled else { return false }
        guard
            let api, let session, let runtime,
            runtime.id == id,
            runtime.direction == .incoming,
            let snapshot = runtime.snapshot
        else {
            if activeCallId == id, state != .ended {
                await terminate(.failed, reportCallKit: true)
            }
            return false
        }
        guard await microphoneAllowed() else {
            guard self.runtime === runtime, self.session == session else { return false }
            isPresented = true
            failureMessage = String(localized: "Microphone access is required for voice calls.")
            await handleSystemEnd(id)
            return false
        }
        guard !Task.isCancelled else { return false }
        guard self.runtime === runtime, self.session == session else { return false }
        do {
            runtime.answeredAt = clock.now
            scheduleAnsweredDeadlines(for: runtime, acceptedAt: nil, expiresAt: nil)
            let engine = engineFactory()
            let identity = try await engine.prepareLocalIdentity()
            let pair = CallEphemeralKeyPair()
            let material = try CallCrypto.keyMaterial(
                keyPair: pair,
                dtlsFingerprintSHA256: identity.dtlsFingerprintSHA256
            )
            let context = CallHandshakeContextV1(
                identity: CallIdentity(
                    callId: id.uuidString.lowercased(),
                    dialogId: snapshot.dialogId,
                    caller: CallParty(
                        accountId: snapshot.callerAccountId,
                        deviceId: snapshot.callerDeviceId
                    ),
                    calleeAccountId: snapshot.calleeAccountId
                ),
                offeredProtocolVersions: snapshot.offeredProtocolVersions.compactMap(UInt16.init(exactly:)),
                offeredMediaProfileVersions: snapshot.offeredMediaProfileVersions.compactMap(UInt16.init(exactly:))
            )
            guard let callerCommitment = snapshot.callerCommitment.flatMap({ Data(base64Encoded: $0) }) else {
                throw CallProtocolError.invalidCommitment
            }
            let callee = CallParty(accountId: session.accountId, deviceId: session.deviceId)
            let selectedProtocol = CallProtocolVersion.current
            let selectedMedia = try selectedMediaProfile(for: snapshot)
            let commitment = try CallProtocolV1.calleeCommitment(
                context: context,
                callerCommitment: callerCommitment,
                callee: callee,
                selectedProtocolVersion: selectedProtocol,
                selectedMediaProfileVersion: selectedMedia,
                material: material
            )

            runtime.engine = engine
            runtime.keyPair = pair
            runtime.localMaterial = material
            runtime.context = context
            runtime.callerCommitment = callerCommitment
            runtime.calleeCommitment = commitment
            runtime.selectedMediaProfile = selectedMedia
            self.selectedMediaProfile = selectedMedia
            if callKitAudioActive { await engine.setAudioSessionActive(true) }
            startEngineEvents(engine, runtime: runtime)
            try Task.checkCancellation()
            guard self.session == session, self.runtime === runtime, activeCallId == id else {
                await engine.stop()
                return false
            }
            let accepted = try await acceptCallReliably(
                api: api,
                session: session,
                runtime: runtime,
                body: AcceptCloudCallRequest(
                    calleeCommitment: commitment.base64EncodedString(),
                    protocolVersion: Int(selectedProtocol),
                    selectedMediaProfileVersion: Int(selectedMedia)
                )
            )
            guard !Task.isCancelled, self.session == session, self.runtime === runtime, activeCallId == id else {
                _ = try? await api.endCall(
                    id: id.uuidString.lowercased(),
                    reason: "failed",
                    token: session.token
                )
                await engine.stop()
                return false
            }
            runtime.snapshot = accepted
            try transition(.accept)
            scheduleAnsweredDeadlines(
                for: runtime,
                acceptedAt: accepted.acceptedAt,
                expiresAt: accepted.expiresAt
            )
            isPresented = true
            try await installICE(for: runtime)
            try await configureMediaProfileIfNeeded(runtime: runtime)
            startPolling(callId: id)
            await reconcile(callId: id)
            return self.runtime === runtime && state != .ended
        } catch {
            guard self.runtime === runtime, self.session == session else {
                Task {
                    _ = try? await api.endCall(
                        id: id.uuidString.lowercased(),
                        reason: "failed",
                        token: session.token
                    )
                }
                return false
            }
            failureMessage = friendly(error)
            await terminate(callEndReason(error), reportCallKit: true)
            return false
        }
    }

    func reconcile(callId: UUID) async {
        if let existing = reconcileTasks[callId] {
            reconcilesPending.insert(callId)
            await existing.value
            return
        }

        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcilePass(callId: callId)
            while self.reconcilesPending.remove(callId) != nil, !Task.isCancelled {
                await self.reconcilePass(callId: callId)
            }
        }
        reconcileTasks[callId] = task
        reconcileTaskTokens[callId] = token
        await task.value
        if reconcileTaskTokens[callId] == token {
            reconcileTasks.removeValue(forKey: callId)
            reconcileTaskTokens.removeValue(forKey: callId)
            reconcilesPending.remove(callId)
        }
    }

    func reconcilePass(callId: UUID) async {
        guard let api, let session else { return }
        var participatingRuntime = runtime?.id == callId ? runtime : nil
        do {
            let snapshot = try await api.call(
                id: callId.uuidString.lowercased(),
                token: session.token
            ).call
            try Task.checkCancellation()
            guard self.session == session, self.api != nil else { return }

            if let terminalReason = CallLifecycleProjectionPolicy.terminalReason(
                view: snapshot.view,
                state: snapshot.state,
                endReason: snapshot.endReason
            ) {
                callKit.reportEnded(callId: callId, reason: terminalReason.callKitReason)
                if runtime?.id == callId {
                    await terminate(terminalReason, reportCallKit: false)
                }
                return
            }

            if runtime == nil, snapshot.calleeAccountId == session.accountId, snapshot.state == "requested" {
                try transition(.receiveIncoming)
                let incoming = Runtime(
                    id: callId,
                    direction: .incoming,
                    privacyMode: preferences.mode,
                    initialKind: snapshot.initialKind ?? .voice,
                    dialogId: snapshot.dialogId,
                    peerAccountId: snapshot.callerAccountId
                )
                incoming.snapshot = snapshot
                incoming.cameraGeneration = videoReducer.beginRuntime(
                    initialCameraIntent: false
                )
                runtime = incoming
                participatingRuntime = incoming
                activeCallId = callId
                initialKind = incoming.initialKind
                hasVideoExperience = incoming.initialKind == .video
                isCameraEnabled = false
                peerName = peerNameProvider?(snapshot.dialogId, snapshot.callerAccountId)
                    ?? String(localized: "Toj caller")
                let needsCallKitReport = !reportedIncomingCallIds.contains(callId)
                reportedIncomingCallIds.insert(callId)
                if needsCallKitReport {
                    try await callKit.reportIncoming(
                        callId: callId,
                        callerAccountId: snapshot.callerAccountId,
                        displayName: peerName,
                        initialKind: incoming.initialKind
                    )
                }
                try requireCurrent(incoming, session: session)
            }
            guard let runtime, runtime.id == callId else { return }
            participatingRuntime = runtime
            runtime.snapshot = snapshot
            runtime.dialogId = snapshot.dialogId
            runtime.peerAccountId = runtime.direction == .outgoing
                ? snapshot.calleeAccountId : snapshot.callerAccountId
            peerName = peerNameProvider?(snapshot.dialogId, runtime.peerAccountId) ?? peerName

            if runtime.direction == .incoming,
               let acceptedDeviceId = snapshot.acceptedDeviceId,
               acceptedDeviceId != session.deviceId {
                await terminate(.answeredElsewhere, reportCallKit: true)
                return
            }

            if snapshot.state == "ended" {
                await terminate(endReason(snapshot.endReason), reportCallKit: true)
                return
            }

            if snapshot.state == "requested" {
                scheduleRingDeadline(for: runtime, expiresAt: snapshot.expiresAt)
            }

            var fetchedEvents: [CloudCallEvent] = []
            var fetchCursor = runtime.processedEventSequence
            var hasMore = true
            while hasMore {
                let page = try await api.callEvents(
                    callId: callId.uuidString.lowercased(),
                    after: fetchCursor,
                    token: session.token
                )
                try Task.checkCancellation()
                guard self.runtime === runtime, self.session == session else {
                    throw CancellationError()
                }
                for event in page.events {
                    fetchedEvents.append(event)
                    fetchCursor = max(fetchCursor, event.eventSeq)
                }
                hasMore = page.hasMore
            }
            try Task.checkCancellation()
            guard self.runtime === runtime, self.session == session else {
                throw CancellationError()
            }

            // Confirmation control records are needed to finish the handshake before encrypted
            // signaling can be opened. Consuming them twice is harmless; the durable event
            // checkpoint advances only after each record has been applied successfully below.
            for event in fetchedEvents where event.type != "encrypted" {
                consumeControl(event, runtime: runtime)
            }
            try await advanceHandshake(runtime: runtime, snapshot: snapshot)
            try requireCurrent(runtime, session: session)
            for event in fetchedEvents where event.eventSeq > runtime.processedEventSequence {
                if event.type == "encrypted" {
                    do {
                        try await consumeEncrypted(event, runtime: runtime)
                    } catch CallCryptoError.expired {
                        // Signaling envelopes are intentionally short-lived. A candidate that
                        // expires between fetch and decrypt is obsolete and safe to skip.
                    }
                } else {
                    consumeControl(event, runtime: runtime)
                }
                try requireCurrent(runtime, session: session)
                runtime.processedEventSequence = event.eventSeq
            }
            scheduleCandidateFlush(for: runtime)
        } catch let error as CloudAPIError where error.status == 404 {
            if let participatingRuntime, self.runtime === participatingRuntime {
                await terminate(.failed, reportCallKit: true)
            }
        } catch {
            if error is CancellationError { return }
            guard let participatingRuntime,
                  self.runtime === participatingRuntime,
                  self.session == session else { return }
            if isSecurityFailure(error) {
                failureMessage = String(localized: "The encrypted call security check failed.")
                _ = try? await api.endCall(
                    id: callId.uuidString.lowercased(),
                    reason: "security_error",
                    token: session.token
                )
                await terminate(.securityError, reportCallKit: true)
            } else if case .transient = cloudFailureDisposition(error) {
                // The serialized poll/hint path will retry without advancing the event cursor.
            } else {
                failureMessage = friendly(error)
                await terminate(.failed, reportCallKit: true)
            }
        }
    }

    func consumeControl(_ event: CloudCallEvent, runtime: Runtime) {
        guard case .object(let values)? = event.data else { return }
        guard case .string(let encoded)? = values["confirmation"],
              let confirmation = Data(base64Encoded: encoded) else { return }
        if case .string(let role)? = values["role"], role == "callee" {
            runtime.calleeConfirmation = confirmation
        } else if event.type == "confirmed" {
            runtime.callerConfirmation = confirmation
        }
    }

    func advanceHandshake(runtime: Runtime, snapshot: CloudCallSnapshot) async throws {
        guard let api, let session else { return }
        try requireCurrent(runtime, session: session)
        let callId = runtime.id.uuidString.lowercased()

        if runtime.direction == .outgoing,
           snapshot.calleeCommitment != nil,
           !runtime.localRevealSent {
            if state == .outgoingRinging { try transition(.remoteAccepted) }
            // The recipient has accepted; start the answer-to-first-audio setup clock.
            scheduleAnsweredDeadlines(
                for: runtime,
                acceptedAt: snapshot.acceptedAt,
                expiresAt: snapshot.expiresAt
            )
            runtime.calleeCommitment = snapshot.calleeCommitment.flatMap { Data(base64Encoded: $0) }
            guard let material = runtime.localMaterial else { throw CallProtocolError.invalidKeyMaterial }
            _ = try await api.revealCall(
                id: callId,
                body: RevealCloudCallRequest(
                    publicKey: material.publicKey.base64EncodedString(),
                    nonce: material.nonce.base64EncodedString(),
                    fingerprint: material.dtlsFingerprintSHA256.base64EncodedString(),
                    confirmation: nil
                ),
                token: session.token
            )
            try requireCurrent(runtime, session: session)
            runtime.localRevealSent = true
        }

        if runtime.direction == .incoming,
           snapshot.callerPublicKey != nil,
           !runtime.localRevealSent {
            let cipher = try await buildCipher(runtime: runtime, snapshot: snapshot)
            try requireCurrent(runtime, session: session)
            runtime.cipher = cipher
            let emojis = await cipher.securityEmojis()
            try requireCurrent(runtime, session: session)
            securityEmojis = emojis
            let confirmation = await cipher.localConfirmationTag()
            try requireCurrent(runtime, session: session)
            guard let material = runtime.localMaterial else { throw CallProtocolError.invalidKeyMaterial }
            _ = try await api.revealCall(
                id: callId,
                body: RevealCloudCallRequest(
                    publicKey: material.publicKey.base64EncodedString(),
                    nonce: material.nonce.base64EncodedString(),
                    fingerprint: material.dtlsFingerprintSHA256.base64EncodedString(),
                    confirmation: confirmation.base64EncodedString()
                ),
                token: session.token
            )
            try requireCurrent(runtime, session: session)
            runtime.localRevealSent = true
        }

        if runtime.direction == .outgoing,
           snapshot.calleePublicKey != nil,
           let remoteConfirmation = runtime.calleeConfirmation,
           !runtime.localConfirmationSent {
            let cipher = try await buildCipher(runtime: runtime, snapshot: snapshot)
            try requireCurrent(runtime, session: session)
            let confirmationIsValid = await cipher.verifyRemoteConfirmationTag(remoteConfirmation)
            try requireCurrent(runtime, session: session)
            guard confirmationIsValid else {
                throw CallCryptoError.authenticationFailed
            }
            runtime.cipher = cipher
            let emojis = await cipher.securityEmojis()
            try requireCurrent(runtime, session: session)
            securityEmojis = emojis
            let confirmation = await cipher.localConfirmationTag()
            try requireCurrent(runtime, session: session)
            _ = try await api.confirmCall(
                id: callId,
                body: ConfirmCloudCallRequest(confirmation: confirmation.base64EncodedString()),
                token: session.token
            )
            try requireCurrent(runtime, session: session)
            runtime.localConfirmationSent = true
        }

        if runtime.direction == .outgoing,
           runtime.localConfirmationSent,
           !runtime.mediaStarted {
            try await startMedia(runtime: runtime)
        }

        if runtime.direction == .incoming,
           snapshot.state == "active",
           let remoteConfirmation = runtime.callerConfirmation,
           let cipher = runtime.cipher,
           !runtime.mediaStarted {
            let confirmationIsValid = await cipher.verifyRemoteConfirmationTag(remoteConfirmation)
            try requireCurrent(runtime, session: session)
            guard confirmationIsValid else {
                throw CallCryptoError.authenticationFailed
            }
            try await startMedia(runtime: runtime)
        }
    }

    func buildCipher(runtime: Runtime, snapshot: CloudCallSnapshot) async throws -> CallCipherSession {
        guard
            let context = runtime.context,
            let pair = runtime.keyPair,
            let localMaterial = runtime.localMaterial,
            let callerCommitment = runtime.callerCommitment
                ?? snapshot.callerCommitment.flatMap({ Data(base64Encoded: $0) }),
            let calleeCommitment = runtime.calleeCommitment
                ?? snapshot.calleeCommitment.flatMap({ Data(base64Encoded: $0) }),
            let selectedProtocol = snapshot.protocolVersion.flatMap(UInt16.init(exactly:)),
            let selectedMedia = snapshot.mediaProfileVersion.flatMap(UInt16.init(exactly:)),
            let acceptedDeviceId = snapshot.acceptedDeviceId,
            let session
        else { throw CallCryptoError.invalidTranscript }

        let callerMaterial: CallKeyMaterialV1
        let calleeMaterial: CallKeyMaterialV1
        let remotePublicKey: Data
        let remoteDeviceId: String
        let role: CallRole
        if runtime.direction == .outgoing {
            callerMaterial = localMaterial
            calleeMaterial = try remoteMaterial(
                publicKey: snapshot.calleePublicKey,
                nonce: snapshot.calleeNonce,
                fingerprint: snapshot.calleeFingerprint
            )
            remotePublicKey = calleeMaterial.publicKey
            remoteDeviceId = acceptedDeviceId
            role = .caller
        } else {
            callerMaterial = try remoteMaterial(
                publicKey: snapshot.callerPublicKey,
                nonce: snapshot.callerNonce,
                fingerprint: snapshot.callerFingerprint
            )
            calleeMaterial = localMaterial
            remotePublicKey = callerMaterial.publicKey
            remoteDeviceId = snapshot.callerDeviceId
            role = .callee
        }
        let transcript = try CallProtocolV1.transcript(
            context: context,
            callerCommitment: callerCommitment,
            callerMaterial: callerMaterial,
            calleeCommitment: calleeCommitment,
            callee: CallParty(accountId: snapshot.calleeAccountId, deviceId: acceptedDeviceId),
            calleeMaterial: calleeMaterial,
            selectedProtocolVersion: selectedProtocol,
            selectedMediaProfileVersion: selectedMedia
        )
        let keys = try CallCrypto.deriveSessionKeys(
            localPrivateKey: pair.privateKey,
            remotePublicKey: remotePublicKey,
            transcript: transcript
        )
        return CallCipherSession(
            callId: runtime.id.uuidString.lowercased(),
            localDeviceId: session.deviceId,
            remoteDeviceId: remoteDeviceId,
            localRole: role,
            keys: keys
        )
    }

    func remoteMaterial(publicKey: String?, nonce: String?, fingerprint: String?) throws -> CallKeyMaterialV1 {
        guard
            let publicKey = publicKey.flatMap({ Data(base64Encoded: $0) }),
            let nonce = nonce.flatMap({ Data(base64Encoded: $0) }),
            let fingerprint = fingerprint.flatMap({ Data(base64Encoded: $0) })
        else { throw CallProtocolError.invalidKeyMaterial }
        return CallKeyMaterialV1(
            publicKey: publicKey,
            nonce: nonce,
            dtlsFingerprintSHA256: fingerprint
        )
    }

    func selectedMediaProfile(for snapshot: CloudCallSnapshot) throws -> UInt16 {
        let offered = Set(snapshot.offeredMediaProfileVersions.compactMap(UInt16.init(exactly:)))
        let selectable = Set(
            (snapshot.selectableMediaProfileVersions ?? snapshot.offeredMediaProfileVersions)
                .compactMap(UInt16.init(exactly:))
        )
        let local = Set(WebRTCEngineFactory.deviceCapabilities.supportedCallMediaProfileVersions)
        let common = offered.intersection(selectable).intersection(local)
        if (snapshot.initialKind ?? .voice) == .video {
            guard common.contains(CallMediaProfileVersion.cameraVideo) else {
                throw CloudAPIError(
                    status: 409,
                    message: "Video is unavailable on this device",
                    retryAfter: nil,
                    code: "video_unavailable"
                )
            }
            return CallMediaProfileVersion.cameraVideo
        }
        guard let selected = common.max() else {
            throw CallProtocolError.unsupportedSelectedMediaProfileVersion(0)
        }
        return selected
    }

    func configureMediaProfileIfNeeded(runtime: Runtime) async throws {
        guard let engine = runtime.engine, let profile = runtime.selectedMediaProfile else {
            throw CallCryptoError.invalidTranscript
        }
        guard !runtime.mediaProfileConfigured else { return }
        let permissionIsGranted = permissions.cameraPermission == .authorized
        // Incoming setup may run before transcript verification so the answer contains the
        // permanent disabled video track. Its one-shot intent must remain camera-off; the reducer
        // enables capture only after startMedia authenticates the transcript.
        let initialCameraIntent = runtime.direction == .outgoing
            && runtime.initialKind == .video
            && permissionIsGranted
        try await engine.configureMediaProfile(profile, initialCameraIntent: initialCameraIntent)
        try Task.checkCancellation()
        guard self.runtime === runtime else { throw CancellationError() }
        // An identical concurrent setup may have completed while the engine call was suspended.
        guard !runtime.mediaProfileConfigured else { return }
        runtime.mediaProfileConfigured = true
        if profile == CallMediaProfileVersion.cameraVideo {
            videoReducer.setPermission(
                permissionIsGranted ? .authorized : cameraPermissionState(),
                generation: runtime.cameraGeneration
            )
            if runtime.initialKind == .video, permissionIsGranted {
                videoReducer.setUserWantsCamera(true, generation: runtime.cameraGeneration)
                isCameraEnabled = true
            }
            try await installVideoRenderersIfNeeded(runtime: runtime)
            try Task.checkCancellation()
            guard self.runtime === runtime else { throw CancellationError() }
        }
    }

    @discardableResult
    func installICE(for runtime: Runtime, scheduleRefresh: Bool = true) async throws -> Int {
        guard let api, let session, let engine = runtime.engine else {
            throw CallCryptoError.invalidTranscript
        }
        let config: CloudCallIceConfiguration
        var retry = 0
        while true {
            try Task.checkCancellation()
            guard self.runtime === runtime, self.session == session else {
                throw CancellationError()
            }
            do {
                config = try await api.callIceConfiguration(
                    callId: runtime.id.uuidString.lowercased(),
                    token: session.token
                )
                break
            } catch {
                guard case .transient(let retryAfter) = cloudFailureDisposition(error), retry < 2 else {
                    throw error
                }
                let delay = retryAfter ?? (0.5 * pow(2, Double(retry)))
                guard delay <= 2 else { throw error }
                retry += 1
                try await clock.sleep(for: .seconds(delay))
            }
        }
        guard self.runtime === runtime, self.session == session else {
            throw CancellationError()
        }
        try await engine.updateICEConfiguration(CallICEConfiguration(
            servers: config.iceServers.map {
                CallICEServer(urls: $0.urls, username: $0.username, credential: $0.credential)
            },
            transportPolicy: runtime.privacyMode.iceTransportPolicy
        ))
        guard self.runtime === runtime, self.session == session else {
            throw CancellationError()
        }
        if scheduleRefresh {
            scheduleTurnRefresh(runtime: runtime, ttlSeconds: config.ttlSeconds)
        }
        return config.ttlSeconds
    }

    func startMedia(runtime: Runtime) async throws {
        guard !runtime.mediaStarted, let engine = runtime.engine else { return }
        try requireCurrent(runtime)
        if let snapshot = runtime.snapshot,
           let selected = snapshot.mediaProfileVersion.flatMap(UInt16.init(exactly:)) {
            runtime.selectedMediaProfile = selected
            selectedMediaProfile = selected
        }
        try await configureMediaProfileIfNeeded(runtime: runtime)
        try requireCurrent(runtime)
        videoReducer.setSecureMediaReady(true, generation: runtime.cameraGeneration)
        let owningSceneIsForeground = runtime.owningSceneIdentifier.map {
            sceneLifecycle.isForeground(sceneIdentifier: $0)
        } ?? false
        videoReducer.setScene(
            foreground: owningSceneIsForeground,
            pictureInPicture: false,
            backgroundCameraAvailable: false,
            generation: runtime.cameraGeneration
        )
        await applyVideoCaptureDecision(runtime: runtime)
        try requireCurrent(runtime)
        if state == .keyExchange { try transition(.keysConfirmed) }
        keyExchangeDeadlineTask?.cancel()
        keyExchangeDeadlineTask = nil
        scheduleConnectionDeadline(for: runtime)
        if runtime.direction == .outgoing {
            callKit.reportOutgoingConnecting(callId: runtime.id)
            runtime.signalingReadyForCandidates = false
            let offer = try await engine.makeOffer(iceRestart: false)
            try await sendSignal(.offer, payload: CallWirePayload(description: offer, candidate: nil), runtime: runtime)
            try requireCurrent(runtime)
            runtime.signalingReadyForCandidates = true
        }
        runtime.mediaStarted = true
        scheduleCandidateFlush(for: runtime)
        startVideoQualityLoop(runtime: runtime)
        try await sendMediaState(runtime: runtime, force: true)
    }

    func scheduleRingDeadline(for runtime: Runtime, expiresAt: String) {
        scheduleRingDeadline(
            for: runtime,
            deadline: parseServerDate(expiresAt) ?? clock.now.addingTimeInterval(30)
        )
    }

    func scheduleRingDeadline(for runtime: Runtime, deadline: Date) {
        guard runtime.answeredAt == nil else { return }
        ringDeadlineTask?.cancel()
        let callId = runtime.id
        let scheduler = clock
        ringDeadlineTask = Task { [weak self] in
            try? await scheduler.sleep(for: .seconds(max(0, deadline.timeIntervalSince(scheduler.now))))
            guard
                !Task.isCancelled,
                self?.runtime?.id == callId,
                self?.state == .outgoingRinging || self?.state == .incomingRinging
            else { return }
            await self?.terminate(.unanswered, reportCallKit: true)
        }
    }

    func scheduleAnsweredDeadlines(for runtime: Runtime, acceptedAt: String?, expiresAt: String?) {
        let serverAcceptedAt = acceptedAt.flatMap(parseServerDate)
        if let serverAcceptedAt {
            runtime.answeredAt = min(runtime.answeredAt ?? serverAcceptedAt, serverAcceptedAt)
        } else {
            runtime.answeredAt = runtime.answeredAt ?? clock.now
        }
        ringDeadlineTask?.cancel()
        ringDeadlineTask = nil

        keyExchangeDeadlineTask?.cancel()
        let callId = runtime.id
        let keyDeadline = expiresAt.flatMap(parseServerDate)
            ?? (runtime.answeredAt ?? clock.now).addingTimeInterval(10)
        let keyScheduler = clock
        keyExchangeDeadlineTask = Task { [weak self] in
            try? await keyScheduler.sleep(
                for: .seconds(max(0, keyDeadline.timeIntervalSince(keyScheduler.now)))
            )
            guard
                !Task.isCancelled,
                self?.runtime?.id == callId,
                self?.state == .incomingRinging || self?.state == .outgoingRinging
                    || self?.state == .keyExchange
            else { return }
            await self?.terminate(.networkLost, reportCallKit: true)
        }
        scheduleConnectionDeadline(for: runtime)
    }

    func scheduleConnectionDeadline(for runtime: Runtime) {
        connectionDeadlineTask?.cancel()
        let answeredAt = runtime.answeredAt ?? clock.now
        runtime.answeredAt = answeredAt
        let callId = runtime.id
        let connectionScheduler = clock
        connectionDeadlineTask = Task { [weak self] in
            let remaining = max(0, 20 - connectionScheduler.now.timeIntervalSince(answeredAt))
            try? await connectionScheduler.sleep(for: .seconds(remaining))
            guard
                !Task.isCancelled,
                self?.runtime?.id == callId,
                self?.state == .incomingRinging || self?.state == .outgoingRinging
                    || self?.state == .keyExchange || self?.state == .connecting
            else { return }
            await self?.terminate(.networkLost, reportCallKit: true)
        }
    }

    func parseServerDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    func sendCandidate(_ candidate: CallICECandidate, runtime: Runtime) async throws {
        if !CallICECandidatePolicy.permits(
            candidate.candidate,
            transportPolicy: runtime.privacyMode.iceTransportPolicy
        ) {
            return
        }
        try await sendSignal(
            .iceCandidate,
            payload: CallWirePayload(description: nil, candidate: candidate),
            runtime: runtime
        )
    }

    func sendSignal(_ kind: CallSignalKind, payload: CallWirePayload, runtime: Runtime) async throws {
        try await runtime.signalOutbox.perform { [weak self, weak runtime] in
            guard
                let self, let runtime,
                self.runtime === runtime,
                let api = self.api,
                let session = self.session,
                let cipher = runtime.cipher
            else { throw CancellationError() }

            let expiry = Int64(clock.now.addingTimeInterval(60).timeIntervalSince1970 * 1_000)
            let plaintext = try JSONEncoder().encode(payload)
            let envelope = try await cipher.seal(plaintext, kind: kind, expiresAtMilliseconds: expiry)
            guard let senderSequence = Int64(exactly: envelope.sequence) else {
                throw CallCryptoError.sequenceExhausted
            }
            let body = SendCloudCallEventRequest(
                version: Int(envelope.version),
                kind: envelope.kind.rawValue,
                senderSequence: senderSequence,
                ciphertext: envelope.ciphertext.base64EncodedString(),
                expiresAtMilliseconds: envelope.expiresAtMilliseconds
            )

            var attempt = 0
            while true {
                try Task.checkCancellation()
                do {
                    _ = try await api.sendCallEvent(
                        callId: runtime.id.uuidString.lowercased(),
                        body: body,
                        token: session.token
                    )
                    return
                } catch {
                    guard case .transient(let retryAfter) = cloudFailureDisposition(error) else {
                        throw error
                    }
                    if await signalEventWasCommitted(body, runtime: runtime, api: api, session: session) {
                        return
                    }
                    attempt = min(attempt + 1, 4)
                    let delay = retryAfter ?? min(4, pow(2, Double(attempt - 1)))
                    let remaining = Double(envelope.expiresAtMilliseconds) / 1_000 - clock.now.timeIntervalSince1970
                    guard remaining > delay + 1 else {
                        if await signalEventWasCommitted(body, runtime: runtime, api: api, session: session) {
                            return
                        }
                        throw error
                    }
                    try await clock.sleep(for: .seconds(delay))
                }
            }
        }
    }

    func signalEventWasCommitted(
        _ body: SendCloudCallEventRequest,
        runtime: Runtime,
        api: any CallAPITransport,
        session: CloudSession
    ) async -> Bool {
        guard self.runtime === runtime, self.session == session else { return false }
        var cursor = max(0, runtime.processedEventSequence - min(runtime.processedEventSequence, 256))
        var pages = 0
        while pages < 20, !Task.isCancelled {
            guard let page = try? await api.callEvents(
                callId: runtime.id.uuidString.lowercased(),
                after: cursor,
                limit: 100,
                token: session.token
            ) else { return false }
            if page.events.contains(where: { event in
                event.senderDeviceId == session.deviceId
                    && event.senderSequence == body.senderSequence
                    && event.version == body.version
                    && event.kind == body.kind
                    && event.ciphertext == body.ciphertext
                    && event.expiresAtMilliseconds == body.expiresAtMilliseconds
            }) {
                return true
            }
            guard page.hasMore, let last = page.events.last, last.eventSeq > cursor else { return false }
            cursor = last.eventSeq
            pages += 1
        }
        return false
    }

    func flushPendingCandidates(runtime: Runtime) async throws {
        guard runtime.mediaStarted, runtime.signalingReadyForCandidates else { return }
        while let candidate = runtime.pendingCandidates.first {
            do {
                try await sendCandidate(candidate, runtime: runtime)
                runtime.pendingCandidates.removeFirst()
            } catch {
                if case .transient = cloudFailureDisposition(error) {
                    try await clock.sleep(for: .seconds(1))
                    continue
                }
                throw error
            }
        }
    }

    func scheduleCandidateFlush(for runtime: Runtime) {
        guard
            candidateFlushTask == nil,
            self.runtime === runtime,
            runtime.cipher != nil,
            runtime.mediaStarted,
            runtime.signalingReadyForCandidates,
            !runtime.pendingCandidates.isEmpty
        else { return }
        candidateFlushTask = Task { @MainActor [weak self, weak runtime] in
            guard let self, let runtime, self.runtime === runtime else { return }
            defer {
                if self.runtime === runtime { self.candidateFlushTask = nil }
            }
            do {
                try await self.flushPendingCandidates(runtime: runtime)
            } catch {
                guard !(error is CancellationError), self.runtime === runtime else { return }
                await self.terminate(
                    self.isSecurityFailure(error) ? .securityError : .networkLost,
                    reportCallKit: true
                )
            }
        }
    }

    func consumeEncrypted(_ event: CloudCallEvent, runtime: Runtime) async throws {
        guard let session else { throw CancellationError() }
        try requireCurrent(runtime, session: session)
        guard event.senderDeviceId != session.deviceId else { return }

        let decoded: DecryptedSignal
        if let cached = runtime.decryptedSignals[event.eventSeq] {
            decoded = cached
        } else {
            guard
                let cipher = runtime.cipher,
                let senderDeviceId = event.senderDeviceId,
                let sequence = event.senderSequence.flatMap(UInt64.init(exactly:)),
                let version = event.version.flatMap(UInt16.init(exactly:)),
                let rawKind = event.kind,
                let kind = CallSignalKind(rawValue: rawKind),
                let ciphertext = event.ciphertext.flatMap({ Data(base64Encoded: $0) }),
                let expiry = event.expiresAtMilliseconds
            else { throw CallProtocolError.invalidKeyMaterial }
            let envelope = CallEncryptedSignalV1(
                version: version,
                callId: runtime.id.uuidString.lowercased(),
                senderDeviceId: senderDeviceId,
                kind: kind,
                sequence: sequence,
                ciphertext: ciphertext,
                expiresAtMilliseconds: expiry
            )
            let plaintext = try await cipher.open(
                envelope,
                nowMilliseconds: Int64(clock.now.timeIntervalSince1970 * 1_000)
            )
            guard let payload = try? JSONDecoder().decode(CallWirePayload.self, from: plaintext) else {
                throw CallCryptoError.metadataMismatch
            }
            decoded = DecryptedSignal(kind: kind, payload: payload)
            runtime.decryptedSignals[event.eventSeq] = decoded
        }

        guard let engine = runtime.engine else { throw CallCryptoError.invalidTranscript }
        let kind = decoded.kind
        let payload = decoded.payload
        switch kind {
        case .offer, .iceRestart:
            guard runtime.direction == .incoming,
                  let description = payload.description,
                  CallSignalDescriptionPolicy.accepts(
                    kind: kind,
                    descriptionType: description.type
                  )
            else {
                throw CallCryptoError.metadataMismatch
            }
            let fingerprint = try remoteMaterial(
                publicKey: runtime.snapshot?.callerPublicKey,
                nonce: runtime.snapshot?.callerNonce,
                fingerprint: runtime.snapshot?.callerFingerprint
            ).dtlsFingerprintSHA256
            try await engine.setRemoteDescription(
                description,
                expectedDTLSFingerprintSHA256: fingerprint
            )
            try requireCurrent(runtime, session: session)
            runtime.remoteDescriptionInstalled = true
            try await flushRemoteCandidates(runtime: runtime)
            try requireCurrent(runtime, session: session)
            runtime.signalingReadyForCandidates = false
            let answer = try await engine.makeAnswer()
            try requireCurrent(runtime, session: session)
            try await sendSignal(.answer, payload: CallWirePayload(description: answer, candidate: nil), runtime: runtime)
            try requireCurrent(runtime, session: session)
            runtime.signalingReadyForCandidates = true
            scheduleCandidateFlush(for: runtime)
        case .answer:
            guard runtime.direction == .outgoing,
                  let description = payload.description,
                  CallSignalDescriptionPolicy.accepts(
                    kind: kind,
                    descriptionType: description.type
                  )
            else {
                throw CallCryptoError.metadataMismatch
            }
            let fingerprint = try remoteMaterial(
                publicKey: runtime.snapshot?.calleePublicKey,
                nonce: runtime.snapshot?.calleeNonce,
                fingerprint: runtime.snapshot?.calleeFingerprint
            ).dtlsFingerprintSHA256
            try await engine.setRemoteDescription(
                description,
                expectedDTLSFingerprintSHA256: fingerprint
            )
            try requireCurrent(runtime, session: session)
            runtime.remoteDescriptionInstalled = true
            try await flushRemoteCandidates(runtime: runtime)
            try requireCurrent(runtime, session: session)
        case .iceCandidate:
            if let candidate = payload.candidate {
                if runtime.remoteDescriptionInstalled {
                    try await engine.addRemoteICECandidate(candidate)
                    try requireCurrent(runtime, session: session)
                } else {
                    guard runtime.pendingRemoteCandidates.count < 256 else {
                        throw WebRTCEngineError.operationFailed
                    }
                    runtime.pendingRemoteCandidates.append(candidate)
                }
            }
        case .hangup:
            await terminate(.remoteEnded, reportCallKit: true)
        case .control:
            if let mediaState = payload.mediaState {
                guard mediaState.version == CallMediaStateUpdateV1.currentVersion else {
                    throw CallCryptoError.metadataMismatch
                }
                if CallMediaRevisionPolicy.accepts(
                    remote: mediaState.revision,
                    highestAccepted: runtime.remoteHighestMediaRevision
                ) {
                    runtime.remoteHighestMediaRevision = mediaState.revision
                    runtime.peerMaximumReceiveTier = mediaState.requestedMaximumReceiveTier
                    remoteVideoState = mediaState.effectiveState
                    remoteVideoPauseReason = mediaState.genericPauseReason
                    if mediaState.desiredCameraState || mediaState.effectiveState == .active {
                        hasVideoExperience = true
                        callKit.updateHasVideo(callId: runtime.id, hasVideo: true)
                    }
                }
            } else if payload.control == .requestICERestart, runtime.direction == .outgoing {
                try await performICERestart(runtime: runtime)
            }
        }
        runtime.decryptedSignals.removeValue(forKey: event.eventSeq)
    }

    func flushRemoteCandidates(runtime: Runtime) async throws {
        guard runtime.remoteDescriptionInstalled, let engine = runtime.engine else { return }
        while let candidate = runtime.pendingRemoteCandidates.first {
            try await engine.addRemoteICECandidate(candidate)
            guard self.runtime === runtime else { throw CancellationError() }
            runtime.pendingRemoteCandidates.removeFirst()
        }
    }

    func startEngineEvents(_ engine: any WebRTCEngine, runtime: Runtime) {
        engineTask?.cancel()
        engineTask = Task { [weak self, weak runtime] in
            guard let runtime else { return }
            let events = await engine.events()
            for await event in events {
                guard let self, self.runtime === runtime else { return }
                await self.handleEngineEvent(event)
            }
        }
    }

    func handleEngineEvent(_ event: WebRTCEvent) async {
        guard let runtime else { return }
        do {
            switch event {
            case .localCandidate(let candidate):
                guard runtime.pendingCandidates.count < 256 else {
                    throw WebRTCEngineError.operationFailed
                }
                runtime.pendingCandidates.append(candidate)
                scheduleCandidateFlush(for: runtime)
            case .connectionStateChanged(.connected):
                recoveryTask?.cancel()
                recoveryTask = nil
                recoveryDebounceTask?.cancel()
                recoveryDebounceTask = nil
                ringDeadlineTask?.cancel()
                ringDeadlineTask = nil
                keyExchangeDeadlineTask?.cancel()
                keyExchangeDeadlineTask = nil
                connectionDeadlineTask?.cancel()
                connectionDeadlineTask = nil
                if let recoveryStartedAt = runtime.recoveryStartedAt {
                    // Close out a recovery episode and keep the worst recovery time for telemetry.
                    let elapsed = clock.now.timeIntervalSince(recoveryStartedAt)
                    runtime.maxRecoverySeconds = max(runtime.maxRecoverySeconds ?? 0, elapsed)
                    runtime.recoveryStartedAt = nil
                }
                if state == .connecting || state == .reconnecting {
                    try transition(.mediaConnected)
                }
                connectedAt = connectedAt ?? clock.now
                startHeartbeat(runtime: runtime)
                if runtime.direction == .outgoing {
                    callKit.reportOutgoingConnected(callId: runtime.id)
                }
                videoQuality.resetBaselines()
                try? await sendMediaState(runtime: runtime, force: true)
            case .connectionStateChanged(.disconnected):
                if state == .active {
                    try transition(.mediaDisconnected)
                    heartbeatTask?.cancel()
                    heartbeatTask = nil
                    // A fresh recovery episode begins the moment active media drops.
                    if runtime.recoveryStartedAt == nil {
                        runtime.recoveryStartedAt = clock.now
                        runtime.recoveryCount += 1
                    }
                }
                await recoverMediaIfNeeded()
            case .connectionStateChanged(.failed):
                if state == .active {
                    try transition(.mediaDisconnected)
                    heartbeatTask?.cancel()
                    heartbeatTask = nil
                    if runtime.recoveryStartedAt == nil {
                        runtime.recoveryStartedAt = clock.now
                        runtime.recoveryCount += 1
                    }
                }
                if state == .reconnecting { await recoverMediaIfNeeded() }
                // During initial connection the 20-second deadline owns failure handling.
            case .connectionStateChanged(.closed):
                await terminate(.networkLost, reportCallKit: true)
            case .connectionStateChanged:
                break
            case .audioRouteChanged(let route):
                audioRouteName = route.displayName
                isSpeakerEnabled = route == .speaker
            case .remoteVideoAvailabilityChanged(let available):
                remoteVideoTrackAvailable = available
                if !available, remoteVideoState == .active { remoteVideoState = .paused }
            case .localVideoCaptureHealthChanged(let health):
                videoReducer.setCaptureHealth(
                    interrupted: health.interrupted,
                    runtimeFailed: health.runtimeFailed,
                    cameraAvailable: health.cameraAvailable,
                    pressureCritical: health.pressureCritical,
                    generation: runtime.cameraGeneration
                )
                await applyVideoCaptureDecision(runtime: runtime)
                try? await sendMediaState(runtime: runtime)
            }
        } catch {
            guard self.runtime === runtime else { return }
            await terminate(isSecurityFailure(error) ? .securityError : .networkLost, reportCallKit: true)
        }
    }

    func recoverMediaIfNeeded() async {
        guard let runtime, state == .reconnecting else { return }
        let id = runtime.id
        if recoveryTask == nil {
            let recoveryScheduler = clock
            recoveryTask = Task { [weak self] in
                try? await recoveryScheduler.sleep(for: .seconds(20))
                guard !Task.isCancelled, self?.runtime?.id == id, self?.state == .reconnecting else { return }
                await self?.terminate(.networkLost, reportCallKit: true)
            }
        }
        guard recoveryDebounceTask == nil else { return }
        let debounceScheduler = clock
        recoveryDebounceTask = Task { @MainActor [weak self, weak runtime] in
            try? await debounceScheduler.sleep(for: .seconds(1))
            guard
                !Task.isCancelled,
                let self,
                let runtime,
                self.runtime === runtime,
                self.state == .reconnecting
            else { return }
            defer {
                if self.runtime === runtime { self.recoveryDebounceTask = nil }
            }
            do {
                if runtime.direction == .outgoing {
                    try await self.performICERestart(runtime: runtime)
                } else {
                    try await self.sendSignal(
                        .control,
                        payload: CallWirePayload(
                            description: nil,
                            candidate: nil,
                            control: .requestICERestart
                        ),
                        runtime: runtime
                    )
                }
            } catch {
                // The recovery deadline remains authoritative while polling and hints retry.
            }
        }
    }

    func startPolling(callId: UUID) {
        pollTask?.cancel()
        let pollingScheduler = clock
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let delay = self?.state == .active ? 5 : 1
                try? await pollingScheduler.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.reconcile(callId: callId)
            }
        }
    }

    func scheduleTurnRefresh(runtime: Runtime, ttlSeconds: Int) {
        turnRefreshTask?.cancel()
        let delay = min(2_700, max(60, Int(Double(ttlSeconds) * 0.75)))
        let id = runtime.id
        let refreshScheduler = clock
        turnRefreshTask = Task { [weak self] in
            try? await refreshScheduler.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.runtime?.id == id, let runtime = self.runtime else { return }
            do {
                let ttl = try await self.installICE(for: runtime, scheduleRefresh: false)
                if runtime.mediaStarted {
                    if runtime.direction == .outgoing {
                        try await self.performICERestart(runtime: runtime)
                    } else {
                        try await self.sendSignal(
                            .control,
                            payload: CallWirePayload(
                                description: nil,
                                candidate: nil,
                                control: .requestICERestart
                            ),
                            runtime: runtime
                        )
                    }
                }
                self.scheduleTurnRefresh(runtime: runtime, ttlSeconds: ttl)
            } catch {
                guard self.runtime?.id == id else { return }
                // Retry while the old credential still has ample lifetime.
                self.scheduleTurnRefresh(runtime: runtime, ttlSeconds: 80)
            }
        }
    }

    func performICERestart(runtime: Runtime) async throws {
        guard runtime.direction == .outgoing, let engine = runtime.engine else { return }
        guard !runtime.iceRestartInFlight else { return }
        runtime.iceRestartInFlight = true
        defer { runtime.iceRestartInFlight = false }

        runtime.signalingReadyForCandidates = false
        let offer = try await engine.makeOffer(iceRestart: true)
        try await sendSignal(
            .iceRestart,
            payload: CallWirePayload(description: offer, candidate: nil),
            runtime: runtime
        )
        runtime.signalingReadyForCandidates = true
        scheduleCandidateFlush(for: runtime)
        videoQuality.resetBaselines()
        try? await sendMediaState(runtime: runtime, force: true)
    }

    func startHeartbeat(runtime: Runtime) {
        heartbeatTask?.cancel()
        let id = runtime.id
        let heartbeatScheduler = clock
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await heartbeatScheduler.sleep(for: .seconds(30))
                guard
                    !Task.isCancelled,
                    let self,
                    self.runtime?.id == id,
                    let runtime = self.runtime,
                    runtime.mediaStarted
                else { return }
                try? await self.sendSignal(
                    .control,
                    payload: CallWirePayload(description: nil, candidate: nil),
                    runtime: runtime
                )
            }
        }
    }

    func handleSystemEnd(_ id: UUID) async {
        guard let runtime, runtime.id == id else { return }
        try? transition(.endRequested)
        let endingAPI = api
        let endingSession = session
        let shouldDecline = runtime.direction == .incoming
            && runtime.snapshot?.acceptedDeviceId == nil
        let shouldCancel = runtime.direction == .outgoing && connectedAt == nil
        let reason: CallEndReason = shouldDecline ? .declined : .cancelled
        await terminate(reason, reportCallKit: false)
        guard let endingAPI, let endingSession else { return }
        Task {
            if shouldDecline {
                _ = try? await endingAPI.declineCall(
                    id: id.uuidString.lowercased(),
                    reason: "declined",
                    token: endingSession.token
                )
            } else if shouldCancel {
                _ = try? await endingAPI.cancelCall(
                    id: id.uuidString.lowercased(),
                    reason: "cancelled",
                    token: endingSession.token
                )
            } else {
                _ = try? await endingAPI.endCall(
                    id: id.uuidString.lowercased(),
                    reason: "local_ended",
                    token: endingSession.token
                )
            }
        }
    }

    func setMutedFromSystem(id: UUID, muted: Bool) async {
        guard runtime?.id == id else { return }
        isMuted = muted
        await runtime?.engine?.setMuted(muted)
    }

    func terminate(_ reason: CallEndReason, reportCallKit: Bool) async {
        guard state != .idle else { return }
        let id = activeCallId
        let endingRuntime = runtime
        let endingLocalVideoRenderer = localVideoRenderer
        let endingRemoteVideoRenderer = remoteVideoRenderer
        let endingPictureInPictureVideoRenderer = pictureInPictureVideoRenderer
        // Detach shared ownership before the first await so a replacement call can never inherit
        // or lose renderer handles that belong to this teardown.
        localVideoRenderer = nil
        remoteVideoRenderer = nil
        pictureInPictureVideoRenderer = nil
        let shouldNotifyServer = [
            CallEndReason.networkLost, .securityError, .failed, .permissionDenied, .remoteEnded,
        ].contains(reason)
        let endingAPI = api
        let endingSession = session
        let connectedAtSnapshot = connectedAt
        let deferredInvitations = Array(deferredGlareInvitations.values)
        deferredGlareInvitations.removeAll()

        // Invalidate the call generation before the first await. Old network, reconciliation,
        // and engine callbacks can no longer mutate or signal for a replacement call.
        pollTask?.cancel()
        engineTask?.cancel()
        candidateFlushTask?.cancel()
        recoveryTask?.cancel()
        recoveryDebounceTask?.cancel()
        ringDeadlineTask?.cancel()
        keyExchangeDeadlineTask?.cancel()
        connectionDeadlineTask?.cancel()
        turnRefreshTask?.cancel()
        heartbeatTask?.cancel()
        qualityTask?.cancel()
        for task in reconcileTasks.values { task.cancel() }
        endingRuntime?.signalOutbox.cancel()
        pollTask = nil
        engineTask = nil
        candidateFlushTask = nil
        recoveryTask = nil
        recoveryDebounceTask = nil
        ringDeadlineTask = nil
        keyExchangeDeadlineTask = nil
        connectionDeadlineTask = nil
        turnRefreshTask = nil
        heartbeatTask = nil
        qualityTask = nil
        reconcileTasks.removeAll()
        reconcileTaskTokens.removeAll()
        reconcilesPending.removeAll()
        if let id { reportedIncomingCallIds.remove(id) }
        runtime = nil // Erases all per-call private material and nonce state.
        videoReducer.endRuntime()
        pictureInPicture.stopAndReset()
        if state != .ended {
            try? transition(.terminated(reason))
        }
        if reportCallKit, let id {
            callKit.reportEnded(callId: id, reason: reason.callKitReason)
        }
        for invitation in deferredInvitations {
            reportedIncomingCallIds.remove(invitation.callId)
            callKit.reportEnded(callId: invitation.callId, reason: .unanswered)
            if let endingAPI, let endingSession {
                Task {
                    _ = try? await endingAPI.declineCall(
                        id: invitation.callId.uuidString.lowercased(),
                        reason: "busy",
                        token: endingSession.token
                    )
                }
            }
        }
        endReason = reason
        connectedAt = nil
        isMuted = false
        isSpeakerEnabled = false
        securityVerified = false
        securityEmojis = []
        callKitAudioActive = false
        isCameraEnabled = false
        localVideoState = .inactive
        remoteVideoState = .inactive
        remoteVideoPauseReason = nil
        remoteVideoTrackAvailable = false
        selectedMediaProfile = nil
        hasVideoExperience = false
        videoQualityTier = .high
        videoIsAutomaticallyPaused = false
        userSelectedAudioRoute = false

        // Stop capture/playout immediately after detaching. Final telemetry deliberately omits a
        // potentially blocking last-moment WebRTC stats sample so teardown is privacy-first.
        if let engine = endingRuntime?.engine {
            if let endingLocalVideoRenderer {
                await engine.releaseVideoRenderer(endingLocalVideoRenderer)
            }
            if let endingRemoteVideoRenderer {
                await engine.releaseVideoRenderer(endingRemoteVideoRenderer)
            }
            if let endingPictureInPictureVideoRenderer {
                await engine.releaseVideoRenderer(endingPictureInPictureVideoRenderer)
            }
            await engine.stop()
        }

        if shouldNotifyServer, let id, let endingAPI, let endingSession {
            Task {
                _ = try? await endingAPI.endCall(
                    id: id.uuidString.lowercased(),
                    reason: reason.rawValue,
                    token: endingSession.token
                )
            }
        }

        // Best-effort, fire-and-forget telemetry for any call that reached the server. Failures never
        // affect teardown, and only pinned buckets leave the device.
        if let id, let endingAPI, let endingSession, let endingRuntime,
           endingRuntime.snapshot != nil, !endingRuntime.telemetryReported {
            endingRuntime.telemetryReported = true
            let outcome = connectedAtSnapshot != nil ? "completed" : reason.rawValue
            let setupSeconds: Double? = {
                guard let answered = endingRuntime.answeredAt, let connected = connectedAtSnapshot else { return nil }
                return max(0, connected.timeIntervalSince(answered))
            }()
            let report = CallTelemetry.report(
                outcome: outcome,
                role: endingRuntime.role,
                privacyMode: endingRuntime.privacyMode,
                routeClass: nil,
                setupSeconds: setupSeconds,
                recoverySeconds: endingRuntime.maxRecoverySeconds,
                recoveryCount: endingRuntime.recoveryCount,
                stats: nil
            )
            Task {
                _ = try? await endingAPI.sendCallTelemetry(
                    callId: id.uuidString.lowercased(),
                    body: report,
                    token: endingSession.token
                )
            }
        }
    }

    func reset() {
        if state == .ended { try? transition(.reset) }
        activeCallId = nil
        peerName = String(localized: "Toj caller")
        endReason = nil
        failureMessage = nil
        securityEmojis = []
        securityVerified = false
        initialKind = .voice
        selectedMediaProfile = nil
        audioFallback = nil
    }

    func presentVideoPreflightFailure(
        _ message: String,
        reason: CallEndReason,
        dialogId: String,
        peerAccountId: String,
        displayName: String
    ) async {
        try? transition(.startOutgoing)
        initialKind = .video
        peerName = displayName
        failureMessage = message
        audioFallback = AudioFallback(
            dialogId: dialogId,
            peerAccountId: peerAccountId,
            displayName: displayName
        )
        isPresented = true
        await terminate(reason, reportCallKit: false)
    }

    func refreshAudioRoute() {
        audioRouteName = callKit.callAudioSession.currentRouteName
        isSpeakerEnabled = callKit.callAudioSession.isSpeakerEnabled
    }

    func microphoneAllowed() async -> Bool {
        await permissions.microphoneAllowed()
    }

    func cameraAllowedForOutgoing() async -> Bool {
        switch permissions.cameraPermission {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            guard sceneLifecycle.isForeground else { return false }
            return await permissions.requestCameraAccess()
        }
    }

    func callOwningSceneIsForeground(_ runtime: Runtime) -> Bool {
        guard let sceneIdentifier = runtime.owningSceneIdentifier else { return false }
        return sceneLifecycle.isForeground(sceneIdentifier: sceneIdentifier)
    }

    func cameraPermissionState() -> CallCameraPermissionState {
        permissions.cameraPermission
    }

    func installVideoRenderersIfNeeded(runtime: Runtime) async throws {
        guard let engine = runtime.engine,
              runtime.selectedMediaProfile == CallMediaProfileVersion.cameraVideo else { return }
        if localVideoRenderer == nil {
            let handle = try await engine.makeVideoRenderer(source: .local)
            guard self.runtime === runtime else {
                await engine.releaseVideoRenderer(handle)
                throw CancellationError()
            }
            if localVideoRenderer == nil {
                localVideoRenderer = handle
            } else {
                await engine.releaseVideoRenderer(handle)
            }
        }
        if remoteVideoRenderer == nil {
            let handle = try await engine.makeVideoRenderer(source: .remote)
            guard self.runtime === runtime else {
                await engine.releaseVideoRenderer(handle)
                throw CancellationError()
            }
            if remoteVideoRenderer == nil {
                remoteVideoRenderer = handle
            } else {
                await engine.releaseVideoRenderer(handle)
            }
        }
        if pictureInPictureVideoRenderer == nil {
            let handle = try await engine.makeVideoRenderer(source: .remote)
            guard self.runtime === runtime else {
                await engine.releaseVideoRenderer(handle)
                throw CancellationError()
            }
            if pictureInPictureVideoRenderer == nil {
                pictureInPictureVideoRenderer = handle
            } else {
                await engine.releaseVideoRenderer(handle)
            }
        }
    }

    func applyVideoCaptureDecision(runtime: Runtime) async {
        guard self.runtime === runtime,
              let engine = runtime.engine,
              runtime.selectedMediaProfile == CallMediaProfileVersion.cameraVideo else { return }
        runtime.cameraApplyGeneration &+= 1
        let applyGeneration = runtime.cameraApplyGeneration
        let decision = videoReducer.decision()
        localVideoState = decision.effectiveState
        do {
            try await engine.setCameraEnabled(
                decision.shouldCapture,
                position: decision.preferredCameraPosition
            )
            guard self.runtime === runtime,
                  runtime.cameraApplyGeneration == applyGeneration else { return }
        } catch {
            guard self.runtime === runtime,
                  runtime.cameraApplyGeneration == applyGeneration else { return }
            videoReducer.setCaptureHealth(
                interrupted: false,
                runtimeFailed: true,
                cameraAvailable: false,
                pressureCritical: false,
                generation: runtime.cameraGeneration
            )
            localVideoState = .paused
        }
    }

    func sendMediaState(runtime: Runtime, force: Bool = false) async throws {
        guard self.runtime === runtime,
              runtime.mediaStarted,
              runtime.cipher != nil,
              runtime.selectedMediaProfile == CallMediaProfileVersion.cameraVideo else { return }
        let followingRevision = try CallMediaRevisionPolicy.advanced(
            after: runtime.localNextMediaRevision
        )
        let decision = videoReducer.decision()
        let candidate = CallMediaStateUpdateV1(
            version: CallMediaStateUpdateV1.currentVersion,
            revision: runtime.localNextMediaRevision,
            desiredCameraState: videoReducer.userWantsCamera,
            effectiveState: decision.effectiveState,
            genericPauseReason: decision.genericPauseReason,
            requestedMaximumReceiveTier: videoQuality.requestedReceiveTier
        )
        if !force, let previous = runtime.lastSentMediaState,
           previous.desiredCameraState == candidate.desiredCameraState,
           previous.effectiveState == candidate.effectiveState,
           previous.genericPauseReason == candidate.genericPauseReason,
           previous.requestedMaximumReceiveTier == candidate.requestedMaximumReceiveTier {
            return
        }
        runtime.localNextMediaRevision = followingRevision
        try await sendSignal(
            .control,
            payload: CallWirePayload(
                description: nil,
                candidate: nil,
                mediaState: candidate
            ),
            runtime: runtime
        )
        runtime.lastSentMediaState = candidate
    }

    func startVideoQualityLoop(runtime: Runtime) {
        qualityTask?.cancel()
        guard runtime.selectedMediaProfile == CallMediaProfileVersion.cameraVideo else { return }
        let id = runtime.id
        let qualityScheduler = clock
        let qualityNetworkPath = networkPath
        qualityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await qualityScheduler.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let current = self.runtime,
                      current.id == id, let engine = current.engine else { return }
                let stats = await engine.statistics()
                let now = qualityScheduler.uptime
                let path = qualityNetworkPath.snapshot()
                let pathChanged = current.lastNetworkPath.map { $0 != path } ?? false
                if pathChanged { self.videoQuality.resetBaselines() }
                current.lastNetworkPath = path
                let pathPolicy = CallVideoPathPolicy(
                    kind: path.networkClass == .cellular || path.networkClass == .roaming
                        ? .cellular : path.networkClass == .wifi ? .wifi : .other,
                    isConstrained: path.isConstrained,
                    isLowDataMode: path.isConstrained,
                    isRoaming: path.isRoaming
                )
                let thermal = self.currentThermalState()
                self.videoReducer.setThermalState(
                    thermal,
                    now: qualityScheduler.now,
                    generation: current.cameraGeneration
                )
                self.videoQuality.ingestSender(
                    stats.map {
                        CallVideoSenderStats(
                            timestamp: now,
                            packetsLost: $0.videoPacketsLost,
                            packetsSent: $0.videoPacketsSent,
                            roundTripTimeMilliseconds: $0.roundTripTimeMilliseconds,
                            jitterMilliseconds: $0.jitterMilliseconds,
                            availableOutgoingBitrate: $0.availableOutgoingBitrate
                        )
                    },
                    policy: self.preferences.dataUsagePolicy,
                    path: pathPolicy,
                    thermal: thermal,
                    peerMaximumReceiveTier: current.peerMaximumReceiveTier
                )
                self.videoQuality.ingestReceiver(
                    stats.map {
                        CallVideoReceiverStats(
                            timestamp: now,
                            packetsLost: $0.videoInboundPacketsLost,
                            packetsReceived: $0.videoPacketsReceived,
                            jitterMilliseconds: $0.videoJitterMilliseconds,
                            totalFreezeMilliseconds: $0.videoTotalFreezeMilliseconds,
                            totalFramesDecoded: $0.videoFramesDecoded
                        )
                    },
                    policy: self.preferences.dataUsagePolicy,
                    path: pathPolicy,
                    thermal: thermal
                )
                let previousTier = self.videoQualityTier
                self.videoQualityTier = self.videoQuality.senderTier
                self.videoIsAutomaticallyPaused = self.videoQuality.outgoingVideoPaused
                let frameRateCap = thermal == .serious ? 15 : nil
                let captureConfigurationChanged = previousTier != self.videoQuality.senderTier
                    || current.lastMaximumVideoFramesPerSecond != frameRateCap
                try? await engine.setVideoQualityTier(
                    self.videoQuality.senderTier,
                    maximumFramesPerSecond: frameRateCap
                )
                current.lastMaximumVideoFramesPerSecond = frameRateCap
                if captureConfigurationChanged {
                    self.videoQuality.resetBaselines()
                }
                self.videoReducer.setNetworkStarved(
                    self.videoQuality.outgoingVideoPaused,
                    generation: current.cameraGeneration
                )
                await self.applyVideoCaptureDecision(runtime: current)
                try? await self.sendMediaState(
                    runtime: current,
                    force: pathChanged || captureConfigurationChanged
                )
            }
        }
    }

    func currentThermalState() -> CallVideoThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }

    func waitForConfiguration() async -> Bool {
        let deadline = clock.now.addingTimeInterval(8)
        while (api == nil || session == nil), clock.now < deadline, !Task.isCancelled {
            try? await clock.sleep(for: .milliseconds(100))
        }
        return api != nil && session != nil
    }

    func requireCurrent(_ runtime: Runtime, session: CloudSession) throws {
        try Task.checkCancellation()
        guard self.runtime === runtime, self.session == session else {
            throw CancellationError()
        }
    }

    func requireCurrent(_ runtime: Runtime) throws {
        try Task.checkCancellation()
        guard self.runtime === runtime else { throw CancellationError() }
    }

    func friendly(_ error: Error) -> String {
        if let apiError = error as? CloudAPIError {
            switch apiError.code {
            case "busy": return String(localized: "This person is already on another call.")
            case "blocked", "ineligible": return String(localized: "Voice calls are not available in this conversation.")
            case "answered_elsewhere": return String(localized: "Answered on another device.")
            case "rate_limited": return String(localized: "Too many calls. Please try again shortly.")
            case "video_unavailable": return String(localized: "Video is unavailable for this call. You can still place an audio call.")
            default: return apiError.localizedDescription
            }
        }
        if error as? WebRTCEngineError == .frameworkUnavailable {
            return String(localized: "Secure calling is unavailable in this build.")
        }
        return error.localizedDescription
    }

    func isSecurityFailure(_ error: Error) -> Bool {
        if error is CallProtocolError { return true }
        if let crypto = error as? CallCryptoError {
            switch crypto {
            case .invalidPeerPublicKey, .invalidTranscript, .weakSharedSecret,
                 .invalidSequence, .sequenceTooFarAhead, .replayedSequence,
                 .metadataMismatch, .invalidNonce, .authenticationFailed:
                return true
            case .invalidPrivateKey, .plaintextTooLarge, .sequenceExhausted, .expired:
                return false
            }
        }
        return (error as? WebRTCEngineError) == .invalidFingerprint
    }

    func callEndReason(_ error: Error) -> CallEndReason {
        guard let code = (error as? CloudAPIError)?.code else { return .failed }
        switch code {
        case "busy": return .busy
        case "answered_elsewhere": return .answeredElsewhere
        case "expired": return .unanswered
        case "blocked", "ineligible": return .declined
        default: return .failed
        }
    }

    func endReason(_ raw: String?) -> CallEndReason {
        CallServerEndReasonPolicy.resolve(raw)
    }
}

@MainActor
final class OrderedCallSignalOutbox {
    private var tail: Task<Void, Error>?
    private var tasks: [UUID: Task<Void, Error>] = [:]
    private var isClosed = false

    func perform(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        guard !isClosed else { throw CancellationError() }
        let predecessor = tail
        let id = UUID()
        let task = Task { @MainActor in
            if let predecessor { _ = try? await predecessor.value }
            try Task.checkCancellation()
            try await operation()
        }
        tail = task
        tasks[id] = task
        defer { tasks.removeValue(forKey: id) }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancel() {
        isClosed = true
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        tail = nil
    }
}

private extension CallAudioRoute {
    var displayName: String {
        switch self {
        case .builtInReceiver: String(localized: "iPhone")
        case .speaker: String(localized: "Speaker")
        case .bluetooth: String(localized: "Bluetooth")
        case .wired: String(localized: "Headphones")
        case .airPlay: String(localized: "AirPlay")
        case .unknown: String(localized: "Audio")
        }
    }
}

private extension CallEndReason {
    var callKitReason: CXCallEndedReason {
        switch self {
        case .answeredElsewhere: .answeredElsewhere
        case .unanswered, .cancelled: .unanswered
        case .remoteEnded, .declined: .remoteEnded
        case .busy, .networkLost, .securityError, .permissionDenied, .failed: .failed
        }
    }
}
