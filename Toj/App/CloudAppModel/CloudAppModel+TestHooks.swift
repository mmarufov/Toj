import Foundation
import Observation
import UIKit

extension CloudAppModel {
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
}
