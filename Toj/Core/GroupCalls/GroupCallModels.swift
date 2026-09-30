import Foundation

nonisolated enum GroupCallInitialKind: String, Codable, CaseIterable, Sendable {
    case voice
    case video
}

nonisolated struct GroupCallDeviceCapabilities: Codable, Equatable, Sendable {
    let supportedGroupCallVersions: [UInt16]
    let groupCallViewVersion: UInt16
    let supportsGroupScreenShare: Bool

    static let legacy = Self(
        supportedGroupCallVersions: [],
        groupCallViewVersion: 0,
        supportsGroupScreenShare: false
    )
}

nonisolated struct GroupCallCapabilityRegistrationRequest: Codable, Equatable, Sendable {
    let supportedGroupCallVersions: [Int]
    let groupCallViewVersion: Int
    let supportsGroupScreenShare: Bool
}

nonisolated struct GroupCallCapabilityRegistrationResponse: Codable, Equatable, Sendable {
    let registered: Bool
    let supportedGroupCallVersions: [Int]
    let groupCallViewVersion: Int
    let supportsGroupScreenShare: Bool
}

nonisolated enum GroupCallParticipantStatus: String, Codable, Sendable {
    case pendingKey = "pending_key"
    case active
}

nonisolated struct CloudGroupCallParticipant: Codable, Identifiable, Equatable, Sendable {
    var id: String { participantId }

    let accountId: String
    let deviceId: String
    let participantId: String
    let status: GroupCallParticipantStatus
    let joinPublicKey: String
    let joinNonce: String
    let joinedMembershipRevision: Int64
    let readyMediaEpoch: Int64?
    let joinedAt: String
    let isSelf: Bool
    let isKeyLeader: Bool
}

nonisolated struct CloudGroupCallEpoch: Codable, Equatable, Sendable {
    let epoch: Int64
    let membershipRevision: Int64
    let keyCommitment: String
    let participantSetHash: String
    let activatedAt: String
    let previousEpochGraceExpiresAt: String?
}

nonisolated struct CloudGroupCallEpochEnvelope: Codable, Equatable, Sendable {
    let epoch: Int64
    let senderPublicKey: String
    let recipientPublicKey: String
    let ciphertext: String
}

nonisolated struct CloudGroupCallScreenShare: Codable, Equatable, Sendable {
    let participantId: String
    let expiresAt: String
}

nonisolated struct CloudGroupCallSnapshot: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let dialogId: String
    let initialKind: GroupCallInitialKind
    let state: String
    let participantLimit: Int
    let publisherLimit: Int
    let membershipRevision: Int64
    let stateRevision: Int64
    let selfRole: String
    let mediaEpoch: Int64
    let keyLeaderDeviceId: String
    let rekeyRequired: Bool
    let epoch: CloudGroupCallEpoch
    let participants: [CloudGroupCallParticipant]
    let selfEnvelope: CloudGroupCallEpochEnvelope?
    let cameraPublishers: [String]
    let screenShare: CloudGroupCallScreenShare?
    let createdAt: String
    let endedAt: String?
    let endReason: String?

    var selfParticipant: CloudGroupCallParticipant? {
        participants.first(where: \.isSelf)
    }

    var isActive: Bool { state == "active" && endedAt == nil }
}

nonisolated struct CloudGroupCallCredentials: Codable, Equatable, Sendable {
    let url: String
    let token: String
    let participantId: String
    let expiresAt: String
    let mediaEpoch: Int64
}

nonisolated struct CloudGroupCallResponse: Codable, Equatable, Sendable {
    let call: CloudGroupCallSnapshot
}

nonisolated struct CloudActiveGroupCallResponse: Codable, Equatable, Sendable {
    let call: CloudGroupCallSnapshot?
}

nonisolated struct CloudGroupCallStartResponse: Codable, Equatable, Sendable {
    let call: CloudGroupCallSnapshot
    let credentials: CloudGroupCallCredentials
    let duplicate: Bool
}

nonisolated struct CloudGroupCallJoinResponse: Codable, Equatable, Sendable {
    let call: CloudGroupCallSnapshot
    let duplicate: Bool
}

nonisolated struct CloudGroupCallCredentialsResponse: Codable, Equatable, Sendable {
    let credentials: CloudGroupCallCredentials
}

nonisolated struct CloudGroupCallHeartbeatResponse: Codable, Equatable, Sendable {
    let state: String
    let stateRevision: Int64
}

nonisolated struct CloudGroupCallScreenLeaseResponse: Codable, Equatable, Sendable {
    let generation: String
    let expiresAt: String
    let call: CloudGroupCallSnapshot?
}

nonisolated struct CloudGroupCallCameraLeaseResponse: Codable, Equatable, Sendable {
    let generation: String
    let expiresAt: String
    let call: CloudGroupCallSnapshot?
}

nonisolated struct CloudGroupCallScreenReleaseResponse: Codable, Equatable, Sendable {
    let released: Bool
}

nonisolated struct GroupCallEpochRecipientEnvelope: Codable, Equatable, Sendable {
    let recipientDeviceId: String
    let ciphertext: String
}

nonisolated struct StartCloudGroupCallRequest: Codable, Equatable, Sendable {
    let callId: String
    let dialogId: String
    let initialKind: GroupCallInitialKind
    let joinPublicKey: String
    let joinNonce: String
    let epochKeyCommitment: String
}

nonisolated struct JoinCloudGroupCallRequest: Codable, Equatable, Sendable {
    let joinPublicKey: String
    let joinNonce: String
}

nonisolated struct ActivateCloudGroupCallEpochRequest: Codable, Equatable, Sendable {
    let epoch: Int64
    let expectedMembershipRevision: Int64
    let keyCommitment: String
    let participantSetHash: String
    let envelopes: [GroupCallEpochRecipientEnvelope]
}

nonisolated struct CloudGroupCallScreenLeaseRequest: Codable, Equatable, Sendable {
    let generation: String
}

nonisolated struct CloudGroupCallEndRequest: Codable, Equatable, Sendable {
    let reason: String
}

nonisolated struct CloudGroupCallEmptyRequest: Codable, Equatable, Sendable {}

nonisolated struct GroupCallHint: Codable, Equatable, Sendable {
    let type: String
    let callId: String
    let stateRevision: Int64
}

/// Narrow transport seam for deterministic coordinator tests. The production implementation is
/// `CloudAPI`; no SFU administrative credential crosses this client interface.
nonisolated protocol GroupCallAPITransport {
    func startGroupCall(
        _ body: StartCloudGroupCallRequest,
        token: String
    ) async throws -> CloudGroupCallStartResponse
    func activeGroupCall(dialogId: String, token: String) async throws -> CloudActiveGroupCallResponse
    func groupCall(id: String, token: String) async throws -> CloudGroupCallResponse
    func joinGroupCall(
        id: String,
        body: JoinCloudGroupCallRequest,
        token: String
    ) async throws -> CloudGroupCallJoinResponse
    func activateGroupCallEpoch(
        id: String,
        body: ActivateCloudGroupCallEpochRequest,
        token: String
    ) async throws -> CloudGroupCallJoinResponse
    func groupCallCredentials(id: String, token: String) async throws -> CloudGroupCallCredentialsResponse
    func heartbeatGroupCall(id: String, token: String) async throws -> CloudGroupCallHeartbeatResponse
    func leaveGroupCall(id: String, token: String) async throws -> CloudGroupCallJoinResponse
    func endGroupCall(id: String, reason: String, token: String) async throws -> CloudGroupCallJoinResponse
    func removeGroupCallParticipant(
        callId: String,
        deviceId: String,
        token: String
    ) async throws -> CloudGroupCallResponse
    func acquireGroupCamera(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallCameraLeaseResponse
    func heartbeatGroupCamera(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallCameraLeaseResponse
    func releaseGroupCamera(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallScreenReleaseResponse
    func acquireGroupScreenShare(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallScreenLeaseResponse
    func heartbeatGroupScreenShare(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallScreenLeaseResponse
    func releaseGroupScreenShare(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallScreenReleaseResponse
}

extension CloudAPI: GroupCallAPITransport {}

nonisolated enum GroupCallConnectionState: String, Codable, Equatable, Sendable {
    case idle
    case preparing
    case waitingForKey = "waiting_for_key"
    case connecting
    case connected
    case reconnecting
    case ending
    case ended
    case failed
}

nonisolated enum GroupCallSecurityState: String, Codable, Equatable, Sendable {
    case preparing
    case keyReady = "key_ready"
    case verified
    case rekeying
    case failed
}

nonisolated enum GroupCallCameraPosition: String, Codable, Equatable, Sendable {
    case front
    case back
}

nonisolated enum GroupCallQualityTier: Int, Codable, CaseIterable, Comparable, Sendable {
    case low
    case medium
    case high

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var maximumVideoBitrate: Int {
        switch self {
        case .low: 180_000
        case .medium: 600_000
        case .high: 1_500_000
        }
    }

    var captureFramesPerSecond: Int {
        switch self {
        case .low: 15
        case .medium: 24
        case .high: 30
        }
    }
}

nonisolated struct GroupCallEngineParticipant: Identifiable, Equatable, Sendable {
    let id: String
    let isSpeaking: Bool
    let connectionQuality: String
    let hasCamera: Bool
    let hasScreenShare: Bool
}

nonisolated struct GroupCallPresentationParticipant: Identifiable, Equatable, Sendable {
    let id: String
    let accountId: String
    let participantId: String
    let displayName: String
    let isSelf: Bool
    let isSpeaking: Bool
    let connectionQuality: String
    let hasCamera: Bool
    let hasScreenShare: Bool
}
