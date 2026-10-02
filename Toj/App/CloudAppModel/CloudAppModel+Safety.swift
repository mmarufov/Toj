import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func blockPeer(dialogId: String) async -> Bool {
        #if DEBUG
        if isDemoMode { return false }
        #endif
        guard
            let session = storedSession?.session,
            let peer = try? await localStore?.peerAccountId(dialogId: dialogId, excluding: session.accountId)
        else { return false }
        do {
            _ = try await api.blockAccount(id: peer, token: session.token)
            return true
        } catch {
            presentNotice("Could not block account", message: error.localizedDescription)
            return false
        }
    }

    func submitAccountReport(
        dialogId: String,
        reason: AbuseReportReason,
        details: String?,
        clientReportId: UUID
    ) async -> AbuseReportSubmissionResult {
        guard capabilities.contains(.abuseReports) else {
            return .failed(String(localized: "Reporting is not available on this server yet."))
        }
        guard canShowAccountReport(dialogId: dialogId) else {
            return .failed(String(localized: "The account could not be verified."))
        }
        guard
            let session = storedSession?.session,
            let peer = try? await localStore?.peerAccountId(
                dialogId: dialogId,
                excluding: session.accountId
            )
        else {
            return .failed(String(localized: "The account could not be verified."))
        }
        return await submitAbuseReport(
            dialogId: dialogId,
            subject: .account(peer),
            reason: reason,
            details: details,
            clientReportId: clientReportId
        )
    }

    func submitMessageReport(
        _ line: Line,
        reason: AbuseReportReason,
        details: String?,
        clientReportId: UUID
    ) async -> AbuseReportSubmissionResult {
        guard
            Self.isReportable(line, capabilities: capabilities),
            let dialogId = line.dialogId,
            let msgId = line.msgId,
            let dialogType = dialogs.first(where: { $0.id == dialogId })?.type,
            dialogType == "direct" || dialogType == "group"
        else {
            return .failed(String(localized: "This message can no longer be reported."))
        }
        return await submitAbuseReport(
            dialogId: dialogId,
            subject: .message(msgId),
            reason: reason,
            details: details,
            clientReportId: clientReportId
        )
    }

    private func submitAbuseReport(
        dialogId: String,
        subject: CloudAbuseReportSubject,
        reason: AbuseReportReason,
        details: String?,
        clientReportId: UUID
    ) async -> AbuseReportSubmissionResult {
        guard capabilities.contains(.abuseReports) else {
            return .failed(String(localized: "Reporting is not available on this server yet."))
        }
        guard !isSessionTeardownInProgress, let session = storedSession?.session else {
            return .cancelled
        }
        let generation = accountSessionGeneration
        let accountId = session.accountId
        let token = session.token
        do {
            _ = try await api.submitAbuseReport(
                clientReportId: clientReportId,
                dialogId: dialogId,
                subject: subject,
                reason: reason,
                details: details,
                token: token
            )
            guard
                !Task.isCancelled,
                !isSessionTeardownInProgress,
                generation == accountSessionGeneration,
                storedSession?.session.accountId == accountId,
                storedSession?.session.token == token
            else {
                return .cancelled
            }
            return .submitted
        } catch is CancellationError {
            return .cancelled
        } catch {
            guard
                !isSessionTeardownInProgress,
                generation == accountSessionGeneration,
                storedSession?.session.accountId == accountId,
                storedSession?.session.token == token
            else {
                return .cancelled
            }
            if let apiError = error as? CloudAPIError,
               Self.shouldWithdrawAbuseReportCapability(after: apiError) {
                negotiatedCapabilities.remove(.abuseReports)
            }
            return .failed(error.localizedDescription)
        }
    }

    nonisolated static func shouldWithdrawAbuseReportCapability(
        after error: CloudAPIError
    ) -> Bool {
        error.code == "capability_unavailable"
            || (error.status == 404 && error.code == nil)
    }
}
