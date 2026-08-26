import Foundation

nonisolated enum LaunchPhase: Equatable, Sendable {
    case restoringLocal
    case signedOut
    case localReady
    case recoveringStore
}

nonisolated enum SavedMessagesCapabilityState: Equatable, Sendable {
    case unknown
    case supported
    case unsupported

    static func advertised(in capabilities: Set<String>) -> Self {
        capabilities.contains("saved_messages_v1") ? .supported : .unsupported
    }

    func resolvingEnsureFailure(statusCode: Int?) -> Self {
        statusCode == 404 ? .unsupported : self
    }
}

nonisolated struct MessagingCapabilities: OptionSet, Sendable, Equatable {
    let rawValue: UInt64

    static let chatOrganization = Self(rawValue: 1 << 0)
    static let replies = Self(rawValue: 1 << 1)
    static let editing = Self(rawValue: 1 << 2)
    static let deletion = Self(rawValue: 1 << 3)
    static let forwarding = Self(rawValue: 1 << 4)
    static let reactions = Self(rawValue: 1 << 5)
    static let media = Self(rawValue: 1 << 6)
    static let voiceNotes = Self(rawValue: 1 << 7)
    static let groups = Self(rawValue: 1 << 8)
    static let calls = Self(rawValue: 1 << 9)
    static let profiles = Self(rawValue: 1 << 10)
    static let richSearch = Self(rawValue: 1 << 11)
    static let multipartMedia = Self(rawValue: 1 << 12)
    static let videoCalls = Self(rawValue: 1 << 13)

    static let savedMessages = Self(rawValue: 1 << 14)
    static let cloudDrafts = Self(rawValue: 1 << 15)
    static let dialogPreferences = Self(rawValue: 1 << 16)
    /// Local message search. Set from the device rather than negotiated with the server: the index
    /// lives on disk here and nothing about it is advertised. Dropping the bit degrades the search
    /// screen to chats and people rather than showing a broken Messages tab.
    static let localSearch = Self(rawValue: 1 << 17)
    static let mediaGroups = Self(rawValue: 1 << 18)
    static let groupCalls = Self(rawValue: 1 << 19)
    static let groupVideoCalls = Self(rawValue: 1 << 20)
    static let screenSharing = Self(rawValue: 1 << 21)
    static let chatFolders = Self(rawValue: 1 << 22)
    static let scheduledDelivery = Self(rawValue: 1 << 23)
    static let linkPreviews = Self(rawValue: 1 << 24)
    static let abuseReports = Self(rawValue: 1 << 25)
    static let presence = Self(rawValue: 1 << 26)
    static let profilePhotos = Self(rawValue: 1 << 27)

    static let productionText: Self = [.replies, .editing, .deletion, .forwarding, .reactions]
    static let demo: Self = [
        .chatOrganization, .replies, .editing, .deletion, .forwarding,
        .reactions, .media, .voiceNotes, .groups, .calls, .profiles, .richSearch, .multipartMedia,
        .videoCalls,
        .cloudDrafts, .mediaGroups, .chatFolders, .scheduledDelivery, .linkPreviews,
        .presence, .profilePhotos,
    ]
}

nonisolated enum AbuseReportReason: String, CaseIterable, Identifiable, Sendable {
    case spam
    case scam
    case harassment
    case violence
    case sexualContent = "sexual_content"
    case childSafety = "child_safety"
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spam: String(localized: "Spam")
        case .scam: String(localized: "Scam or fraud")
        case .harassment: String(localized: "Harassment")
        case .violence: String(localized: "Violence or threats")
        case .sexualContent: String(localized: "Sexual content")
        case .childSafety: String(localized: "Child safety")
        case .other: String(localized: "Other")
        }
    }
}

nonisolated struct AbuseReportDraft: Equatable, Sendable {
    var reason: AbuseReportReason = .spam
    var details = ""

    var normalizedDetails: String? {
        let value = details.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var validationMessage: String? {
        if details.unicodeScalars.count > 500 {
            return String(localized: "Details must be 500 characters or fewer.")
        }
        if reason == .other && (normalizedDetails?.unicodeScalars.count ?? 0) < 10 {
            return String(localized: "Add at least 10 characters of detail for Other.")
        }
        return nil
    }
}

nonisolated enum AbuseReportSubmissionResult: Equatable, Sendable {
    case submitted
    case failed(String)
    case cancelled
}

/// The single source of truth for how ordinary server-decryptable chats are described in UI.
/// Calls have a separate E2E security model and must not reuse this presentation.
nonisolated enum CloudChatPrivacyPresentation {
    static let systemImage = "cloud.fill"
    static var title: String { String(localized: "Cloud chat") }
    static var detail: String { String(localized: "Cloud encrypted") }
    static var disclosure: String {
        String(localized: "Messages use encrypted connections and are stored encrypted on Toj’s servers. They are not end-to-end encrypted, so Toj can access them to deliver and sync messages and review safety reports.")
    }
    static var accessibilityLabel: String {
        String(localized: "Cloud chat. Messages are not end-to-end encrypted.")
    }
    static var savedMessagesAccessibilityLabel: String {
        String(localized: "Saved Messages. Cloud chat. Messages are not end-to-end encrypted.")
    }
}

nonisolated enum MessageAction: String, CaseIterable, Identifiable, Sendable {
    case reply
    case react
    case copy
    case edit
    case save
    case forward
    case delete
    case retry
    case remove
    case report
    case inspect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reply: String(localized: "Reply")
        case .react: String(localized: "React")
        case .copy: String(localized: "Copy")
        case .edit: String(localized: "Edit")
        case .save: String(localized: "Save")
        case .forward: String(localized: "Forward")
        case .delete: String(localized: "Delete")
        case .retry: String(localized: "Retry")
        case .remove: String(localized: "Remove")
        case .report: String(localized: "Report")
        case .inspect: String(localized: "Details")
        }
    }

    var systemImage: String {
        switch self {
        case .reply: "arrowshape.turn.up.left"
        case .react: "face.smiling"
        case .copy: "doc.on.doc"
        case .edit: "pencil"
        case .save: "bookmark"
        case .forward: "arrowshape.turn.up.right"
        case .delete: "trash"
        case .retry: "arrow.clockwise"
        case .remove: "trash"
        case .report: "exclamationmark.bubble"
        case .inspect: "info.circle"
        }
    }
}

nonisolated enum ComposerMode: Equatable, Sendable {
    case text
    case replying(messageId: String, preview: String)
    case editing(messageId: String, original: String)
    case recording(elapsedSeconds: Int)
    case attachmentPreview(DemoAttachment)
    case uploading(DemoAttachment, progress: Double)
    case disabled(reason: String)
}

nonisolated enum ReplicaConnectionState: Equatable, Sendable {
    case live
    case connecting
    case offline

    var title: String {
        switch self {
        case .live: String(localized: "Connected")
        case .connecting: String(localized: "Connecting…")
        case .offline: String(localized: "Waiting for network")
        }
    }

    var systemImage: String {
        switch self {
        case .live: "network"
        case .connecting: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        }
    }
}

nonisolated enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case chats
    case people
    case messages
    case media
    case links
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: String(localized: "Chats")
        case .people: String(localized: "People")
        case .messages: String(localized: "Messages")
        case .media: String(localized: "Media")
        case .links: String(localized: "Links")
        case .files: String(localized: "Files")
        }
    }
}

nonisolated enum ChatListPreviewKind: String, Equatable, Sendable {
    case text
    case photo
    case video
    case voice
    case file
    case link
    case attachment

    init(messageKind: String?) {
        switch messageKind?.lowercased() {
        case nil, "", "text": self = .text
        case "photo", "image": self = .photo
        case "video": self = .video
        case "voice", "audio": self = .voice
        case "file", "document": self = .file
        case "link": self = .link
        default: self = .attachment
        }
    }

    var title: String {
        switch self {
        case .text: ""
        case .photo: String(localized: "Photo")
        case .video: String(localized: "Video")
        case .voice: String(localized: "Voice message")
        case .file: String(localized: "File")
        case .link: String(localized: "Link")
        case .attachment: String(localized: "Attachment")
        }
    }

    var systemImage: String? {
        switch self {
        case .text: nil
        case .photo: "photo.fill"
        case .video: "video.fill"
        case .voice: "mic.fill"
        case .file: "doc.fill"
        case .link: "link"
        case .attachment: "paperclip"
        }
    }
}

nonisolated enum DemoAttachment: Equatable, Sendable {
    case photo(name: String)
    case video(name: String, duration: String)
    case file(name: String, size: String)
    case voice(duration: String)
    case link(title: String, host: String)

    var title: String {
        switch self {
        case let .photo(name), let .video(name, _), let .file(name, _): name
        case let .voice(duration): String(localized: "Voice message \(duration)")
        case let .link(title, _): title
        }
    }

    var chatListPreviewKind: ChatListPreviewKind {
        switch self {
        case .photo: .photo
        case .video: .video
        case .file: .file
        case .voice: .voice
        case .link: .link
        }
    }
}

nonisolated struct ChatListViewState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case loading
        case empty
        case content
        case error(message: String)
        case partial(message: String)
    }

    let phase: Phase
    let query: String
    let scope: SearchScope
}

nonisolated struct ConversationViewState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case loading
        case empty
        case content
        case error(message: String)
        case partial(message: String)
    }

    let phase: Phase
    let connection: ReplicaConnectionState
    let unreadBelow: Int
}

nonisolated struct ComposerViewState: Equatable, Sendable {
    let mode: ComposerMode
    let text: String
    let canSend: Bool
}

nonisolated struct MessageViewState: Equatable, Identifiable, Sendable {
    let id: String
    let text: String
    let isMine: Bool
    let availableActions: [MessageAction]
}

nonisolated struct ProfileViewState: Equatable, Sendable {
    let title: String
    let subtitle: String
    let sharedMediaCount: Int
    let sharedFileCount: Int
    let sharedLinkCount: Int
}

nonisolated struct CallViewState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case ringing
        case connecting
        case active
        case reconnecting
        case declined
        case ended
    }

    let peerName: String
    let phase: Phase
    let isMuted: Bool
    let isCameraEnabled: Bool
}
