import Foundation
import Observation
import UIKit

extension CloudAppModel {
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

    func activeMentionQuery(in text: String) -> String? {
        guard let range = activeMentionRange(in: text) else { return nil }
        return String(text[range].dropFirst())
    }

    func resolvedMentions(in text: String, dialogId: String) -> [CloudMention] {
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

    func restoreUnderlyingDraftComposer() {
        let text = transientUnderlyingDraftText ?? (currentDraft?.state == "active" ? currentDraft?.text ?? "" : "")
        let mode = transientUnderlyingComposerMode ?? .text
        transientUnderlyingDraftText = nil
        transientUnderlyingComposerMode = nil
        suppressDraftPersistence = true
        draft = text
        composerMode = mode
        suppressDraftPersistence = false
    }
}
