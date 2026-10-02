import Foundation
import Observation
import UIKit

extension CloudAppModel {
    func refreshMediaCacheUsage() async {
        if let localStore {
            mediaCacheBytes = await mediaEngine.cacheUsageBytes(localStore: localStore)
        } else {
            mediaCacheBytes = await mediaEngine.cacheUsageBytes()
        }
    }

    func loadMediaPolicies() async {
        mediaAutoDownloadPolicy = await mediaEngine.currentAutoDownloadPolicy()
        mediaCachePolicy = await mediaEngine.currentCachePolicy()
    }

    func updateMediaAutoDownloadPolicy(_ policy: MediaAutoDownloadPolicy) async {
        do {
            try await mediaEngine.updateAutoDownloadPolicy(policy)
            mediaAutoDownloadPolicy = policy
        } catch {
            status = "Could not save automatic download settings"
        }
    }

    func updateMediaCachePolicy(_ policy: MediaCachePolicy) async {
        do {
            try await mediaEngine.updateCachePolicy(policy)
            mediaCachePolicy = policy
            await refreshMediaCacheUsage()
        } catch {
            status = "Could not save media cache settings"
        }
    }

    func clearMediaCache() async {
        guard !clearingMediaCache else { return }
        clearingMediaCache = true
        defer { clearingMediaCache = false }
        MediaPresentationCache.shared.removeAll()
        if let localStore {
            await mediaEngine.clearDownloadedCache(localStore: localStore)
        } else {
            await mediaEngine.clearDownloadedCache()
        }
        await refreshMediaCacheUsage()
        status = "Downloaded media cleared"
    }

    func clearMediaCache(kind: String) async {
        guard !clearingMediaCache, let localStore else { return }
        clearingMediaCache = true
        defer { clearingMediaCache = false }
        let mediaIds = (try? await localStore.mediaIds(kind: kind)) ?? []
        MediaPresentationCache.shared.invalidate(mediaIds: mediaIds)
        await mediaEngine.clearMediaCache(mediaIds: mediaIds, localStore: localStore)
        await refreshMediaCacheUsage()
        status = "Downloaded media cleared"
    }

    func clearMediaCache(dialogId: String) async {
        guard !clearingMediaCache, let localStore else { return }
        clearingMediaCache = true
        defer { clearingMediaCache = false }
        let mediaIds = (try? await localStore.mediaIds(dialogId: dialogId)) ?? []
        MediaPresentationCache.shared.invalidate(mediaIds: mediaIds)
        await mediaEngine.clearMediaCache(mediaIds: mediaIds, localStore: localStore)
        await refreshMediaCacheUsage()
        status = "Downloaded media cleared"
    }

    func queueMediaDownloads(
        _ mediaItems: [CloudMedia],
        dialogId: String?,
        visible: Bool
    ) async {
        guard visible, !mediaItems.isEmpty, let localStore else { return }
        let snapshot = ReplicaNetworkMonitor.shared.snapshot()
        let network = snapshot.mediaNetworkClass
        let chat = if let dialogId {
            (try? await localStore.mediaChatClass(dialogId: dialogId)) ?? .privateChat
        } else {
            MediaChatClass.privateChat
        }

        for media in mediaItems {
            _ = await mediaEngine.enqueueAutoDownload(
                media: media,
                chat: chat,
                network: network,
                dialogId: dialogId,
                localStore: localStore,
                visible: visible
            )
        }
        scheduleMediaDownloadProcessing()
    }

    /// Telegram-style arrival prefetch: media referenced by newly written messages is queued for
    /// download immediately under the auto-download policy, so a chat can open with its media
    /// already on disk. The engine skips components that are already downloaded, so re-applying
    /// the same messages is cheap.
    func enqueueArrivalMediaDownloads(_ messages: [CloudMessage], recentOnly: Bool = false) async {
        await enqueueArrivalMediaDownloads(
            messages.map { (media: $0.media, dialogId: $0.dialogId, state: $0.state, serverTs: $0.serverTs) },
            recentOnly: recentOnly
        )
    }

    func enqueueArrivalMediaDownloads(window messages: [LocalMessage]) async {
        await enqueueArrivalMediaDownloads(
            messages.map { (media: $0.media, dialogId: $0.dialogId, state: $0.state, serverTs: $0.serverTs) },
            recentOnly: false
        )
    }

    func enqueueArrivalMediaDownloads(
        _ candidates: [(media: CloudMedia?, dialogId: String, state: String, serverTs: String?)],
        recentOnly: Bool
    ) async {
        guard let localStore else { return }
        let snapshot = ReplicaNetworkMonitor.shared.snapshot()
        guard snapshot.allowsEssentialSync else { return }
        let network = snapshot.mediaNetworkClass
        let cutoff = recentOnly ? Date(timeIntervalSinceNow: -Self.arrivalPrefetchMaxAge) : nil
        var chatClassByDialog: [String: MediaChatClass] = [:]
        var enqueuedAny = false
        for candidate in candidates {
            guard let media = candidate.media, candidate.state == "visible" else { continue }
            if let cutoff {
                guard let serverTs = candidate.serverTs,
                      let timestamp = Self.serverTimestamp(serverTs),
                      timestamp >= cutoff else { continue }
            }
            let chat: MediaChatClass
            if let known = chatClassByDialog[candidate.dialogId] {
                chat = known
            } else {
                chat = (try? await localStore.mediaChatClass(dialogId: candidate.dialogId)) ?? .privateChat
                chatClassByDialog[candidate.dialogId] = chat
            }
            _ = await mediaEngine.enqueueAutoDownload(
                media: media,
                chat: chat,
                network: network,
                dialogId: candidate.dialogId,
                localStore: localStore
            )
            enqueuedAny = true
        }
        if enqueuedAny { scheduleMediaDownloadProcessing() }
    }

    nonisolated static let arrivalPrefetchMaxAge: TimeInterval = 30 * 24 * 60 * 60

    nonisolated static func serverTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    func scheduleMediaDownloadProcessing() {
        guard mediaDownloadTask == nil else { return }
        mediaDownloadTask = Task { [weak self] in
            guard let self else { return }
            let networkClass = ReplicaNetworkMonitor.shared.snapshot().networkClass
            await self.mediaPrefetchScheduler.wake(networkClass: networkClass)
            self.mediaDownloadTask = nil
        }
    }

    func processMediaDownloadJobs(maximumJobs: Int) async {
        for _ in 0..<maximumJobs {
            guard await processOneMediaDownload(component: nil) else { break }
        }
        await refreshMediaCacheUsage()
        guard let localStore else { return }
        let remainingJobs = try? await localStore.mediaDownloadJobsReady(limit: 1)
        if remainingJobs?.isEmpty == false {
            BackgroundRuntimeCoordinator.shared.scheduleProcessing(
                earliestBeginDate: Date(timeIntervalSinceNow: 60)
            )
        } else if let nextRetry = try? await localStore.nextMediaDownloadRetryDate() {
            BackgroundRuntimeCoordinator.shared.scheduleProcessing(earliestBeginDate: nextRetry)
        }
    }

    func processOneMediaDownload(component: MediaDownloadComponent?) async -> Bool {
        let networkSnapshot = ReplicaNetworkMonitor.shared.snapshot()
        guard networkSnapshot.allowsEssentialSync,
              let token = storedSession?.session.token,
              let localStore,
              !Task.isCancelled else { return false }
        guard let item = await mediaEngine.dequeueAutoDownload(
            localStore: localStore,
            component: component
        ) else { return false }
        let readyCount = (try? await localStore.mediaDownloadJobsReady(limit: 200).count) ?? 0
        LocalFirstMetrics.queueDepth(readyCount)
        let chat = if let dialogId = item.dialogId {
            (try? await localStore.mediaChatClass(dialogId: dialogId)) ?? .privateChat
        } else {
            MediaChatClass.privateChat
        }
        do {
            // Revalidate the live policy and path after the durable claim; scrolling, roaming, and
            // Low Data Mode can all change while a job waits in SQLCipher.
            let currentNetwork = ReplicaNetworkMonitor.shared.snapshot()
            try await mediaEngine.performAutoDownload(
                item,
                token: token,
                localStore: localStore,
                chat: chat,
                network: currentNetwork.mediaNetworkClass
            )
            if item.component == .thumbnail,
               item.media.kind == "photo" || item.media.kind == "video" {
                _ = await presentationImage(for: item.media, variant: .bubble720)
            } else if item.component == .fullMedia, item.media.kind == "photo" {
                _ = await presentationImage(for: item.media, variant: .screen2048)
            } else if item.component == .fullMedia, item.media.kind == "video" {
                _ = await presentationImage(for: item.media, variant: .videoPoster)
                await prewarmStreamingVideoAssetIfLocal(for: item.media)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            if await mediaEngine.areAutomaticDownloadsSuspendedForLowDisk(),
               operationNotice?.title != "Storage needed for media" {
                presentNotice(
                    "Storage needed for media",
                    message: "Toj kept your saved chats, but paused new automatic media downloads to preserve free space."
                )
            }
            if let nextRetry = try? await localStore.nextMediaDownloadRetryDate() {
                BackgroundRuntimeCoordinator.shared.scheduleProcessing(earliestBeginDate: nextRetry)
            }
            if case .authenticationRequired = cloudFailureDisposition(error) { return false }
            return true
        }
    }
}
