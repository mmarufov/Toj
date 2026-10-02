import Foundation
import Observation
import UIKit

extension CloudAppModel {
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
}
