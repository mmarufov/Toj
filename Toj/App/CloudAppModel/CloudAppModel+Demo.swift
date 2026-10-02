import Foundation
import Observation
import UIKit

extension CloudAppModel {
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

    func leaveDemoMode() {
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

    func sendDemo(_ text: String, replyPreview: String? = nil, attachment: DemoAttachment? = nil) {
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

    func updateDemoMessage(messageId: String, text: String) {
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

    static func demoTimestamp(minutesAgo: Int) -> String {
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

    func demoMediaBytes(for media: CloudMedia, thumbnail: Bool) -> Data? {
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
