import Foundation

nonisolated struct SyncHint: Codable, Equatable, Sendable {
    let type: String
    let pts: Int64
    let ptsCount: Int64
}

nonisolated struct CallHint: Codable, Equatable, Sendable {
    let type: String
    let callId: String
    let latestEventSeq: Int64
}

nonisolated struct GroupCallSocketHint: Codable, Equatable, Sendable {
    let type: String
    let callId: String
    let stateRevision: Int64
}

nonisolated struct SessionRevokedHint: Codable, Equatable, Sendable {
    let type: String
    let deviceId: String?
    let reason: String?
}

nonisolated struct PresenceUpdateHint: Codable, Equatable, Sendable {
    let type: String
    let accountId: String
    let online: Bool
    let lastSeenAt: String?
    let revision: Int64
}

nonisolated struct PresenceVisibilityHint: Codable, Equatable, Sendable {
    let type: String
    let accountId: String
    let visible: Bool
}

nonisolated struct TypingUpdateHint: Codable, Equatable, Sendable {
    let type: String
    let dialogId: String
    let actorAccountId: String
    let typingSessionId: String
    let active: Bool
    let expiresInMs: Int
}

nonisolated enum CloudSocketEvent: Equatable, Sendable {
    case sync(SyncHint)
    case call(CallHint)
    case groupCall(GroupCallSocketHint)
    case sessionRevoked(SessionRevokedHint)
    case presence(PresenceUpdateHint)
    case presenceVisibility(PresenceVisibilityHint)
    case typing(TypingUpdateHint)
}

actor CloudHintSocket {
    enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
    }

    private let url: URL
    private let token: String
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var runLoop: Task<Void, Never>?
    private var backoff = BackoffPolicy()
    private var presenceActive = false
    private var credentialRevoked = false
    private var revocationDelivered = false
    private(set) var state: State = .disconnected

    private let statesContinuation: AsyncStream<State>.Continuation
    nonisolated let states: AsyncStream<State>
    private let eventsContinuation: AsyncStream<CloudSocketEvent>.Continuation
    nonisolated let events: AsyncStream<CloudSocketEvent>
    private let revocationsContinuation: AsyncStream<SessionRevokedHint>.Continuation
    nonisolated let revocations: AsyncStream<SessionRevokedHint>

    init(url: URL, token: String, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.url = url
        self.token = token
        self.session = session
        (states, statesContinuation) = AsyncStream.makeStream(
            of: State.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        statesContinuation.yield(.disconnected)
        // Sync/presence events carry monotonic revisions or expiring leases. Keeping the newest
        // bounded window preserves recovery while preventing a stalled MainActor consumer from
        // growing memory without limit; revocation uses the separate control stream below.
        (events, eventsContinuation) = AsyncStream.makeStream(
            of: CloudSocketEvent.self,
            bufferingPolicy: .bufferingNewest(512)
        )
        (revocations, revocationsContinuation) = AsyncStream.makeStream(
            of: SessionRevokedHint.self,
            bufferingPolicy: .bufferingNewest(8)
        )
    }

    func start() {
        guard runLoop == nil, !credentialRevoked else { return }
        runLoop = Task { await run() }
    }

    func stop() {
        runLoop?.cancel()
        runLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setState(.disconnected)
    }

    func setPresenceActive(_ active: Bool) async {
        presenceActive = active
        await sendJSON(PresenceActivityMessage(type: "presence_activity", active: active))
    }

    func sendTyping(dialogId: String, active: Bool) async {
        await sendJSON(TypingActivityMessage(
            type: "typing_activity",
            dialogId: dialogId,
            active: active
        ))
    }

    private func run() async {
        while !Task.isCancelled {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let task = session.webSocketTask(with: request)
            self.task = task
            setState(.connecting)
            task.resume()
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [weak self, task] in
                        guard let self else { return }
                        try await self.receiveLoop(on: task)
                    }
                    group.addTask { [weak self, task] in
                        guard let self else { return }
                        try await self.heartbeatLoop(on: task)
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch {
                // Reconnect below.
            }
            if let hint = Self.revocationHint(
                statusCode: (task.response as? HTTPURLResponse)?.statusCode,
                closeCode: task.closeCode.rawValue
            ) {
                credentialRevoked = true
                if !revocationDelivered {
                    revocationDelivered = true
                    revocationsContinuation.yield(hint)
                }
            }
            task.cancel(with: .abnormalClosure, reason: nil)
            setState(.disconnected)
            guard !Task.isCancelled, !credentialRevoked else { return }
            let delay = backoff.nextDelay()
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func receiveLoop(on task: URLSessionWebSocketTask) async throws {
        setState(.connected)
        if presenceActive {
            try await sendJSON(
                PresenceActivityMessage(type: "presence_activity", active: true),
                on: task
            )
        }
        while !Task.isCancelled {
            let message = try await task.receive()
            backoff.reset()
            guard let event = Self.event(from: message) else { continue }
            if case .sessionRevoked(let hint) = event {
                // Credential invalidation is a sticky control signal, never part of the bounded
                // high-rate sync/presence queue.
                credentialRevoked = true
                revocationDelivered = true
                revocationsContinuation.yield(hint)
                throw CloudHintSocketError.credentialRevoked
            } else {
                guard enqueue(event) else {
                    // Presence revisions are per peer, not part of the global sync cursor. Once
                    // any event is evicted, reconnect so the app runs both difference sync and a
                    // full known-peer presence refresh instead of displaying stale online state.
                    throw CloudHintSocketError.eventBufferOverflow
                }
            }
        }
    }

    @discardableResult
    private func enqueue(_ event: CloudSocketEvent) -> Bool {
        switch eventsContinuation.yield(event) {
        case .enqueued:
            return true
        case .dropped(_), .terminated:
            return false
        @unknown default:
            return false
        }
    }

    @discardableResult
    func enqueueForTesting(_ event: CloudSocketEvent) -> Bool {
        enqueue(event)
    }

    private func heartbeatLoop(on task: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(20))
            try Task.checkCancellation()
            if presenceActive {
                try await sendJSON(PresenceHeartbeatMessage(type: "presence_heartbeat"), on: task)
            }
            try await Self.awaitPong(on: task)
        }
    }

    private nonisolated static func awaitPong(on task: URLSessionWebSocketTask) async throws {
        let stream = AsyncThrowingStream<Void, Error> { continuation in
            task.sendPing { error in
                if let error { continuation.finish(throwing: error) }
                else { continuation.finish() }
            }
            Task {
                do {
                    try await Task.sleep(for: .seconds(10))
                    continuation.finish(throwing: URLError(.timedOut))
                } catch {
                    // The stream already completed or its parent was cancelled.
                }
            }
        }
        for try await _ in stream {}
    }

    private func setState(_ next: State) {
        guard state != next else { return }
        state = next
        statesContinuation.yield(next)
    }

    private func sendJSON<Value: Encodable & Sendable>(_ value: Value) async {
        guard state == .connected, let task else { return }
        try? await sendJSON(value, on: task)
    }

    private func sendJSON<Value: Encodable & Sendable>(
        _ value: Value,
        on task: URLSessionWebSocketTask
    ) async throws {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await task.send(.string(text))
    }

    nonisolated static func event(from message: URLSessionWebSocketTask.Message) -> CloudSocketEvent? {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        @unknown default: return nil
        }
        guard let discriminator = try? JSONDecoder().decode(SocketDiscriminator.self, from: data) else {
            return nil
        }
        let decoder = JSONDecoder()
        switch discriminator.type {
        case "sync_hint":
            return (try? decoder.decode(SyncHint.self, from: data)).map(CloudSocketEvent.sync)
        case "call_hint":
            return (try? decoder.decode(CallHint.self, from: data)).map(CloudSocketEvent.call)
        case "group_call_hint":
            return (try? decoder.decode(GroupCallSocketHint.self, from: data))
                .map(CloudSocketEvent.groupCall)
        case "session_revoked":
            return (try? decoder.decode(SessionRevokedHint.self, from: data)).map(CloudSocketEvent.sessionRevoked)
        case "presence_update":
            return (try? decoder.decode(PresenceUpdateHint.self, from: data)).map(CloudSocketEvent.presence)
        case "presence_visibility":
            return (try? decoder.decode(PresenceVisibilityHint.self, from: data))
                .map(CloudSocketEvent.presenceVisibility)
        case "typing_update":
            return (try? decoder.decode(TypingUpdateHint.self, from: data)).map(CloudSocketEvent.typing)
        default:
            return nil
        }
    }

    nonisolated static func revocationHint(
        statusCode: Int?,
        closeCode: Int
    ) -> SessionRevokedHint? {
        if statusCode == 401 {
            return SessionRevokedHint(type: "session_revoked", deviceId: nil, reason: "unauthorized")
        }
        switch closeCode {
        case 4001:
            return SessionRevokedHint(type: "session_revoked", deviceId: nil, reason: "device_revoked")
        case 4002:
            return SessionRevokedHint(type: "session_revoked", deviceId: nil, reason: "account_deleted")
        default:
            return nil
        }
    }
}

private nonisolated enum CloudHintSocketError: Error {
    case credentialRevoked
    case eventBufferOverflow
}

private nonisolated struct SocketDiscriminator: Codable, Sendable {
    let type: String
}

private nonisolated struct PresenceActivityMessage: Codable, Sendable {
    let type: String
    let active: Bool
}

private nonisolated struct PresenceHeartbeatMessage: Codable, Sendable {
    let type: String
}

private nonisolated struct TypingActivityMessage: Codable, Sendable {
    let type: String
    let dialogId: String
    let active: Bool
}
