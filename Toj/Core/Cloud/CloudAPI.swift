import Foundation

nonisolated struct CloudReaction: Codable, Equatable, Sendable {
    let accountId: String
    let emoji: String

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case emoji
    }
}

nonisolated struct CloudMention: Codable, Equatable, Sendable {
    let accountId: String
    let offset: Int
    let length: Int

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case offset, length
    }
}

nonisolated struct CloudMessage: Codable, Identifiable, Equatable, Sendable {
    nonisolated var id: String { "\(dialogId):\(msgId)" }
    let dialogId: String
    let msgId: Int64
    let senderAccountId: String
    let clientMsgId: String
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
    let mediaGroupId: String?
    let mediaGroupIndex: Int?
    let mediaGroupCount: Int?
    let serviceType: String?
    let serviceData: CloudServiceData?
    let linkPreview: CloudLinkPreview?
    let editVersion: Int
    let state: String
    let serverTs: String

    init(
        dialogId: String,
        msgId: Int64,
        senderAccountId: String,
        clientMsgId: String,
        kind: String,
        text: String,
        replyToMsgId: Int64? = nil,
        forwardedFromAccountId: String? = nil,
        forwardedFromDialogId: String? = nil,
        forwardedFromMsgId: Int64? = nil,
        isForwarded: Bool = false,
        reactions: [CloudReaction] = [],
        mentions: [CloudMention] = [],
        media: CloudMedia? = nil,
        mediaGroupId: String? = nil,
        mediaGroupIndex: Int? = nil,
        mediaGroupCount: Int? = nil,
        serviceType: String? = nil,
        serviceData: CloudServiceData? = nil,
        linkPreview: CloudLinkPreview? = nil,
        editVersion: Int,
        state: String,
        serverTs: String
    ) {
        self.dialogId = dialogId
        self.msgId = msgId
        self.senderAccountId = senderAccountId
        self.clientMsgId = clientMsgId
        self.kind = kind
        self.text = text
        self.replyToMsgId = replyToMsgId
        self.forwardedFromAccountId = forwardedFromAccountId
        self.forwardedFromDialogId = forwardedFromDialogId
        self.forwardedFromMsgId = forwardedFromMsgId
        self.isForwarded = isForwarded
        self.reactions = reactions
        self.mentions = mentions
        self.media = media
        self.mediaGroupId = mediaGroupId
        self.mediaGroupIndex = mediaGroupIndex
        self.mediaGroupCount = mediaGroupCount
        self.serviceType = serviceType
        self.serviceData = serviceData
        self.linkPreview = linkPreview
        self.editVersion = editVersion
        self.state = state
        self.serverTs = serverTs
    }

    enum CodingKeys: String, CodingKey {
        case dialogId = "dialog_id"
        case msgId = "msg_id"
        case senderAccountId = "sender_account_id"
        case clientMsgId = "client_msg_id"
        case kind
        case text
        case replyToMsgId = "reply_to_msg_id"
        case forwardedFromAccountId = "forwarded_from_account_id"
        case forwardedFromDialogId = "forwarded_from_dialog_id"
        case forwardedFromMsgId = "forwarded_from_msg_id"
        case isForwarded = "forwarded"
        case reactions
        case mentions
        case media
        case mediaGroupId = "media_group_id"
        case mediaGroupIndex = "media_group_index"
        case mediaGroupCount = "media_group_count"
        case serviceType = "service_type"
        case serviceData = "service_data"
        case linkPreview = "link_preview"
        case editVersion = "edit_version"
        case state
        case serverTs = "server_ts"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dialogId = try values.decode(String.self, forKey: .dialogId)
        msgId = try values.decode(Int64.self, forKey: .msgId)
        senderAccountId = try values.decode(String.self, forKey: .senderAccountId)
        clientMsgId = try values.decode(String.self, forKey: .clientMsgId)
        kind = try values.decode(String.self, forKey: .kind)
        text = try values.decode(String.self, forKey: .text)
        replyToMsgId = try values.decodeIfPresent(Int64.self, forKey: .replyToMsgId)
        forwardedFromAccountId = try values.decodeIfPresent(String.self, forKey: .forwardedFromAccountId)
        forwardedFromDialogId = try values.decodeIfPresent(String.self, forKey: .forwardedFromDialogId)
        forwardedFromMsgId = try values.decodeIfPresent(Int64.self, forKey: .forwardedFromMsgId)
        isForwarded = try values.decodeIfPresent(Bool.self, forKey: .isForwarded) ?? false
        reactions = try values.decodeIfPresent([CloudReaction].self, forKey: .reactions) ?? []
        mentions = try values.decodeIfPresent([CloudMention].self, forKey: .mentions) ?? []
        media = try values.decodeIfPresent(CloudMedia.self, forKey: .media)
        mediaGroupId = try values.decodeIfPresent(String.self, forKey: .mediaGroupId)
        mediaGroupIndex = try values.decodeIfPresent(Int.self, forKey: .mediaGroupIndex)
        mediaGroupCount = try values.decodeIfPresent(Int.self, forKey: .mediaGroupCount)
        serviceType = try values.decodeIfPresent(String.self, forKey: .serviceType)
        serviceData = try values.decodeIfPresent(CloudServiceData.self, forKey: .serviceData)
        linkPreview = try values.decodeIfPresent(CloudLinkPreview.self, forKey: .linkPreview)
        editVersion = try values.decode(Int.self, forKey: .editVersion)
        state = try values.decode(String.self, forKey: .state)
        serverTs = try values.decode(String.self, forKey: .serverTs)
    }
}

nonisolated struct CloudDraftReplyPreview: Codable, Equatable, Sendable {
    let msgId: Int64
    let senderAccountId: String
    let text: String
    let unavailable: Bool

    enum CodingKeys: String, CodingKey {
        case msgId = "msg_id"
        case senderAccountId = "sender_account_id"
        case text, unavailable
    }
}

nonisolated struct CloudDraftAttachment: Codable, Equatable, Sendable {
    let attachmentId: String
    let mediaId: String
    let position: Int
    let media: CloudMedia

    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case mediaId = "media_id"
        case position, media
    }
}

nonisolated struct CloudDraft: Codable, Equatable, Sendable {
    let dialogId: String
    let revision: Int64
    let state: String
    let text: String
    let replyToMsgId: Int64?
    let replyPreview: CloudDraftReplyPreview?
    let mentions: [CloudMention]
    let attachments: [CloudDraftAttachment]
    let operationId: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case dialogId = "dialog_id"
        case revision, state, text
        case replyToMsgId = "reply_to_msg_id"
        case replyPreview = "reply_preview"
        case mentions, attachments
        case operationId = "operation_id"
        case updatedAt = "updated_at"
    }
}

nonisolated struct CloudUpdate: Codable, Sendable {
    let pts: Int64
    let ptsCount: Int64
    let type: String
    let dialogId: String?
    let dialogTitle: String?
    let dialogType: String?
    let message: CloudMessage?
    let draft: CloudDraft?
    let group: CloudUpdateGroup?
    let member: CloudGroupMember?
    let readerAccountId: String?
    let maxReadMsgId: Int64?
    let unreadCount: Int?
    let subjectAccountId: String?
    let username: String?
    let firstName: String?
    let lastName: String?
    let displayName: String?
    let bio: String?
    let birthday: String?
    let colorIndex: Int?
    let photo: CloudMedia?
    let photoRevision: Int64?
    let profileUpdatedAt: String?
    let peerAccountId: String?
    let sharedDialogIds: [String]?
    let preferences: CloudDialogPreferences?
    let clientMutationId: String?
    let changedFields: [String]?
    let chatFolders: CloudChatFolderSnapshot?
    let scheduledDelivery: CloudScheduledDelivery?
    let scheduledDeliveryId: String?
    let collectionRevision: Int64?

    init(
        pts: Int64,
        ptsCount: Int64,
        type: String,
        dialogId: String?,
        dialogTitle: String?,
        dialogType: String? = nil,
        message: CloudMessage?,
        draft: CloudDraft? = nil,
        group: CloudUpdateGroup? = nil,
        member: CloudGroupMember? = nil,
        readerAccountId: String?,
        maxReadMsgId: Int64?,
        unreadCount: Int? = nil,
        subjectAccountId: String? = nil,
        username: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        displayName: String? = nil,
        bio: String? = nil,
        birthday: String? = nil,
        colorIndex: Int? = nil,
        photo: CloudMedia? = nil,
        photoRevision: Int64? = nil,
        profileUpdatedAt: String? = nil,
        peerAccountId: String? = nil,
        sharedDialogIds: [String]? = nil,
        preferences: CloudDialogPreferences? = nil,
        clientMutationId: String? = nil,
        changedFields: [String]? = nil,
        chatFolders: CloudChatFolderSnapshot? = nil,
        scheduledDelivery: CloudScheduledDelivery? = nil,
        scheduledDeliveryId: String? = nil,
        collectionRevision: Int64? = nil
    ) {
        self.pts = pts
        self.ptsCount = ptsCount
        self.type = type
        self.dialogId = dialogId
        self.dialogTitle = dialogTitle
        self.dialogType = dialogType
        self.message = message
        self.draft = draft
        self.group = group
        self.member = member
        self.readerAccountId = readerAccountId
        self.maxReadMsgId = maxReadMsgId
        self.unreadCount = unreadCount
        self.subjectAccountId = subjectAccountId
        self.username = username
        self.firstName = firstName
        self.lastName = lastName
        self.displayName = displayName
        self.bio = bio
        self.birthday = birthday
        self.colorIndex = colorIndex
        self.photo = photo
        self.photoRevision = photoRevision
        self.profileUpdatedAt = profileUpdatedAt
        self.peerAccountId = peerAccountId
        self.sharedDialogIds = sharedDialogIds
        self.preferences = preferences
        self.clientMutationId = clientMutationId
        self.changedFields = changedFields
        self.chatFolders = chatFolders
        self.scheduledDelivery = scheduledDelivery
        self.scheduledDeliveryId = scheduledDeliveryId
        self.collectionRevision = collectionRevision
    }

    enum CodingKeys: String, CodingKey {
        case pts
        case ptsCount
        case type
        case dialogId = "dialog_id"
        case dialogTitle = "dialog_title"
        case dialogType = "dialog_type"
        case message
        case draft
        case group
        case member
        case readerAccountId = "reader_account_id"
        case maxReadMsgId = "max_read_msg_id"
        case unreadCount = "unread_count"
        case subjectAccountId = "subject_account_id"
        case username
        case firstName = "first_name"
        case lastName = "last_name"
        case displayName = "display_name"
        case bio
        case birthday
        case colorIndex = "color_index"
        case photo
        case photoRevision = "photo_revision"
        case profileUpdatedAt = "updated_at"
        case peerAccountId = "peer_account_id"
        case sharedDialogIds = "shared_dialog_ids"
        case preferences
        case clientMutationId = "client_mutation_id"
        case changedFields = "changed_fields"
        case chatFolders = "chat_folders"
        case scheduledDelivery = "scheduled_delivery"
        case scheduledDeliveryId = "scheduled_delivery_id"
        case collectionRevision = "collection_revision"
    }
}

nonisolated struct CloudSession: Codable, Equatable, Sendable {
    let accountId: String
    let deviceId: String
    let token: String
    let refreshToken: String?
    let accessTokenExpiresAt: String?
    let sessionExpiresAt: String?
    let tokenVersion: Int

    enum CodingKeys: String, CodingKey {
        case accountId
        case deviceId
        case token
        case accessToken
        case refreshToken
        case accessTokenExpiresAt
        case sessionExpiresAt
        case tokenVersion
    }

    init(
        accountId: String,
        deviceId: String,
        token: String,
        refreshToken: String? = nil,
        accessTokenExpiresAt: String? = nil,
        sessionExpiresAt: String? = nil,
        tokenVersion: Int = 1
    ) {
        self.accountId = accountId
        self.deviceId = deviceId
        self.token = token
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.sessionExpiresAt = sessionExpiresAt
        self.tokenVersion = tokenVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try container.decode(String.self, forKey: .accountId)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        token = try container.decodeIfPresent(String.self, forKey: .accessToken)
            ?? container.decode(String.self, forKey: .token)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        accessTokenExpiresAt = try container.decodeIfPresent(String.self, forKey: .accessTokenExpiresAt)
        sessionExpiresAt = try container.decodeIfPresent(String.self, forKey: .sessionExpiresAt)
        tokenVersion = try container.decodeIfPresent(Int.self, forKey: .tokenVersion)
            ?? (refreshToken == nil ? 1 : 2)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountId, forKey: .accountId)
        try container.encode(deviceId, forKey: .deviceId)
        if tokenVersion >= 2 {
            try container.encode(token, forKey: .accessToken)
        } else {
            try container.encode(token, forKey: .token)
        }
        try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try container.encodeIfPresent(accessTokenExpiresAt, forKey: .accessTokenExpiresAt)
        try container.encodeIfPresent(sessionExpiresAt, forKey: .sessionExpiresAt)
        try container.encode(tokenVersion, forKey: .tokenVersion)
    }
}

nonisolated struct StoredCloudSession: Codable, Equatable, Sendable {
    let session: CloudSession
    let phone: String
    let displayName: String
}

nonisolated struct AuthStartResponse: Codable, Sendable {
    let code: String?
    let retryAfter: Int?
}

nonisolated struct AuthV2CheckResponse: Codable, Sendable {
    let state: String
    let session: CloudSession?
    let challengeId: String?
    let expiresAt: String?
}

nonisolated struct TwoFactorLoginResponse: Codable, Sendable {
    let session: CloudSession
    let recoveryCodes: [String]?
}

nonisolated struct TwoFactorStatusResponse: Codable, Sendable {
    let enabled: Bool
    let recoveryCodesRemaining: Int
}

nonisolated struct SecurityStepUpResponse: Codable, Sendable {
    let stepUpToken: String
    let expiresAt: String
}

nonisolated struct TwoFactorConfigurationResponse: Codable, Sendable {
    let enabled: Bool
    let recoveryCodes: [String]?
    let session: CloudSession
}

nonisolated struct ContactLookupResponse: Codable, Sendable {
    let accountId: String?
    let displayName: String?
    let found: Bool?
    let username: String?
    let firstName: String?
    let lastName: String?
    let bio: String?
    let birthday: String?
    let colorIndex: Int?
    let photo: CloudMedia?
    let photoRevision: Int64?
    let updatedAt: String?
}

nonisolated struct CloudProfile: Codable, Equatable, Sendable {
    let accountId: String
    var username: String? = nil
    let firstName: String
    let lastName: String
    let displayName: String
    let bio: String
    let birthday: String?
    let colorIndex: Int
    let photo: CloudMedia?
    let photoRevision: Int64
    let updatedAt: String

    init(
        accountId: String,
        username: String? = nil,
        firstName: String,
        lastName: String,
        displayName: String,
        bio: String,
        birthday: String?,
        colorIndex: Int,
        photo: CloudMedia? = nil,
        photoRevision: Int64 = 0,
        updatedAt: String
    ) {
        self.accountId = accountId
        self.username = username
        self.firstName = firstName
        self.lastName = lastName
        self.displayName = displayName
        self.bio = bio
        self.birthday = birthday
        self.colorIndex = colorIndex
        self.photo = photo
        self.photoRevision = photoRevision
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try values.decode(String.self, forKey: .accountId)
        username = try values.decodeIfPresent(String.self, forKey: .username)
        firstName = try values.decode(String.self, forKey: .firstName)
        lastName = try values.decode(String.self, forKey: .lastName)
        displayName = try values.decode(String.self, forKey: .displayName)
        bio = try values.decode(String.self, forKey: .bio)
        birthday = try values.decodeIfPresent(String.self, forKey: .birthday)
        colorIndex = try values.decode(Int.self, forKey: .colorIndex)
        photo = try values.decodeIfPresent(CloudMedia.self, forKey: .photo)
        photoRevision = try values.decodeIfPresent(Int64.self, forKey: .photoRevision) ?? 0
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case accountId, username, firstName, lastName, displayName, bio, birthday, colorIndex
        case photo, photoRevision, updatedAt
    }
}

nonisolated struct ProfilePhotoMutationResponse: Codable, Sendable {
    let profile: CloudProfile
    let committedPhotoRevision: Int64
    let duplicate: Bool
}

nonisolated struct CloudServiceData: Codable, Equatable, Sendable {
    let actorAccountId: String?
    let subjectAccountId: String?
    let memberAccountIds: [String]?
    let successorAccountId: String?
    let role: String?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case actorAccountId = "actor_account_id"
        case subjectAccountId = "subject_account_id"
        case memberAccountIds = "member_account_ids"
        case successorAccountId = "successor_account_id"
        case role
        case title
    }
}

nonisolated struct CloudUpdateGroup: Codable, Equatable, Sendable {
    let id: String
    let title: String?
    let revision: Int64
    let memberCount: Int
}

nonisolated struct CloudDialogPreferences: Codable, Equatable, Sendable {
    let dialogId: String
    let pinned: Bool
    let pinnedAt: String?
    let muted: Bool
    let archived: Bool
    let updatedAt: String
}

nonisolated struct CloudGroup: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let photo: CloudMedia?
    let revision: Int64
    let memberCount: Int
    let selfRole: String
    let notificationMode: String
    let createdBy: String
    let createdAt: String
    let closedAt: String?
    var membersCanSend: Bool? = nil
    var membersCanAddMembers: Bool? = nil
    var membersCanEditInfo: Bool? = nil
}

nonisolated struct CloudGroupMember: Codable, Equatable, Sendable {
    let accountId: String
    let role: String
    let joinedAt: String
    let isActive: Bool
}

nonisolated struct CloudGroupEnvelope: Codable, Sendable {
    let group: CloudGroup
    let members: [CloudGroupMember]?
    let profiles: [CloudProfile]
    let duplicate: Bool?
}

nonisolated struct CloudGroupMembersPage: Codable, Sendable {
    let group: CloudGroup
    let members: [CloudGroupMember]
    let profiles: [CloudProfile]
    let nextCursor: String?
    let hasMore: Bool
}

nonisolated struct CloudGroupLeaveResponse: Codable, Sendable {
    let left: Bool
    let closed: Bool
}

private struct ProfileUpdateRequest: Encodable, Sendable {
    let username: String?
    let firstName: String
    let lastName: String
    let bio: String
    let birthday: String?
    let colorIndex: Int

    enum CodingKeys: String, CodingKey {
        case username, firstName, lastName, bio, birthday, colorIndex
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // This client edits the complete profile. Encode an explicit null for a cleared handle;
        // omission is reserved for legacy clients and means "preserve" on the server.
        if let username {
            try container.encode(username, forKey: .username)
        } else {
            try container.encodeNil(forKey: .username)
        }
        try container.encode(firstName, forKey: .firstName)
        try container.encode(lastName, forKey: .lastName)
        try container.encode(bio, forKey: .bio)
        try container.encodeIfPresent(birthday, forKey: .birthday)
        try container.encode(colorIndex, forKey: .colorIndex)
    }
}

nonisolated struct DirectDialogResponse: Codable, Sendable {
    let dialogId: String
    let created: Bool
}

nonisolated struct SavedDialogResponse: Codable, Equatable, Sendable {
    let dialogId: String
    let type: String
    let created: Bool
    let repaired: Bool
    let eventPts: Int64?
}

nonisolated struct DialogPreferencesResponse: Codable, Sendable {
    let preferences: CloudDialogPreferences
    let pts: Int64
    let duplicate: Bool
}

nonisolated struct SendMessageResponse: Codable, Sendable {
    let dialogId: String
    let clientMsgId: String
    let msgId: Int64
    let senderPts: Int64
    let clearedDraftRevision: Int64?
    let duplicate: Bool
    let serverTs: String?
    let text: String?

    init(
        dialogId: String,
        clientMsgId: String,
        msgId: Int64,
        senderPts: Int64,
        clearedDraftRevision: Int64? = nil,
        duplicate: Bool,
        serverTs: String?,
        text: String?
    ) {
        self.dialogId = dialogId
        self.clientMsgId = clientMsgId
        self.msgId = msgId
        self.senderPts = senderPts
        self.clearedDraftRevision = clearedDraftRevision
        self.duplicate = duplicate
        self.serverTs = serverTs
        self.text = text
    }
}

nonisolated struct DraftMutationResponse: Codable, Sendable {
    let draft: CloudDraft
    let duplicate: Bool
}

nonisolated struct MediaGroupSendResponse: Codable, Sendable {
    let dialogId: String
    let clientGroupId: String
    let messages: [CloudMessage]
    let senderPts: Int64
    let clearedDraftRevision: Int64?
    let duplicate: Bool
}

nonisolated struct MessageMutationResponse: Codable, Sendable {
    let dialogId: String
    let msgId: Int64
    let actorPts: Int64
    let duplicate: Bool
    let message: CloudMessage
}

nonisolated struct SyncStateResponse: Codable, Sendable {
    let pts: Int64
}

nonisolated struct DifferenceResponse: Codable, Sendable {
    struct State: Codable, Sendable {
        let pts: Int64
    }

    let kind: String
    let state: State
    let updates: [CloudUpdate]?
    let profiles: [CloudProfile]?
    let hasMore: Bool?

    init(
        kind: String,
        state: State,
        updates: [CloudUpdate]?,
        profiles: [CloudProfile]? = nil,
        hasMore: Bool?
    ) {
        self.kind = kind
        self.state = state
        self.updates = updates
        self.profiles = profiles
        self.hasMore = hasMore
    }
}

nonisolated struct BootstrapStartResponse: Codable, Sendable {
    struct State: Codable, Sendable {
        let pts: Int64
    }

    let token: String
    let state: State
    let expiresAt: String
    let dialogCount: Int

    enum CodingKeys: String, CodingKey {
        case token
        case state
        case expiresAt
        case dialogCount
    }
}

nonisolated struct BootstrapDialogMember: Codable, Equatable, Sendable {
    let accountId: String
    let role: String
    let lastReadMsgId: Int64
    let joinedAt: String?
    let isActive: Bool?

    init(
        accountId: String,
        role: String,
        lastReadMsgId: Int64,
        joinedAt: String? = nil,
        isActive: Bool? = nil
    ) {
        self.accountId = accountId
        self.role = role
        self.lastReadMsgId = lastReadMsgId
        self.joinedAt = joinedAt
        self.isActive = isActive
    }

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case role
        case lastReadMsgId = "last_read_msg_id"
        case joinedAt = "joined_at"
        case isActive = "is_active"
    }
}

nonisolated struct BootstrapDialog: Codable, Equatable, Sendable {
    let dialogId: String
    let type: String
    let title: String?
    let lastMsgId: Int64
    let updatedAt: String
    let unreadCount: Int?
    let revision: Int64?
    let memberCount: Int?
    let selfRole: String?
    let notificationMode: String?
    let preferences: CloudDialogPreferences?
    let photo: CloudMedia?
    let draft: CloudDraft?
    let members: [BootstrapDialogMember]
    let profiles: [CloudProfile]?
    let messages: [CloudMessage]

    init(
        dialogId: String,
        type: String,
        title: String?,
        lastMsgId: Int64,
        updatedAt: String,
        unreadCount: Int? = nil,
        revision: Int64? = nil,
        memberCount: Int? = nil,
        selfRole: String? = nil,
        notificationMode: String? = nil,
        preferences: CloudDialogPreferences? = nil,
        photo: CloudMedia? = nil,
        draft: CloudDraft? = nil,
        members: [BootstrapDialogMember],
        profiles: [CloudProfile]? = nil,
        messages: [CloudMessage]
    ) {
        self.dialogId = dialogId
        self.type = type
        self.title = title
        self.lastMsgId = lastMsgId
        self.updatedAt = updatedAt
        self.unreadCount = unreadCount
        self.revision = revision
        self.memberCount = memberCount
        self.selfRole = selfRole
        self.notificationMode = notificationMode
        self.preferences = preferences
        self.photo = photo
        self.draft = draft
        self.members = members
        self.profiles = profiles
        self.messages = messages
    }

    enum CodingKeys: String, CodingKey {
        case dialogId = "dialog_id"
        case type
        case title
        case lastMsgId = "last_msg_id"
        case updatedAt = "updated_at"
        case unreadCount = "unread_count"
        case revision
        case memberCount = "member_count"
        case selfRole = "self_role"
        case notificationMode = "notification_mode"
        case preferences
        case photo
        case draft
        case members
        case profiles
        case messages
    }
}

nonisolated struct BootstrapDialogsPage: Codable, Sendable {
    struct State: Codable, Sendable {
        let pts: Int64
    }

    let token: String
    let state: State
    let dialogs: [BootstrapDialog]
    let nextCursor: String?
    let hasMore: Bool
}

nonisolated struct HistoryPageResponse: Codable, Sendable {
    let dialogId: String
    let messages: [CloudMessage]
    let profiles: [CloudProfile]?
    let nextBeforeMsgId: Int64?
    let nextAfterMsgId: Int64?
    let hasMore: Bool

    init(
        dialogId: String,
        messages: [CloudMessage],
        profiles: [CloudProfile]? = nil,
        nextBeforeMsgId: Int64?,
        nextAfterMsgId: Int64? = nil,
        hasMore: Bool
    ) {
        self.dialogId = dialogId
        self.messages = messages
        self.profiles = profiles
        self.nextBeforeMsgId = nextBeforeMsgId
        self.nextAfterMsgId = nextAfterMsgId
        self.hasMore = hasMore
    }

    enum CodingKeys: String, CodingKey {
        case dialogId
        case messages
        case profiles
        case nextBeforeMsgId
        case nextAfterMsgId
        case hasMore
    }
}

nonisolated struct ReadResponse: Codable, Sendable {
    let dialogId: String
    let maxReadMsgId: Int64
    let unreadCount: Int?
}

nonisolated struct PushRegistrationResponse: Codable, Sendable {
    let registered: Bool
}

nonisolated struct SessionRevocationResponse: Codable, Sendable {
    let revoked: Bool
}

nonisolated struct AccountDeletionResponse: Codable, Sendable {
    let deleted: Bool
}

nonisolated struct CloudAbuseReportSubject: Encodable, Equatable, Sendable {
    let type: String
    let accountId: String?
    let msgId: Int64?

    static func account(_ accountId: String) -> Self {
        Self(type: "account", accountId: accountId, msgId: nil)
    }

    static func message(_ msgId: Int64) -> Self {
        Self(type: "message", accountId: nil, msgId: msgId)
    }
}

private struct CloudAbuseReportRequest: Encodable, Sendable {
    let clientReportId: String
    let dialogId: String
    let subject: CloudAbuseReportSubject
    let reason: String
    let details: String?
}

nonisolated struct CloudAbuseReportResponse: Decodable, Equatable, Sendable {
    let reportId: String
    let status: String
    let duplicate: Bool

    var isAcknowledged: Bool {
        status == "received" && UUID(uuidString: reportId) != nil
    }
}

nonisolated struct CloudDevice: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let platform: String
    let deviceName: String?
    let createdAt: String
    let lastSeenAt: String?
    let sessionExpiresAt: String?
    let current: Bool

    init(
        id: String,
        platform: String,
        deviceName: String?,
        createdAt: String,
        lastSeenAt: String?,
        sessionExpiresAt: String? = nil,
        current: Bool
    ) {
        self.id = id
        self.platform = platform
        self.deviceName = deviceName
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.sessionExpiresAt = sessionExpiresAt
        self.current = current
    }
}

nonisolated struct CloudPresence: Codable, Equatable, Sendable {
    let accountId: String
    let online: Bool
    let lastSeenAt: String?
    let revision: Int64
}

nonisolated struct CloudPresenceResponse: Codable, Equatable, Sendable {
    let presences: [CloudPresence]
}

private struct PresenceQueryRequest: Codable, Sendable {
    let accountIds: [String]
}

private struct DeviceListResponse: Codable, Sendable {
    let devices: [CloudDevice]
}

nonisolated struct CloudAPIError: Error, LocalizedError {
    let status: Int
    let message: String
    let retryAfter: Int?
    var code: String? = nil
    var existingCallId: String? = nil

    var errorDescription: String? {
        message
    }
}

nonisolated struct CloudCapabilitiesResponse: Codable, Equatable, Sendable {
    let apiVersion: Int
    let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case capabilities
    }
}

nonisolated enum CloudFailureDisposition: Equatable, Sendable {
    case transient(retryAfter: TimeInterval?)
    case authenticationRequired
    case unsupportedServer
    case permanent
}

nonisolated func cloudFailureDisposition(_ error: Error) -> CloudFailureDisposition {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            return .transient(retryAfter: nil)
        default:
            return .permanent
        }
    }
    guard let apiError = error as? CloudAPIError else { return .permanent }
    if apiError.code == "capability_unavailable" {
        return .unsupportedServer
    }
    switch apiError.status {
    case 401, 403:
        return .authenticationRequired
    case 408, 425, 429, 500...599:
        return .transient(retryAfter: apiError.retryAfter.map(TimeInterval.init))
    default:
        return .permanent
    }
}

nonisolated func cloudOperationFailureDisposition(
    _ error: Error,
    serverAdvertisesFeature: Bool
) -> CloudFailureDisposition {
    if error is DecodingError {
        // The server may have committed before returning a response this client cannot decode.
        // Durable operations must replay the same idempotency key instead of declaring failure.
        return .transient(retryAfter: nil)
    }
    if let apiError = error as? CloudAPIError {
        if apiError.status == -1 {
            return .transient(retryAfter: nil)
        }
        if apiError.status == 404, apiError.code == nil {
            // A code-less 404 is route/version skew, not an authoritative object result. This is
            // true even just after capability discovery because a request can hit a different node.
            return .unsupportedServer
        }
        if !serverAdvertisesFeature,
           apiError.status == 404,
           apiError.code == "capability_unavailable" {
            return .unsupportedServer
        }
    }
    return cloudFailureDisposition(error)
}

nonisolated func cloudScheduledCreateRetryDelay(
    _ storedDelay: TimeInterval?,
    serverAdvertisesFeature: Bool
) -> TimeInterval? {
    serverAdvertisesFeature ? storedDelay : nil
}

nonisolated func cloudScheduledCreateCanTerminalizePermanentFailure(
    wasPreviouslyAttempted: Bool
) -> Bool {
    // Once any earlier attempt may have committed, a later 4xx cannot prove that no schedule
    // exists on another version-skewed node. Keep replaying the original idempotent bytes until
    // the server returns the authoritative create receipt, after which cancellation can proceed.
    !wasPreviouslyAttempted
}

actor SessionCredentialCoordinator {
    static let shared = SessionCredentialCoordinator()

    private var storedSession: StoredCloudSession?
    private var config: CloudConfig = .current
    private var tokenStore = TokenStore()
    private var acceptedAccessTokens: Set<String> = []
    private var refreshTask: Task<CloudSession, Error>?
    private var generation: UInt64 = 0
    private let networkSession: URLSession
    private let updatesContinuation: AsyncStream<SessionCredentialEvent>.Continuation
    nonisolated let updates: AsyncStream<SessionCredentialEvent>

    init(networkSession: URLSession = .shared) {
        self.networkSession = networkSession
        (updates, updatesContinuation) = AsyncStream.makeStream(of: SessionCredentialEvent.self)
    }

    func install(_ session: StoredCloudSession, config: CloudConfig, tokenStore: TokenStore) {
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        self.config = config
        self.tokenStore = tokenStore
        storedSession = session
        // An explicit install is an authoritative session boundary (login, upgrade, restore, or
        // security reissue). Only refreshes performed inside this actor retain their preceding
        // access-token alias for in-flight retries. Otherwise an old account token could be
        // rebound to another account, or a late device_revoked response from a security reissue
        // could tear down the replacement session.
        acceptedAccessTokens = [session.session.token]
    }

    func clear() {
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        storedSession = nil
        acceptedAccessTokens.removeAll()
    }

    func authorizationToken(matching supplied: String) -> String? {
        guard let storedSession,
              storedSession.session.tokenVersion >= 2,
              acceptedAccessTokens.contains(supplied)
        else { return nil }
        return storedSession.session.token
    }

    func refreshIfNeeded(matching supplied: String, force: Bool = false) async throws -> String? {
        guard let stored = storedSession,
              stored.session.tokenVersion >= 2,
              stored.session.refreshToken != nil,
              acceptedAccessTokens.contains(supplied)
        else { return nil }
        if !force, let expiry = Self.date(stored.session.accessTokenExpiresAt),
           expiry.timeIntervalSinceNow > 120 {
            return stored.session.token
        }
        if let refreshTask {
            let waitingGeneration = generation
            let refreshed = try await refreshTask.value
            guard generation == waitingGeneration,
                  storedSession?.session.deviceId == stored.session.deviceId
            else { throw CancellationError() }
            return refreshed.token
        }
        let refreshGeneration = generation
        let task = Task<CloudSession, Error> {
            guard let refreshToken = stored.session.refreshToken else {
                throw CloudAPIError(status: 401, message: "Session refresh unavailable", retryAfter: nil)
            }
            let pending = try await tokenStore.loadPendingRefreshRotation()
            let rotationId = pending ?? UUID().uuidString.lowercased()
            if pending == nil { try await tokenStore.savePendingRefreshRotation(rotationId) }
            return try await CloudAPI(
                config: config,
                session: networkSession,
                credentialCoordinator: nil
            ).refreshSession(refreshToken: refreshToken, rotationId: rotationId)
        }
        refreshTask = task
        do {
            let refreshed = try await task.value
            guard generation == refreshGeneration,
                  storedSession?.session.deviceId == stored.session.deviceId
            else { throw CancellationError() }
            let replacement = StoredCloudSession(
                session: refreshed,
                phone: stored.phone,
                displayName: stored.displayName
            )
            try await tokenStore.save(replacement)
            guard generation == refreshGeneration else {
                try? await tokenStore.clearSession(ifTokenMatches: replacement.session.token)
                throw CancellationError()
            }
            try await tokenStore.clearPendingRefreshRotation()
            acceptedAccessTokens.insert(replacement.session.token)
            storedSession = replacement
            refreshTask = nil
            updatesContinuation.yield(.updated(replacement))
            return replacement.session.token
        } catch {
            refreshTask = nil
            if let apiError = error as? CloudAPIError,
               ["session_expired", "device_revoked", "refresh_reuse_detected"].contains(apiError.code) {
                try? await tokenStore.clearPendingRefreshRotation()
                handleAuthenticationFailure(code: apiError.code, matching: stored.session.token)
            }
            throw error
        }
    }

    func handleAuthenticationFailure(code: String?, matching supplied: String) {
        guard let code,
              let stored = storedSession,
              acceptedAccessTokens.contains(supplied)
        else { return }
        let event: SessionCredentialEvent
        switch code {
        case "session_expired": event = .authenticationRequired(stored)
        case "device_revoked", "refresh_reuse_detected": event = .securityRevoked(stored)
        default: return
        }
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        storedSession = nil
        acceptedAccessTokens.removeAll()
        updatesContinuation.yield(event)
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}

nonisolated enum SessionCredentialEvent: Sendable {
    case updated(StoredCloudSession)
    case authenticationRequired(StoredCloudSession)
    case securityRevoked(StoredCloudSession)
}

struct CloudAPI: Sendable {
    let config: CloudConfig
    var session: URLSession = .shared
    var credentialCoordinator: SessionCredentialCoordinator? = .shared

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    private static let profileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    func startAuth(phone: String, deliveryChannel: String? = nil) async throws -> AuthStartResponse {
        var body = ["phone": phone]
        if let deliveryChannel { body["deliveryChannel"] = deliveryChannel }
        return try await post("v1/auth/start", body: body, token: nil)
    }

    func capabilities(token: String? = nil) async throws -> CloudCapabilitiesResponse {
        try await get("v1/capabilities", token: token)
    }

    func checkAuth(phone: String, code: String, displayName: String, deviceName: String) async throws -> CloudSession {
        try await post(
            "v1/auth/check",
            body: [
                "phone": phone,
                "code": code,
                "platform": "ios",
                "deviceName": deviceName,
                "displayName": displayName
            ],
            token: nil
        )
    }

    func checkAuthV2(
        phone: String,
        code: String,
        displayName: String,
        deviceName: String
    ) async throws -> AuthV2CheckResponse {
        try await post(
            "v1/auth/check",
            body: [
                "phone": phone,
                "code": code,
                "platform": "ios",
                "deviceName": deviceName,
                "displayName": displayName,
                "authProtocolVersion": "2"
            ],
            token: nil
        )
    }

    func completeTwoFactorLogin(
        challengeId: String,
        password: String?,
        recoveryCode: String?,
        newPassword: String?
    ) async throws -> TwoFactorLoginResponse {
        struct Request: Encodable {
            let challengeId: String
            let password: String?
            let recoveryCode: String?
            let newPassword: String?
        }
        return try await post(
            "v1/auth/two-factor/check",
            body: Request(
                challengeId: challengeId,
                password: password,
                recoveryCode: recoveryCode,
                newPassword: newPassword
            ),
            token: nil
        )
    }

    func upgradeSession(token: String) async throws -> CloudSession {
        struct Response: Decodable { let session: CloudSession }
        let response: Response = try await post("v1/session/upgrade", body: EmptyBody(), token: token)
        return response.session
    }

    func refreshSession(refreshToken: String, rotationId: String) async throws -> CloudSession {
        try await post(
            "v1/session/refresh",
            body: ["refreshToken": refreshToken, "rotationId": rotationId],
            token: nil
        )
    }

    func twoFactorStatus(token: String) async throws -> TwoFactorStatusResponse {
        try await get("v1/security/two-factor", token: token)
    }

    func startSecurityStepUp(token: String) async throws -> AuthStartResponse {
        try await post("v1/security/step-up/start", body: EmptyBody(), token: token)
    }

    func checkSecurityStepUp(code: String, token: String) async throws -> SecurityStepUpResponse {
        try await post("v1/security/step-up/check", body: ["code": code], token: token)
    }

    func configureTwoFactor(
        stepUpToken: String,
        password: String,
        currentCredential: String?,
        token: String
    ) async throws -> TwoFactorConfigurationResponse {
        struct Request: Encodable {
            let stepUpToken: String
            let password: String
            let currentCredential: String?
        }
        return try await put(
            "v1/security/two-factor",
            body: Request(
                stepUpToken: stepUpToken,
                password: password,
                currentCredential: currentCredential
            ),
            token: token
        )
    }

    func disableTwoFactor(
        stepUpToken: String,
        currentCredential: String,
        token: String
    ) async throws -> TwoFactorConfigurationResponse {
        try await delete(
            "v1/security/two-factor",
            body: ["stepUpToken": stepUpToken, "currentCredential": currentCredential],
            token: token
        )
    }

    func regenerateTwoFactorRecoveryCodes(
        stepUpToken: String,
        currentCredential: String,
        token: String
    ) async throws -> TwoFactorConfigurationResponse {
        try await post(
            "v1/security/two-factor/recovery-codes",
            body: ["stepUpToken": stepUpToken, "currentCredential": currentCredential],
            token: token
        )
    }

    func lookupContact(phone: String, token: String) async throws -> ContactLookupResponse {
        try await post("v1/contacts/lookup", body: ["phone": phone], token: token)
    }

    func lookupUsername(_ username: String, token: String) async throws -> ContactLookupResponse {
        let value = username.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw CloudAPIError(status: 400, message: "Invalid username", retryAfter: nil)
        }
        return try await get("v1/usernames/\(encoded)", token: token)
    }

    func getProfile(token: String) async throws -> CloudProfile {
        try await get("v1/profile", token: token)
    }

    func updateProfile(_ profile: StoredProfileDetails, token: String) async throws -> CloudProfile {
        try await put(
            "v1/profile",
            body: ProfileUpdateRequest(
                username: profile.username,
                firstName: profile.firstName,
                lastName: profile.lastName,
                bio: profile.bio,
                birthday: profile.birthday.map(Self.profileDateFormatter.string(from:)),
                colorIndex: profile.colorIndex
            ),
            token: token
        )
    }

    func updateProfilePhoto(
        mediaId: String?,
        clientMutationId: String,
        basePhotoRevision: Int64,
        token: String
    ) async throws -> ProfilePhotoMutationResponse {
        try await put(
            "v1/profile/photo",
            body: ProfilePhotoMutationRequest(
                mediaId: mediaId,
                clientMutationId: clientMutationId,
                basePhotoRevision: basePhotoRevision
            ),
            token: token
        )
    }

    func createDirectDialog(peerAccountId: String, token: String) async throws -> DirectDialogResponse {
        try await post("v1/dialogs/direct", body: ["peerAccountId": peerAccountId], token: token)
    }

    func ensureSavedMessages(token: String) async throws -> SavedDialogResponse {
        try await post("v1/dialogs/saved", body: EmptyBody(), token: token)
    }

    func createGroup(
        id: String,
        title: String,
        memberIds: [String],
        token: String
    ) async throws -> CloudGroupEnvelope {
        try await post(
            "v1/groups",
            body: CreateGroupRequest(groupId: id, title: title, memberIds: memberIds),
            token: token,
            timeoutInterval: 12
        )
    }

    func group(id: String, token: String) async throws -> CloudGroupEnvelope {
        try await get("v1/groups/\(id)", token: token)
    }

    func groupMembers(
        id: String,
        cursor: String?,
        limit: Int = 50,
        token: String
    ) async throws -> CloudGroupMembersPage {
        var query = [URLQueryItem(name: "limit", value: String(max(1, min(100, limit))))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await get("v1/groups/\(id)/members", queryItems: query, token: token)
    }

    func addGroupMembers(
        id: String,
        memberIds: [String],
        clientMutationId: String,
        token: String
    ) async throws -> CloudGroupEnvelope {
        try await post(
            "v1/groups/\(id)/members",
            body: AddGroupMembersRequest(memberIds: memberIds, clientMutationId: clientMutationId),
            token: token
        )
    }

    func removeGroupMember(
        groupId: String,
        accountId: String,
        clientMutationId: String,
        token: String
    ) async throws -> CloudGroupEnvelope {
        try await delete(
            "v1/groups/\(groupId)/members/\(accountId)",
            body: GroupMutationRequest(clientMutationId: clientMutationId),
            token: token
        )
    }

    func changeGroupMemberRole(
        groupId: String,
        accountId: String,
        role: String,
        clientMutationId: String,
        token: String
    ) async throws -> CloudGroupEnvelope {
        try await patch(
            "v1/groups/\(groupId)/members/\(accountId)",
            body: ChangeGroupRoleRequest(role: role, clientMutationId: clientMutationId),
            token: token
        )
    }

    func updateGroup(
        id: String,
        title: String? = nil,
        photoMediaId: String? = nil,
        clearPhoto: Bool = false,
        clientMutationId: String,
        token: String
    ) async throws -> CloudGroupEnvelope {
        try await patch(
            "v1/groups/\(id)",
            body: UpdateGroupRequest(
                title: title,
                photoMediaId: photoMediaId,
                clearPhoto: clearPhoto,
                clientMutationId: clientMutationId
            ),
            token: token
        )
    }

    func transferGroupOwner(
        id: String,
        accountId: String,
        clientMutationId: String,
        token: String
    ) async throws -> CloudGroupEnvelope {
        try await post(
            "v1/groups/\(id)/transfer-owner",
            body: TransferGroupOwnerRequest(
                accountId: accountId,
                clientMutationId: clientMutationId
            ),
            token: token
        )
    }

    func leaveGroup(
        id: String,
        successorAccountId: String? = nil,
        clientMutationId: String,
        token: String
    ) async throws -> CloudGroupLeaveResponse {
        try await post(
            "v1/groups/\(id)/leave",
            body: LeaveGroupRequest(
                successorAccountId: successorAccountId,
                clientMutationId: clientMutationId
            ),
            token: token
        )
    }

    func updateGroupNotifications(
        id: String,
        mode: String,
        clientMutationId: String,
        token: String
    ) async throws -> CloudGroupEnvelope {
        try await put(
            "v1/groups/\(id)/notifications",
            body: GroupNotificationsRequest(mode: mode, clientMutationId: clientMutationId),
            token: token
        )
    }

    func updateGroupPermissions(
        id: String,
        membersCanSend: Bool,
        membersCanAddMembers: Bool,
        membersCanEditInfo: Bool,
        clientMutationId: String,
        token: String
    ) async throws -> CloudGroupEnvelope {
        try await put(
            "v1/groups/\(id)/permissions",
            body: GroupPermissionsRequest(
                membersCanSend: membersCanSend,
                membersCanAddMembers: membersCanAddMembers,
                membersCanEditInfo: membersCanEditInfo,
                clientMutationId: clientMutationId
            ),
            token: token
        )
    }

    func updateDialogPreferences(
        dialogId: String,
        clientMutationId: String,
        pinned: Bool? = nil,
        muted: Bool? = nil,
        archived: Bool? = nil,
        token: String
    ) async throws -> DialogPreferencesResponse {
        try await put(
            "v1/dialogs/\(dialogId)/preferences",
            body: DialogPreferencesRequest(
                clientMutationId: clientMutationId,
                pinned: pinned,
                muted: muted,
                archived: archived
            ),
            token: token
        )
    }

    func getState(token: String) async throws -> SyncStateResponse {
        try await get("v1/sync/state", token: token)
    }

    func chatFolders(token: String) async throws -> CloudChatFolderSnapshot {
        try await get("v1/chat-folders", token: token)
    }

    func createChatFolder(
        persistedBody: Data,
        token: String
    ) async throws -> CloudChatFolderSnapshot {
        try await persistedJSON("v1/chat-folders", method: "POST", body: persistedBody, token: token)
    }

    func updateChatFolder(
        id: String,
        persistedBody: Data,
        token: String
    ) async throws -> CloudChatFolderSnapshot {
        try await persistedJSON(
            "v1/chat-folders/\(id)", method: "PATCH", body: persistedBody, token: token
        )
    }

    func moveChatFolder(
        id: String,
        persistedBody: Data,
        token: String
    ) async throws -> CloudChatFolderSnapshot {
        try await persistedJSON(
            "v1/chat-folders/\(id)/move", method: "POST", body: persistedBody, token: token
        )
    }

    func deleteChatFolder(
        id: String,
        persistedBody: Data,
        token: String
    ) async throws -> CloudChatFolderSnapshot {
        try await persistedJSON(
            "v1/chat-folders/\(id)", method: "DELETE", body: persistedBody, token: token
        )
    }

    func scheduledDeliveries(
        dialogId: String? = nil,
        cursor: String? = nil,
        token: String
    ) async throws -> CloudScheduledListResponse {
        var query: [URLQueryItem] = []
        if let dialogId { query.append(URLQueryItem(name: "dialogId", value: dialogId)) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        query.append(URLQueryItem(name: "limit", value: "100"))
        return try await get("v1/scheduled-messages", queryItems: query, token: token)
    }

    func createScheduledDelivery(
        persistedBody: Data,
        token: String
    ) async throws -> CloudScheduledMutationResponse {
        try await persistedJSON(
            "v1/scheduled-messages", method: "POST", body: persistedBody, token: token
        )
    }

    func updateScheduledDelivery(
        id: String,
        persistedBody: Data,
        token: String
    ) async throws -> CloudScheduledMutationResponse {
        try await persistedJSON(
            "v1/scheduled-messages/\(id)", method: "PATCH", body: persistedBody, token: token
        )
    }

    func cancelScheduledDelivery(
        id: String,
        persistedBody: Data,
        token: String
    ) async throws -> CloudScheduledMutationResponse {
        try await persistedJSON(
            "v1/scheduled-messages/\(id)", method: "DELETE", body: persistedBody, token: token
        )
    }

    func getDifference(
        sincePts: Int64,
        maxEvents: Int = 200,
        maxBytes: Int = 256 * 1_024,
        token: String
    ) async throws -> DifferenceResponse {
        try await post(
            "v1/sync/difference",
            body: DifferenceRequest(
                sincePts: sincePts,
                maxEvents: maxEvents,
                maxBytes: maxBytes
            ),
            token: token,
            timeoutInterval: 20
        )
    }

    func startBootstrap(token: String) async throws -> BootstrapStartResponse {
        try await post("v1/bootstrap/start", body: EmptyBody(), token: token)
    }

    func getBootstrapDialogs(
        bootstrapToken: String,
        cursor: String?,
        limit: Int = 20,
        previewMessages: Int = 25,
        token: String
    ) async throws -> BootstrapDialogsPage {
        try await post(
            "v1/bootstrap/dialogs",
            body: BootstrapDialogsRequest(
                token: bootstrapToken,
                cursor: cursor,
                limit: limit,
                previewMessages: previewMessages
            ),
            token: token
        )
    }

    func sendMessage(
        dialogId: String,
        clientMsgId: String,
        body: String,
        replyToMsgId: Int64? = nil,
        mentions: [CloudMention] = [],
        draftConsumeOperationId: String? = nil,
        silent: Bool = false,
        token: String
    ) async throws -> SendMessageResponse {
        try await post(
            "v1/messages/send",
            body: SendMessageRequest(
                dialogId: dialogId,
                clientMsgId: clientMsgId,
                kind: "text",
                body: body,
                replyToMsgId: replyToMsgId,
                mediaId: nil,
                forwardedFrom: nil,
                mentions: mentions,
                draftConsumeOperationId: draftConsumeOperationId,
                silent: silent,
                linkPreviewCandidate: CloudLinkPreviewCandidate.first(in: body)
            ),
            token: token
        )
    }

    func sendMediaMessage(
        dialogId: String,
        clientMsgId: String,
        body: String,
        mediaId: String,
        replyToMsgId: Int64? = nil,
        mentions: [CloudMention] = [],
        draftConsumeOperationId: String? = nil,
        silent: Bool = false,
        token: String
    ) async throws -> SendMessageResponse {
        try await post(
            "v1/messages/send",
            body: SendMessageRequest(
                dialogId: dialogId, clientMsgId: clientMsgId, kind: nil,
                body: body, replyToMsgId: replyToMsgId, mediaId: mediaId,
                forwardedFrom: nil, mentions: mentions,
                draftConsumeOperationId: draftConsumeOperationId,
                silent: silent,
                linkPreviewCandidate: CloudLinkPreviewCandidate.first(in: body)
            ),
            token: token
        )
    }

    func forwardMessage(
        dialogId: String,
        clientMsgId: String,
        sourceDialogId: String,
        sourceMsgId: Int64,
        token: String
    ) async throws -> SendMessageResponse {
        try await post(
            "v1/messages/send",
            body: SendMessageRequest(
                dialogId: dialogId,
                clientMsgId: clientMsgId,
                kind: "text",
                body: nil,
                replyToMsgId: nil,
                mediaId: nil,
                forwardedFrom: ForwardedFromRequest(dialogId: sourceDialogId, msgId: sourceMsgId),
                mentions: [],
                draftConsumeOperationId: nil,
                silent: false,
                linkPreviewCandidate: nil
            ),
            token: token
        )
    }

    func updateDraft(
        dialogId: String,
        operationId: String,
        state: String,
        text: String,
        replyToMsgId: Int64?,
        mentions: [CloudMention],
        attachments: [DraftAttachmentRequest],
        token: String
    ) async throws -> DraftMutationResponse {
        try await put(
            "v1/drafts/\(dialogId)",
            body: DraftMutationRequest(
                operationId: operationId,
                state: state,
                text: text,
                replyToMsgId: replyToMsgId,
                mentions: mentions,
                attachments: attachments
            ),
            token: token
        )
    }

    func sendMediaGroup(
        dialogId: String,
        clientGroupId: String,
        items: [MediaGroupItemRequest],
        caption: String,
        replyToMsgId: Int64?,
        mentions: [CloudMention],
        draftConsumeOperationId: String?,
        silent: Bool = false,
        token: String
    ) async throws -> MediaGroupSendResponse {
        try await post(
            "v1/messages/send-group",
            body: MediaGroupSendRequest(
                clientGroupId: clientGroupId,
                dialogId: dialogId,
                items: items,
                body: caption,
                replyToMsgId: replyToMsgId,
                mentions: mentions,
                draftConsumeOperationId: draftConsumeOperationId,
                silent: silent,
                linkPreviewCandidate: CloudLinkPreviewCandidate.first(in: caption)
            ),
            token: token
        )
    }

    func editMessage(
        dialogId: String,
        msgId: Int64,
        clientMutationId: String,
        expectedEditVersion: Int,
        body: String,
        token: String
    ) async throws -> MessageMutationResponse {
        try await post(
            "v1/messages/edit",
            body: EditMessageRequest(
                dialogId: dialogId,
                msgId: msgId,
                clientMutationId: clientMutationId,
                expectedEditVersion: expectedEditVersion,
                body: body,
                linkPreviewCandidate: CloudLinkPreviewCandidate.first(in: body)
            ),
            token: token
        )
    }

    func deleteMessage(
        dialogId: String,
        msgId: Int64,
        clientMutationId: String,
        token: String
    ) async throws -> MessageMutationResponse {
        try await post(
            "v1/messages/delete",
            body: DeleteMessageRequest(
                dialogId: dialogId,
                msgId: msgId,
                clientMutationId: clientMutationId
            ),
            token: token
        )
    }

    func setReaction(
        dialogId: String,
        msgId: Int64,
        clientMutationId: String,
        emoji: String?,
        token: String
    ) async throws -> MessageMutationResponse {
        try await post(
            "v1/messages/react",
            body: ReactionRequest(
                dialogId: dialogId,
                msgId: msgId,
                clientMutationId: clientMutationId,
                emoji: emoji
            ),
            token: token
        )
    }

    func getHistory(
        dialogId: String,
        beforeMsgId: Int64?,
        afterMsgId: Int64? = nil,
        limit: Int = 50,
        token: String
    ) async throws -> HistoryPageResponse {
        try await post(
            "v1/history",
            body: HistoryRequest(
                dialogId: dialogId,
                beforeMsgId: beforeMsgId,
                afterMsgId: afterMsgId,
                limit: limit,
                maxBytes: 512 * 1_024
            ),
            token: token
        )
    }

    func markRead(dialogId: String, maxReadMsgId: Int64, token: String) async throws -> ReadResponse {
        try await post(
            "v1/read",
            body: ReadRequest(dialogId: dialogId, maxReadMsgId: maxReadMsgId),
            token: token
        )
    }

    func registerPushToken(_ deviceToken: String, environment: String, token: String) async throws -> PushRegistrationResponse {
        try await post(
            "v1/devices/push",
            body: PushRegistrationRequest(token: deviceToken, environment: environment),
            token: token
        )
    }

    func unregisterPushToken(token: String) async throws -> PushRegistrationResponse {
        try await delete("v1/devices/push", token: token)
    }

    func registerVoIPPushToken(
        _ deviceToken: String,
        environment: String,
        token: String,
        capabilities: CallDeviceCapabilities = WebRTCEngineFactory.deviceCapabilities,
        groupCapabilities: GroupCallDeviceCapabilities = GroupCallEngineFactory.deviceCapabilities
    ) async throws -> PushRegistrationResponse {
        try await put(
            "v1/devices/voip-push",
            body: VoIPPushRegistrationRequest(
                token: deviceToken,
                environment: environment,
                supportedCallProtocolVersions: capabilities.supportedCallProtocolVersions.map(Int.init),
                supportedCallMediaProfileVersions: capabilities.supportedCallMediaProfileVersions.map(Int.init),
                callViewVersion: Int(capabilities.callViewVersion),
                supportedGroupCallVersions: groupCapabilities.supportedGroupCallVersions.map(Int.init),
                groupCallViewVersion: Int(groupCapabilities.groupCallViewVersion),
                supportsGroupScreenShare: groupCapabilities.supportsGroupScreenShare
            ),
            token: token
        )
    }

    func unregisterVoIPPushToken(token: String) async throws -> PushRegistrationResponse {
        try await delete("v1/devices/voip-push", token: token)
    }

    func registerGroupCallCapabilities(
        _ capabilities: GroupCallDeviceCapabilities = GroupCallEngineFactory.deviceCapabilities,
        token: String
    ) async throws -> GroupCallCapabilityRegistrationResponse {
        try await put(
            "v1/devices/group-call-capabilities",
            body: GroupCallCapabilityRegistrationRequest(
                supportedGroupCallVersions: capabilities.supportedGroupCallVersions.map(Int.init),
                groupCallViewVersion: Int(capabilities.groupCallViewVersion),
                supportsGroupScreenShare: capabilities.supportsGroupScreenShare
            ),
            token: token
        )
    }

    func startGroupCall(
        _ body: StartCloudGroupCallRequest,
        token: String
    ) async throws -> CloudGroupCallStartResponse {
        try await post("v1/group-calls", body: body, token: token, timeoutInterval: 15)
    }

    func activeGroupCall(dialogId: String, token: String) async throws -> CloudActiveGroupCallResponse {
        try await get(
            "v1/group-calls/active",
            queryItems: [URLQueryItem(name: "dialogId", value: dialogId)],
            token: token,
            timeoutInterval: 15
        )
    }

    func groupCall(id: String, token: String) async throws -> CloudGroupCallResponse {
        try await get("v1/group-calls/\(id)", token: token, timeoutInterval: 8)
    }

    func joinGroupCall(
        id: String,
        body: JoinCloudGroupCallRequest,
        token: String
    ) async throws -> CloudGroupCallJoinResponse {
        try await post("v1/group-calls/\(id)/join", body: body, token: token, timeoutInterval: 15)
    }

    func activateGroupCallEpoch(
        id: String,
        body: ActivateCloudGroupCallEpochRequest,
        token: String
    ) async throws -> CloudGroupCallJoinResponse {
        try await post("v1/group-calls/\(id)/epochs", body: body, token: token, timeoutInterval: 15)
    }

    func groupCallCredentials(id: String, token: String) async throws -> CloudGroupCallCredentialsResponse {
        try await get("v1/group-calls/\(id)/credentials", token: token, timeoutInterval: 15)
    }

    func heartbeatGroupCall(id: String, token: String) async throws -> CloudGroupCallHeartbeatResponse {
        try await post(
            "v1/group-calls/\(id)/heartbeat",
            body: CloudGroupCallEmptyRequest(),
            token: token,
            timeoutInterval: 15
        )
    }

    func leaveGroupCall(id: String, token: String) async throws -> CloudGroupCallJoinResponse {
        try await post(
            "v1/group-calls/\(id)/leave",
            body: CloudGroupCallEmptyRequest(),
            token: token,
            timeoutInterval: 15
        )
    }

    func endGroupCall(id: String, reason: String, token: String) async throws -> CloudGroupCallJoinResponse {
        try await post(
            "v1/group-calls/\(id)/end",
            body: CloudGroupCallEndRequest(reason: reason),
            token: token,
            timeoutInterval: 15
        )
    }

    func removeGroupCallParticipant(
        callId: String,
        deviceId: String,
        token: String
    ) async throws -> CloudGroupCallResponse {
        try await delete(
            "v1/group-calls/\(callId)/participants/\(deviceId)",
            token: token,
            timeoutInterval: 15
        )
    }

    func acquireGroupCamera(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallCameraLeaseResponse {
        try await post(
            "v1/group-calls/\(callId)/camera",
            body: CloudGroupCallScreenLeaseRequest(generation: generation),
            token: token,
            timeoutInterval: 15
        )
    }

    func heartbeatGroupCamera(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallCameraLeaseResponse {
        try await post(
            "v1/group-calls/\(callId)/camera/heartbeat",
            body: CloudGroupCallScreenLeaseRequest(generation: generation),
            token: token,
            timeoutInterval: 3
        )
    }

    func releaseGroupCamera(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallScreenReleaseResponse {
        try await post(
            "v1/group-calls/\(callId)/camera/release",
            body: CloudGroupCallScreenLeaseRequest(generation: generation),
            token: token,
            timeoutInterval: 15
        )
    }

    func acquireGroupScreenShare(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallScreenLeaseResponse {
        try await post(
            "v1/group-calls/\(callId)/screen-share",
            body: CloudGroupCallScreenLeaseRequest(generation: generation),
            token: token,
            timeoutInterval: 15
        )
    }

    func heartbeatGroupScreenShare(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallScreenLeaseResponse {
        try await post(
            "v1/group-calls/\(callId)/screen-share/heartbeat",
            body: CloudGroupCallScreenLeaseRequest(generation: generation),
            token: token,
            timeoutInterval: 3
        )
    }

    func releaseGroupScreenShare(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallScreenReleaseResponse {
        try await post(
            "v1/group-calls/\(callId)/screen-share/release",
            body: CloudGroupCallScreenLeaseRequest(generation: generation),
            token: token,
            timeoutInterval: 15
        )
    }

    func createCall(_ body: CreateCloudCallRequest, token: String) async throws -> CloudCallCreateResponse {
        try await post("v1/calls", body: body, token: token, timeoutInterval: 8)
    }

    func activeCalls(token: String) async throws -> CloudActiveCallsResponse {
        try await get("v1/calls/active", token: token, timeoutInterval: 8)
    }

    func call(id: String, token: String) async throws -> CloudCallResponse {
        try await get("v1/calls/\(id)", token: token, timeoutInterval: 8)
    }

    func acceptCall(
        id: String,
        body: AcceptCloudCallRequest,
        token: String
    ) async throws -> CloudCallResponse {
        try await post("v1/calls/\(id)/accept", body: body, token: token, timeoutInterval: 8)
    }

    func revealCall(
        id: String,
        body: RevealCloudCallRequest,
        token: String
    ) async throws -> CloudCallResponse {
        try await post("v1/calls/\(id)/reveal", body: body, token: token, timeoutInterval: 8)
    }

    func confirmCall(
        id: String,
        body: ConfirmCloudCallRequest,
        token: String
    ) async throws -> CloudCallResponse {
        try await post("v1/calls/\(id)/confirm", body: body, token: token, timeoutInterval: 8)
    }

    func declineCall(id: String, reason: String? = nil, token: String) async throws -> CloudCallResponse {
        try await post("v1/calls/\(id)/decline", body: EndCloudCallRequest(reason: reason), token: token, timeoutInterval: 8)
    }

    func cancelCall(id: String, reason: String? = nil, token: String) async throws -> CloudCallResponse {
        try await post("v1/calls/\(id)/cancel", body: EndCloudCallRequest(reason: reason), token: token, timeoutInterval: 8)
    }

    func endCall(id: String, reason: String? = nil, token: String) async throws -> CloudCallResponse {
        try await post("v1/calls/\(id)/end", body: EndCloudCallRequest(reason: reason), token: token, timeoutInterval: 8)
    }

    func sendCallEvent(
        callId: String,
        body: SendCloudCallEventRequest,
        token: String
    ) async throws -> CloudCallEventResponse {
        try await post("v1/calls/\(callId)/events", body: body, token: token, timeoutInterval: 8)
    }

    func callEvents(
        callId: String,
        after eventSequence: Int64,
        limit: Int = 100,
        token: String
    ) async throws -> CloudCallEventsResponse {
        try await get(
            "v1/calls/\(callId)/events",
            queryItems: [
                URLQueryItem(name: "after", value: String(max(0, eventSequence))),
                URLQueryItem(name: "limit", value: String(max(1, min(100, limit)))),
            ],
            token: token,
            timeoutInterval: 8
        )
    }

    func sendCallTelemetry(
        callId: String,
        body: CallTelemetryRequest,
        token: String
    ) async throws -> CloudCallTelemetryResponse {
        try await post("v1/calls/\(callId)/telemetry", body: body, token: token)
    }

    func callIceConfiguration(callId: String, token: String) async throws -> CloudCallIceConfiguration {
        try await get("v1/calls/\(callId)/ice-config", token: token, timeoutInterval: 8)
    }

    func blockAccount(id: String, token: String) async throws -> CloudBlockResponse {
        try await put("v1/blocks/\(id)", body: EmptyBody(), token: token)
    }

    func unblockAccount(id: String, token: String) async throws -> CloudBlockResponse {
        try await delete("v1/blocks/\(id)", token: token)
    }

    func submitAbuseReport(
        clientReportId: UUID,
        dialogId: String,
        subject: CloudAbuseReportSubject,
        reason: AbuseReportReason,
        details: String?,
        token: String
    ) async throws -> CloudAbuseReportResponse {
        let response: CloudAbuseReportResponse = try await post(
            "v1/reports",
            body: CloudAbuseReportRequest(
                clientReportId: clientReportId.uuidString.lowercased(),
                dialogId: dialogId,
                subject: subject,
                reason: reason.rawValue,
                details: details
            ),
            token: token
        )
        guard response.isAcknowledged else {
            throw CloudAPIError(
                status: 502,
                message: String(localized: "The server returned an invalid report acknowledgement."),
                retryAfter: nil,
                code: "invalid_report_acknowledgement"
            )
        }
        return response
    }

    func revokeSession(token: String) async throws -> SessionRevocationResponse {
        try await delete("v1/session", token: token)
    }

    func listDevices(token: String) async throws -> [CloudDevice] {
        let response: DeviceListResponse = try await get("v1/devices", token: token)
        return response.devices
    }

    func queryPresence(accountIds: [String], token: String) async throws -> CloudPresenceResponse {
        try await post(
            "v1/presence/query",
            body: PresenceQueryRequest(accountIds: accountIds),
            token: token,
            timeoutInterval: 8
        )
    }

    func revokeDevice(id: String, token: String) async throws -> SessionRevocationResponse {
        try await delete("v1/devices/\(id)", token: token)
    }

    func startAccountDeletion(token: String) async throws -> AuthStartResponse {
        try await post("v1/account/deletion/start", body: EmptyBody(), token: token)
    }

    func deleteAccount(code: String, token: String) async throws -> AccountDeletionResponse {
        try await delete("v1/account", body: ["code": code], token: token)
    }

    private func get<Response: Decodable>(
        _ path: String,
        token: String?,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Response {
        try await get(path, queryItems: [], token: token, timeoutInterval: timeoutInterval)
    }

    private func get<Response: Decodable>(
        _ path: String,
        queryItems: [URLQueryItem],
        token: String?,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Response {
        var components = URLComponents(url: config.httpURL(path: path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await run(request)
    }

    /// Sends the exact journaled bytes. Re-encoding a decoded request is not equivalent here:
    /// JSON key order can change across processes, while server idempotency fingerprints bind to
    /// the original parsed request shape.
    private func persistedJSON<Response: Decodable>(
        _ path: String,
        method: String,
        body: Data,
        token: String
    ) async throws -> Response {
        precondition(["POST", "PATCH", "DELETE"].contains(method))
        var request = URLRequest(url: config.httpURL(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await run(request)
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        token: String?,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Response {
        var request = URLRequest(url: config.httpURL(path: path))
        request.httpMethod = "POST"
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await run(request)
    }

    private func put<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        token: String?
    ) async throws -> Response {
        var request = URLRequest(url: config.httpURL(path: path))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await run(request)
    }

    private func patch<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        token: String?
    ) async throws -> Response {
        var request = URLRequest(url: config.httpURL(path: path))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await run(request)
    }

    private func delete<Response: Decodable>(
        _ path: String,
        token: String?,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Response {
        var request = URLRequest(url: config.httpURL(path: path))
        request.httpMethod = "DELETE"
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await run(request)
    }

    private func delete<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        token: String?
    ) async throws -> Response {
        var request = URLRequest(url: config.httpURL(path: path))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await run(request)
    }

    private func run<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        var authorizedRequest = request
        let suppliedToken = Self.bearerToken(in: request)
        if let suppliedToken,
           let replacement = await credentialCoordinator?.authorizationToken(matching: suppliedToken) {
            authorizedRequest.setValue("Bearer \(replacement)", forHTTPHeaderField: "Authorization")
        }
        var (data, response) = try await session.data(for: authorizedRequest)
        guard let http = response as? HTTPURLResponse else {
            throw CloudAPIError(status: -1, message: "Invalid server response", retryAfter: nil)
        }
        if http.statusCode == 401,
           let serverError = try? decoder.decode(ServerError.self, from: data),
           serverError.code == "access_token_expired",
           let sentToken = Self.bearerToken(in: authorizedRequest),
           let refreshed = try await credentialCoordinator?.refreshIfNeeded(
               matching: sentToken,
               force: true
           ) {
            authorizedRequest.setValue("Bearer \(refreshed)", forHTTPHeaderField: "Authorization")
            (data, response) = try await session.data(for: authorizedRequest)
        }
        guard let finalHTTP = response as? HTTPURLResponse else {
            throw CloudAPIError(status: -1, message: "Invalid server response", retryAfter: nil)
        }
        guard (200..<300).contains(finalHTTP.statusCode) else {
            let serverError = try? decoder.decode(ServerError.self, from: data)
            let message = serverError?.error
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(finalHTTP.statusCode)"
            let retryAfter = finalHTTP.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            let error = CloudAPIError(
                status: finalHTTP.statusCode,
                message: message,
                retryAfter: retryAfter,
                code: serverError?.code,
                existingCallId: serverError?.existingCallId
            )
            if let sentToken = Self.bearerToken(in: authorizedRequest) {
                await credentialCoordinator?.handleAuthenticationFailure(
                    code: error.code,
                    matching: sentToken
                )
            }
            throw error
        }
        return try decoder.decode(Response.self, from: data)
    }

    private static func bearerToken(in request: URLRequest) -> String? {
        guard let value = request.value(forHTTPHeaderField: "Authorization"),
              value.lowercased().hasPrefix("bearer ")
        else { return nil }
        return String(value.dropFirst(7))
    }
}

private struct DifferenceRequest: Codable, Sendable {
    let sincePts: Int64
    let maxEvents: Int
    let maxBytes: Int
}

private struct ServerError: Codable {
    let error: String
    let code: String?
    let existingCallId: String?
}

private struct EmptyBody: Encodable {}

private struct ProfilePhotoMutationRequest: Encodable {
    let mediaId: String?
    let clientMutationId: String
    let basePhotoRevision: Int64
}

private struct CreateGroupRequest: Encodable {
    let groupId: String
    let title: String
    let memberIds: [String]
}

private struct GroupMutationRequest: Encodable {
    let clientMutationId: String
}

private struct AddGroupMembersRequest: Encodable {
    let memberIds: [String]
    let clientMutationId: String
}

private struct ChangeGroupRoleRequest: Encodable {
    let role: String
    let clientMutationId: String
}

private struct UpdateGroupRequest: Encodable {
    let title: String?
    let photoMediaId: String?
    let clearPhoto: Bool
    let clientMutationId: String
}

private struct TransferGroupOwnerRequest: Encodable {
    let accountId: String
    let clientMutationId: String
}

private struct LeaveGroupRequest: Encodable {
    let successorAccountId: String?
    let clientMutationId: String
}

private struct GroupNotificationsRequest: Encodable {
    let mode: String
    let clientMutationId: String
}

private struct GroupPermissionsRequest: Encodable {
    let membersCanSend: Bool
    let membersCanAddMembers: Bool
    let membersCanEditInfo: Bool
    let clientMutationId: String
}

private struct DialogPreferencesRequest: Encodable {
    let clientMutationId: String
    let pinned: Bool?
    let muted: Bool?
    let archived: Bool?
}

private struct BootstrapDialogsRequest: Encodable {
    let token: String
    let cursor: String?
    let limit: Int
    let previewMessages: Int
}

private struct HistoryRequest: Encodable {
    let dialogId: String
    let beforeMsgId: Int64?
    let afterMsgId: Int64?
    let limit: Int
    let maxBytes: Int
}

nonisolated struct DraftAttachmentRequest: Codable, Equatable, Sendable {
    let attachmentId: String
    let mediaId: String
    let position: Int

    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case mediaId = "media_id"
        case position
    }
}

private struct DraftMutationRequest: Encodable {
    let operationId: String
    let state: String
    let text: String
    let replyToMsgId: Int64?
    let mentions: [CloudMention]
    let attachments: [DraftAttachmentRequest]

    enum CodingKeys: String, CodingKey {
        case operationId = "operation_id"
        case state, text
        case replyToMsgId = "reply_to_msg_id"
        case mentions, attachments
    }
}

nonisolated struct MediaGroupItemRequest: Codable, Equatable, Sendable {
    let clientMsgId: String
    let mediaId: String

    enum CodingKeys: String, CodingKey {
        case clientMsgId = "client_msg_id"
        case mediaId = "media_id"
    }
}

private struct MediaGroupSendRequest: Encodable {
    let clientGroupId: String
    let dialogId: String
    let items: [MediaGroupItemRequest]
    let body: String
    let replyToMsgId: Int64?
    let mentions: [CloudMention]
    let draftConsumeOperationId: String?
    let silent: Bool
    let linkPreviewCandidate: CloudLinkPreviewCandidate?

    enum CodingKeys: String, CodingKey {
        case clientGroupId = "client_group_id"
        case dialogId = "dialog_id"
        case items, body
        case replyToMsgId = "reply_to_msg_id"
        case mentions
        case draftConsumeOperationId = "draft_consume_operation_id"
        case silent
        case linkPreviewCandidate = "link_preview_candidate"
    }
}

private struct SendMessageRequest: Encodable {
    let dialogId: String
    let clientMsgId: String
    let kind: String?
    let body: String?
    let replyToMsgId: Int64?
    let mediaId: String?
    let forwardedFrom: ForwardedFromRequest?
    let mentions: [CloudMention]
    let draftConsumeOperationId: String?
    let silent: Bool
    let linkPreviewCandidate: CloudLinkPreviewCandidate?
}

private struct ForwardedFromRequest: Encodable {
    let dialogId: String
    let msgId: Int64
}

private struct EditMessageRequest: Encodable {
    let dialogId: String
    let msgId: Int64
    let clientMutationId: String
    let expectedEditVersion: Int
    let body: String
    let linkPreviewCandidate: CloudLinkPreviewCandidate?
}

private struct DeleteMessageRequest: Encodable {
    let dialogId: String
    let msgId: Int64
    let clientMutationId: String
}

private struct ReactionRequest: Encodable {
    let dialogId: String
    let msgId: Int64
    let clientMutationId: String
    let emoji: String?
}

private struct ReadRequest: Encodable {
    let dialogId: String
    let maxReadMsgId: Int64
}

private struct PushRegistrationRequest: Encodable {
    let token: String
    let environment: String
}
