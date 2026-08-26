import Foundation
import Observation

@MainActor
@Observable
final class PresenceCoordinator {
    struct PeerPresence: Equatable, Sendable {
        let accountId: String
        var online: Bool
        var lastSeenAt: String?
        var revision: Int64
    }

    private struct TypingLease: Equatable, Sendable {
        let actorAccountId: String
        let expiresAt: Date
    }

    private struct PresenceAcceptance {
        let snapshot: LocalPresenceSnapshot?
    }

    private let api: CloudAPI
    private(set) var values: [String: PeerPresence] = [:]
    private(set) var typingRevision: UInt64 = 0
    private(set) var presenceRevision: UInt64 = 0

    @ObservationIgnored private weak var store: CloudLocalStore?
    @ObservationIgnored private var observerAccountId: String?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var socket: CloudHintSocket?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var foregroundActive = true
    @ObservationIgnored private var transportConnected = false
    @ObservationIgnored private var knownDirectPeers = Set<String>()
    @ObservationIgnored private var hiddenAccountIds = Set<String>()
    @ObservationIgnored private var typingLeasesByDialog: [String: [String: TypingLease]] = [:]
    @ObservationIgnored private var typingExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var authoritativeRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var typingIdleTask: Task<Void, Never>?
    @ObservationIgnored private var typingSendTail: Task<Void, Never>?
    @ObservationIgnored private var localTypingDialogId: String?
    @ObservationIgnored private var lastTypingSentAt: Date?
    @ObservationIgnored private let authoritativeRefreshInterval: Duration

    init(api: CloudAPI, authoritativeRefreshInterval: Duration = .seconds(30)) {
        self.api = api
        self.authoritativeRefreshInterval = authoritativeRefreshInterval
    }

    func configure(
        store: CloudLocalStore?,
        session: CloudSession?,
        enabled: Bool
    ) async {
        generation &+= 1
        let expectedGeneration = generation
        let identityChanged = observerAccountId != session?.accountId || token != session?.token
        if identityChanged {
            // Capability negotiation can finish after the authenticated hint socket has already
            // connected. Preserve that initial socket while adopting its account-scoped state,
            // but never carry an old account's socket across an actual identity change.
            let adoptingInitialIdentity = observerAccountId == nil && token == nil
            await reset(
                clearCacheValues: true,
                invalidatesGeneration: false,
                preserveSocket: adoptingInitialIdentity
            )
            guard generation == expectedGeneration else { return }
            self.store = store
            observerAccountId = session?.accountId
            token = session?.token
            if let store, let accountId = session?.accountId {
                let cached = try? await store.loadPresenceCache(observerAccountId: accountId)
                guard generation == expectedGeneration,
                      observerAccountId == accountId,
                      token == session?.token
                else { return }
                if let cached {
                    values = Dictionary(uniqueKeysWithValues: cached.map {
                        ($0.subjectAccountId, PeerPresence(
                            accountId: $0.subjectAccountId,
                            online: false,
                            lastSeenAt: $0.lastSeenAt,
                            revision: $0.revision
                        ))
                    })
                    presenceRevision &+= 1
                }
            }
        } else {
            self.store = store
        }
        await finishConfiguration(enabled: enabled, expectedGeneration: expectedGeneration)
    }

    private func finishConfiguration(enabled: Bool, expectedGeneration: UInt64) async {
        guard generation == expectedGeneration else { return }
        self.enabled = enabled
        guard enabled else {
            updateAuthoritativeRefreshLoop()
            await stopLocalTyping()
            guard generation == expectedGeneration, !self.enabled else { return }
            await flushTypingSends()
            guard generation == expectedGeneration, !self.enabled else { return }
            clearEphemeral()
            let attachedSocket = socket
            await attachedSocket?.setPresenceActive(false)
            return
        }
        if foregroundActive, transportConnected {
            let attachedSocket = socket
            await attachedSocket?.setPresenceActive(true)
            guard generation == expectedGeneration,
                  self.enabled,
                  foregroundActive,
                  transportConnected,
                  socket === attachedSocket
            else { return }
            await refreshKnownPeers()
        }
        updateAuthoritativeRefreshLoop()
    }

    func attach(socket: CloudHintSocket?) async {
        self.socket = socket
        if enabled, foregroundActive, transportConnected {
            await socket?.setPresenceActive(true)
        }
    }

    func setForegroundActive(_ active: Bool) async {
        foregroundActive = active
        guard enabled else {
            updateAuthoritativeRefreshLoop()
            return
        }
        if !active { updateAuthoritativeRefreshLoop() }
        if active, transportConnected {
            let attachedSocket = socket
            await attachedSocket?.setPresenceActive(true)
            guard foregroundActive, enabled, transportConnected, socket === attachedSocket else { return }
            await refreshKnownPeers()
            updateAuthoritativeRefreshLoop()
        } else {
            await stopLocalTyping()
            guard foregroundActive == active, enabled else { return }
            await flushTypingSends()
            guard foregroundActive == active, enabled else { return }
            let attachedSocket = socket
            await attachedSocket?.setPresenceActive(false)
            guard foregroundActive == active, enabled, socket === attachedSocket else { return }
            clearEphemeral()
        }
    }

    func transportChanged(_ state: CloudHintSocket.State) async {
        transportConnected = state == .connected
        guard enabled else {
            updateAuthoritativeRefreshLoop()
            return
        }
        if !transportConnected { updateAuthoritativeRefreshLoop() }
        if transportConnected, foregroundActive {
            let attachedSocket = socket
            await attachedSocket?.setPresenceActive(true)
            guard transportConnected, foregroundActive, enabled, socket === attachedSocket else { return }
            await refreshKnownPeers()
            updateAuthoritativeRefreshLoop()
        } else if state == .disconnected {
            await stopLocalTyping()
            guard !transportConnected, enabled else { return }
            await flushTypingSends()
            guard !transportConnected, enabled else { return }
            clearEphemeral()
        }
    }

    func refresh(accountIds: [String]) async {
        guard enabled, let token, let observerAccountId else { return }
        let expectedGeneration = generation
        let requested = Set(accountIds.filter { $0 != observerAccountId })
        knownDirectPeers.formUnion(requested)
        guard transportConnected, !requested.isEmpty else { return }
        for chunk in requested.sorted().chunked(maximumCount: 200) {
            do {
                let response = try await api.queryPresence(accountIds: chunk, token: token)
                guard generation == expectedGeneration,
                      enabled,
                      self.token == token,
                      self.observerAccountId == observerAccountId
                else { return }
                let returned = Set(response.presences.map(\.accountId))
                let hidden = chunk.filter { !returned.contains($0) }
                hiddenAccountIds.subtract(returned)
                hiddenAccountIds.formUnion(hidden)
                var changed = false
                var snapshots: [LocalPresenceSnapshot] = []
                for presence in response.presences {
                    if let accepted = accept(presence) {
                        changed = true
                        if let snapshot = accepted.snapshot { snapshots.append(snapshot) }
                    }
                }
                if !snapshots.isEmpty {
                    try? await store?.savePresenceSnapshots(snapshots)
                    guard generation == expectedGeneration,
                          self.token == token,
                          self.observerAccountId == observerAccountId
                    else { return }
                }
                if !hidden.isEmpty {
                    for accountId in hidden {
                        changed = values.removeValue(forKey: accountId) != nil || changed
                    }
                    try? await store?.removePresenceCache(
                        observerAccountId: observerAccountId,
                        subjectAccountIds: hidden
                    )
                    guard generation == expectedGeneration,
                          self.token == token,
                          self.observerAccountId == observerAccountId
                    else { return }
                }
                if changed { presenceRevision &+= 1 }
            } catch {
                guard generation == expectedGeneration,
                      self.token == token,
                      self.observerAccountId == observerAccountId
                else { return }
                if case .unsupportedServer = cloudFailureDisposition(error) {
                    await stopLocalTyping()
                    guard generation == expectedGeneration,
                          self.token == token,
                          self.observerAccountId == observerAccountId
                    else { return }
                    await flushTypingSends()
                    guard generation == expectedGeneration,
                          self.token == token,
                          self.observerAccountId == observerAccountId
                    else { return }
                    self.enabled = false
                    updateAuthoritativeRefreshLoop()
                    clearEphemeral()
                    await socket?.setPresenceActive(false)
                }
            }
        }
    }

    func updateDirectPeers(_ accountIds: [String]) async {
        let expectedGeneration = generation
        let next = Set(accountIds)
        let added = next.subtracting(knownDirectPeers)
        // Cached values can predate this process, so use both the last peer set and the cache as
        // revocation inputs. A closed/removed direct dialog must not leave last-seen data behind.
        let removed = knownDirectPeers.subtracting(next)
            .union(Set(values.keys).subtracting(next))
        knownDirectPeers = next
        if !removed.isEmpty {
            hiddenAccountIds.formUnion(removed)
            var changed = false
            for accountId in removed {
                changed = values.removeValue(forKey: accountId) != nil || changed
            }
            if let observerAccountId, let store {
                try? await store.removePresenceCache(
                    observerAccountId: observerAccountId,
                    subjectAccountIds: Array(removed)
                )
            }
            guard generation == expectedGeneration else { return }
            if changed { presenceRevision &+= 1 }
        }
        if !added.isEmpty { await refresh(accountIds: Array(added)) }
    }

    func handle(_ hint: PresenceUpdateHint) async {
        guard enabled, !hiddenAccountIds.contains(hint.accountId) else { return }
        let expectedGeneration = generation
        guard let accepted = accept(CloudPresence(
            accountId: hint.accountId,
            online: hint.online,
            lastSeenAt: hint.lastSeenAt,
            revision: hint.revision
        )) else { return }
        presenceRevision &+= 1
        if let snapshot = accepted.snapshot {
            try? await store?.savePresenceSnapshots([snapshot])
            guard generation == expectedGeneration else { return }
        }
    }

    func handle(_ hint: PresenceVisibilityHint) async {
        guard enabled else { return }
        let expectedGeneration = generation
        // Visibility notifications are invalidations, not ordered truth: PostgreSQL delivery can
        // reorder an older block/unblock echo around a newer commit. Fail closed immediately, then
        // let the authenticated query decide whether the peer is currently visible.
        hiddenAccountIds.insert(hint.accountId)
        values.removeValue(forKey: hint.accountId)
        var typingChanged = false
        for dialogId in Array(typingLeasesByDialog.keys) {
            guard let current = typingLeasesByDialog[dialogId] else { continue }
            let filtered = current.filter {
                $0.value.actorAccountId != hint.accountId
            }
            if filtered.count != current.count {
                typingChanged = true
                if filtered.isEmpty { typingLeasesByDialog.removeValue(forKey: dialogId) }
                else { typingLeasesByDialog[dialogId] = filtered }
            }
        }
        if typingChanged { typingRevision &+= 1 }
        let expectedObserverAccountId = observerAccountId
        if let expectedObserverAccountId {
            try? await store?.removePresenceCache(
                observerAccountId: expectedObserverAccountId,
                subjectAccountIds: [hint.accountId]
            )
            guard generation == expectedGeneration,
                  observerAccountId == expectedObserverAccountId
            else { return }
        }
        guard generation == expectedGeneration else { return }
        presenceRevision &+= 1
        await refresh(accountIds: [hint.accountId])
    }

    func handle(_ hint: TypingUpdateHint) {
        guard enabled, foregroundActive, transportConnected,
              hint.expiresInMs > 0, hint.expiresInMs <= 30_000,
              !hiddenAccountIds.contains(hint.actorAccountId) else { return }
        var leases = typingLeasesByDialog[hint.dialogId] ?? [:]
        if hint.active {
            leases[hint.typingSessionId] = TypingLease(
                actorAccountId: hint.actorAccountId,
                expiresAt: Date(timeIntervalSinceNow: TimeInterval(hint.expiresInMs) / 1_000)
            )
        } else {
            leases.removeValue(forKey: hint.typingSessionId)
        }
        if leases.isEmpty { typingLeasesByDialog.removeValue(forKey: hint.dialogId) }
        else { typingLeasesByDialog[hint.dialogId] = leases }
        typingRevision &+= 1
        scheduleTypingExpiry()
    }

    func typingAccountIds(dialogId: String) -> [String] {
        _ = typingRevision
        let now = Date()
        return Array(Set((typingLeasesByDialog[dialogId] ?? [:]).values.compactMap {
            $0.expiresAt > now ? $0.actorAccountId : nil
        })).sorted()
    }

    func presence(accountId: String) -> PeerPresence? {
        _ = presenceRevision
        guard var value = values[accountId] else { return nil }
        if !transportConnected { value.online = false }
        return value
    }

    func userEditedDraft(dialogId: String, text: String, focused: Bool) {
        guard enabled, foregroundActive, transportConnected, focused,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stopLocalTypingSoon(dialogId: dialogId)
            return
        }
        let now = Date()
        let shouldSend = localTypingDialogId != dialogId
            || lastTypingSentAt == nil
            || now.timeIntervalSince(lastTypingSentAt!) >= 3
        if let previous = localTypingDialogId, previous != dialogId {
            stopLocalTypingSoon(dialogId: previous)
        }
        localTypingDialogId = dialogId
        if shouldSend {
            lastTypingSentAt = now
            enqueueTypingSend(dialogId: dialogId, active: true)
        }
        typingIdleTask?.cancel()
        typingIdleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await self?.stopLocalTyping(dialogId: dialogId)
        }
    }

    func composerFocusChanged(dialogId: String, focused: Bool, text: String) {
        // Focus alone is not user input. In particular, focusing a restored or remotely synced
        // non-empty draft must not announce typing.
        if !focused { stopLocalTypingSoon(dialogId: dialogId) }
    }

    func dialogDidChange(from dialogId: String) {
        stopLocalTypingSoon(dialogId: dialogId)
    }

    func stopLocalTyping(dialogId: String? = nil) async {
        guard let current = localTypingDialogId,
              dialogId == nil || dialogId == current else { return }
        typingIdleTask?.cancel()
        typingIdleTask = nil
        localTypingDialogId = nil
        lastTypingSentAt = nil
        await enqueueTypingSend(dialogId: current, active: false).value
    }

    private func stopLocalTypingSoon(dialogId: String) {
        guard localTypingDialogId == dialogId else { return }
        typingIdleTask?.cancel()
        typingIdleTask = nil
        localTypingDialogId = nil
        lastTypingSentAt = nil
        enqueueTypingSend(dialogId: dialogId, active: false)
    }

    func reset(
        clearCacheValues: Bool = false,
        invalidatesGeneration: Bool = true,
        preserveSocket: Bool = false
    ) async {
        if invalidatesGeneration { generation &+= 1 }
        let attachedSocket = socket
        let pendingTypingSend = typingSendTail
        let activeTypingDialogId = localTypingDialogId
        typingExpiryTask?.cancel()
        authoritativeRefreshTask?.cancel()
        typingIdleTask?.cancel()
        typingExpiryTask = nil
        authoritativeRefreshTask = nil
        typingIdleTask = nil
        typingSendTail = nil
        localTypingDialogId = nil
        lastTypingSentAt = nil
        if !preserveSocket { socket = nil }
        enabled = false
        if !preserveSocket { transportConnected = false }
        knownDirectPeers.removeAll()
        hiddenAccountIds.removeAll()
        typingLeasesByDialog.removeAll()
        typingRevision &+= 1
        if clearCacheValues {
            values.removeAll()
            presenceRevision &+= 1
            observerAccountId = nil
            token = nil
            store = nil
        }
        // All actor state is cleared before suspension. A newer configure/attach call can now run
        // without an older reset resuming later and erasing the new account's state.
        await pendingTypingSend?.value
        if let activeTypingDialogId {
            await attachedSocket?.sendTyping(dialogId: activeTypingDialogId, active: false)
        }
        if !preserveSocket {
            await attachedSocket?.setPresenceActive(false)
        }
    }

    #if DEBUG
    func enableFixturesForTesting(connected: Bool = true) {
        enabled = true
        foregroundActive = true
        transportConnected = connected
    }

    var localTypingDialogIdForTesting: String? { localTypingDialogId }
    #endif

    private func accept(_ presence: CloudPresence) -> PresenceAcceptance? {
        let current = values[presence.accountId]
        guard presence.revision >= (current?.revision ?? -1) else { return nil }
        let value = PeerPresence(
            accountId: presence.accountId,
            online: transportConnected && presence.online,
            lastSeenAt: presence.lastSeenAt,
            revision: presence.revision
        )
        guard current != value else { return nil }
        values[presence.accountId] = value
        let persistentFieldsChanged = current == nil
            || current?.revision != presence.revision
            || current?.lastSeenAt != presence.lastSeenAt
        let snapshot = persistentFieldsChanged ? observerAccountId.map {
            LocalPresenceSnapshot(
                observerAccountId: $0,
                subjectAccountId: presence.accountId,
                lastSeenAt: presence.lastSeenAt,
                revision: presence.revision
            )
        } : nil
        return PresenceAcceptance(snapshot: snapshot)
    }

    private func refreshKnownPeers() async {
        await refresh(accountIds: Array(knownDirectPeers))
    }

    private func updateAuthoritativeRefreshLoop() {
        authoritativeRefreshTask?.cancel()
        authoritativeRefreshTask = nil
        guard enabled, foregroundActive, transportConnected else { return }
        let expectedGeneration = generation
        let interval = authoritativeRefreshInterval
        authoritativeRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self,
                      self.generation == expectedGeneration,
                      self.enabled,
                      self.foregroundActive,
                      self.transportConnected
                else { return }
                await self.refreshKnownPeers()
            }
        }
    }

    @discardableResult
    private func enqueueTypingSend(dialogId: String, active: Bool) -> Task<Void, Never> {
        let previous = typingSendTail
        let attachedSocket = socket
        let task = Task {
            await previous?.value
            await attachedSocket?.sendTyping(dialogId: dialogId, active: active)
        }
        typingSendTail = task
        return task
    }

    private func flushTypingSends() async {
        await typingSendTail?.value
    }

    private func clearEphemeral() {
        var changedPresence = false
        for accountId in values.keys where values[accountId]?.online == true {
            values[accountId]?.online = false
            changedPresence = true
        }
        if changedPresence { presenceRevision &+= 1 }
        if !typingLeasesByDialog.isEmpty {
            typingLeasesByDialog.removeAll()
            typingRevision &+= 1
        }
        typingExpiryTask?.cancel()
        typingExpiryTask = nil
    }

    private func scheduleTypingExpiry() {
        typingExpiryTask?.cancel()
        guard let next = typingLeasesByDialog.values
            .flatMap({ $0.values.map(\.expiresAt) })
            .min() else { return }
        typingExpiryTask = Task { [weak self] in
            let delay = max(0, next.timeIntervalSinceNow)
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            let now = Date()
            for dialogId in Array(self.typingLeasesByDialog.keys) {
                self.typingLeasesByDialog[dialogId] = self.typingLeasesByDialog[dialogId]?
                    .filter { $0.value.expiresAt > now }
                if self.typingLeasesByDialog[dialogId]?.isEmpty == true {
                    self.typingLeasesByDialog.removeValue(forKey: dialogId)
                }
            }
            self.typingRevision &+= 1
            self.scheduleTypingExpiry()
        }
    }
}

nonisolated enum TojPresenceFormatting {
    static func lastSeen(
        _ raw: String?,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let raw,
              let date = fractionalFormatter.date(from: raw)
                ?? ISO8601DateFormatter().date(from: raw) else {
            return String(localized: "status unavailable")
        }
        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.timeStyle = .short
        time.dateStyle = .none
        let timeText = time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(format: String(localized: "last seen today at %@"), timeText)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(format: String(localized: "last seen yesterday at %@"), timeText)
        }
        let day = DateFormatter()
        day.locale = locale
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.dateStyle = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? .medium : .long
        day.timeStyle = .none
        return String(
            format: String(localized: "last seen %@ at %@"),
            day.string(from: date),
            timeText
        )
    }
}

nonisolated private extension Array {
    func chunked(maximumCount: Int) -> [[Element]] {
        guard maximumCount > 0 else { return [] }
        return stride(from: 0, to: count, by: maximumCount).map {
            Array(self[$0..<Swift.min($0 + maximumCount, count)])
        }
    }
}
