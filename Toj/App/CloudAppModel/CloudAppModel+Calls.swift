import Foundation
import Observation
import UIKit

extension CloudAppModel {
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
}
