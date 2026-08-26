import XCTest
import GRDB
import Security
@testable import Toj

final class CloudLocalStoreTests: XCTestCase {
    func testPresenceCacheIsEncryptedAndIsolatedByObserverAccount() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try CloudLocalStore(
            path: directory.appending(path: "presence.sqlite").path,
            key: Data("presence-cache-test-key".utf8)
        )
        try await store.savePresenceSnapshot(LocalPresenceSnapshot(
            observerAccountId: "observer-a", subjectAccountId: "peer",
            lastSeenAt: "2026-08-11T09:30:00.000Z", revision: 4
        ))
        try await store.savePresenceSnapshot(LocalPresenceSnapshot(
            observerAccountId: "observer-b", subjectAccountId: "peer",
            lastSeenAt: "2026-08-11T10:00:00.000Z", revision: 9
        ))
        let observerA = try await store.loadPresenceCache(observerAccountId: "observer-a")
        XCTAssertEqual(observerA, [
            LocalPresenceSnapshot(
                observerAccountId: "observer-a", subjectAccountId: "peer",
                lastSeenAt: "2026-08-11T09:30:00.000Z", revision: 4
            ),
        ])
        try await store.removePresenceCache(
            observerAccountId: "observer-a", subjectAccountIds: ["peer"]
        )
        let observerAAfterRemoval = try await store.loadPresenceCache(observerAccountId: "observer-a")
        let observerB = try await store.loadPresenceCache(observerAccountId: "observer-b")
        XCTAssertTrue(observerAAfterRemoval.isEmpty)
        XCTAssertEqual(observerB.first?.revision, 9)
    }

    func testAppLockTimeoutBoundaries() {
        XCTAssertTrue(AppLockTimeout.immediate.shouldLock(after: 0))
        XCTAssertFalse(AppLockTimeout.oneMinute.shouldLock(after: 59.999))
        XCTAssertTrue(AppLockTimeout.oneMinute.shouldLock(after: 60))
        XCTAssertFalse(AppLockTimeout.fiveMinutes.shouldLock(after: 299.999))
        XCTAssertTrue(AppLockTimeout.fiveMinutes.shouldLock(after: 300))
        XCTAssertFalse(AppLockTimeout.oneHour.shouldLock(after: 3_599.999))
        XCTAssertTrue(AppLockTimeout.oneHour.shouldLock(after: 3_600))
    }

    func testCloudSessionDecodesLegacyAndV2Credentials() throws {
        let legacy = try JSONDecoder().decode(
            CloudSession.self,
            from: Data(#"{"accountId":"a","deviceId":"d","token":"legacy"}"#.utf8)
        )
        XCTAssertEqual(legacy.token, "legacy")
        XCTAssertEqual(legacy.tokenVersion, 1)
        XCTAssertNil(legacy.refreshToken)

        let v2 = try JSONDecoder().decode(
            CloudSession.self,
            from: Data(#"{"accountId":"a","deviceId":"d","accessToken":"access","refreshToken":"refresh","accessTokenExpiresAt":"2026-08-11T00:15:00.000Z","sessionExpiresAt":"2027-02-07T00:00:00.000Z","tokenVersion":2}"#.utf8)
        )
        XCTAssertEqual(v2.token, "access")
        XCTAssertEqual(v2.refreshToken, "refresh")
        XCTAssertEqual(v2.tokenVersion, 2)
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(v2)) as? [String: Any]
        )
        XCTAssertEqual(encoded["accessToken"] as? String, "access")
        XCTAssertNil(encoded["token"])
    }

    func testCredentialInstallDoesNotRebindTokensAcrossAccountsOrDevices() async throws {
        let coordinator = SessionCredentialCoordinator()
        let config = CloudConfig(
            baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))
        )
        let store = TokenStore(service: "com.toj.credential-account-fence.\(UUID().uuidString)")

        let firstAccount = storedSession(accountId: "account-a", deviceId: "device-a", suffix: 1)
        await coordinator.install(firstAccount, config: config, tokenStore: store)
        let firstAuthorization = await coordinator.authorizationToken(
            matching: firstAccount.session.token
        )
        XCTAssertEqual(firstAuthorization, firstAccount.session.token)

        let secondAccount = storedSession(accountId: "account-b", deviceId: "device-b", suffix: 2)
        await coordinator.install(secondAccount, config: config, tokenStore: store)
        let reboundAcrossAccounts = await coordinator.authorizationToken(
            matching: firstAccount.session.token
        )
        XCTAssertNil(reboundAcrossAccounts)
        let secondAuthorization = await coordinator.authorizationToken(
            matching: secondAccount.session.token
        )
        XCTAssertEqual(secondAuthorization, secondAccount.session.token)

        let rotatedSecondAccount = StoredCloudSession(
            session: CloudSession(
                accountId: secondAccount.session.accountId,
                deviceId: secondAccount.session.deviceId,
                token: "access-rotated",
                refreshToken: "refresh-rotated",
                accessTokenExpiresAt: "2099-01-01T00:15:00.000Z",
                sessionExpiresAt: "2099-06-01T00:00:00.000Z",
                tokenVersion: 2
            ),
            phone: secondAccount.phone,
            displayName: secondAccount.displayName
        )
        await coordinator.install(rotatedSecondAccount, config: config, tokenStore: store)
        let reboundWithinDevice = await coordinator.authorizationToken(
            matching: secondAccount.session.token
        )
        XCTAssertNil(reboundWithinDevice)
        await coordinator.handleAuthenticationFailure(
            code: "device_revoked",
            matching: secondAccount.session.token
        )
        let replacementSurvivedLateFailure = await coordinator.authorizationToken(
            matching: rotatedSecondAccount.session.token
        )
        XCTAssertEqual(replacementSurvivedLateFailure, rotatedSecondAccount.session.token)

        let replacementDevice = storedSession(accountId: "account-b", deviceId: "device-c", suffix: 3)
        await coordinator.install(replacementDevice, config: config, tokenStore: store)
        let reboundAcrossDevices = await coordinator.authorizationToken(
            matching: rotatedSecondAccount.session.token
        )
        XCTAssertNil(reboundAcrossDevices)
        try await store.clear()
    }

    func testCredentialRefreshIsSingleFlightAndPersistsTheRotatedSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let networkSession = URLSession(configuration: configuration)
        let counter = LockedCounter()
        CloudAPIMockURLProtocol.deferHandlerExecution = true
        CloudAPIMockURLProtocol.handler = { request in
            counter.increment()
            Thread.sleep(forTimeInterval: 0.05)
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )),
                Data(#"{"accountId":"account","deviceId":"device","accessToken":"next-access","refreshToken":"next-refresh","accessTokenExpiresAt":"2099-01-01T00:15:00.000Z","sessionExpiresAt":"2099-06-01T00:00:00.000Z","tokenVersion":2}"#.utf8)
            )
        }
        defer {
            CloudAPIMockURLProtocol.handler = nil
            CloudAPIMockURLProtocol.deferHandlerExecution = false
        }
        let store = TokenStore(service: "com.toj.refresh-single-flight.\(UUID().uuidString)")
        let saved = StoredCloudSession(
            session: CloudSession(
                accountId: "account", deviceId: "device", token: "old-access",
                refreshToken: "old-refresh", accessTokenExpiresAt: "2020-01-01T00:00:00.000Z",
                sessionExpiresAt: "2099-06-01T00:00:00.000Z", tokenVersion: 2
            ),
            phone: "+16505550100",
            displayName: "Alice"
        )
        try await store.save(saved)
        let coordinator = SessionCredentialCoordinator(networkSession: networkSession)
        await coordinator.install(
            saved,
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            tokenStore: store
        )

        let tokens = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await coordinator.refreshIfNeeded(matching: "old-access", force: true)
                }
            }
            var values: [String?] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(Set(tokens.compactMap { $0 }), ["next-access"])
        let persisted = try await store.load()
        XCTAssertEqual(persisted?.session.refreshToken, "next-refresh")
        try await store.clear()
    }

    func testLogoutFencePreventsLateRefreshFromResurrectingKeychainSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let gate = LockedGate()
        CloudAPIMockURLProtocol.deferHandlerExecution = true
        CloudAPIMockURLProtocol.handler = { request in
            gate.signalStarted()
            gate.waitForRelease()
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )),
                Data(#"{"accountId":"account","deviceId":"device","accessToken":"late-access","refreshToken":"late-refresh","accessTokenExpiresAt":"2099-01-01T00:15:00.000Z","sessionExpiresAt":"2099-06-01T00:00:00.000Z","tokenVersion":2}"#.utf8)
            )
        }
        defer {
            gate.release()
            CloudAPIMockURLProtocol.handler = nil
            CloudAPIMockURLProtocol.deferHandlerExecution = false
        }
        let store = TokenStore(service: "com.toj.refresh-logout-race.\(UUID().uuidString)")
        let saved = StoredCloudSession(
            session: CloudSession(
                accountId: "account", deviceId: "device", token: "old-access",
                refreshToken: "old-refresh", accessTokenExpiresAt: "2020-01-01T00:00:00.000Z",
                sessionExpiresAt: "2099-06-01T00:00:00.000Z", tokenVersion: 2
            ),
            phone: "+16505550101",
            displayName: "Alice"
        )
        try await store.save(saved)
        let coordinator = SessionCredentialCoordinator(networkSession: URLSession(configuration: configuration))
        await coordinator.install(
            saved,
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            tokenStore: store
        )
        let refresh = Task {
            try await coordinator.refreshIfNeeded(matching: "old-access", force: true)
        }
        XCTAssertTrue(gate.waitUntilStarted())
        await coordinator.clear()
        try await store.clear()
        gate.release()
        do {
            _ = try await refresh.value
            XCTFail("A refresh crossing logout must not succeed")
        } catch is CancellationError {
            // Expected generation fence.
        } catch let error as URLError where error.code == .cancelled {
            // URLSession surfaces cancellation this way when the request was already in flight.
        }
        let resurrected = try await store.load()
        XCTAssertNil(resurrected)
    }

    func testAccessTokenExpiryRefreshesAndRetriesTheRequestExactlyOnce() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let originalRequests = LockedCounter()
        let refreshRequests = LockedCounter()
        CloudAPIMockURLProtocol.handler = { request in
            let response: (Int, Data)
            if request.url?.path == "/cloud/v1/session/refresh" {
                refreshRequests.increment()
                response = (
                    200,
                    Data(#"{"accountId":"account","deviceId":"device","accessToken":"next-access","refreshToken":"next-refresh","accessTokenExpiresAt":"2099-01-01T00:15:00.000Z","sessionExpiresAt":"2099-06-01T00:00:00.000Z","tokenVersion":2}"#.utf8)
                )
            } else {
                originalRequests.increment()
                response = (401, Data(#"{"error":"expired","code":"access_token_expired"}"#.utf8))
            }
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: response.0, httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )),
                response.1
            )
        }
        defer { CloudAPIMockURLProtocol.handler = nil }

        let store = TokenStore(service: "com.toj.refresh-exact-retry.\(UUID().uuidString)")
        let saved = StoredCloudSession(
            session: CloudSession(
                accountId: "account", deviceId: "device", token: "old-access",
                refreshToken: "old-refresh", accessTokenExpiresAt: "2020-01-01T00:00:00.000Z",
                sessionExpiresAt: "2099-06-01T00:00:00.000Z", tokenVersion: 2
            ),
            phone: "+16505550102",
            displayName: "Alice"
        )
        try await store.save(saved)
        let coordinator = SessionCredentialCoordinator(networkSession: URLSession(configuration: configuration))
        await coordinator.install(
            saved,
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            tokenStore: store
        )
        let api = CloudAPI(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            session: URLSession(configuration: configuration),
            credentialCoordinator: coordinator
        )

        do {
            _ = try await api.getState(token: "old-access")
            XCTFail("The retried 401 must be returned to the caller")
        } catch let error as CloudAPIError {
            XCTAssertEqual(error.code, "access_token_expired")
        }
        XCTAssertEqual(originalRequests.value, 2)
        XCTAssertEqual(refreshRequests.value, 1)
        try await store.clear()
    }

    func testCapabilitiesEndpointIsPublicAndDecodesContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let api = CloudAPI(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            session: URLSession(configuration: configuration)
        )
        CloudAPIMockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/cloud/v1/capabilities")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )),
                Data("{\"api_version\":2,\"capabilities\":[\"media_uploads\",\"voice_notes\"]}".utf8)
            )
        }
        defer { CloudAPIMockURLProtocol.handler = nil }

        let response = try await api.capabilities()
        XCTAssertEqual(response.apiVersion, 2)
        XCTAssertEqual(response.capabilities, ["media_uploads", "voice_notes"])
    }

    func testDialogPreferencesRequestIsAPatchAndDecodesCanonicalResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let api = CloudAPI(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            session: URLSession(configuration: configuration)
        )
        let dialogId = "11111111-1111-4111-8111-111111111111"
        let mutationId = "22222222-2222-4222-8222-222222222222"
        CloudAPIMockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/cloud/v1/dialogs/\(dialogId)/preferences")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            let body = try XCTUnwrap(CloudAPIMockURLProtocol.bodyData(from: request))
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["clientMutationId"] as? String, mutationId)
            XCTAssertEqual(json["muted"] as? Bool, true)
            XCTAssertNil(json["pinned"])
            XCTAssertNil(json["archived"])
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )),
                Data("""
                {"preferences":{"dialogId":"\(dialogId)","pinned":true,
                "pinnedAt":"2026-07-25T10:00:00.000Z","muted":true,"archived":false,
                "updatedAt":"2026-07-25T10:00:01.000Z"},"pts":17,"duplicate":false}
                """.utf8)
            )
        }
        defer { CloudAPIMockURLProtocol.handler = nil }

        let response = try await api.updateDialogPreferences(
            dialogId: dialogId,
            clientMutationId: mutationId,
            muted: true,
            token: "token"
        )
        XCTAssertEqual(response.pts, 17)
        XCTAssertTrue(response.preferences.pinned)
        XCTAssertTrue(response.preferences.muted)
        XCTAssertFalse(response.preferences.archived)
    }

    func testDialogPreferenceOutboxSurvivesReopenAndProtectsNewerIntentFromStaleEvent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cloud.sqlite").path
        let key = Data("dialog-preference-outbox-key".utf8)
        let accountId = "account-preferences"
        let dialogId = "dialog-preferences"

        let firstMutation: PendingDialogPreferenceMutation
        do {
            let store = try CloudLocalStore(path: path, key: key)
            try await store.upsertDialog(
                dialogId: dialogId,
                title: "Preferences",
                updatedAt: "2026-07-25T09:00:00.000Z"
            )
            let queued = try await store.queueDialogPreference(
                accountId: accountId,
                dialogId: dialogId,
                field: .pinned,
                desiredValue: true
            )
            firstMutation = try XCTUnwrap(queued)
            let optimisticDialog = try await store.dialogs(accountId: accountId).first
            XCTAssertTrue(try XCTUnwrap(optimisticDialog).isPinned)
        }

        let reopened = try CloudLocalStore(path: path, key: key)
        let reopenedPending = try await reopened.pendingDialogPreferencesReady(
            accountId: accountId
        )
        XCTAssertEqual(
            reopenedPending.map(\.clientMutationId),
            [firstMutation.clientMutationId]
        )
        let accepted = CloudDialogPreferences(
            dialogId: dialogId,
            pinned: true,
            pinnedAt: "2026-07-25T10:00:00.000Z",
            muted: false,
            archived: false,
            updatedAt: "2026-07-25T10:00:00.000Z"
        )
        try await reopened.acknowledgeDialogPreference(
            clientMutationId: firstMutation.clientMutationId,
            pts: 7,
            preferences: accepted,
            accountId: accountId
        )
        let newerQueued = try await reopened.queueDialogPreference(
            accountId: accountId,
            dialogId: dialogId,
            field: .pinned
        )
        let newerMutation = try XCTUnwrap(newerQueued)
        XCTAssertFalse(newerMutation.desiredValue)

        try await reopened.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: .init(pts: 7),
                updates: [
                    CloudUpdate(
                        pts: 7,
                        ptsCount: 1,
                        type: "dialog.preferences_updated",
                        dialogId: dialogId,
                        dialogTitle: nil,
                        message: nil,
                        readerAccountId: nil,
                        maxReadMsgId: nil,
                        preferences: accepted,
                        clientMutationId: firstMutation.clientMutationId,
                        changedFields: ["pinned"]
                    )
                ],
                hasMore: false
            ),
            accountId: accountId
        )
        let afterStaleEvent = try await reopened.dialogs(accountId: accountId).first
        XCTAssertFalse(try XCTUnwrap(afterStaleEvent).isPinned)
        let pendingAfterStaleEvent = try await reopened.pendingDialogPreferencesReady(
            accountId: accountId
        )
        XCTAssertEqual(
            pendingAfterStaleEvent.map(\.clientMutationId),
            [newerMutation.clientMutationId]
        )

        let final = CloudDialogPreferences(
            dialogId: dialogId,
            pinned: false,
            pinnedAt: nil,
            muted: false,
            archived: false,
            updatedAt: "2026-07-25T10:00:01.000Z"
        )
        try await reopened.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: .init(pts: 8),
                updates: [
                    CloudUpdate(
                        pts: 8,
                        ptsCount: 1,
                        type: "dialog.preferences_updated",
                        dialogId: dialogId,
                        dialogTitle: nil,
                        message: nil,
                        readerAccountId: nil,
                        maxReadMsgId: nil,
                        preferences: final,
                        clientMutationId: newerMutation.clientMutationId,
                        changedFields: ["pinned"]
                    )
                ],
                hasMore: false
            ),
            accountId: accountId
        )
        let pendingAfterMatchingEvent = try await reopened.pendingDialogPreferencesReady(
            accountId: accountId
        )
        XCTAssertTrue(pendingAfterMatchingEvent.isEmpty)
        let redundantUnpin = try await reopened.queueDialogPreference(
            accountId: accountId,
            dialogId: dialogId,
            field: .pinned,
            desiredValue: false
        )
        XCTAssertNil(redundantUnpin)

        let archived = CloudDialogPreferences(
            dialogId: dialogId,
            pinned: false,
            pinnedAt: nil,
            muted: false,
            archived: true,
            updatedAt: "2026-07-25T10:00:02.000Z"
        )
        let archivedQueued = try await reopened.queueDialogPreference(
            accountId: accountId,
            dialogId: dialogId,
            field: .archived,
            desiredValue: true
        )
        let archivedMutation = try XCTUnwrap(archivedQueued)
        try await reopened.acknowledgeDialogPreference(
            clientMutationId: archivedMutation.clientMutationId,
            pts: 10,
            preferences: archived,
            accountId: accountId
        )
        try await reopened.beginBootstrap(
            accountId: accountId,
            token: "preferences-bootstrap-10",
            snapshotPts: 10,
            mode: .replacement
        )
        try await reopened.applyBootstrapPage(
            BootstrapDialogsPage(
                token: "preferences-bootstrap-10",
                state: .init(pts: 10),
                dialogs: [
                    BootstrapDialog(
                        dialogId: dialogId,
                        type: "direct",
                        title: "Preferences",
                        lastMsgId: 0,
                        updatedAt: archived.updatedAt,
                        preferences: archived,
                        members: [],
                        messages: []
                    )
                ],
                nextCursor: nil,
                hasMore: false
            )
        )
        try await reopened.finishBootstrap(accountId: accountId, pts: 10)
        let redundantArchive = try await reopened.queueDialogPreference(
            accountId: accountId,
            dialogId: dialogId,
            field: .archived,
            desiredValue: true
        )
        XCTAssertNil(
            redundantArchive,
            "A covering bootstrap cursor should clear its acknowledged mutation"
        )

        let unarchiveQueued = try await reopened.queueDialogPreference(
            accountId: accountId,
            dialogId: dialogId,
            field: .archived,
            desiredValue: false
        )
        let unarchiveMutation = try XCTUnwrap(unarchiveQueued)
        let unarchived = CloudDialogPreferences(
            dialogId: dialogId,
            pinned: false,
            pinnedAt: nil,
            muted: false,
            archived: false,
            updatedAt: "2026-07-25T10:00:04.000Z"
        )
        try await reopened.acknowledgeDialogPreference(
            clientMutationId: unarchiveMutation.clientMutationId,
            pts: 12,
            preferences: unarchived,
            accountId: accountId
        )
        try await reopened.beginBootstrap(
            accountId: accountId,
            token: "preferences-bootstrap-11",
            snapshotPts: 11,
            mode: .replacement
        )
        try await reopened.applyBootstrapPage(
            BootstrapDialogsPage(
                token: "preferences-bootstrap-11",
                state: .init(pts: 11),
                dialogs: [
                    BootstrapDialog(
                        dialogId: dialogId,
                        type: "direct",
                        title: "Preferences",
                        lastMsgId: 0,
                        updatedAt: archived.updatedAt,
                        preferences: archived,
                        members: [],
                        messages: []
                    )
                ],
                nextCursor: nil,
                hasMore: false
            )
        )
        try await reopened.finishBootstrap(accountId: accountId, pts: 11)
        let effectiveAfterOlderBootstrap = try await reopened.dialogs(
            accountId: accountId
        ).first
        XCTAssertFalse(try XCTUnwrap(effectiveAfterOlderBootstrap).isArchived)
        let retainedUnarchive = try await reopened.queueDialogPreference(
            accountId: accountId,
            dialogId: dialogId,
            field: .archived,
            desiredValue: false
        )
        XCTAssertEqual(
            retainedUnarchive?.clientMutationId,
            unarchiveMutation.clientMutationId,
            "A snapshot before acknowledged pts must preserve the newer optimistic intent"
        )
    }

    func testRecentOptimisticPinsSortFirstAndArchiveDoesNotDiscardPin() async throws {
        let store = try makeStore()
        let accountId = "account-order"
        try await store.upsertDialog(
            dialogId: "dialog-a",
            title: "A",
            updatedAt: "2026-07-25T10:00:03.000Z"
        )
        try await store.upsertDialog(
            dialogId: "dialog-b",
            title: "B",
            updatedAt: "2026-07-25T10:00:02.000Z"
        )
        _ = try await store.queueDialogPreference(
            accountId: accountId,
            dialogId: "dialog-a",
            field: .pinned,
            desiredValue: true
        )
        try await Task.sleep(for: .milliseconds(2))
        _ = try await store.queueDialogPreference(
            accountId: accountId,
            dialogId: "dialog-b",
            field: .pinned,
            desiredValue: true
        )
        _ = try await store.queueDialogPreference(
            accountId: accountId,
            dialogId: "dialog-b",
            field: .archived,
            desiredValue: true
        )

        let dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(dialogs.map(\.dialogId), ["dialog-b", "dialog-a"])
        XCTAssertEqual(dialogs.map(\.isPinned), [true, true])
        XCTAssertTrue(try XCTUnwrap(
            dialogs.first(where: { $0.dialogId == "dialog-b" })
        ).isArchived)
    }

    func testDelayedPreferenceResponseCannotRegressANewerDifferenceSnapshot() async throws {
        let store = try makeStore()
        let accountId = "account-delayed-response"
        let dialogId = "dialog-delayed-response"
        try await store.upsertDialog(
            dialogId: dialogId,
            title: "Delayed response",
            updatedAt: "2026-07-25T10:00:00.000Z"
        )
        let queuedMutation = try await store.queueDialogPreference(
            accountId: accountId,
            dialogId: dialogId,
            field: .muted,
            desiredValue: true
        )
        let mutation = try XCTUnwrap(queuedMutation)
        let accepted = CloudDialogPreferences(
            dialogId: dialogId,
            pinned: false,
            pinnedAt: nil,
            muted: true,
            archived: false,
            updatedAt: "2026-07-25T10:00:01.000Z"
        )
        let newer = CloudDialogPreferences(
            dialogId: dialogId,
            pinned: true,
            pinnedAt: "2026-07-25T10:00:02.000Z",
            muted: true,
            archived: false,
            updatedAt: "2026-07-25T10:00:02.000Z"
        )
        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: .init(pts: 12),
                updates: [
                    CloudUpdate(
                        pts: 11,
                        ptsCount: 1,
                        type: "dialog.preferences_updated",
                        dialogId: dialogId,
                        dialogTitle: nil,
                        message: nil,
                        readerAccountId: nil,
                        maxReadMsgId: nil,
                        preferences: accepted,
                        clientMutationId: mutation.clientMutationId,
                        changedFields: ["muted"]
                    ),
                    CloudUpdate(
                        pts: 12,
                        ptsCount: 1,
                        type: "dialog.preferences_updated",
                        dialogId: dialogId,
                        dialogTitle: nil,
                        message: nil,
                        readerAccountId: nil,
                        maxReadMsgId: nil,
                        preferences: newer,
                        clientMutationId: UUID().uuidString.lowercased(),
                        changedFields: ["pinned"]
                    ),
                ],
                hasMore: false
            ),
            accountId: accountId
        )

        // Simulate the pts=11 HTTP response arriving after both ordered events were committed.
        try await store.acknowledgeDialogPreference(
            clientMutationId: mutation.clientMutationId,
            pts: 11,
            preferences: accepted,
            accountId: accountId
        )
        let storedDialog = try await store.dialogs(accountId: accountId).first
        let dialog = try XCTUnwrap(storedDialog)
        XCTAssertTrue(dialog.isPinned)
        XCTAssertTrue(dialog.isMuted)
        let pending = try await store.pendingDialogPreferencesReady(accountId: accountId)
        XCTAssertTrue(pending.isEmpty)
    }

    func testBootstrapCursorCoversDelayedPreferenceAcknowledgementBeforeRemoteUpdate() async throws {
        let store = try makeStore()
        let accountId = "account-bootstrap-before-ack"
        let dialogId = "dialog-bootstrap-before-ack"
        try await store.upsertDialog(
            dialogId: dialogId,
            title: "Bootstrap ordering",
            updatedAt: "2026-07-25T10:00:00.000Z"
        )
        let queuedMutation = try await store.queueDialogPreference(
            accountId: accountId,
            dialogId: dialogId,
            field: .archived,
            desiredValue: true
        )
        let mutation = try XCTUnwrap(queuedMutation)
        let accepted = CloudDialogPreferences(
            dialogId: dialogId,
            pinned: false,
            pinnedAt: nil,
            muted: false,
            archived: true,
            updatedAt: "2026-07-25T10:00:01.000Z"
        )

        try await store.beginBootstrap(
            accountId: accountId,
            token: "bootstrap-before-ack",
            snapshotPts: 20,
            mode: .replacement
        )
        try await store.applyBootstrapPage(BootstrapDialogsPage(
            token: "bootstrap-before-ack",
            state: .init(pts: 20),
            dialogs: [
                BootstrapDialog(
                    dialogId: dialogId,
                    type: "direct",
                    title: "Bootstrap ordering",
                    lastMsgId: 0,
                    updatedAt: accepted.updatedAt,
                    preferences: accepted,
                    members: [],
                    messages: []
                ),
            ],
            nextCursor: nil,
            hasMore: false
        ))
        try await store.finishBootstrap(accountId: accountId, pts: 20)

        try await store.acknowledgeDialogPreference(
            clientMutationId: mutation.clientMutationId,
            pts: 20,
            preferences: accepted,
            accountId: accountId
        )
        let pendingAfterAcknowledgement = try await store.pendingDialogPreferencesReady(
            accountId: accountId
        )
        XCTAssertTrue(
            pendingAfterAcknowledgement.isEmpty,
            "A delayed response covered by the current cursor must be removed immediately"
        )

        let remote = CloudDialogPreferences(
            dialogId: dialogId,
            pinned: true,
            pinnedAt: "2026-07-25T10:00:02.000Z",
            muted: true,
            archived: true,
            updatedAt: "2026-07-25T10:00:02.000Z"
        )
        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: .init(pts: 21),
                updates: [
                    CloudUpdate(
                        pts: 21,
                        ptsCount: 1,
                        type: "dialog.preferences_updated",
                        dialogId: dialogId,
                        dialogTitle: nil,
                        message: nil,
                        readerAccountId: nil,
                        maxReadMsgId: nil,
                        preferences: remote,
                        clientMutationId: UUID().uuidString.lowercased(),
                        changedFields: ["pinned", "muted"]
                    ),
                ],
                hasMore: false
            ),
            accountId: accountId
        )
        let storedDialog = try await store.dialogs(accountId: accountId).first
        let dialog = try XCTUnwrap(storedDialog)
        XCTAssertTrue(dialog.isPinned)
        XCTAssertTrue(dialog.isMuted)
        XCTAssertTrue(dialog.isArchived)
        let currentPts = try await store.loadPts(accountId: accountId)
        XCTAssertEqual(currentPts, 21)
    }

    func testIncomingMessagePreferencePayloadAppliesAutoUnarchiveWithTheMessageCursor() async throws {
        let store = try makeStore()
        let accountId = "account-auto-unarchive"
        let dialogId = "dialog-auto-unarchive"
        try await store.upsertDialog(
            dialogId: dialogId,
            title: "Auto unarchive",
            updatedAt: "2026-07-25T10:00:00.000Z"
        )
        try await store.applyDialogPreferences(
            CloudDialogPreferences(
                dialogId: dialogId,
                pinned: true,
                pinnedAt: "2026-07-25T09:00:00.000Z",
                muted: true,
                archived: true,
                updatedAt: "2026-07-25T10:00:00.000Z"
            ),
            accountId: accountId
        )
        let mutedMessage = CloudMessage(
            dialogId: dialogId,
            msgId: 1,
            senderAccountId: "account-peer",
            clientMsgId: UUID().uuidString.lowercased(),
            kind: "text",
            text: "silent",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-25T10:00:01.000Z"
        )
        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: .init(pts: 1),
                updates: [
                    CloudUpdate(
                        pts: 1,
                        ptsCount: 1,
                        type: "message.new",
                        dialogId: dialogId,
                        dialogTitle: "Auto unarchive",
                        message: mutedMessage,
                        readerAccountId: nil,
                        maxReadMsgId: nil
                    ),
                ],
                hasMore: false
            ),
            accountId: accountId
        )
        let stillArchived = try await store.dialogs(accountId: accountId).first
        XCTAssertTrue(try XCTUnwrap(stillArchived).isArchived)

        let autoUnarchived = CloudDialogPreferences(
            dialogId: dialogId,
            pinned: true,
            pinnedAt: "2026-07-25T09:00:00.000Z",
            muted: false,
            archived: false,
            updatedAt: "2026-07-25T10:00:02.000Z"
        )
        let alertingMessage = CloudMessage(
            dialogId: dialogId,
            msgId: 2,
            senderAccountId: "account-peer",
            clientMsgId: UUID().uuidString.lowercased(),
            kind: "text",
            text: "returns to chats",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-25T10:00:02.000Z"
        )
        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: .init(pts: 2),
                updates: [
                    CloudUpdate(
                        pts: 2,
                        ptsCount: 1,
                        type: "message.new",
                        dialogId: dialogId,
                        dialogTitle: "Auto unarchive",
                        message: alertingMessage,
                        readerAccountId: nil,
                        maxReadMsgId: nil,
                        preferences: autoUnarchived
                    ),
                ],
                hasMore: false
            ),
            accountId: accountId
        )
        let returnedDialog = try await store.dialogs(accountId: accountId).first
        let returned = try XCTUnwrap(returnedDialog)
        XCTAssertFalse(returned.isArchived)
        XCTAssertFalse(returned.isMuted)
        XCTAssertTrue(returned.isPinned, "Auto-unarchive must preserve the independent pin field")
        let pts = try await store.loadPts(accountId: accountId)
        XCTAssertEqual(pts, 2)
    }

    func testDialogPreferenceCoordinatorRollsBackPermanentAccessErrorsAndRetainsAuthenticationFailures() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let api = CloudAPI(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            session: URLSession(configuration: configuration)
        )
        let coordinator = DialogPreferencesCoordinator(api: api)
        let store = try makeStore()
        let accountId = "account-coordinator"
        let dialogId = "dialog-coordinator"
        try await store.upsertDialog(
            dialogId: dialogId,
            title: "Coordinator",
            updatedAt: "2026-07-25T10:00:00.000Z"
        )

        CloudAPIMockURLProtocol.handler = { request in
            (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )),
                Data(#"{"error":"not a member","code":"forbidden"}"#.utf8)
            )
        }
        defer { CloudAPIMockURLProtocol.handler = nil }
        _ = try await coordinator.queue(
            store: store,
            accountId: accountId,
            dialogId: dialogId,
            field: .archived,
            desiredValue: true
        )
        let optimisticArchive = try await store.dialogs(accountId: accountId).first
        XCTAssertTrue(try XCTUnwrap(optimisticArchive).isArchived)

        let forbidden = try await coordinator.drain(
            store: store,
            accountId: accountId,
            token: "session-token",
            serverAdvertisesFeature: true
        )
        XCTAssertEqual(forbidden.permanentErrors, ["not a member"])
        XCTAssertFalse(forbidden.authenticationRequired)
        let rolledBackArchive = try await store.dialogs(accountId: accountId).first
        XCTAssertFalse(try XCTUnwrap(rolledBackArchive).isArchived)

        CloudAPIMockURLProtocol.handler = { request in
            (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )),
                Data(#"{"error":"dialog not found","code":"group_not_found"}"#.utf8)
            )
        }
        _ = try await coordinator.queue(
            store: store,
            accountId: accountId,
            dialogId: dialogId,
            field: .pinned,
            desiredValue: true
        )
        let missingDialog = try await coordinator.drain(
            store: store,
            accountId: accountId,
            token: "session-token",
            serverAdvertisesFeature: true
        )
        XCTAssertEqual(missingDialog.permanentErrors, ["dialog not found"])
        let dialogsAfterMissing = try await store.dialogs(accountId: accountId)
        XCTAssertFalse(try XCTUnwrap(dialogsAfterMissing.first).isPinned)

        CloudAPIMockURLProtocol.handler = { request in
            (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )),
                Data(#"{"error":"session expired","code":"unauthorized"}"#.utf8)
            )
        }
        _ = try await coordinator.queue(
            store: store,
            accountId: accountId,
            dialogId: dialogId,
            field: .muted,
            desiredValue: true
        )
        let unauthorized = try await coordinator.drain(
            store: store,
            accountId: accountId,
            token: "expired-session",
            serverAdvertisesFeature: true
        )
        XCTAssertTrue(unauthorized.authenticationRequired)
        XCTAssertTrue(unauthorized.permanentErrors.isEmpty)
        let authenticationRetry = try await store.nextDialogPreferenceRetryDelay(
            accountId: accountId
        )
        XCTAssertNotNil(authenticationRetry)
        let retainedMute = try await store.dialogs(accountId: accountId).first
        XCTAssertTrue(try XCTUnwrap(retainedMute).isMuted)
    }

    func testDialogPreferenceDrainStopsAfterFirstOfflineRateLimitOrAuthenticationFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let api = CloudAPI(
            config: CloudConfig(baseURL: try XCTUnwrap(
                URL(string: "https://cloud.example.test/cloud")
            )),
            session: URLSession(configuration: configuration)
        )
        defer { CloudAPIMockURLProtocol.handler = nil }

        for status in [0, 429, 401] {
            let store = try makeStore()
            let accountId = "account-stop-\(status)"
            for index in 0..<200 {
                let dialogId = "dialog-stop-\(status)-\(index)"
                try await store.upsertDialog(
                    dialogId: dialogId,
                    title: "Queued \(index)",
                    updatedAt: "2026-07-25T10:00:00.000Z"
                )
                _ = try await store.queueDialogPreference(
                    accountId: accountId,
                    dialogId: dialogId,
                    field: .pinned,
                    desiredValue: true
                )
            }
            let requests = LockedCounter()
            CloudAPIMockURLProtocol.handler = { request in
                requests.increment()
                if status == 0 { throw URLError(.notConnectedToInternet) }
                let headers = status == 429
                    ? ["content-type": "application/json", "retry-after": "11"]
                    : ["content-type": "application/json"]
                return (
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!,
                        statusCode: status,
                        httpVersion: "HTTP/1.1",
                        headerFields: headers
                    )),
                    Data(#"{"error":"paused"}"#.utf8)
                )
            }

            let result = try await DialogPreferencesCoordinator(api: api).drain(
                store: store,
                accountId: accountId,
                token: "token-\(status)",
                serverAdvertisesFeature: true,
                sessionGeneration: 7
            )
            XCTAssertEqual(requests.value, 1, "status \(status) must stop the whole drain")
            let pendingCount = try await store.pendingDestructiveLogoutItemCount()
            XCTAssertEqual(pendingCount, 200)
            if status == 401 {
                XCTAssertTrue(result.authenticationRequired)
            } else {
                XCTAssertNotNil(result.retryAfter)
            }
        }
    }

    func testCommittedUnknownOutcomeStaysDormantWhenCapabilityIsWithdrawn() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let api = CloudAPI(
            config: CloudConfig(baseURL: try XCTUnwrap(
                URL(string: "https://cloud.example.test/cloud")
            )),
            session: URLSession(configuration: configuration)
        )
        let coordinator = DialogPreferencesCoordinator(api: api)
        let store = try makeStore()
        let accountId = "account-capability-withdrawn"
        let dialogId = "dialog-capability-withdrawn"
        try await store.upsertDialog(
            dialogId: dialogId,
            type: "group",
            title: "Capability withdrawn",
            updatedAt: "2026-07-25T10:00:00.000Z"
        )
        let queuedMutation = try await coordinator.queue(
            store: store,
            accountId: accountId,
            dialogId: dialogId,
            field: .muted,
            desiredValue: true
        )
        let queued = try XCTUnwrap(queuedMutation)
        let requests = LockedCounter()
        CloudAPIMockURLProtocol.handler = { request in
            requests.increment()
            throw URLError(.networkConnectionLost)
        }
        defer { CloudAPIMockURLProtocol.handler = nil }

        let lostResponse = try await coordinator.drain(
            store: store,
            accountId: accountId,
            token: "session-token",
            serverAdvertisesFeature: true,
            sessionGeneration: 12
        )
        XCTAssertNotNil(lostResponse.retryAfter)
        try await store.failDialogPreference(
            accountId: accountId,
            clientMutationId: queued.clientMutationId,
            retryAfter: nil,
            error: "Retry after capability refresh",
            terminal: false
        )
        CloudAPIMockURLProtocol.handler = { request in
            requests.increment()
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )),
                Data(
                    #"{"error":"dialog preferences capability unavailable","code":"capability_unavailable"}"#
                        .utf8
                )
            )
        }

        let result = try await coordinator.drain(
            store: store,
            accountId: accountId,
            token: "session-token",
            serverAdvertisesFeature: true,
            sessionGeneration: 12
        )
        XCTAssertEqual(requests.value, 2)
        XCTAssertTrue(result.capabilityRefreshRequired)
        let pendingCount = try await store.pendingDestructiveLogoutItemCount()
        XCTAssertEqual(pendingCount, 1)

        let moved = try await store.movePendingGroupMutesToLegacy(accountId: accountId)
        XCTAssertEqual(moved, 0)
        let remainingPreferences = try await store.pendingDialogPreferencesReady(
            accountId: accountId
        )
        XCTAssertTrue(remainingPreferences.isEmpty, "Unknown-outcome requests stay dormant")
        let fallback = try await store.pendingGroupMutationsReady()
        XCTAssertTrue(fallback.isEmpty, "The mutation must not cross idempotency domains")
        let reactivatedCount = try await store.reactivateDormantDialogPreferences(
            accountId: accountId
        )
        XCTAssertEqual(reactivatedCount, 1)
        let reactivated = try await store.pendingDialogPreferencesReady(accountId: accountId)
        XCTAssertEqual(reactivated.map(\.clientMutationId), [queued.clientMutationId])
    }

    func testConvertedMuteIsCoalescedByANewerLegacyUnmute() async throws {
        let store = try makeStore()
        let accountId = "account-converted-order"
        let dialogId = "dialog-converted-order"
        try await store.upsertDialog(
            dialogId: dialogId,
            type: "group",
            title: "Ordered fallback",
            updatedAt: "2026-07-25T10:00:00.000Z"
        )
        let queuedMute = try await store.queueDialogPreference(
            accountId: accountId,
            dialogId: dialogId,
            field: .muted,
            desiredValue: true
        )
        let mute = try XCTUnwrap(queuedMute)
        let moved = try await store.movePendingGroupMutesToLegacy(accountId: accountId)
        XCTAssertEqual(moved, 1)
        let convertedMutations = try await store.pendingGroupMutationsReady()
        let converted = try XCTUnwrap(convertedMutations.first)
        XCTAssertEqual(converted.clientMutationId, mute.clientMutationId)
        XCTAssertEqual(converted.payloadJSON, #"{"mode":"muted"}"#)

        try await store.enqueueGroupMutation(
            dialogId: dialogId,
            operation: "notifications",
            payloadJSON: #"{"mode":"all"}"#,
            clientMutationId: "newer-unmute",
            accountId: accountId
        )
        let ready = try await store.pendingGroupMutationsReady()
        XCTAssertEqual(ready.map(\.clientMutationId), ["newer-unmute"])
        XCTAssertEqual(ready.first?.payloadJSON, #"{"mode":"all"}"#)
        XCTAssertGreaterThan(try XCTUnwrap(ready.first?.localOrder), converted.localOrder)
        let dialogsAfterUnmute = try await store.dialogs(accountId: accountId)
        XCTAssertFalse(try XCTUnwrap(dialogsAfterUnmute.first).isMuted)
    }

    func testTerminalLegacyNotificationFailureRestoresCanonicalMute() async throws {
        let store = try makeStore()
        let accountId = "account-legacy-rollback"
        let dialogId = "dialog-legacy-rollback"
        try await store.upsertDialog(
            dialogId: dialogId,
            type: "group",
            title: "Rollback",
            updatedAt: "2026-07-25T10:00:00.000Z"
        )
        try await store.savePts(1, accountId: accountId)
        try await store.enqueueGroupMutation(
            dialogId: dialogId,
            operation: "notifications",
            payloadJSON: #"{"mode":"muted"}"#,
            clientMutationId: "terminal-legacy-mute",
            accountId: accountId
        )
        let optimisticDialogs = try await store.dialogs(accountId: accountId)
        XCTAssertTrue(try XCTUnwrap(optimisticDialogs.first).isMuted)
        try await store.markGroupMutationAttempted(
            clientMutationId: "terminal-legacy-mute"
        )
        try await store.failGroupMutation(
            clientMutationId: "terminal-legacy-mute",
            retryAfter: nil,
            error: "not a member",
            terminal: true
        )
        let rolledBackDialogs = try await store.dialogs(accountId: accountId)
        XCTAssertFalse(
            try XCTUnwrap(rolledBackDialogs.first).isMuted,
            "A terminal 4xx must remove the optimistic overlay"
        )
    }

    func testPreferenceDrainCancellationWaitsForSuspendedRequestAndPreservesAccountIntent() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let api = CloudAPI(
            config: CloudConfig(baseURL: try XCTUnwrap(
                URL(string: "https://cloud.example.test/cloud")
            )),
            session: URLSession(configuration: configuration)
        )
        let coordinator = DialogPreferencesCoordinator(api: api)
        let store = try makeStore()
        let accountId = "account-logout-suspended"
        let dialogId = "dialog-logout-suspended"
        try await store.upsertDialog(
            dialogId: dialogId,
            title: "Suspended logout",
            updatedAt: "2026-07-25T10:00:00.000Z"
        )
        let queuedMutation = try await coordinator.queue(
            store: store,
            accountId: accountId,
            dialogId: dialogId,
            field: .pinned,
            desiredValue: true
        )
        let mutation = try XCTUnwrap(queuedMutation)
        let gate = LockedGate()
        CloudAPIMockURLProtocol.deferHandlerExecution = true
        CloudAPIMockURLProtocol.handler = { request in
            gate.signalStarted()
            gate.waitForRelease()
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )),
                Data("""
                {"preferences":{"dialogId":"\(dialogId)","pinned":true,
                "pinnedAt":"2026-07-25T10:00:00.000Z","muted":false,"archived":false,
                "updatedAt":"2026-07-25T10:00:00.000Z"},"pts":5,"duplicate":false}
                """.utf8)
            )
        }
        defer {
            gate.release()
            CloudAPIMockURLProtocol.deferHandlerExecution = false
            CloudAPIMockURLProtocol.handler = nil
        }

        let drain = Task {
            try await coordinator.drain(
                store: store,
                accountId: accountId,
                token: "old-session-token",
                serverAdvertisesFeature: true,
                sessionGeneration: 40
            )
        }
        XCTAssertTrue(gate.waitUntilStarted())
        drain.cancel()
        let delayedRelease = Task {
            try? await Task.sleep(for: .milliseconds(20))
            gate.release()
        }
        await coordinator.cancelAndWait()
        await delayedRelease.value
        _ = try? await drain.value

        let hasActiveDrain = await coordinator.hasActiveDrain
        XCTAssertFalse(hasActiveDrain)
        let retained = try await store.queueDialogPreference(
            accountId: accountId,
            dialogId: dialogId,
            field: .pinned,
            desiredValue: true
        )
        XCTAssertEqual(retained?.clientMutationId, mutation.clientMutationId)
        XCTAssertNil(retained?.acknowledgedPts)
    }

    func testCloudFailureClassificationRetriesOnlyRecoverableFailures() {
        XCTAssertEqual(cloudFailureDisposition(URLError(.notConnectedToInternet)), .transient(retryAfter: nil))
        XCTAssertEqual(
            cloudFailureDisposition(CloudAPIError(status: 429, message: "slow", retryAfter: 17)),
            .transient(retryAfter: 17)
        )
        XCTAssertEqual(
            cloudFailureDisposition(CloudAPIError(status: 401, message: "expired", retryAfter: nil)),
            .authenticationRequired
        )
        XCTAssertEqual(
            cloudFailureDisposition(
                CloudAPIError(
                    status: 404,
                    message: "feature disabled",
                    retryAfter: nil,
                    code: "capability_unavailable"
                )
            ),
            .unsupportedServer
        )
        XCTAssertEqual(
            cloudFailureDisposition(
                CloudAPIError(
                    status: 404,
                    message: "resource missing",
                    retryAfter: nil,
                    code: "message_not_found"
                )
            ),
            .permanent
        )
        XCTAssertEqual(
            cloudFailureDisposition(CloudAPIError(status: 413, message: "too large", retryAfter: nil)),
            .permanent
        )
        let unavailable = CloudAPIError(
            status: 404,
            message: "feature disabled",
            retryAfter: nil,
            code: "capability_unavailable"
        )
        XCTAssertEqual(
            cloudOperationFailureDisposition(unavailable, serverAdvertisesFeature: false),
            .unsupportedServer
        )
        let missing = CloudAPIError(
            status: 404,
            message: "message missing",
            retryAfter: nil,
            code: "message_not_found"
        )
        XCTAssertEqual(
            cloudOperationFailureDisposition(missing, serverAdvertisesFeature: true),
            .permanent
        )
        let routeSkew = CloudAPIError(
            status: 404,
            message: "Not Found",
            retryAfter: nil,
            code: nil
        )
        XCTAssertEqual(
            cloudOperationFailureDisposition(routeSkew, serverAdvertisesFeature: true),
            .unsupportedServer
        )
        XCTAssertEqual(
            cloudOperationFailureDisposition(routeSkew, serverAdvertisesFeature: false),
            .unsupportedServer
        )
        XCTAssertEqual(
            cloudOperationFailureDisposition(
                CloudAPIError(status: -1, message: "Invalid server response", retryAfter: nil),
                serverAdvertisesFeature: true
            ),
            .transient(retryAfter: nil)
        )
        let undecodable = DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "newer response shape")
        )
        XCTAssertEqual(
            cloudOperationFailureDisposition(undecodable, serverAdvertisesFeature: true),
            .transient(retryAfter: nil)
        )
        XCTAssertNil(cloudScheduledCreateRetryDelay(0, serverAdvertisesFeature: false))
        XCTAssertEqual(
            cloudScheduledCreateRetryDelay(12, serverAdvertisesFeature: true),
            12
        )
    }

    func testPendingMutationsPersistAndTerminalFailuresDoNotLoop() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cloud.sqlite").path
        let key = Data("durable-mutation-key".utf8)
        let first = try CloudLocalStore(path: path, key: key)
        try await first.enqueueMessageMutation(
            clientMutationId: "mutation-1", operation: "edit", dialogId: "dialog-1",
            msgId: 9, body: "corrected", expectedEditVersion: 2
        )

        let reopened = try CloudLocalStore(path: path, key: key)
        var ready = try await reopened.pendingMessageMutationsReady()
        XCTAssertEqual(ready.map(\.clientMutationId), ["mutation-1"])
        XCTAssertEqual(ready.first?.body, "corrected")
        try await reopened.markMessageMutationFailed(
            clientMutationId: "mutation-1", error: "invalid", retryAfter: nil, terminal: true
        )
        let terminalReady = try await reopened.pendingMessageMutationsReady()
        XCTAssertTrue(terminalReady.isEmpty)
        try await reopened.retryMessageMutation(clientMutationId: "mutation-1")
        ready = try await reopened.pendingMessageMutationsReady()
        XCTAssertEqual(ready.first?.retryCount, 1)
    }

    func testPendingReadReceiptSurvivesReopenAndFailureUntilAcknowledged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cloud.sqlite").path
        let key = Data("durable-read-receipt-key".utf8)
        let dialogId = "dialog-read-receipt"
        let accountId = "account-me"

        do {
            let store = try CloudLocalStore(path: path, key: key)
            try await store.saveMembers(dialogId: dialogId, members: [
                BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 0),
            ])
            try await store.queueReadReceipt(
                dialogId: dialogId,
                accountId: accountId,
                maxReadMsgId: 10
            )
        }

        do {
            let reopened = try CloudLocalStore(path: path, key: key)
            let ready = try await reopened.pendingReadReceiptsReady()
            XCTAssertEqual(ready.map(\.dialogId), [dialogId])
            XCTAssertEqual(ready.first?.maxReadMsgId, 10)
            try await reopened.failReadReceipt(
                dialogId: dialogId,
                accountId: accountId,
                retryAfter: 3_600,
                error: "offline"
            )
        }

        do {
            let reopenedAfterFailure = try CloudLocalStore(path: path, key: key)
            let failedReady = try await reopenedAfterFailure.pendingReadReceiptsReady()
            XCTAssertTrue(failedReady.isEmpty)

            // A newly visible message advances the durable watermark and makes the coalesced
            // acknowledgement immediately eligible again.
            try await reopenedAfterFailure.queueReadReceipt(
                dialogId: dialogId,
                accountId: accountId,
                maxReadMsgId: 12
            )
            let retried = try await reopenedAfterFailure.pendingReadReceiptsReady()
            XCTAssertEqual(retried.first?.maxReadMsgId, 12)
            XCTAssertEqual(retried.first?.retryCount, 0)

            // An older request may fail after this row was coalesced to a newer visible watermark.
            // That stale failure must not put the newer acknowledgement behind a retry timer.
            try await reopenedAfterFailure.failReadReceipt(
                dialogId: dialogId,
                accountId: accountId,
                retryAfter: 3_600,
                error: "stale network failure",
                attemptedMsgId: 10
            )
            let readyAfterStaleFailure = try await reopenedAfterFailure.pendingReadReceiptsReady()
            XCTAssertEqual(readyAfterStaleFailure.first?.maxReadMsgId, 12)
            XCTAssertEqual(readyAfterStaleFailure.first?.retryCount, 0)

            try await reopenedAfterFailure.completeReadReceipt(
                dialogId: dialogId,
                accountId: accountId,
                acknowledgedMsgId: 11
            )
            let afterStaleAcknowledgement = try await reopenedAfterFailure.pendingReadReceiptsReady()
            XCTAssertEqual(
                afterStaleAcknowledgement.first?.maxReadMsgId,
                12,
                "A stale acknowledgement must not delete a newer read watermark"
            )
            try await reopenedAfterFailure.completeReadReceipt(
                dialogId: dialogId,
                accountId: accountId,
                acknowledgedMsgId: 12
            )
        }

        let finalReopen = try CloudLocalStore(path: path, key: key)
        let finalReady = try await finalReopen.pendingReadReceiptsReady()
        XCTAssertTrue(finalReady.isEmpty)
    }

    func testHistoryRequestEncodesAfterCursorAndDecodesNextAfterCursor() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let api = CloudAPI(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            session: URLSession(configuration: configuration)
        )
        CloudAPIMockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/cloud/v1/history")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
            let body = try XCTUnwrap(CloudAPIMockURLProtocol.bodyData(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["dialogId"] as? String, "dialog-history")
            XCTAssertNil(json["beforeMsgId"])
            XCTAssertEqual(json["afterMsgId"] as? Int, 20)
            XCTAssertEqual(json["limit"] as? Int, 100)
            XCTAssertEqual(json["maxBytes"] as? Int, 512 * 1_024)
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )),
                Data("""
                {"dialogId":"dialog-history","messages":[],"nextBeforeMsgId":null,
                 "nextAfterMsgId":42,"hasMore":true}
                """.utf8)
            )
        }
        defer { CloudAPIMockURLProtocol.handler = nil }

        let page = try await api.getHistory(
            dialogId: "dialog-history",
            beforeMsgId: nil,
            afterMsgId: 20,
            limit: 100,
            token: "session-token"
        )
        XCTAssertEqual(page.nextAfterMsgId, 42)
        XCTAssertTrue(page.hasMore)
    }

    func testAccountDeletionRequestUsesBearerAndPurposeCodeBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let config = CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud")))
        let api = CloudAPI(config: config, session: session)
        CloudAPIMockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/cloud/v1/account")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
            let body = try XCTUnwrap(CloudAPIMockURLProtocol.bodyData(from: request))
            XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["code": "123456"])
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["content-type": "application/json"]
            ))
            return (response, Data("{\"deleted\":true}".utf8))
        }
        defer { CloudAPIMockURLProtocol.handler = nil }

        let response = try await api.deleteAccount(code: "123456", token: "session-token")
        let deleted = response.deleted
        XCTAssertTrue(deleted)
    }

    func testProfileUpdateUsesAuthenticatedPutAndDecodesSavedName() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let api = CloudAPI(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            session: URLSession(configuration: configuration)
        )
        CloudAPIMockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/cloud/v1/profile")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
            let body = try XCTUnwrap(CloudAPIMockURLProtocol.bodyData(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["firstName"] as? String, "Mehron")
            XCTAssertEqual(json["lastName"] as? String, "Sharifov")
            XCTAssertEqual(json["bio"] as? String, "Hello")
            XCTAssertEqual(json["birthday"] as? String, "1995-04-18")
            XCTAssertEqual(json["colorIndex"] as? Int, 4)
            XCTAssertTrue(json.keys.contains("username"))
            XCTAssertTrue(json["username"] is NSNull)
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )),
                Data("""
                {"accountId":"account-a","firstName":"Mehron","lastName":"Sharifov",\
                "displayName":"Mehron Sharifov","bio":"Hello","birthday":"1995-04-18",\
                "colorIndex":4,"updatedAt":"2026-07-16T10:00:00.000Z"}
                """.utf8)
            )
        }
        defer { CloudAPIMockURLProtocol.handler = nil }

        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 1995
        components.month = 4
        components.day = 18
        let response = try await api.updateProfile(
            StoredProfileDetails(
                firstName: "Mehron", lastName: "Sharifov", bio: "Hello",
                birthday: try XCTUnwrap(components.date), colorIndex: 4
            ),
            token: "session-token"
        )
        XCTAssertEqual(response.displayName, "Mehron Sharifov")
    }

    func testStoredProfileCombinesTrimmedFirstAndLastNames() {
        let profile = StoredProfileDetails(
            firstName: " Mehron ",
            lastName: " Sharifov ",
            bio: "Hello",
            birthday: nil,
            colorIndex: 2
        )
        XCTAssertEqual(profile.displayName, "Mehron Sharifov")
    }

    func testProfileDetailsPersistSeparatelyFromTheSession() async throws {
        let accountId = "profile-test-\(UUID().uuidString)"
        let store = TokenStore()
        let birthday = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(
            year: 2000, month: 2, day: 16
        )))
        let profile = StoredProfileDetails(
            firstName: "Mehron",
            lastName: "Sharifov",
            bio: "A few words",
            birthday: birthday,
            colorIndex: 4
        )

        try await store.saveProfile(profile, accountId: accountId)
        let loaded = try await store.loadProfile(accountId: accountId)
        XCTAssertEqual(loaded, profile)
        try await store.clearProfile(accountId: accountId)
        let cleared = try await store.loadProfile(accountId: accountId)
        XCTAssertNil(cleared)
    }

    func testAPNsDeviceTokenUsesLowercaseTwoDigitHex() {
        let token = PushRegistrationCenter.hexadecimalToken(from: Data([0x00, 0x01, 0x0f, 0xa0, 0xff]))
        XCTAssertEqual(token, "00010fa0ff")
    }

    func testPushActivationIsFrozenByDefault() {
        XCTAssertFalse(PushRegistrationCenter.isEnabled)
    }

    func testCloudWebSocketURLDoesNotContainBearerToken() throws {
        let config = CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud")))
        let url = config.wsURL()
        XCTAssertEqual(url.absoluteString, "wss://cloud.example.test/cloud/v1/ws")
        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.query)
    }

    @MainActor
    func testMessageMutationRequestsCarryStableIdentifiersAndVersions() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let api = CloudAPI(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            session: URLSession(configuration: configuration)
        )
        var requests: [(String, [String: Any])] = []
        CloudAPIMockURLProtocol.handler = { request in
            let body = try XCTUnwrap(CloudAPIMockURLProtocol.bodyData(from: request))
            requests.append((request.url!.path, try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])))
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["content-type": "application/json"]
            ))
            let state = request.url!.path.hasSuffix("delete") ? "deleted_for_all" : "visible"
            let text = state == "visible" ? "corrected" : ""
            return (response, Data("""
            {"dialogId":"dialog-1","msgId":7,"actorPts":9,"duplicate":false,"message":{
              "dialog_id":"dialog-1","msg_id":7,"sender_account_id":"account-a",
              "client_msg_id":"11111111-1111-1111-1111-111111111111","kind":"text",
              "text":"\(text)","reply_to_msg_id":null,"edit_version":1,"state":"\(state)",
              "server_ts":"2026-07-12T00:00:00Z"}}
            """.utf8))
        }
        defer { CloudAPIMockURLProtocol.handler = nil }

        _ = try await api.editMessage(
            dialogId: "dialog-1", msgId: 7,
            clientMutationId: "22222222-2222-2222-2222-222222222222",
            expectedEditVersion: 0, body: "corrected", token: "session-token"
        )
        _ = try await api.deleteMessage(
            dialogId: "dialog-1", msgId: 7,
            clientMutationId: "33333333-3333-3333-3333-333333333333",
            token: "session-token"
        )

        XCTAssertEqual(requests.map(\.0), ["/cloud/v1/messages/edit", "/cloud/v1/messages/delete"])
        XCTAssertEqual(requests[0].1["expectedEditVersion"] as? Int, 0)
        XCTAssertEqual(requests[0].1["clientMutationId"] as? String, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(requests[1].1["msgId"] as? Int, 7)
    }

    @MainActor
    func testReactionAndForwardRequestsCarryStableSourceAndMutationIdentifiers() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let api = CloudAPI(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            session: URLSession(configuration: configuration)
        )
        var requests: [(String, [String: Any])] = []
        CloudAPIMockURLProtocol.handler = { request in
            let body = try XCTUnwrap(CloudAPIMockURLProtocol.bodyData(from: request))
            requests.append((request.url!.path, try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])))
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["content-type": "application/json"]
            ))
            if request.url!.path.hasSuffix("react") {
                return (response, Data("""
                {"dialogId":"dialog-1","msgId":7,"actorPts":9,"duplicate":false,"message":{
                  "dialog_id":"dialog-1","msg_id":7,"sender_account_id":"account-a",
                  "client_msg_id":"11111111-1111-1111-1111-111111111111","kind":"text",
                  "text":"hello","reply_to_msg_id":null,"reactions":[{"account_id":"account-b","emoji":"❤️"}],
                  "edit_version":0,"state":"visible","server_ts":"2026-07-12T00:00:00Z"}}
                """.utf8))
            }
            return (response, Data("""
            {"dialogId":"dialog-2","clientMsgId":"33333333-3333-3333-3333-333333333333",
             "msgId":8,"senderPts":10,"duplicate":false,"serverTs":"2026-07-12T00:00:01Z","text":"hello"}
            """.utf8))
        }
        defer { CloudAPIMockURLProtocol.handler = nil }

        _ = try await api.setReaction(
            dialogId: "dialog-1", msgId: 7,
            clientMutationId: "22222222-2222-2222-2222-222222222222",
            emoji: "❤️", token: "session-token"
        )
        _ = try await api.forwardMessage(
            dialogId: "dialog-2",
            clientMsgId: "33333333-3333-3333-3333-333333333333",
            sourceDialogId: "dialog-1", sourceMsgId: 7, token: "session-token"
        )

        XCTAssertEqual(requests.map(\.0), ["/cloud/v1/messages/react", "/cloud/v1/messages/send"])
        XCTAssertEqual(requests[0].1["clientMutationId"] as? String, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(requests[0].1["emoji"] as? String, "❤️")
        let source = try XCTUnwrap(requests[1].1["forwardedFrom"] as? [String: Any])
        XCTAssertEqual(source["dialogId"] as? String, "dialog-1")
        XCTAssertEqual(source["msgId"] as? Int, 7)
        XCTAssertNil(requests[1].1["body"])
    }

    func testPendingSessionRevocationTokenPersistsSeparately() async throws {
        let store = TokenStore(service: "com.toj.tests.\(UUID().uuidString)")
        try? await store.clearPendingRevocationToken()
        try await store.savePendingRevocationToken(
            "test-revocation-token",
            localReplicaAccountId: "account-a"
        )
        try await store.savePendingRevocationToken(
            "second-revocation-token",
            eraseLocalReplicaOnLaunch: false,
            localReplicaAccountId: "account-b"
        )
        let loaded = try await store.loadPendingRevocationToken()
        XCTAssertEqual(loaded, "test-revocation-token")
        let intents = try await store.loadPendingRevocations()
        XCTAssertEqual(intents, [
            PendingSessionRevocation(
                token: "test-revocation-token",
                eraseLocalReplicaOnLaunch: true,
                localReplicaAccountId: "account-a"
            ),
            PendingSessionRevocation(
                token: "second-revocation-token",
                eraseLocalReplicaOnLaunch: false,
                localReplicaAccountId: "account-b"
            ),
        ])
        try await store.clearPendingRevocationToken(ifMatches: "different-token")
        var preserved = try await store.loadPendingRevocationTokens()
        XCTAssertEqual(preserved, ["test-revocation-token", "second-revocation-token"])
        try await store.clearPendingRevocationToken(ifMatches: "test-revocation-token")
        preserved = try await store.loadPendingRevocationTokens()
        XCTAssertEqual(preserved, ["second-revocation-token"])
        try await store.clearPendingRevocationToken(ifMatches: "second-revocation-token")
        let cleared = try await store.loadPendingRevocationToken()
        XCTAssertNil(cleared)
    }

    func testPendingRevocationQueueMigratesTheLegacySingleTokenFormat() async throws {
        let service = "com.toj.pending-revocation-migration.\(UUID().uuidString)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "pending-session-revocation",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data("legacy-revocation-token".utf8),
        ]
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
        let store = TokenStore(service: service)
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }

        let legacyTokens = try await store.loadPendingRevocationTokens()
        XCTAssertEqual(legacyTokens, ["legacy-revocation-token"])
        let legacyIntent = try await store.loadPendingRevocations()
        XCTAssertEqual(legacyIntent, [PendingSessionRevocation(
            token: "legacy-revocation-token",
            eraseLocalReplicaOnLaunch: true,
            localReplicaAccountId: nil
        )])
        try await store.savePendingRevocationToken("queued-revocation-token")
        let migratedTokens = try await store.loadPendingRevocationTokens()
        XCTAssertEqual(migratedTokens, ["legacy-revocation-token", "queued-revocation-token"])
    }

    func testPendingRevocationQueueMigratesTheLegacyStringArrayFormat() async throws {
        let service = "com.toj.pending-revocation-array-migration.\(UUID().uuidString)"
        let data = try JSONEncoder().encode(["first-token", "first-token", "second-token", ""])
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "pending-session-revocation",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
        let store = TokenStore(service: service)
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }

        let migratedIntents = try await store.loadPendingRevocations()
        XCTAssertEqual(migratedIntents, [
            PendingSessionRevocation(
                token: "first-token",
                eraseLocalReplicaOnLaunch: true,
                localReplicaAccountId: nil
            ),
            PendingSessionRevocation(
                token: "second-token",
                eraseLocalReplicaOnLaunch: true,
                localReplicaAccountId: nil
            ),
        ])
    }

    func testPendingRevocationIntentCannotBeDowngradedBeforeLocalCleanup() async throws {
        let store = TokenStore(service: "com.toj.pending-revocation-intent.\(UUID().uuidString)")
        defer { Task { try? await store.clearPendingRevocationToken() } }

        try await store.savePendingRevocationToken(
            "token",
            eraseLocalReplicaOnLaunch: false,
            localReplicaAccountId: "preserved-account"
        )
        try await store.savePendingRevocationToken(
            "token",
            localReplicaAccountId: "erased-account"
        )
        try await store.savePendingRevocationToken(
            "token",
            eraseLocalReplicaOnLaunch: false,
            localReplicaAccountId: "must-not-downgrade"
        )
        try await store.savePendingRevocationToken(
            "replacement-token",
            eraseLocalReplicaOnLaunch: false,
            localReplicaAccountId: "erased-account"
        )
        try await store.savePendingRevocationToken(
            "other-account-token",
            eraseLocalReplicaOnLaunch: false,
            localReplicaAccountId: "other-account"
        )
        let upgradedIntents = try await store.loadPendingRevocations()
        XCTAssertEqual(upgradedIntents, [
            PendingSessionRevocation(
                token: "token",
                eraseLocalReplicaOnLaunch: true,
                localReplicaAccountId: "erased-account"
            ),
            PendingSessionRevocation(
                token: "replacement-token",
                eraseLocalReplicaOnLaunch: false,
                localReplicaAccountId: "erased-account"
            ),
            PendingSessionRevocation(
                token: "other-account-token",
                eraseLocalReplicaOnLaunch: false,
                localReplicaAccountId: "other-account"
            ),
        ])

        try await store.markPendingRevocationLocalErasureCompleted(accountId: "erased-account")
        let remoteOnlyIntents = try await store.loadPendingRevocations()
        XCTAssertEqual(remoteOnlyIntents, [
            PendingSessionRevocation(
                token: "token",
                eraseLocalReplicaOnLaunch: false,
                localReplicaAccountId: nil
            ),
            PendingSessionRevocation(
                token: "replacement-token",
                eraseLocalReplicaOnLaunch: false,
                localReplicaAccountId: nil
            ),
            PendingSessionRevocation(
                token: "other-account-token",
                eraseLocalReplicaOnLaunch: false,
                localReplicaAccountId: "other-account"
            ),
        ])
    }

    func testSuccessfulAuthenticationMakesOnlyItsPreservedRevocationsRemoteOnly() async throws {
        let store = TokenStore(service: "com.toj.pending-revocation-auth.\(UUID().uuidString)")
        defer { Task { try? await store.clearPendingRevocationToken() } }
        try await store.savePendingRevocationToken(
            "token-a",
            eraseLocalReplicaOnLaunch: false,
            localReplicaAccountId: "account-a"
        )
        try await store.savePendingRevocationToken(
            "token-b",
            eraseLocalReplicaOnLaunch: false,
            localReplicaAccountId: "account-b"
        )

        try await store.markPendingRevocationsRemoteOnly(localReplicaAccountId: "account-a")
        let resolvedIntents = try await store.loadPendingRevocations()
        XCTAssertEqual(resolvedIntents, [
            PendingSessionRevocation(
                token: "token-a",
                eraseLocalReplicaOnLaunch: false,
                localReplicaAccountId: nil
            ),
            PendingSessionRevocation(
                token: "token-b",
                eraseLocalReplicaOnLaunch: false,
                localReplicaAccountId: "account-b"
            ),
        ])
    }

    func testCanceledStagedLoginMakesOnlyItsExactRevocationRemoteOnly() async throws {
        let store = TokenStore(service: "com.toj.pending-revocation-cancel.\(UUID().uuidString)")
        defer { Task { try? await store.clearPendingRevocationToken() } }
        try await store.savePendingRevocationToken(
            "staged-token",
            eraseLocalReplicaOnLaunch: false,
            localReplicaAccountId: "preserved-account"
        )
        try await store.savePendingRevocationToken(
            "security-reissue-token",
            eraseLocalReplicaOnLaunch: false,
            localReplicaAccountId: "preserved-account"
        )
        try await store.savePendingRevocationToken(
            "destructive-token",
            localReplicaAccountId: "preserved-account"
        )

        try await store.markPendingRevocationRemoteOnly(ifMatches: "staged-token")

        let pendingRevocations = try await store.loadPendingRevocations()
        XCTAssertEqual(pendingRevocations, [
            PendingSessionRevocation(
                token: "staged-token",
                eraseLocalReplicaOnLaunch: false,
                localReplicaAccountId: nil
            ),
            PendingSessionRevocation(
                token: "security-reissue-token",
                eraseLocalReplicaOnLaunch: false,
                localReplicaAccountId: "preserved-account"
            ),
            PendingSessionRevocation(
                token: "destructive-token",
                eraseLocalReplicaOnLaunch: true,
                localReplicaAccountId: "preserved-account"
            ),
        ])
    }

    func testPendingRevocationLaunchPolicySeparatesErasePreserveAndRemoteOnlyIntents() {
        let saved = storedSession(accountId: "account-a", deviceId: "device-a", suffix: 1)
        let remoteOnly = PendingSessionRevocation(
            token: "old-unrelated-token",
            eraseLocalReplicaOnLaunch: false,
            localReplicaAccountId: nil
        )
        let preserve = PendingSessionRevocation(
            token: "abandoned-replacement-token",
            eraseLocalReplicaOnLaunch: false,
            localReplicaAccountId: "account-a"
        )
        let eraseRotatedAccount = PendingSessionRevocation(
            token: "superseded-access-token",
            eraseLocalReplicaOnLaunch: true,
            localReplicaAccountId: "account-a"
        )

        XCTAssertEqual(PendingRevocationLaunchPolicy.action(
            savedSession: saved,
            pendingRevocations: [remoteOnly],
            hasPendingLocalErasure: false
        ), .restoreSavedSession)
        XCTAssertEqual(PendingRevocationLaunchPolicy.action(
            savedSession: saved,
            pendingRevocations: [remoteOnly],
            hasPendingLocalErasure: false,
            pendingReauthenticationAccountId: "account-a"
        ), .requireAuthentication(localReplicaAccountId: "account-a"))
        XCTAssertEqual(PendingRevocationLaunchPolicy.action(
            savedSession: saved,
            pendingRevocations: [preserve],
            hasPendingLocalErasure: false
        ), .requireAuthentication(localReplicaAccountId: "account-a"))
        XCTAssertEqual(PendingRevocationLaunchPolicy.action(
            savedSession: nil,
            pendingRevocations: [preserve],
            hasPendingLocalErasure: false
        ), .requireAuthentication(localReplicaAccountId: "account-a"))
        XCTAssertEqual(PendingRevocationLaunchPolicy.action(
            savedSession: nil,
            pendingRevocations: [remoteOnly],
            hasPendingLocalErasure: false
        ), .restoreSavedSession)
        XCTAssertEqual(PendingRevocationLaunchPolicy.action(
            savedSession: saved,
            pendingRevocations: [eraseRotatedAccount, preserve],
            hasPendingLocalErasure: false
        ), .eraseLocalReplica)
        XCTAssertEqual(PendingRevocationLaunchPolicy.action(
            savedSession: saved,
            pendingRevocations: [],
            hasPendingLocalErasure: true
        ), .eraseLocalReplica)
    }

    func testPendingReauthenticationPersistsIndependentlyFromSessionAndRevocationCleanup() async throws {
        let store = TokenStore(service: "com.toj.pending-reauthentication.\(UUID().uuidString)")
        defer { Task { try? await store.clearAllStoredData() } }
        let session = storedSession(accountId: "account-a", deviceId: "device-a", suffix: 9)
        try await store.save(session)
        try await store.savePendingReauthentication(accountId: "account-a")
        try await store.savePendingRevocationToken(
            "staged-other-account-token",
            eraseLocalReplicaOnLaunch: false,
            localReplicaAccountId: "account-a"
        )

        try await store.clearSession(ifTokenMatches: session.session.token)
        try await store.clearPendingRevocationToken(ifMatches: "staged-other-account-token")

        let persistedSession = try await store.load()
        XCTAssertNil(persistedSession)
        let pendingAccountId = try await store.loadPendingReauthenticationAccountId()
        XCTAssertEqual(pendingAccountId, "account-a")
        XCTAssertEqual(PendingRevocationLaunchPolicy.action(
            savedSession: nil,
            pendingRevocations: [],
            hasPendingLocalErasure: false,
            pendingReauthenticationAccountId: pendingAccountId
        ), .requireAuthentication(localReplicaAccountId: "account-a"))
        try await store.clearPendingReauthentication()
        let clearedAccountId = try await store.loadPendingReauthenticationAccountId()
        XCTAssertNil(clearedAccountId)
    }

    func testPendingLocalErasureSurvivesProfileCleanupUntilExplicitlyCleared() async throws {
        let store = TokenStore(service: "com.toj.tests.\(UUID().uuidString)")
        let profile = StoredProfileDetails(
            firstName: "Mehron",
            lastName: "Sharifov",
            bio: "Private profile",
            birthday: nil,
            colorIndex: 2
        )
        try await store.saveProfile(profile, accountId: "account-a")
        try await store.saveProfile(profile, accountId: "account-b")
        try await store.savePendingRevocationToken("revocation-token")
        try await store.savePendingLocalErasure(accountId: "account-a")

        try await store.clearAllProfiles()

        let firstProfile = try await store.loadProfile(accountId: "account-a")
        let secondProfile = try await store.loadProfile(accountId: "account-b")
        let revocationToken = try await store.loadPendingRevocationToken()
        let erasurePending = try await store.hasPendingLocalErasure()
        XCTAssertNil(firstProfile)
        XCTAssertNil(secondProfile)
        XCTAssertEqual(revocationToken, "revocation-token")
        XCTAssertTrue(erasurePending)

        try await store.clearPendingLocalErasure()
        let erasureCleared = try await store.hasPendingLocalErasure()
        XCTAssertFalse(erasureCleared)
        try await store.clearPendingRevocationToken()
    }

    func testCloudConfigPersistsInjectedURLForManualRelaunch() throws {
        let suiteName = "CloudConfigTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expected = try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))

        let injected = CloudConfig.resolve(
            environment: ["TOJ_CLOUD_BASE_URL": expected.absoluteString],
            defaults: defaults
        )
        let restored = CloudConfig.resolve(environment: [:], defaults: defaults)

        XCTAssertEqual(injected.baseURL, expected)
        XCTAssertEqual(restored.baseURL, expected)
    }

    func testCloudConfigUsesBundledReleaseURLOnFreshInstall() throws {
        let suiteName = "CloudConfigTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expected = "https://api.sandstrm.online/cloud"

        let config = CloudConfig.resolve(
            environment: [:],
            defaults: defaults,
            bundledBaseURL: expected
        )

        XCTAssertEqual(config.baseURL.absoluteString, expected)
        XCTAssertNil(config.validationIssue(environment: [:]))
    }

    func testBundledReleaseURLOverridesStalePersistedDevelopmentURL() throws {
        let suiteName = "CloudConfigTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://127.0.0.1:8788", forKey: "TOJ_CLOUD_BASE_URL")

        let config = CloudConfig.resolve(
            environment: [:],
            defaults: defaults,
            bundledBaseURL: "https://api.sandstrm.online/cloud"
        )

        XCTAssertEqual(config.baseURL.absoluteString, "https://api.sandstrm.online/cloud")
    }

    func testExplicitEnvironmentURLOverridesBundledReleaseURL() throws {
        let suiteName = "CloudConfigTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let override = "https://staging.example.test/cloud"

        let config = CloudConfig.resolve(
            environment: ["TOJ_CLOUD_BASE_URL": override],
            defaults: defaults,
            bundledBaseURL: "https://api.sandstrm.online/cloud"
        )

        XCTAssertEqual(config.baseURL.absoluteString, override)
        XCTAssertEqual(defaults.string(forKey: "TOJ_CLOUD_BASE_URL"), override)
    }

    func testLocalDatabaseKeyPersistsAcrossLookups() throws {
        let service = "com.toj.tests.cloud-db.\(UUID().uuidString)"
        let account = "sqlcipher-key"
        let store = LocalDatabaseKeyStore(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        defer { SecItemDelete(query as CFDictionary) }

        let created = try store.loadOrCreateKey()
        let loaded = try store.loadOrCreateKey()

        XCTAssertEqual(loaded, created)
    }

    @MainActor
    func testLocalStorePersistsSendReconcileAndDifference() async throws {
        let store = try makeStore()
        let accountId = "account-a"
        let peerId = "account-b"
        let dialogId = "dialog-1"
        let clientMsgId = UUID().uuidString.lowercased()

        let initialPts = try await store.loadPts(accountId: accountId)
        XCTAssertEqual(initialPts, 0)
        try await store.upsertDialog(dialogId: dialogId, title: "Bob")

        let pending = try await store.insertSending(
            dialogId: dialogId,
            clientMsgId: clientMsgId,
            text: "local first",
            senderAccountId: accountId
        )
        let pendingState = pending.localState
        let pendingMsgId = pending.msgId
        XCTAssertEqual(pendingState, "sending")
        XCTAssertNil(pendingMsgId)

        var dueOutbox = try await store.pendingOutboxReady()
        XCTAssertEqual(dueOutbox.map(\.clientMsgId), [clientMsgId])

        try await store.markFailed(clientMsgId: clientMsgId, retryAfter: 60)
        dueOutbox = try await store.pendingOutboxReady()
        let retryDelay = try await store.nextPendingOutboxDelay()
        XCTAssertTrue(dueOutbox.isEmpty)
        XCTAssertNotNil(retryDelay)

        try await store.markRetrying(clientMsgId: clientMsgId)
        dueOutbox = try await store.pendingOutboxReady()
        XCTAssertEqual(dueOutbox.map(\.clientMsgId), [clientMsgId])

        try await store.markFailed(clientMsgId: clientMsgId, terminal: true)
        dueOutbox = try await store.pendingOutboxReady()
        XCTAssertTrue(dueOutbox.isEmpty, "Permanent failures must not loop")
        let terminalOutboxDelay = try await store.nextPendingOutboxDelay()
        XCTAssertNil(terminalOutboxDelay)
        try await store.markRetrying(clientMsgId: clientMsgId)
        dueOutbox = try await store.pendingOutboxReady()
        XCTAssertEqual(dueOutbox.map(\.clientMsgId), [clientMsgId], "Manual retry clears terminal state")

        try await store.markSent(
            SendMessageResponse(
                dialogId: dialogId,
                clientMsgId: clientMsgId,
                msgId: 1,
                senderPts: 2,
                duplicate: false,
                serverTs: "2026-07-09T00:00:00Z",
                text: "local first"
            ),
            senderAccountId: accountId
        )

        var messages = try await store.messages(dialogId: dialogId)
        XCTAssertEqual(messages.count, 1)
        let sentMsgId = messages[0].msgId
        let sentState = messages[0].localState
        XCTAssertEqual(sentMsgId, 1)
        XCTAssertEqual(sentState, "sent")
        dueOutbox = try await store.pendingOutboxReady()
        XCTAssertTrue(dueOutbox.isEmpty)

        let remote = CloudMessage(
            dialogId: dialogId,
            msgId: 2,
            senderAccountId: peerId,
            clientMsgId: UUID().uuidString.lowercased(),
            kind: "text",
            text: "remote reply",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-09T00:00:01Z"
        )
        let update = CloudUpdate(
            pts: 3,
            ptsCount: 1,
            type: "message.new",
            dialogId: dialogId,
            dialogTitle: "Bob",
            message: remote,
            readerAccountId: nil,
            maxReadMsgId: nil
        )
        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: DifferenceResponse.State(pts: 3),
                updates: [update],
                hasMore: false
            ),
            accountId: accountId
        )
        let readUpdate = CloudUpdate(
            pts: 4,
            ptsCount: 1,
            type: "read.updated",
            dialogId: dialogId,
            dialogTitle: "Bob",
            message: nil,
            readerAccountId: peerId,
            maxReadMsgId: 1
        )
        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: DifferenceResponse.State(pts: 4),
                updates: [readUpdate],
                hasMore: false
            ),
            accountId: accountId
        )

        messages = try await store.messages(dialogId: dialogId)
        let texts = messages.map(\.text)
        let finalPts = try await store.loadPts(accountId: accountId)
        let latestDialogId = try await store.latestDialogId()
        let peerReadMsgId = try await store.maxPeerReadMsgId(dialogId: dialogId, excluding: accountId)
        XCTAssertEqual(texts, ["local first", "remote reply"])
        XCTAssertEqual(finalPts, 4)
        XCTAssertEqual(latestDialogId, dialogId)
        XCTAssertEqual(peerReadMsgId, 1)

        let dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(dialogs.map(\.title), ["Bob"])
        XCTAssertEqual(dialogs.map(\.lastText), ["remote reply"])
    }

    @MainActor
    func testDifferencePersistsDirectPeerTitle() async throws {
        let store = try makeStore()
        let accountId = "account-a"
        let dialogId = "dialog-incoming"

        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: DifferenceResponse.State(pts: 1),
                updates: [
                    CloudUpdate(
                        pts: 1,
                        ptsCount: 1,
                        type: "dialog.created",
                        dialogId: dialogId,
                        dialogTitle: "Bob",
                        message: nil,
                        readerAccountId: nil,
                        maxReadMsgId: nil
                    )
                ],
                hasMore: false
            ),
            accountId: accountId
        )

        let dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(dialogs.map(\.dialogId), [dialogId])
        XCTAssertEqual(dialogs.map(\.title), ["Bob"])
    }

    @MainActor
    func testDialogCreatedAppliesRecipientPreferencesAtomically() async throws {
        let store = try makeStore()
        let accountId = "account-stranger-invite"
        let dialogId = "dialog-stranger-invite"
        let preferences = CloudDialogPreferences(
            dialogId: dialogId,
            pinned: false,
            pinnedAt: nil,
            muted: true,
            archived: true,
            updatedAt: "2026-07-25T10:00:00.000Z"
        )

        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: .init(pts: 1),
                updates: [
                    CloudUpdate(
                        pts: 1,
                        ptsCount: 1,
                        type: "dialog.created",
                        dialogId: dialogId,
                        dialogTitle: "Stranger invitation",
                        dialogType: "group",
                        message: nil,
                        readerAccountId: nil,
                        maxReadMsgId: nil,
                        preferences: preferences
                    )
                ],
                hasMore: false
            ),
            accountId: accountId
        )

        let dialogs = try await store.dialogs(accountId: accountId)
        let dialog = try XCTUnwrap(dialogs.first)
        XCTAssertEqual(dialog.dialogId, dialogId)
        XCTAssertTrue(dialog.isMuted)
        XCTAssertTrue(dialog.isArchived)
        XCTAssertEqual(dialog.notificationMode, "muted")
        let pts = try await store.loadPts(accountId: accountId)
        XCTAssertEqual(pts, 1)
    }

    @MainActor
    func testBootstrapPageDoesNotAdvancePtsUntilFinished() async throws {
        let store = try makeStore()
        let accountId = "account-a"
        let peerId = "account-b"
        let dialogId = "dialog-bootstrap"
        let bootstrapMessage = CloudMessage(
            dialogId: dialogId,
            msgId: 9,
            senderAccountId: peerId,
            clientMsgId: UUID().uuidString.lowercased(),
            kind: "text",
            text: "snapshot message",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-09T00:00:09Z"
        )
        let page = BootstrapDialogsPage(
            token: "bootstrap-token",
            state: BootstrapDialogsPage.State(pts: 44),
            dialogs: [
                BootstrapDialog(
                    dialogId: dialogId,
                    type: "direct",
                    title: "Alice",
                    lastMsgId: 9,
                    updatedAt: "2026-07-09T00:00:09Z",
                    members: [
                        BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 0),
                        BootstrapDialogMember(accountId: peerId, role: "member", lastReadMsgId: 0)
                    ],
                    profiles: [
                        CloudProfile(
                            accountId: peerId, firstName: "Alice", lastName: "", displayName: "Alice",
                            bio: "Initial bio", birthday: "1995-04-18", colorIndex: 2,
                            updatedAt: "2026-07-09T00:00:00Z"
                        )
                    ],
                    messages: [bootstrapMessage]
                )
            ],
            nextCursor: nil,
            hasMore: false
        )

        try await store.savePts(17, accountId: accountId)
        try await store.beginBootstrap(accountId: accountId)
        try await store.applyBootstrapPage(page)
        let bootstrapProgress = try await store.loadBootstrapState(accountId: accountId)
        let firstPageDialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(bootstrapProgress?.mode, .initial)
        XCTAssertEqual(
            firstPageDialogs.map(\.dialogId),
            [dialogId],
            "A new device publishes its first committed page immediately"
        )
        let olderMessage = CloudMessage(
            dialogId: dialogId,
            msgId: 3,
            senderAccountId: accountId,
            clientMsgId: UUID().uuidString.lowercased(),
            kind: "text",
            text: "older message",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-09T00:00:03Z"
        )
        try await store.applyHistoryPage(
            HistoryPageResponse(
                dialogId: dialogId,
                messages: [olderMessage],
                nextBeforeMsgId: nil,
                hasMore: false
            )
        )

        let messages = try await store.messages(dialogId: dialogId)
        let oldestMsgId = try await store.oldestServerMsgId(dialogId: dialogId)
        let ptsBeforeFinish = try await store.loadPts(accountId: accountId)
        XCTAssertEqual(messages.map(\.text), ["older message", "snapshot message"])
        XCTAssertEqual(oldestMsgId, 3)
        XCTAssertEqual(ptsBeforeFinish, 17, "Bootstrap keeps the last live cursor until its snapshot commits")

        try await store.finishBootstrap(accountId: accountId, pts: page.state.pts)
        let ptsAfterFinish = try await store.loadPts(accountId: accountId)
        let launchSnapshot = try await store.loadLaunchSnapshot(accountId: accountId)
        let latestDialogId = try await store.latestDialogId()
        let dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(ptsAfterFinish, 44)
        XCTAssertEqual(launchSnapshot.pts, 44)
        XCTAssertEqual(launchSnapshot.dialogs.map(\.dialogId), [dialogId])
        XCTAssertEqual(latestDialogId, dialogId)
        XCTAssertEqual(dialogs.first?.title, "Alice")
        XCTAssertEqual(dialogs.first?.lastText, "snapshot message")
        XCTAssertEqual(dialogs.first?.peerBio, "Initial bio")
        XCTAssertEqual(dialogs.first?.peerBirthday, "1995-04-18")
        XCTAssertEqual(dialogs.first?.peerColorIndex, 2)

        let profileUpdate = CloudUpdate(
            pts: 45, ptsCount: 1, type: "profile.updated", dialogId: nil,
            dialogTitle: nil, message: nil, readerAccountId: nil, maxReadMsgId: nil,
            subjectAccountId: peerId, firstName: "Alicia", lastName: "Karimova",
            displayName: "Alicia Karimova", bio: "Updated everywhere",
            birthday: "1996-05-19", colorIndex: 6,
            profileUpdatedAt: "2026-07-16T10:00:00Z", sharedDialogIds: [dialogId]
        )
        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference", state: .init(pts: 45),
                updates: [profileUpdate], hasMore: false
            ),
            accountId: accountId
        )
        let refreshed = try await store.dialogs(accountId: accountId).first
        XCTAssertEqual(refreshed?.title, "Alicia Karimova")
        XCTAssertEqual(refreshed?.peerBio, "Updated everywhere")
        XCTAssertEqual(refreshed?.peerBirthday, "1996-05-19")
        XCTAssertEqual(refreshed?.peerColorIndex, 6)
    }

    @MainActor
    func testFreshReplicaBootstrapPersistsInitializationAndAuthoritativeUnreadCount() async throws {
        let store = try makeStore()
        let accountId = "account-fresh"
        let peerId = "account-peer"
        let dialogId = "dialog-sparse-unread"
        let initializedBeforeBootstrap = try await store.isReplicaInitialized(accountId: accountId)
        XCTAssertFalse(initializedBeforeBootstrap)

        let recent = CloudMessage(
            dialogId: dialogId,
            msgId: 100,
            senderAccountId: peerId,
            clientMsgId: "bootstrap-recent-100",
            kind: "text",
            text: "recent",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-16T10:01:40Z"
        )
        let page = BootstrapDialogsPage(
            token: "fresh-token",
            state: .init(pts: 90),
            dialogs: [
                BootstrapDialog(
                    dialogId: dialogId,
                    type: "direct",
                    title: "Peer",
                    lastMsgId: 100,
                    updatedAt: "2026-07-16T10:01:40Z",
                    unreadCount: 37,
                    members: [
                        .init(accountId: accountId, role: "member", lastReadMsgId: 20),
                        .init(accountId: peerId, role: "member", lastReadMsgId: 0),
                    ],
                    messages: [recent]
                )
            ],
            nextCursor: nil,
            hasMore: false
        )

        try await store.beginBootstrap(
            accountId: accountId,
            token: page.token,
            snapshotPts: page.state.pts,
            mode: .initial
        )
        try await store.applyBootstrapPage(page)
        let firstPageUnread = try await store.dialogs(accountId: accountId).first?.unreadCount
        let initializedAfterFirstPage = try await store.isReplicaInitialized(accountId: accountId)
        XCTAssertEqual(firstPageUnread, 37)
        XCTAssertFalse(initializedAfterFirstPage)

        // Filling a sparse historical page must not replace the server's exact count with the
        // number of rows that happen to be cached locally.
        try await store.applyHistoryPage(
            .init(
                dialogId: dialogId,
                messages: [
                    CloudMessage(
                        dialogId: dialogId,
                        msgId: 95,
                        senderAccountId: peerId,
                        clientMsgId: "hydrated-95",
                        kind: "text",
                        text: "hydrated",
                        editVersion: 0,
                        state: "visible",
                        serverTs: "2026-07-16T10:01:35Z"
                    )
                ],
                nextBeforeMsgId: 95,
                hasMore: true
            )
        )
        let unreadAfterHydration = try await store.dialogs(accountId: accountId).first?.unreadCount
        let prioritizedHydration = try await store.historyStatesReady(dialogIds: [dialogId])
        XCTAssertEqual(unreadAfterHydration, 37)
        XCTAssertEqual(prioritizedHydration.map(\.dialogId), [dialogId])

        try await store.finishBootstrap(accountId: accountId, pts: page.state.pts)
        let initializedAfterFinish = try await store.isReplicaInitialized(accountId: accountId)
        let unreadAfterFinish = try await store.dialogs(accountId: accountId).first?.unreadCount
        XCTAssertTrue(initializedAfterFinish)
        XCTAssertEqual(unreadAfterFinish, 37)

        try await store.markRead(
            dialogId: dialogId,
            accountId: accountId,
            maxReadMsgId: 96,
            exactUnreadCount: 4
        )
        let exactAcknowledgedUnread = try await store.dialogs(accountId: accountId).first?.unreadCount
        XCTAssertEqual(exactAcknowledgedUnread, 4)
    }

    @MainActor
    func testUnreadCountsOnlyVisiblePeerMessagesAfterReadPosition() async throws {
        let store = try makeStore()
        let accountId = "account-me"
        let peerId = "account-peer"
        let dialogId = "dialog-unread"

        try await store.upsertDialog(dialogId: dialogId, title: "Mehrona")
        try await store.saveMembers(dialogId: dialogId, members: [
            BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 0),
            BootstrapDialogMember(accountId: peerId, role: "member", lastReadMsgId: 0),
        ])

        let messages = [
            CloudMessage(
                dialogId: dialogId,
                msgId: 1,
                senderAccountId: peerId,
                clientMsgId: UUID().uuidString,
                kind: "text",
                text: "peer one",
                editVersion: 0,
                state: "visible",
                serverTs: "2026-07-12T10:00:00Z"
            ),
            CloudMessage(
                dialogId: dialogId,
                msgId: 2,
                senderAccountId: accountId,
                clientMsgId: UUID().uuidString,
                kind: "text",
                text: "my reply",
                editVersion: 0,
                state: "visible",
                serverTs: "2026-07-12T10:00:01Z"
            ),
            CloudMessage(
                dialogId: dialogId,
                msgId: 3,
                senderAccountId: peerId,
                clientMsgId: UUID().uuidString,
                kind: "text",
                text: "peer two",
                editVersion: 0,
                state: "visible",
                serverTs: "2026-07-12T10:00:02Z"
            ),
        ]

        for (index, message) in messages.enumerated() {
            try await store.applyDifference(
                DifferenceResponse(
                    kind: "difference",
                    state: DifferenceResponse.State(pts: Int64(index + 1)),
                    updates: [
                        CloudUpdate(
                            pts: Int64(index + 1),
                            ptsCount: 1,
                            type: "message.new",
                            dialogId: dialogId,
                            dialogTitle: "Mehrona",
                            message: message,
                            readerAccountId: nil,
                            maxReadMsgId: nil
                        )
                    ],
                    hasMore: false
                ),
                accountId: accountId
            )
        }

        var dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(dialogs.first?.unreadCount, 2, "The current user's own message must not count as unread")

        try await store.markRead(dialogId: dialogId, accountId: accountId, maxReadMsgId: 1)
        dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(dialogs.first?.unreadCount, 1)

        try await store.markRead(dialogId: dialogId, accountId: accountId, maxReadMsgId: 3)
        dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(dialogs.first?.unreadCount, 0)
    }

    @MainActor
    func testReplyEditAndDeletePersistAcrossLocalReplicaReloads() async throws {
        let store = try makeStore()
        let accountId = "account-me"
        let peerId = "account-peer"
        let dialogId = "dialog-actions"
        let originalClientId = UUID().uuidString
        let replyClientId = UUID().uuidString

        func update(_ pts: Int64, type: String, message: CloudMessage) -> DifferenceResponse {
            DifferenceResponse(
                kind: "difference",
                state: DifferenceResponse.State(pts: pts),
                updates: [CloudUpdate(
                    pts: pts,
                    ptsCount: 1,
                    type: type,
                    dialogId: dialogId,
                    dialogTitle: "Mehrona",
                    message: message,
                    readerAccountId: nil,
                    maxReadMsgId: nil
                )],
                hasMore: false
            )
        }

        let original = CloudMessage(
            dialogId: dialogId, msgId: 1, senderAccountId: peerId,
            clientMsgId: originalClientId, kind: "text", text: "before",
            editVersion: 0, state: "visible", serverTs: "2026-07-12T10:00:00Z"
        )
        let reply = CloudMessage(
            dialogId: dialogId, msgId: 2, senderAccountId: accountId,
            clientMsgId: replyClientId, kind: "text", text: "reply",
            replyToMsgId: 1, editVersion: 0, state: "visible", serverTs: "2026-07-12T10:00:01Z"
        )
        try await store.applyDifference(update(1, type: "message.new", message: original), accountId: accountId)
        try await store.applyDifference(update(2, type: "message.new", message: reply), accountId: accountId)

        let edited = CloudMessage(
            dialogId: dialogId, msgId: 1, senderAccountId: peerId,
            clientMsgId: originalClientId, kind: "text", text: "after",
            editVersion: 1, state: "visible", serverTs: "2026-07-12T10:00:00Z"
        )
        try await store.applyDifference(update(3, type: "message.edited", message: edited), accountId: accountId)

        let deleteMutationId = UUID().uuidString
        try await store.enqueueMessageMutation(
            clientMutationId: deleteMutationId,
            operation: "delete",
            dialogId: dialogId,
            msgId: 2
        )
        var dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(dialogs.first?.lastText, "after", "Pending deletion hides the latest message preview")
        XCTAssertEqual(dialogs.first?.lastState, "visible")

        let deletedReply = CloudMessage(
            dialogId: dialogId, msgId: 2, senderAccountId: accountId,
            clientMsgId: replyClientId, kind: "text", text: "",
            replyToMsgId: 1, editVersion: 0, state: "deleted_for_all", serverTs: "2026-07-12T10:00:01Z"
        )
        try await store.applyDifference(update(4, type: "message.deleted", message: deletedReply), accountId: accountId)
        try await store.completeMessageMutation(clientMutationId: deleteMutationId)

        let messages = try await store.messages(dialogId: dialogId)
        XCTAssertEqual(messages.map(\.text), ["after", ""])
        XCTAssertEqual(messages[0].editVersion, 1)
        XCTAssertEqual(messages[1].replyToMsgId, 1)
        XCTAssertEqual(messages[1].state, "deleted_for_all")
        let savedPts = try await store.loadPts(accountId: accountId)
        dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(savedPts, 4)
        XCTAssertEqual(dialogs.first?.lastText, "after")
        XCTAssertEqual(dialogs.first?.lastState, "visible")
    }

    @MainActor
    func testReactionsForwardProvenanceAndForwardOutboxPersistInEncryptedReplica() async throws {
        let store = try makeStore()
        let accountId = "account-me"
        let dialogId = "dialog-source"
        let targetDialogId = "dialog-target"
        let message = CloudMessage(
            dialogId: dialogId,
            msgId: 4,
            senderAccountId: "account-peer",
            clientMsgId: UUID().uuidString,
            kind: "text",
            text: "forward me",
            forwardedFromAccountId: "account-original",
            forwardedFromDialogId: "dialog-original",
            forwardedFromMsgId: 2,
            isForwarded: true,
            reactions: [
                CloudReaction(accountId: accountId, emoji: "❤️"),
                CloudReaction(accountId: "account-peer", emoji: "❤️"),
            ],
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-12T12:00:00Z"
        )
        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: DifferenceResponse.State(pts: 5),
                updates: [CloudUpdate(
                    pts: 5,
                    ptsCount: 1,
                    type: "reaction.updated",
                    dialogId: dialogId,
                    dialogTitle: "Peer",
                    message: message,
                    readerAccountId: nil,
                    maxReadMsgId: nil
                )],
                hasMore: false
            ),
            accountId: accountId
        )

        let storedMessages = try await store.messages(dialogId: dialogId)
        let stored = try XCTUnwrap(storedMessages.first)
        XCTAssertEqual(stored.forwardedFromAccountId, "account-original")
        XCTAssertEqual(stored.forwardedFromDialogId, "dialog-original")
        XCTAssertEqual(stored.forwardedFromMsgId, 2)
        XCTAssertTrue(stored.isForwarded)
        XCTAssertEqual(stored.reactions, message.reactions)

        let clientMsgId = UUID().uuidString.lowercased()
        _ = try await store.insertSending(
            dialogId: targetDialogId,
            clientMsgId: clientMsgId,
            text: stored.text,
            senderAccountId: accountId,
            forwardedFromAccountId: stored.senderAccountId,
            forwardedFromDialogId: dialogId,
            forwardedFromMsgId: stored.msgId
        )
        let pendingItems = try await store.pendingOutboxReady()
        let pending = try XCTUnwrap(pendingItems.first)
        XCTAssertEqual(pending.forwardedFromDialogId, dialogId)
        XCTAssertEqual(pending.forwardedFromMsgId, 4)
        let optimisticMessages = try await store.messages(dialogId: targetDialogId)
        let optimistic = try XCTUnwrap(optimisticMessages.first)
        XCTAssertEqual(optimistic.text, "forward me")
        XCTAssertEqual(optimistic.forwardedFromDialogId, dialogId)
        XCTAssertEqual(optimistic.forwardedFromMsgId, 4)
    }

    @MainActor
    func testExistingSQLCipherReplicaMigratesReplyAndEditColumnsWithoutDataLoss() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cloud.sqlite").path
        let key = Data("legacy-test-passphrase".utf8)

        do {
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try db.usePassphrase(key)
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            let legacy = try DatabaseQueue(path: path, configuration: configuration)
            try await legacy.write { db in
                try db.execute(sql: """
                CREATE TABLE messages (
                  local_id TEXT PRIMARY KEY,
                  dialog_id TEXT NOT NULL,
                  msg_id INTEGER,
                  client_msg_id TEXT NOT NULL UNIQUE,
                  sender_account_id TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  text TEXT NOT NULL,
                  state TEXT NOT NULL,
                  server_ts TEXT,
                  local_state TEXT NOT NULL
                );
                CREATE TABLE pending_outbox (
                  client_msg_id TEXT PRIMARY KEY,
                  dialog_id TEXT NOT NULL,
                  body TEXT NOT NULL,
                  retry_count INTEGER NOT NULL DEFAULT 0,
                  next_retry_at TEXT,
                  created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                INSERT INTO messages (
                  local_id, dialog_id, msg_id, client_msg_id, sender_account_id,
                  kind, text, state, server_ts, local_state
                ) VALUES (
                  'dialog-legacy:1', 'dialog-legacy', 1, 'legacy-client-id', 'account-peer',
                  'text', 'preserve me', 'visible', '2026-07-12T09:00:00Z', 'sent'
                );
                """)
            }
        }

        let store = try CloudLocalStore(path: path, key: key)
        let preserved = try await store.messages(dialogId: "dialog-legacy")
        XCTAssertEqual(preserved.first?.text, "preserve me")
        XCTAssertNil(preserved.first?.replyToMsgId)
        XCTAssertEqual(preserved.first?.editVersion, 0)

        _ = try await store.insertSending(
            dialogId: "dialog-legacy",
            clientMsgId: UUID().uuidString,
            text: "reply after upgrade",
            senderAccountId: "account-me",
            replyToMsgId: 1
        )
        let outbox = try await store.pendingOutboxReady()
        XCTAssertEqual(outbox.first?.replyToMsgId, 1)
    }

    func testDialogPreferenceMigrationSeedsLegacyMuteAndConvertsQueuedGroupMutation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cloud.sqlite").path
        let key = Data("legacy-dialog-preferences-key".utf8)
        let accountId = "account-legacy-preferences"
        let dialogId = "dialog-legacy-preferences"
        let mutationId = "33333333-3333-4333-8333-333333333333"

        do {
            let latest = try CloudLocalStore(path: path, key: key)
            try await latest.savePts(9, accountId: accountId)
            try await latest.upsertDialog(
                dialogId: dialogId,
                type: "group",
                title: "Legacy group",
                updatedAt: "2026-07-25T08:00:00.000Z"
            )
            try await latest.enqueueGroupMutation(
                dialogId: dialogId,
                operation: "notifications",
                payloadJSON: "{\"mode\":\"muted\"}",
                clientMutationId: mutationId
            )
        }

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.usePassphrase(key)
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        do {
            let v9 = try DatabaseQueue(path: path, configuration: configuration)
            try await v9.write { db in
                try db.execute(sql: """
                UPDATE dialogs
                SET notification_mode = 'muted'
                WHERE dialog_id = '\(dialogId)';
                CREATE TABLE pending_group_mutations_v9 (
                  client_mutation_id TEXT PRIMARY KEY,
                  dialog_id TEXT NOT NULL,
                  operation TEXT NOT NULL,
                  payload_json TEXT NOT NULL,
                  retry_count INTEGER NOT NULL DEFAULT 0,
                  next_retry_at TEXT,
                  last_error TEXT,
                  terminal INTEGER NOT NULL DEFAULT 0,
                  created_at TEXT NOT NULL
                );
                INSERT INTO pending_group_mutations_v9 (
                  client_mutation_id, dialog_id, operation, payload_json,
                  retry_count, next_retry_at, last_error, terminal, created_at
                )
                SELECT client_mutation_id, dialog_id, operation, payload_json,
                       retry_count, next_retry_at, last_error, terminal, created_at
                FROM pending_group_mutations;
                DROP TABLE pending_group_mutations;
                ALTER TABLE pending_group_mutations_v9 RENAME TO pending_group_mutations;
                CREATE INDEX pending_group_mutations_ready_idx
                  ON pending_group_mutations(terminal, next_retry_at, created_at);
                DROP TABLE pending_dialog_preference_mutations;
                DROP TABLE dialog_preferences;
                DROP TABLE local_mutation_sequence;
                DELETE FROM grdb_migrations
                WHERE identifier IN (
                  'v10-dialog-preferences',
                  'v11-ordered-preference-outbox'
                );
                """)
            }
        }

        let upgraded = try CloudLocalStore(path: path, key: key)
        let migratedDialog = try await upgraded.dialogs(accountId: accountId).first
        let dialog = try XCTUnwrap(migratedDialog)
        XCTAssertTrue(dialog.isMuted)
        XCTAssertEqual(dialog.notificationMode, "muted")
        let converted = try await upgraded.pendingDialogPreferencesReady(accountId: accountId)
        XCTAssertEqual(converted.map(\.clientMutationId), [mutationId])
        XCTAssertEqual(converted.first?.field, .muted)
        XCTAssertEqual(converted.first?.desiredValue, true)
        let legacyGroupMutations = try await upgraded.pendingGroupMutationsReady()
        XCTAssertTrue(legacyGroupMutations.isEmpty)
        let destructiveLogoutCount = try await upgraded.pendingDestructiveLogoutItemCount()
        XCTAssertEqual(destructiveLogoutCount, 1)

        let moved = try await upgraded.movePendingGroupMutesToLegacy(accountId: accountId)
        XCTAssertEqual(moved, 1)
        let pendingPreferences = try await upgraded.pendingDialogPreferencesReady(
            accountId: accountId
        )
        XCTAssertTrue(
            pendingPreferences.isEmpty,
            "With the capability off, the preference lane must not remain immediately due"
        )
        let legacyFallback = try await upgraded.pendingGroupMutationsReady()
        XCTAssertEqual(legacyFallback.map(\.clientMutationId), [mutationId])
        XCTAssertEqual(legacyFallback.first?.operation, "notifications")
        XCTAssertEqual(legacyFallback.first?.payloadJSON, #"{"mode":"muted"}"#)
        let fallbackDialog = try await upgraded.dialogs(accountId: accountId).first
        XCTAssertTrue(try XCTUnwrap(fallbackDialog).isMuted)

        try await upgraded.clearAccount(accountId: accountId)
        let dialogsAfterClear = try await upgraded.dialogs(accountId: accountId)
        let preferencesAfterClear = try await upgraded.pendingDialogPreferencesReady(
            accountId: accountId
        )
        XCTAssertTrue(dialogsAfterClear.isEmpty)
        XCTAssertTrue(preferencesAfterClear.isEmpty)
    }

    func testMediaCacheEncryptsPendingFilesAndSurvivesCacheReset() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = try EncryptedMediaCache(
            root: directory,
            keyData: Data(repeating: 0x2a, count: 32),
            limitBytes: 2 * 1024 * 1024
        )
        let plaintext = Data("a private media payload that must never appear on disk".utf8)
        let thumbnail = Data("private thumbnail".utf8)

        let prepared = try await cache.prepareUpload(
            data: plaintext, kind: "file", contentType: "application/octet-stream",
            fileName: "notes.bin", thumbnail: thumbnail
        )
        let encrypted = try Data(contentsOf: URL(filePath: prepared.encryptedSourcePath))
        XCTAssertNotEqual(encrypted, plaintext)
        XCTAssertNil(encrypted.range(of: plaintext))
        let decrypted = try await cache.preparedData(transferId: prepared.transferId)
        let decryptedThumbnail = try await cache.preparedThumbnail(transferId: prepared.transferId)
        XCTAssertEqual(decrypted, plaintext)
        XCTAssertEqual(decryptedThumbnail, thumbnail)

        let downloadedMediaId = UUID().uuidString.lowercased()
        try await cache.storeDownloadChunk(plaintext, mediaId: downloadedMediaId, offset: 0)
        try await cache.storeThumbnail(thumbnail, mediaId: downloadedMediaId)
        let preview = try await cache.createTemporaryPreview(plaintext, fileExtension: "../../unsafe")
        XCTAssertEqual(preview.pathExtension, "bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path))
        let usageBeforeClear = try await cache.downloadedUsageBytes()
        XCTAssertGreaterThan(usageBeforeClear, 0)
        try await cache.clearDownloaded()
        let retainedUpload = try await cache.preparedData(transferId: prepared.transferId)
        let clearedOffset = try await cache.contiguousDownloadOffset(mediaId: downloadedMediaId)
        let usageAfterClear = try await cache.downloadedUsageBytes()
        XCTAssertEqual(retainedUpload, plaintext)
        XCTAssertEqual(clearedOffset, 0)
        XCTAssertEqual(usageAfterClear, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path))

        try await cache.clearAll()
        let second = try await cache.prepareUpload(
            data: plaintext, kind: "voice", contentType: "audio/mp4",
            fileName: "voice.m4a", durationMs: 900
        )
        let decryptedAfterReset = try await cache.preparedData(transferId: second.transferId)
        XCTAssertEqual(decryptedAfterReset, plaintext)
    }

    func testCachedByteRangeAssemblesChunksAndDetectsGaps() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = try EncryptedMediaCache(
            root: directory, keyData: Data(repeating: 0x2a, count: 32), limitBytes: 4 * 1024 * 1024
        )

        // 15 distinct bytes stored as three 5-byte chunks, written out of order.
        let mediaId = UUID().uuidString.lowercased()
        try await cache.storeDownloadChunk(Data("ABCDE".utf8), mediaId: mediaId, offset: 10)
        try await cache.storeDownloadChunk(Data("01234".utf8), mediaId: mediaId, offset: 0)
        try await cache.storeDownloadChunk(Data("56789".utf8), mediaId: mediaId, offset: 5)

        let wholeData = try await cache.cachedByteRange(mediaId: mediaId, offset: 0, length: 15)
        XCTAssertEqual(String(decoding: try XCTUnwrap(wholeData), as: UTF8.self), "0123456789ABCDE")
        let straddleData = try await cache.cachedByteRange(mediaId: mediaId, offset: 3, length: 5)
        XCTAssertEqual(String(decoding: try XCTUnwrap(straddleData), as: UTF8.self), "34567")
        let tailData = try await cache.cachedByteRange(mediaId: mediaId, offset: 12, length: 3)
        XCTAssertEqual(String(decoding: try XCTUnwrap(tailData), as: UTF8.self), "CDE")
        let coverageEnd = try await cache.coverageEnd(mediaId: mediaId, from: 0)
        XCTAssertEqual(coverageEnd, 15)

        // A missing middle chunk breaks coverage across the gap but not ranges that avoid it.
        let gapMedia = UUID().uuidString.lowercased()
        try await cache.storeDownloadChunk(Data("01234".utf8), mediaId: gapMedia, offset: 0)
        try await cache.storeDownloadChunk(Data("ABCDE".utf8), mediaId: gapMedia, offset: 10)
        let coveredData = try await cache.cachedByteRange(mediaId: gapMedia, offset: 0, length: 5)
        XCTAssertEqual(String(decoding: try XCTUnwrap(coveredData), as: UTF8.self), "01234")
        let acrossGap = try await cache.cachedByteRange(mediaId: gapMedia, offset: 0, length: 8)
        XCTAssertNil(acrossGap)
        let afterGapData = try await cache.cachedByteRange(mediaId: gapMedia, offset: 10, length: 5)
        XCTAssertEqual(String(decoding: try XCTUnwrap(afterGapData), as: UTF8.self), "ABCDE")
        let gapCoverageFromStart = try await cache.coverageEnd(mediaId: gapMedia, from: 0)
        let gapCoverageAfter = try await cache.coverageEnd(mediaId: gapMedia, from: 10)
        XCTAssertEqual(gapCoverageFromStart, 5)
        XCTAssertEqual(gapCoverageAfter, 15)
    }

    func testMediaCacheRefusesToEvictPendingUploadsForNewSelections() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = try EncryptedMediaCache(
            root: directory,
            keyData: Data(repeating: 0x31, count: 32),
            limitBytes: 300
        )
        _ = try await cache.prepareUpload(
            data: Data(repeating: 0x11, count: 100), kind: "file",
            contentType: "application/octet-stream", fileName: "first.bin"
        )

        do {
            _ = try await cache.prepareUpload(
                data: Data(repeating: 0x22, count: 100), kind: "file",
                contentType: "application/octet-stream", fileName: "second.bin"
            )
            XCTFail("Expected the protected pending upload to consume the local quota")
        } catch let error as MediaCacheError {
            guard case .localQuotaExceeded = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testMediaCacheInvalidatesCorruptDownloadsAndRestartsFromZero() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = try EncryptedMediaCache(
            root: directory, keyData: Data(repeating: 0x52, count: 32), limitBytes: 1_000_000
        )
        let mediaId = UUID().uuidString.lowercased()
        try await cache.storeDownloadChunk(Data("valid chunk".utf8), mediaId: mediaId, offset: 0)
        let encryptedChunk = directory.appending(path: "downloads/\(mediaId)/0.tojchunk")
        try Data("corrupt".utf8).write(to: encryptedChunk, options: .atomic)

        let restartedOffset = try await cache.contiguousDownloadOffset(mediaId: mediaId)
        XCTAssertEqual(restartedOffset, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: encryptedChunk.path))
    }

    func testMediaDownloadRejectsInconsistentServerOffsets() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let mediaId = "11111111-1111-1111-1111-111111111111"
        CloudAPIMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: [
                    "content-type": "application/octet-stream",
                    "x-media-next-offset": "999",
                    "x-media-total-size": "999",
                ]
            ))
            return (response, Data("tiny".utf8))
        }
        defer { CloudAPIMockURLProtocol.handler = nil }
        let api = CloudMediaAPI(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await api.downloadChunk(mediaId: mediaId, offset: 0, token: "session-token")
            XCTFail("A malformed offset contract must not be cached")
        } catch let error as CloudAPIError {
            XCTAssertEqual(error.status, -1)
        }
    }

    func testMediaTransferPersistsAcrossBootstrapAndUsesProvisionalMedia() async throws {
        let store = try makeStore()
        let transferId = UUID().uuidString.lowercased()
        let clientMsgId = UUID().uuidString.lowercased()
        let prepared = PreparedMediaUpload(
            transferId: transferId, kind: "photo", contentType: "image/jpeg",
            fileName: "photo.jpg", byteSize: 123, sha256: String(repeating: "a", count: 64),
            durationMs: nil, width: 20, height: 10,
            encryptedSourcePath: "/private/pending.tojmedia",
            encryptedThumbnailPath: "/private/pending.thumb"
        )
        try await store.insertMediaTransfer(
            prepared: prepared, dialogId: "dialog-media", clientMsgId: clientMsgId,
            caption: "caption", replyToMsgId: nil
        )
        let storedTransfer = try await store.mediaTransfer(id: transferId)
        let transfer = try XCTUnwrap(storedTransfer)
        XCTAssertEqual(transfer.media.id, "pending:\(transferId)")
        try await store.insertSendingMedia(transfer, senderAccountId: "account-me")
        let optimisticMessages = try await store.messages(dialogId: "dialog-media")
        let optimisticMedia = optimisticMessages.first?.media
        let expectedMedia = transfer.media
        XCTAssertEqual(optimisticMedia, expectedMedia)

        try await store.markMediaTerminal(clientMsgId: clientMsgId, error: "File is too large")
        let terminalTransfers = try await store.mediaTransfers(dialogId: "dialog-media")
        let terminalTransfer = try XCTUnwrap(terminalTransfers.first)
        XCTAssertTrue(terminalTransfer.terminal)
        XCTAssertEqual(terminalTransfer.lastError, "File is too large")
        let terminalMediaDelay = try await store.nextMediaTransferDelay()
        XCTAssertNil(terminalMediaDelay)
        try await store.markMediaRetrying(clientMsgId: clientMsgId)
        let retriedTransfer = try await store.mediaTransfer(id: transferId)
        XCTAssertFalse(try XCTUnwrap(retriedTransfer).terminal)

        try await store.beginBootstrap(accountId: "account-me")
        let retained = try await store.mediaTransfer(id: transferId)
        XCTAssertNotNil(retained)
        try await store.markMediaRetrying(clientMsgId: clientMsgId)
        try await store.updateMediaTransfer(
            transferId: transferId, mediaId: "11111111-1111-1111-1111-111111111111",
            uploadOffset: 123, state: "ready_to_send", error: nil
        )
        let storedReady = try await store.mediaTransfer(id: transferId)
        let ready = try XCTUnwrap(storedReady)
        XCTAssertEqual(ready.media.id, "11111111-1111-1111-1111-111111111111")
        try await store.resetMediaUpload(transferId: transferId)
        let reset = try await store.mediaTransfer(id: transferId)
        XCTAssertEqual(reset?.media.id, "pending:\(transferId)")
        XCTAssertEqual(reset?.uploadOffset, 0)
        try await store.completeMediaTransfer(transferId: transferId)
        let completed = try await store.mediaTransfer(id: transferId)
        XCTAssertNil(completed)
    }

    func testProfilePhotoMutationAndPreparedTransferSurviveProcessDeathAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "profile-photo.sqlite").path
        let key = Data("profile-photo-recovery-key".utf8)
        let accountId = "account-profile-photo"
        let transferId = UUID().uuidString.lowercased()
        let prepared = PreparedMediaUpload(
            transferId: transferId, kind: "photo", contentType: "image/jpeg",
            fileName: "profile-photo.jpg", byteSize: 1_024,
            sha256: String(repeating: "c", count: 64), durationMs: nil,
            width: 1_024, height: 768,
            encryptedSourcePath: "/private/profile-photo.tojmedia",
            encryptedThumbnailPath: "/private/profile-photo.thumb"
        )
        let mutationId: String
        do {
            let store = try CloudLocalStore(path: path, key: key)
            let mutation = try await store.stageProfilePhotoSet(
                accountId: accountId,
                prepared: prepared,
                basePhotoRevision: 7
            )
            mutationId = mutation.clientMutationId
            XCTAssertEqual(mutation.state, "pending")
            let stagedTransfer = try await store.mediaTransfer(id: transferId)
            XCTAssertEqual(stagedTransfer?.purpose, "profile_photo")
        }

        let reopened = try CloudLocalStore(path: path, key: key)
        let recoveredValue = try await reopened.pendingProfilePhotoMutation(accountId: accountId)
        let recovered = try XCTUnwrap(recoveredValue)
        XCTAssertEqual(recovered.clientMutationId, mutationId)
        XCTAssertEqual(recovered.basePhotoRevision, 7)
        XCTAssertEqual(recovered.transferId, transferId)
        let reopenedTransfer = try await reopened.mediaTransfer(id: transferId)
        XCTAssertNotNil(reopenedTransfer)

        let mediaId = UUID().uuidString.lowercased()
        try await reopened.updateMediaTransfer(
            transferId: transferId, mediaId: mediaId, uploadOffset: 1_024,
            state: "ready_to_send", error: nil
        )
        try await reopened.markProfilePhotoUploaded(transferId: transferId, mediaId: mediaId)
        let readyValue = try await reopened.readyProfilePhotoMutation(accountId: accountId)
        let ready = try XCTUnwrap(readyValue)
        XCTAssertEqual(ready.mediaId, mediaId)

        let canonicalMedia = CloudMedia(
            id: mediaId, kind: "photo", contentType: "image/jpeg",
            fileName: "profile-photo.jpg", byteSize: 1_024,
            durationMs: nil, width: 1_024, height: 768, hasThumbnail: true
        )
        let profile = CloudProfile(
            accountId: accountId, firstName: "A", lastName: "B", displayName: "A B",
            bio: "", birthday: nil, colorIndex: 2, photo: canonicalMedia,
            photoRevision: 8, updatedAt: "2026-08-11T10:00:00.000Z"
        )
        _ = try await reopened.completeProfilePhotoMutation(
            accountId: accountId,
            clientMutationId: mutationId,
            profile: profile
        )
        let completedMutation = try await reopened.pendingProfilePhotoMutation(accountId: accountId)
        let completedTransfer = try await reopened.mediaTransfer(id: transferId)
        let completedProfile = try await reopened.profile(accountId: accountId)
        XCTAssertNil(completedMutation)
        XCTAssertNil(completedTransfer)
        XCTAssertEqual(completedProfile?.photoRevision, 8)
        XCTAssertEqual(completedProfile?.photo, canonicalMedia)
    }

    func testProfilePhotoConflictPreservesMineAndExplicitRebaseCreatesNewIntent() async throws {
        let store = try makeStore()
        let accountId = "account-profile-conflict"
        let prepared = PreparedMediaUpload(
            transferId: UUID().uuidString.lowercased(), kind: "photo",
            contentType: "image/jpeg", fileName: "mine.jpg", byteSize: 64,
            sha256: String(repeating: "d", count: 64), durationMs: nil,
            width: 64, height: 64, encryptedSourcePath: "/private/mine.tojmedia",
            encryptedThumbnailPath: nil
        )
        let original = try await store.stageProfilePhotoSet(
            accountId: accountId, prepared: prepared, basePhotoRevision: 3
        )
        try await store.markProfilePhotoUploaded(
            transferId: prepared.transferId,
            mediaId: UUID().uuidString.lowercased()
        )
        _ = try await store.failProfilePhotoMutation(
            accountId: accountId,
            clientMutationId: original.clientMutationId,
            error: "changed elsewhere",
            retryAfter: nil,
            conflict: true
        )
        let conflictedValue = try await store.pendingProfilePhotoMutation(accountId: accountId)
        let conflicted = try XCTUnwrap(conflictedValue)
        XCTAssertEqual(conflicted.state, "conflict")
        XCTAssertEqual(conflicted.transferId, prepared.transferId)

        _ = try await store.rebaseProfilePhotoMutation(
            accountId: accountId,
            clientMutationId: original.clientMutationId,
            baseRevision: 9
        )
        let rebasedValue = try await store.readyProfilePhotoMutation(accountId: accountId)
        let rebased = try XCTUnwrap(rebasedValue)
        XCTAssertNotEqual(rebased.clientMutationId, original.clientMutationId)
        XCTAssertEqual(rebased.basePhotoRevision, 9)
        XCTAssertEqual(rebased.transferId, prepared.transferId)
        XCTAssertNil(rebased.lastError)

        let rebasedTransferValue = try await store.mediaTransfer(id: prepared.transferId)
        let rebasedTransfer = try XCTUnwrap(rebasedTransferValue)
        try await store.markMediaTerminal(
            clientMsgId: rebasedTransfer.clientMsgId,
            error: "invalid photo"
        )
        _ = try await store.failProfilePhotoMutation(
            accountId: accountId,
            clientMutationId: rebased.clientMutationId,
            error: "invalid photo",
            retryAfter: nil,
            terminal: true
        )
        _ = try await store.retryProfilePhotoMutation(
            accountId: accountId,
            clientMutationId: rebased.clientMutationId
        )
        let retriedMutation = try await store.pendingProfilePhotoMutation(accountId: accountId)
        XCTAssertFalse(try XCTUnwrap(retriedMutation).terminal)
        let retriedTransfer = try await store.mediaTransfer(id: prepared.transferId)
        XCTAssertFalse(try XCTUnwrap(retriedTransfer).terminal)
    }

    func testFailedProfilePhotoRemovalRetryReturnsDirectlyToCommitLane() async throws {
        let store = try makeStore()
        let accountId = "account-profile-removal-retry"
        let removal = try await store.stageProfilePhotoRemoval(
            accountId: accountId,
            basePhotoRevision: 4
        )
        _ = try await store.failProfilePhotoMutation(
            accountId: accountId,
            clientMutationId: removal.clientMutationId,
            error: "temporary outage",
            retryAfter: nil,
            terminal: true
        )
        _ = try await store.retryProfilePhotoMutation(
            accountId: accountId,
            clientMutationId: removal.clientMutationId
        )
        let readyValue = try await store.readyProfilePhotoMutation(accountId: accountId)
        let ready = try XCTUnwrap(readyValue)
        XCTAssertEqual(ready.operation, "remove")
        XCTAssertEqual(ready.state, "ready_to_commit")
        XCTAssertNil(ready.mediaId)
        XCTAssertFalse(ready.terminal)
    }

    func testProfileTextAndPhotoClocksMergeWithoutCrossClobbering() async throws {
        let store = try makeStore()
        let accountId = "account-independent-profile-clocks"
        let firstPhoto = CloudMedia(
            id: UUID().uuidString.lowercased(), kind: "photo", contentType: "image/jpeg",
            fileName: "first.jpg", byteSize: 10, durationMs: nil,
            width: 10, height: 10, hasThumbnail: true
        )
        let newerPhoto = CloudMedia(
            id: UUID().uuidString.lowercased(), kind: "photo", contentType: "image/jpeg",
            fileName: "newer.jpg", byteSize: 11, durationMs: nil,
            width: 11, height: 11, hasThumbnail: true
        )
        try await store.saveProfile(CloudProfile(
            accountId: accountId, firstName: "Newest text", lastName: "One",
            displayName: "Newest text One", bio: "new bio", birthday: nil, colorIndex: 1,
            photo: firstPhoto, photoRevision: 2, updatedAt: "2026-08-11T12:00:00.000Z"
        ))
        try await store.saveProfile(CloudProfile(
            accountId: accountId, firstName: "Older text", lastName: "Two",
            displayName: "Older text Two", bio: "old bio", birthday: nil, colorIndex: 2,
            photo: newerPhoto, photoRevision: 3, updatedAt: "2026-08-11T11:00:00.000Z"
        ))
        let firstMerged = try await store.profile(accountId: accountId)
        var merged = try XCTUnwrap(firstMerged)
        XCTAssertEqual(merged.displayName, "Newest text One")
        XCTAssertEqual(merged.photo, newerPhoto)
        XCTAssertEqual(merged.photoRevision, 3)

        try await store.saveProfile(CloudProfile(
            accountId: accountId, firstName: "Newest text", lastName: "Three",
            displayName: "Newest text Three", bio: "latest bio", birthday: nil, colorIndex: 3,
            photo: firstPhoto, photoRevision: 2, updatedAt: "2026-08-11T13:00:00.000Z"
        ))
        let secondMerged = try await store.profile(accountId: accountId)
        merged = try XCTUnwrap(secondMerged)
        XCTAssertEqual(merged.displayName, "Newest text Three")
        XCTAssertEqual(merged.photo, newerPhoto)
        XCTAssertEqual(merged.photoRevision, 3)
    }

    func testExactPhotoRollbackCannotDeleteANewerIntent() async throws {
        let store = try makeStore()
        let accountId = "account-profile-exact-rollback"
        let old = try await store.stageProfilePhotoRemoval(
            accountId: accountId,
            basePhotoRevision: 1
        )
        let newer = try await store.stageProfilePhotoRemoval(
            accountId: accountId,
            basePhotoRevision: 2
        )
        let discardedOld = try await store.discardProfilePhotoMutation(
            accountId: accountId,
            clientMutationId: old.clientMutationId
        )
        XCTAssertFalse(discardedOld)
        let remaining = try await store.pendingProfilePhotoMutation(accountId: accountId)
        XCTAssertEqual(
            remaining?.clientMutationId,
            newer.clientMutationId
        )
    }

    func testDelayedPhotoCompletionPreservesANewerIntent() async throws {
        let store = try makeStore()
        let accountId = "account-profile-delayed-completion"
        let older = try await store.stageProfilePhotoRemoval(
            accountId: accountId,
            basePhotoRevision: 2
        )
        let newer = try await store.stageProfilePhotoRemoval(
            accountId: accountId,
            basePhotoRevision: 3
        )
        let canonical = CloudProfile(
            accountId: accountId, firstName: "Canonical", lastName: "Profile",
            displayName: "Canonical Profile", bio: "", birthday: nil, colorIndex: 2,
            photo: nil, photoRevision: 3, updatedAt: "2026-08-11T12:00:00.000Z"
        )

        let completed = try await store.completeProfilePhotoMutation(
            accountId: accountId,
            clientMutationId: older.clientMutationId,
            profile: canonical
        )

        XCTAssertFalse(completed)
        let remaining = try await store.pendingProfilePhotoMutation(accountId: accountId)
        let storedCanonical = try await store.profile(accountId: accountId)
        XCTAssertEqual(remaining?.clientMutationId, newer.clientMutationId)
        XCTAssertEqual(storedCanonical, canonical)
    }

    func testInFlightPhotoCommitCannotConsumeANewerStagedIntent() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let config = CloudConfig(
            baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))
        )
        let api = CloudAPI(config: config, session: session)
        let mediaEngine = CloudMediaTransferEngine(config: config, session: session)
        let store = try makeStore()
        let accountId = "account-profile-in-flight"
        let cloudSession = CloudSession(
            accountId: accountId,
            deviceId: "device-profile-in-flight",
            token: "session-token"
        )
        let gate = LockedGate()
        CloudAPIMockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/cloud/v1/profile/photo")
            gate.signalStarted()
            gate.waitForRelease()
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )),
                Data("""
                {"profile":{"accountId":"\(accountId)","firstName":"Canonical",
                 "lastName":"Profile","displayName":"Canonical Profile","bio":"",
                 "birthday":null,"colorIndex":2,"photo":null,"photoRevision":1,
                 "updatedAt":"2026-08-11T12:00:00.000Z"},
                 "committedPhotoRevision":1,"duplicate":false}
                """.utf8)
            )
        }
        defer {
            gate.release()
            CloudAPIMockURLProtocol.handler = nil
        }

        let coordinator = ProfilePhotoSyncCoordinator(api: api, mediaEngine: mediaEngine)
        await coordinator.configure(store: store, session: cloudSession, enabled: true)
        _ = try await coordinator.stageRemoval(baseRevision: 0)
        let olderCommit = Task { await coordinator.commitReady() }
        XCTAssertTrue(gate.waitUntilStarted())

        let newer = try await coordinator.stageRemoval(baseRevision: 1)
        if case .idle = await coordinator.commitReady() {
            // The mutation lane is intentionally serialized while the older request is unresolved.
        } else {
            XCTFail("A second profile-photo commit must not run concurrently")
        }
        gate.release()

        guard case let .superseded(profile) = await olderCommit.value else {
            return XCTFail("The delayed response should be canonical without consuming the newer intent")
        }
        XCTAssertEqual(profile.photoRevision, 1)
        let remaining = try await store.pendingProfilePhotoMutation(accountId: accountId)
        XCTAssertEqual(remaining?.clientMutationId, newer.clientMutationId)
    }

    func testRevokedLastSharedDialogPurgesProfileThumbnailButAnotherDialogProtectsIt() async throws {
        let store = try makeStore()
        let accountId = "account-me"
        let peerId = "account-peer"
        let firstDialog = "dialog-profile-first"
        let secondDialog = "dialog-profile-second"
        let media = CloudMedia(
            id: UUID().uuidString.lowercased(), kind: "photo", contentType: "image/jpeg",
            fileName: "peer.jpg", byteSize: 128, durationMs: nil,
            width: 64, height: 64, hasThumbnail: true
        )
        let profile = CloudProfile(
            accountId: peerId, firstName: "Peer", lastName: "", displayName: "Peer",
            bio: "", birthday: nil, colorIndex: 0, photo: media,
            photoRevision: 1, updatedAt: "2026-08-11T10:00:00.000Z"
        )
        for dialogId in [firstDialog, secondDialog] {
            try await store.upsertDialog(dialogId: dialogId, type: "direct", title: "Peer")
            try await store.saveMembers(dialogId: dialogId, members: [
                BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 0),
                BootstrapDialogMember(accountId: peerId, role: "member", lastReadMsgId: 0),
            ])
        }
        try await store.saveProfile(profile)

        try await store.revokeGroupAccess(dialogId: firstDialog, reason: "access revoked")
        let firstJobs = try await store.pendingAccessPurgeJobs()
        let firstJob = try XCTUnwrap(firstJobs.first)
        XCTAssertFalse(firstJob.purgeMediaIds.contains(media.id))
        try await store.markAccessPurgeFilesDeleted(id: firstJob.id)
        try await store.finalizeAccessPurge(id: firstJob.id)

        try await store.revokeGroupAccess(dialogId: secondDialog, reason: "access revoked")
        let secondJobs = try await store.pendingAccessPurgeJobs()
        let secondJob = try XCTUnwrap(secondJobs.first)
        XCTAssertTrue(secondJob.allMediaIds.contains(media.id))
        XCTAssertTrue(secondJob.purgeMediaIds.contains(media.id))
    }

    func testCancellingMediaTransferRemovesDurableRetryAndOptimisticBubble() async throws {
        let store = try makeStore()
        let transferId = UUID().uuidString.lowercased()
        let clientMsgId = UUID().uuidString.lowercased()
        let prepared = PreparedMediaUpload(
            transferId: transferId, kind: "file", contentType: "application/octet-stream",
            fileName: "cancel.bin", byteSize: 12, sha256: String(repeating: "b", count: 64),
            durationMs: nil, width: nil, height: nil,
            encryptedSourcePath: "/private/cancel.tojmedia", encryptedThumbnailPath: nil
        )
        try await store.insertMediaTransfer(
            prepared: prepared, dialogId: "dialog-cancel", clientMsgId: clientMsgId,
            caption: "wrong file", replyToMsgId: nil
        )
        let storedTransfer = try await store.mediaTransfer(id: transferId)
        let transfer = try XCTUnwrap(storedTransfer)
        try await store.insertSendingMedia(transfer, senderAccountId: "account-me")

        try await store.cancelMediaTransfer(transferId: transferId, clientMsgId: clientMsgId)

        let cancelledTransfer = try await store.mediaTransfer(id: transferId)
        let remainingMessages = try await store.messages(dialogId: "dialog-cancel")
        let nextRetry = try await store.nextMediaTransferDelay()
        XCTAssertNil(cancelledTransfer)
        XCTAssertTrue(remainingMessages.isEmpty)
        XCTAssertNil(nextRetry)
    }

    func testMediaTransferEngineResumesFromServerOffsetAndPersistsEveryChunk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = try EncryptedMediaCache(
            root: directory.appending(path: "cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x42, count: 32), limitBytes: 1_000_000
        )
        let payload = Data("abcdef".utf8)
        let prepared = try await cache.prepareUpload(
            data: payload, kind: "file", contentType: "application/octet-stream", fileName: "resume.bin"
        )
        let store = try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            key: Data("media-transfer-test-key".utf8)
        )
        let clientMsgId = UUID().uuidString.lowercased()
        let mediaId = "11111111-1111-1111-1111-111111111111"
        try await store.insertMediaTransfer(
            prepared: prepared, dialogId: "dialog-resume", clientMsgId: clientMsgId,
            caption: "", replyToMsgId: nil
        )
        try await store.updateMediaTransfer(
            transferId: prepared.transferId, mediaId: mediaId,
            uploadOffset: 0, state: "uploading", error: nil
        )
        let stored = try await store.mediaTransfer(id: prepared.transferId)
        let transfer = try XCTUnwrap(stored)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let recorder = LockedMediaRequests()
        CloudAPIMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["content-type": "application/json"]
            ))
            if request.httpMethod == "GET" {
                return (response, Data("""
                {"mediaId":"\(mediaId)","uploadOffset":2,"byteSize":6,"status":"uploading",
                 "expiresAt":"2026-07-14T00:00:00Z","chunkSize":2}
                """.utf8))
            }
            if request.url?.path.hasSuffix("/chunks") == true {
                let offset = try XCTUnwrap(request.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init))
                let bytes = try XCTUnwrap(CloudAPIMockURLProtocol.bodyData(from: request))
                recorder.append(offset: offset, bytes: bytes)
                return (response, Data("""
                {"mediaId":"\(mediaId)","uploadOffset":\(offset + Int64(bytes.count)),
                 "complete":\(offset + Int64(bytes.count) == 6),"duplicate":false}
                """.utf8))
            }
            if request.httpMethod == "DELETE" {
                return (response, Data("""
                {"mediaId":"\(mediaId)","cancelled":true}
                """.utf8))
            }
            return (response, Data("""
            {"mediaId":"\(mediaId)","ready":true,"duplicate":false}
            """.utf8))
        }
        defer { CloudAPIMockURLProtocol.handler = nil }
        let engine = CloudMediaTransferEngine(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            cache: cache, session: URLSession(configuration: configuration)
        )

        let uploadedId = try await engine.upload(
            transfer: transfer, token: "session-token", localStore: store, progress: { _ in }
        )
        XCTAssertEqual(uploadedId, mediaId)
        let recorded = recorder.snapshot()
        XCTAssertEqual(recorded.map(\.offset), [2, 4])
        XCTAssertEqual(recorded.map(\.bytes), [Data("cd".utf8), Data("ef".utf8)])
        let updated = try await store.mediaTransfer(id: prepared.transferId)
        XCTAssertEqual(updated?.uploadOffset, 6)
        await engine.cancelUpload(transfer, token: "session-token")
        do {
            _ = try await cache.preparedData(transferId: prepared.transferId)
            XCTFail("Cancelled upload plaintext must be removed from the encrypted outbox")
        } catch {
            // Expected: the encrypted source file was removed.
        }
    }

    func testMultipartMediaResumesOnlyMissingParts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let partSize = 256 * 1024
        let payload = Data((0..<(partSize * 3 + 19)).map { UInt8($0 % 251) })
        let cache = try EncryptedMediaCache(
            root: directory.appending(path: "cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x52, count: 32), limitBytes: 3_000_000
        )
        let prepared = try await cache.prepareUpload(
            data: payload, kind: "file", contentType: "application/octet-stream", fileName: "parallel.bin"
        )
        let store = try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            key: Data("multipart-transfer-test-key".utf8)
        )
        let mediaId = "22222222-2222-2222-2222-222222222222"
        try await store.insertMediaTransfer(
            prepared: prepared, dialogId: "dialog-parallel", clientMsgId: UUID().uuidString,
            caption: "", replyToMsgId: nil
        )
        try await store.updateMediaTransfer(
            transferId: prepared.transferId, mediaId: mediaId,
            uploadOffset: Int64(partSize), state: "uploading", error: nil
        )
        let storedTransfer = try await store.mediaTransfer(id: prepared.transferId)
        let transfer = try XCTUnwrap(storedTransfer)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        configuration.httpMaximumConnectionsPerHost = 3
        let recorder = LockedMultipartRequests()
        CloudAPIMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/2",
                headerFields: ["content-type": "application/json"]
            ))
            if request.httpMethod == "GET" {
                return (response, Data("""
                {"mediaId":"\(mediaId)","uploadOffset":\(partSize),"byteSize":\(payload.count),
                 "status":"uploading","expiresAt":"2026-07-15T00:00:00Z","chunkSize":1048576,
                 "uploadProtocol":"parts_v2","partSize":\(partSize),"totalParts":4,"receivedParts":[1]}
                """.utf8))
            }
            if request.url?.path.contains("/parts/") == true {
                let component = try XCTUnwrap(request.url?.lastPathComponent)
                let partIndex = try XCTUnwrap(Int(component))
                let bytes = try XCTUnwrap(CloudAPIMockURLProtocol.bodyData(from: request))
                recorder.begin(partIndex: partIndex, bytes: bytes)
                Thread.sleep(forTimeInterval: 0.05)
                recorder.end()
                return (response, Data("""
                {"mediaId":"\(mediaId)","partIndex":\(partIndex),"receivedBytes":\(payload.count),
                 "complete":false,"duplicate":false}
                """.utf8))
            }
            return (response, Data("""
            {"mediaId":"\(mediaId)","ready":true,"duplicate":false}
            """.utf8))
        }
        defer { CloudAPIMockURLProtocol.handler = nil }
        let engine = CloudMediaTransferEngine(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            cache: cache, session: URLSession(configuration: configuration)
        )
        let progress = LockedProgressValues()
        let uploaded = try await engine.upload(
            transfer: transfer, token: "session-token", localStore: store,
            useMultipartV2: true, progress: { progress.append($0) }
        )

        XCTAssertEqual(uploaded, mediaId)
        XCTAssertEqual(Set(recorder.snapshot().map(\.partIndex)), Set([0, 2, 3]))
        let completedTransfer = try await store.mediaTransfer(id: prepared.transferId)
        XCTAssertEqual(completedTransfer?.uploadOffset, Int64(payload.count))
        XCTAssertEqual(progress.snapshot().last, 1)
        XCTAssertTrue(progress.snapshot().allSatisfy { (0...1).contains($0) })
    }

    func testTelegramStyleMediaPoliciesUseExpectedDefaultsAndUserOverride() throws {
        let megabyte: Int64 = 1024 * 1024
        let policy = MediaAutoDownloadPolicy.default
        let photo = CloudMedia(
            id: UUID().uuidString, kind: "photo", contentType: "image/jpeg",
            fileName: nil, byteSize: 3 * megabyte, durationMs: nil,
            width: 1_000, height: 1_000, hasThumbnail: true
        )
        let largePhoto = CloudMedia(
            id: UUID().uuidString, kind: "photo", contentType: "image/jpeg",
            fileName: nil, byteSize: 3 * megabyte + 1, durationMs: nil,
            width: 1_000, height: 1_000, hasThumbnail: true
        )
        let voice = CloudMedia(
            id: UUID().uuidString, kind: "voice", contentType: "audio/mp4",
            fileName: nil, byteSize: 10 * megabyte, durationMs: 1_000,
            width: nil, height: nil, hasThumbnail: false
        )
        let video = CloudMedia(
            id: UUID().uuidString, kind: "video", contentType: "video/mp4",
            fileName: nil, byteSize: 10 * megabyte, durationMs: 1_000,
            width: 1_000, height: 1_000, hasThumbnail: true
        )
        let file = CloudMedia(
            id: UUID().uuidString, kind: "file", contentType: "application/octet-stream",
            fileName: "file.bin", byteSize: 5 * megabyte, durationMs: nil,
            width: nil, height: nil, hasThumbnail: false
        )

        XCTAssertTrue(policy.directive(for: photo, chat: .privateChat, network: .cellular).downloadsFullMedia)
        XCTAssertFalse(policy.directive(for: largePhoto, chat: .privateChat, network: .cellular).downloadsFullMedia)
        XCTAssertTrue(policy.directive(for: voice, chat: .group, network: .cellular).downloadsFullMedia)
        XCTAssertTrue(policy.directive(for: video, chat: .group, network: .cellular).downloadsFullMedia)
        XCTAssertTrue(policy.directive(for: file, chat: .privateChat, network: .cellular).downloadsFullMedia)
        XCTAssertFalse(policy.directive(for: video, chat: .privateChat, network: .constrained).downloadsFullMedia)
        XCTAssertTrue(policy.directive(for: voice, chat: .privateChat, network: .roaming).downloadsFullMedia)

        let override = policy.directive(
            for: largePhoto, chat: .group, network: .roaming, userInitiated: true
        )
        XCTAssertTrue(override.downloadsFullMedia)
        XCTAssertEqual(override.priority, .userInitiated)
        XCTAssertEqual(MediaCachePolicy.default.sizeLimit, .unlimited)
        XCTAssertEqual(MediaCachePolicy.default.retention, .forever)
        XCTAssertEqual(MediaCachePolicy.minimumFreeSpaceBytes(totalCapacity: 10 * 1024 * 1024 * 1024), 1 * 1024 * 1024 * 1024)
        XCTAssertEqual(MediaCachePolicy.minimumFreeSpaceBytes(totalCapacity: 200 * 1024 * 1024 * 1024), 5 * 1024 * 1024 * 1024)

        let roundTrip = try JSONDecoder().decode(
            MediaAutoDownloadPolicy.self, from: JSONEncoder().encode(policy)
        )
        XCTAssertEqual(roundTrip, policy)
    }

    func testRoamingSignalUsesRoamingMediaPolicyEvenWithLowDataMode() {
        let snapshot = ReplicaNetworkSnapshot(
            networkClass: .constrained,
            isExpensive: true,
            isConstrained: true,
            isRoaming: true
        )
        XCTAssertEqual(snapshot.mediaNetworkClass, .roaming)
        XCTAssertFalse(snapshot.allowsDiscretionaryHydration)
    }

    func testMediaRetryUsesBoundedExponentialFullJitter() {
        XCTAssertEqual(
            CloudMediaTransferEngine.automaticRetryDelay(retryCount: 1, randomUnit: 0),
            0
        )
        XCTAssertEqual(
            CloudMediaTransferEngine.automaticRetryDelay(retryCount: 1, randomUnit: 1),
            2
        )
        XCTAssertEqual(
            CloudMediaTransferEngine.automaticRetryDelay(retryCount: 3, randomUnit: 0.5),
            4
        )
        XCTAssertEqual(
            CloudMediaTransferEngine.automaticRetryDelay(retryCount: 20, randomUnit: 1),
            300
        )
    }

    func testMediaPoliciesPersistWithSafeDefaultsAndQueueThumbnailsFirst() async throws {
        let suiteName = "TojTests.MediaPolicy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MediaPolicyStore(defaults: defaults)
        XCTAssertEqual(store.loadAutoDownloadPolicy(), .default)
        XCTAssertEqual(store.loadCachePolicy(), .default)

        var customAutoDownload = MediaAutoDownloadPolicy.default
        customAutoDownload.groupChats.cellular = MediaAutoDownloadLimits(
            photoBytes: 1024, voiceBytes: 2048, videoBytes: 4096, fileBytes: 8192
        )
        let customCache = MediaCachePolicy(sizeLimit: .unlimited, retention: .forever)
        try store.saveAutoDownloadPolicy(customAutoDownload)
        try store.saveCachePolicy(customCache)
        XCTAssertEqual(store.loadAutoDownloadPolicy(), customAutoDownload)
        XCTAssertEqual(store.loadCachePolicy(), customCache)

        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = try EncryptedMediaCache(
            root: directory, keyData: Data(repeating: 0x41, count: 32), limitBytes: 1_000_000
        )
        let engine = CloudMediaTransferEngine(cache: cache, policyStore: store)
        let video = CloudMedia(
            id: UUID().uuidString.lowercased(), kind: "video", contentType: "video/mp4",
            fileName: nil, byteSize: 10_000, durationMs: 1_000,
            width: 100, height: 100, hasThumbnail: true
        )

        let automatic = await engine.enqueueAutoDownload(
            media: video, chat: .group, network: .cellular
        )
        let automaticQueue = await engine.queuedAutoDownloads()
        XCTAssertFalse(automatic.downloadsFullMedia)
        XCTAssertEqual(automaticQueue.map(\.component), [.thumbnail])

        let user = await engine.enqueueAutoDownload(
            media: video, chat: .group, network: .roaming, userInitiated: true
        )
        let queued = await engine.queuedAutoDownloads()
        XCTAssertTrue(user.downloadsFullMedia)
        XCTAssertEqual(queued.map(\.component), [.thumbnail, .fullMedia])
        XCTAssertTrue(queued.allSatisfy { $0.priority == .userInitiated })
        XCTAssertEqual(
            try JSONDecoder().decode(
                [MediaDownloadQueueItem].self, from: JSONEncoder().encode(queued)
            ),
            queued
        )

        defaults.set(Data("corrupt".utf8), forKey: "toj.media.cache-policy.v1")
        XCTAssertEqual(store.loadCachePolicy(), .default)
    }

    func testCompletedUploadIsPromotedToEncryptedDownloadCacheBeforeSourceRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = try EncryptedMediaCache(
            root: directory, keyData: Data(repeating: 0x63, count: 32), limitBytes: 4 * 1024 * 1024
        )
        let payload = Data((0..<(700 * 1024)).map { UInt8($0 % 251) })
        let thumbnail = Data("sent-media-thumbnail".utf8)
        let prepared = try await cache.prepareUpload(
            data: payload, kind: "video", contentType: "video/mp4",
            fileName: "sent.mp4", durationMs: 2_000, width: 640, height: 480,
            thumbnail: thumbnail
        )
        let mediaId = UUID().uuidString.lowercased()
        let transfer = MediaTransferRecord(
            transferId: prepared.transferId, dialogId: "dialog-sent", clientMsgId: UUID().uuidString,
            caption: "", replyToMsgId: nil, kind: prepared.kind, contentType: prepared.contentType,
            fileName: prepared.fileName, byteSize: prepared.byteSize, sha256: prepared.sha256,
            durationMs: prepared.durationMs, width: prepared.width, height: prepared.height,
            encryptedSourcePath: prepared.encryptedSourcePath,
            encryptedThumbnailPath: prepared.encryptedThumbnailPath, mediaId: mediaId,
            uploadOffset: prepared.byteSize, state: "ready_to_send", retryCount: 0,
            nextRetryAt: nil, lastError: nil, terminal: false
        )

        try await cache.finishUpload(transfer)

        let promoted = try await cache.downloadedData(mediaId: mediaId, expectedSize: prepared.byteSize)
        let promotedThumbnail = try await cache.thumbnail(mediaId: mediaId)
        let state = try await cache.downloadState(mediaId: mediaId, expectedSize: prepared.byteSize)
        let usage = try await cache.usageSnapshot()
        XCTAssertEqual(promoted, payload)
        XCTAssertEqual(promotedThumbnail, thumbnail)
        XCTAssertTrue(state.isComplete)
        XCTAssertTrue(state.hasThumbnail)
        XCTAssertEqual(usage.protectedUploadBytes, 0)
        XCTAssertGreaterThan(usage.downloadedBytes, prepared.byteSize)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.encryptedSourcePath))
        XCTAssertGreaterThan(
            try FileManager.default.contentsOfDirectory(
                at: directory.appending(path: "downloads/\(mediaId)"),
                includingPropertiesForKeys: nil
            ).count,
            1
        )
    }

    func testActiveMediaAndPendingUploadsAreProtectedDuringLRUEviction() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = try EncryptedMediaCache(
            root: directory, keyData: Data(repeating: 0x71, count: 32), limitBytes: 700
        )
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        let third = UUID().uuidString.lowercased()
        try await cache.storeDownloadChunk(Data(repeating: 0x01, count: 250), mediaId: first, offset: 0)
        try await cache.beginAccess(mediaId: first)
        try await cache.storeDownloadChunk(Data(repeating: 0x02, count: 250), mediaId: second, offset: 0)
        try await cache.storeDownloadChunk(Data(repeating: 0x03, count: 250), mediaId: third, offset: 0)

        let firstOffset = try await cache.contiguousDownloadOffset(mediaId: first)
        let secondOffset = try await cache.contiguousDownloadOffset(mediaId: second)
        let thirdOffset = try await cache.contiguousDownloadOffset(mediaId: third)
        let activeState = try await cache.downloadState(mediaId: first, expectedSize: 250)
        XCTAssertEqual(firstOffset, 250)
        XCTAssertEqual(secondOffset, 0)
        XCTAssertEqual(thirdOffset, 250)
        XCTAssertTrue(activeState.isActive)
        await cache.endAccess(mediaId: first)
        let inactiveState = try await cache.downloadState(mediaId: first, expectedSize: 250)
        XCTAssertFalse(inactiveState.isActive)
    }

    func testDynamicCachePolicyAndSelectiveClearEvictOnlyDownloadedMedia() async throws {
        let suiteName = "TojTests.DynamicMediaPolicy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = try EncryptedMediaCache(
            root: directory, keyData: Data(repeating: 0x51, count: 32), limitBytes: 1_000
        )
        let engine = CloudMediaTransferEngine(
            cache: cache, policyStore: MediaPolicyStore(defaults: defaults)
        )
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        try await cache.storeDownloadChunk(Data(repeating: 0x01, count: 250), mediaId: first, offset: 0)
        try await cache.storeDownloadChunk(Data(repeating: 0x02, count: 250), mediaId: second, offset: 0)

        let smaller = MediaCachePolicy(sizeLimit: .custom(400), retention: .forever)
        try await engine.updateCachePolicy(smaller)
        let afterLimit = try await cache.usageSnapshot()
        let currentPolicy = await engine.currentCachePolicy()
        XCTAssertLessThanOrEqual(afterLimit.downloadedBytes, 400)
        XCTAssertEqual(currentPolicy, smaller)

        await engine.clearMediaCache(mediaIds: [first, second])
        let afterClear = try await cache.usageSnapshot()
        XCTAssertEqual(afterClear.downloadedBytes, 0)
    }

    func testStoreBackedMediaQueuePersistsJobsAndCacheLedgerWithoutFilesystemBootstrap() async throws {
        let suiteName = "TojTests.DurableMediaLedger.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            key: Data("durable-media-ledger-test-key".utf8)
        )
        let cache = try EncryptedMediaCache(
            root: directory.appending(path: "cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x61, count: 32), limitBytes: 1_000_000
        )
        let payload = Data("durable media payload".utf8)
        let media = CloudMedia(
            id: UUID().uuidString.lowercased(), kind: "file",
            contentType: "application/octet-stream", fileName: "durable.bin",
            byteSize: Int64(payload.count), durationMs: nil, width: nil, height: nil,
            hasThumbnail: true
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        CloudAPIMockURLProtocol.handler = { request in
            let offset = Int64(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "offset" })?.value ?? "0") ?? 0
            let bytes = Data(payload[Int(offset)..<payload.count])
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "content-type": "application/octet-stream",
                        "x-media-next-offset": String(payload.count),
                        "x-media-total-size": String(payload.count),
                    ]
                )),
                bytes
            )
        }
        defer { CloudAPIMockURLProtocol.handler = nil }
        let engine = CloudMediaTransferEngine(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            cache: cache,
            session: URLSession(configuration: configuration),
            policyStore: MediaPolicyStore(defaults: defaults)
        )

        try await store.applyHistoryPage(HistoryPageResponse(
            dialogId: "dialog-durable",
            messages: [CloudMessage(
                dialogId: "dialog-durable", msgId: 1, senderAccountId: "account-peer",
                clientMsgId: "durable-media-message", kind: "file", text: "",
                media: media, editVersion: 0, state: "visible",
                serverTs: "2026-07-16T10:00:00Z"
            )],
            nextBeforeMsgId: nil,
            hasMore: false
        ))

        _ = await engine.enqueueAutoDownload(
            media: media, chat: .privateChat, network: .wifi,
            dialogId: "dialog-durable", localStore: store
        )
        let jobs = try await store.mediaDownloadJobsReady()
        XCTAssertEqual(jobs.map(\.variant), ["thumbnail", "full"])
        XCTAssertEqual(jobs.map(\.priority), [11, 10])
        XCTAssertEqual(jobs.first?.dialogId, "dialog-durable")
        let expectedComponents: [MediaDownloadComponent] = [.thumbnail, .fullMedia]
        for expected in expectedComponents {
            let dequeued = await engine.dequeueAutoDownload(localStore: store)
            let item = try XCTUnwrap(dequeued)
            XCTAssertEqual(item.component, expected)
            try await engine.performAutoDownload(
                item,
                token: "session-token",
                localStore: store,
                network: .wifi
            )
        }

        let ledger = try await store.mediaCacheEntry(mediaId: media.id, variant: "full")
        let thumbnailLedger = try await store.mediaCacheEntry(mediaId: media.id, variant: "thumbnail")
        let remainingJobs = try await store.mediaDownloadJobsReady()
        let durableUsage = try await store.downloadedMediaUsageBytes()
        XCTAssertEqual(ledger?.contiguousOffset, Int64(payload.count))
        XCTAssertEqual(ledger?.state, "complete")
        XCTAssertEqual(thumbnailLedger?.state, "complete")
        XCTAssertTrue(remainingJobs.isEmpty)
        XCTAssertGreaterThan(durableUsage, Int64(payload.count))
    }

    func testDurableMediaQueueSkipsOrphansAndRechecksActualGroupPolicy() async throws {
        let suiteName = "TojTests.MediaRecheck.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var policy = MediaAutoDownloadPolicy.default
        policy.groupChats.wifi = MediaAutoDownloadLimits(
            photoBytes: 0, voiceBytes: 0, videoBytes: 0, fileBytes: 0
        )
        let policyStore = MediaPolicyStore(defaults: defaults)
        try policyStore.saveAutoDownloadPolicy(policy)

        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            key: Data("media-policy-recheck-store-key".utf8)
        )
        let cache = try EncryptedMediaCache(
            root: directory.appending(path: "cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x28, count: 32), limitBytes: 1_000_000
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        CloudAPIMockURLProtocol.handler = { request in
            XCTFail("A policy-deferred job must not start a network request")
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil
                )),
                Data()
            )
        }
        defer { CloudAPIMockURLProtocol.handler = nil }
        let engine = CloudMediaTransferEngine(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            cache: cache,
            session: URLSession(configuration: configuration),
            policyStore: policyStore
        )
        let dialogId = "dialog-group-policy"
        let media = CloudMedia(
            id: UUID().uuidString.lowercased(), kind: "file",
            contentType: "application/octet-stream", fileName: "group.bin",
            byteSize: 128, durationMs: nil, width: nil, height: nil, hasThumbnail: false
        )
        try await store.applyHistoryPage(HistoryPageResponse(
            dialogId: dialogId,
            messages: [CloudMessage(
                dialogId: dialogId, msgId: 1, senderAccountId: "account-peer",
                clientMsgId: "group-media-message", kind: "file", text: "", media: media,
                editVersion: 0, state: "visible", serverTs: "2026-07-16T10:00:00Z"
            )],
            nextBeforeMsgId: nil,
            hasMore: false
        ))
        try await store.upsertDialog(dialogId: dialogId, type: "group")
        // Generic message/history upserts use the direct default; they must not erase a known
        // group classification that media policy depends on.
        try await store.upsertDialog(dialogId: dialogId, lastMsgId: 2)
        try await store.upsertMediaDownloadJob(MediaDownloadJobRecord(
            mediaId: "deleted-media", variant: "full", dialogId: dialogId,
            priority: 1_000, state: .queued, userInitiated: false, retryCount: 0,
            nextRetryAt: nil, lastError: nil,
            updatedAt: CloudLocalStore.sqliteTimestamp(Date())
        ))
        _ = await engine.enqueueAutoDownload(
            media: media, chat: .privateChat, network: .wifi,
            dialogId: dialogId, localStore: store
        )

        let dequeued = await engine.dequeueAutoDownload(localStore: store)
        let item = try XCTUnwrap(dequeued)
        XCTAssertEqual(item.media.id, media.id)
        let chatClass = try await store.mediaChatClass(dialogId: dialogId)
        let readyAfterDequeue = try await store.mediaDownloadJobsReady()
        XCTAssertEqual(chatClass, .group)
        XCTAssertFalse(readyAfterDequeue.contains { $0.mediaId == "deleted-media" })
        do {
            try await engine.performAutoDownload(item, token: "session-token", localStore: store)
            XCTFail("Group policy must be re-evaluated immediately before transfer")
        } catch let error as MediaCacheError {
            guard case .automaticDownloadDeferred = error else {
                return XCTFail("Unexpected media error: \(error)")
            }
        }
        let nextPolicyRetry = try await store.nextMediaDownloadRetryDate()
        XCTAssertNotNil(nextPolicyRetry)
    }

    func testLowDiskReserveSuspendsAutomaticDownloadAndPersistsRetry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            key: Data("media-low-disk-store-key".utf8)
        )
        let cacheRoot = directory.appending(path: "cache", directoryHint: .isDirectory)
        let cache = try EncryptedMediaCache(
            root: cacheRoot,
            keyData: Data(repeating: 0x29, count: 32), limitBytes: 1_000_000
        )
        let evictedMediaId = UUID().uuidString.lowercased()
        let evictedPayload = Data(repeating: 0x2a, count: 250)
        try await cache.storeDownloadChunk(evictedPayload, mediaId: evictedMediaId, offset: 0)
        try await store.upsertMediaCacheEntry(MediaCacheEntry(
            mediaId: evictedMediaId, variant: "full",
            encryptedPath: cacheRoot.appending(path: "downloads/\(evictedMediaId)").path,
            byteSize: Int64(evictedPayload.count), cachedBytes: Int64(evictedPayload.count + 28),
            contiguousOffset: Int64(evictedPayload.count), state: "complete",
            lastAccessedAt: CloudLocalStore.sqliteTimestamp(.distantPast), protectedUntil: nil
        ))
        let engine = CloudMediaTransferEngine(
            cache: cache,
            volumeCapacityProvider: {
                MediaVolumeCapacity(
                    availableBytes: 0,
                    totalCapacityBytes: 10 * 1024 * 1024 * 1024
                )
            }
        )
        let dialogId = "dialog-low-disk"
        let media = CloudMedia(
            id: UUID().uuidString.lowercased(), kind: "file",
            contentType: "application/octet-stream", fileName: "deferred.bin",
            byteSize: 256, durationMs: nil, width: nil, height: nil, hasThumbnail: false
        )
        try await store.applyHistoryPage(HistoryPageResponse(
            dialogId: dialogId,
            messages: [CloudMessage(
                dialogId: dialogId, msgId: 1, senderAccountId: "account-peer",
                clientMsgId: "low-disk-media-message", kind: "file", text: "", media: media,
                editVersion: 0, state: "visible", serverTs: "2026-07-16T10:00:00Z"
            )],
            nextBeforeMsgId: nil,
            hasMore: false
        ))
        _ = await engine.enqueueAutoDownload(
            media: media, chat: .privateChat, network: .wifi,
            dialogId: dialogId, localStore: store
        )
        let dequeued = await engine.dequeueAutoDownload(localStore: store)
        let item = try XCTUnwrap(dequeued)

        do {
            try await engine.performAutoDownload(
                item, token: "session-token", localStore: store,
                chat: .privateChat, network: .wifi
            )
            XCTFail("Automatic download must stop below the free-space reserve")
        } catch let error as MediaCacheError {
            guard case .automaticDownloadDeferred = error else {
                return XCTFail("Unexpected media error: \(error)")
            }
        }
        let suspended = await engine.areAutomaticDownloadsSuspendedForLowDisk()
        let nextLowDiskRetry = try await store.nextMediaDownloadRetryDate()
        let evictedLedger = try await store.mediaCacheEntry(
            mediaId: evictedMediaId,
            variant: "full"
        )
        XCTAssertTrue(suspended)
        XCTAssertNotNil(nextLowDiskRetry)
        XCTAssertNil(evictedLedger)
    }

    func testSelectiveClearKeepsActiveMediaAndItsExactLedgerEntry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            key: Data("media-selective-clear-store-key".utf8)
        )
        let cacheRoot = directory.appending(path: "cache", directoryHint: .isDirectory)
        let cache = try EncryptedMediaCache(
            root: cacheRoot, keyData: Data(repeating: 0x30, count: 32), limitBytes: 1_000_000
        )
        let engine = CloudMediaTransferEngine(cache: cache)
        let activeId = UUID().uuidString.lowercased()
        let inactiveId = UUID().uuidString.lowercased()
        let payload = Data(repeating: 0x31, count: 250)
        try await cache.storeDownloadChunk(payload, mediaId: activeId, offset: 0)
        try await cache.storeDownloadChunk(payload, mediaId: inactiveId, offset: 0)
        for mediaId in [activeId, inactiveId] {
            try await store.upsertMediaCacheEntry(MediaCacheEntry(
                mediaId: mediaId, variant: "full",
                encryptedPath: cacheRoot.appending(path: "downloads/\(mediaId)").path,
                byteSize: Int64(payload.count), cachedBytes: Int64(payload.count + 28),
                contiguousOffset: Int64(payload.count), state: "complete",
                lastAccessedAt: CloudLocalStore.sqliteTimestamp(Date()), protectedUntil: nil
            ))
        }
        try await engine.warmCache(localStore: store)
        try await cache.beginAccess(mediaId: activeId)

        await engine.clearMediaCache(mediaIds: [activeId, inactiveId], localStore: store)

        let activeLedger = try await store.mediaCacheEntry(mediaId: activeId, variant: "full")
        let inactiveLedger = try await store.mediaCacheEntry(mediaId: inactiveId, variant: "full")
        let activeOffset = try await cache.contiguousDownloadOffset(mediaId: activeId)
        let inactiveOffset = try await cache.contiguousDownloadOffset(mediaId: inactiveId)
        XCTAssertNotNil(activeLedger)
        XCTAssertNil(inactiveLedger)
        XCTAssertEqual(activeOffset, Int64(payload.count))
        XCTAssertEqual(inactiveOffset, 0)
        await cache.endAccess(mediaId: activeId)
    }

    func testStreamingByteRangePersistsEncryptedChunkLedger() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            key: Data("media-stream-ledger-store-key".utf8)
        )
        let cache = try EncryptedMediaCache(
            root: directory.appending(path: "cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x32, count: 32), limitBytes: 1_000_000
        )
        let payload = Data("streamed encrypted bytes".utf8)
        let media = CloudMedia(
            id: UUID().uuidString.lowercased(), kind: "video", contentType: "video/mp4",
            fileName: "clip.mp4", byteSize: Int64(payload.count), durationMs: 1_000,
            width: 320, height: 180, hasThumbnail: false
        )
        try await store.applyHistoryPage(HistoryPageResponse(
            dialogId: "dialog-stream",
            messages: [CloudMessage(
                dialogId: "dialog-stream", msgId: 1, senderAccountId: "account-peer",
                clientMsgId: "stream-media-message", kind: "video", text: "", media: media,
                editVersion: 0, state: "visible", serverTs: "2026-07-16T10:00:00Z"
            )],
            nextBeforeMsgId: nil,
            hasMore: false
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        CloudAPIMockURLProtocol.handler = { request in
            let offset = Int64(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "offset" })?.value ?? "0") ?? 0
            let bytes = Data(payload[Int(offset)..<payload.count])
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "x-media-next-offset": String(payload.count),
                        "x-media-total-size": String(payload.count),
                    ]
                )),
                bytes
            )
        }
        defer { CloudAPIMockURLProtocol.handler = nil }
        let engine = CloudMediaTransferEngine(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            cache: cache,
            session: URLSession(configuration: configuration)
        )

        let range = try await engine.byteRange(
            media: media, token: "session-token", offset: 0, length: 8, localStore: store
        )

        XCTAssertEqual(range, Data(payload.prefix(8)))
        let entry = try await store.mediaCacheEntry(mediaId: media.id, variant: "full")
        XCTAssertEqual(entry?.contiguousOffset, Int64(payload.count))
        XCTAssertEqual(entry?.state, "complete")
    }

    func testTimelineReadsAreBoundedKeysetWindowsAndOpeningAnchorIsDeterministic() async throws {
        let store = try makeStore()
        let journalMode = try await store.databaseJournalMode()
        XCTAssertEqual(journalMode.lowercased(), "wal")
        let dialogId = "dialog-window"
        let accountId = "account-me"
        let peerId = "account-peer"
        try await store.saveMembers(dialogId: dialogId, members: [
            BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 220),
            BootstrapDialogMember(accountId: peerId, role: "member", lastReadMsgId: 0),
        ])
        let history = (1...250).map { value in
            CloudMessage(
                dialogId: dialogId,
                msgId: Int64(value),
                senderAccountId: peerId,
                clientMsgId: "window-\(value)",
                kind: "text",
                text: "message \(value)",
                editVersion: 0,
                state: "visible",
                serverTs: String(format: "2026-07-16T10:%02d:%02dZ", (value / 60) % 60, value % 60)
            )
        }
        try await store.applyHistoryPage(
            HistoryPageResponse(
                dialogId: dialogId,
                messages: history,
                nextBeforeMsgId: nil,
                hasMore: false
            )
        )

        let latest = try await store.messages(dialogId: dialogId, limit: TimelineWindow.initialLimit)
        XCTAssertEqual(latest.count, 120)
        XCTAssertEqual(latest.first?.msgId, 131)
        XCTAssertEqual(latest.last?.msgId, 250)

        let earlier = try await store.messages(
            dialogId: dialogId,
            limit: TimelineWindow.pageLimit,
            beforeMsgId: 131
        )
        XCTAssertEqual(earlier.count, 80)
        XCTAssertEqual(earlier.first?.msgId, 51)
        XCTAssertEqual(earlier.last?.msgId, 130)

        let aroundAnchor = try await store.messageWindow(
            dialogId: dialogId,
            anchorMsgId: 150,
            beforeCount: 2,
            afterCount: 2
        )
        XCTAssertEqual(aroundAnchor.compactMap(\.msgId), [148, 149, 150, 151, 152])
        let aroundSnapshot = try await store.timelineWindow(
            dialogId: dialogId,
            anchorMsgId: 150,
            beforeCount: 2,
            afterCount: 2
        )
        XCTAssertEqual(aroundSnapshot.messages.compactMap(\.msgId), [148, 149, 150, 151, 152])
        XCTAssertTrue(aroundSnapshot.hasEarlierLocalMessages)
        XCTAssertTrue(aroundSnapshot.hasLaterLocalMessages)

        let snapshot = try await store.timeline(dialogId: dialogId)
        XCTAssertEqual(snapshot.oldestServerMsgId, 131)
        XCTAssertEqual(snapshot.newestServerMsgId, 250)
        XCTAssertTrue(snapshot.hasEarlierLocalMessages)
        XCTAssertFalse(
            snapshot.hasLaterLocalMessages,
            "The latest keyset page must represent the real local end of the conversation"
        )

        let earlierSnapshot = try await store.timeline(
            dialogId: dialogId,
            window: .earlier(beforeMsgId: 131)
        )
        XCTAssertEqual(earlierSnapshot.messages.compactMap(\.msgId), Array(51...130).map(Int64.init))
        XCTAssertTrue(earlierSnapshot.hasEarlierLocalMessages)
        XCTAssertTrue(
            earlierSnapshot.hasLaterLocalMessages,
            "An older keyset page must not present its retained last row as the chat bottom"
        )

        let centeredSnapshot = try await store.timeline(
            dialogId: dialogId,
            window: TimelineWindow(afterMsgId: 147, limit: 5)
        )
        XCTAssertEqual(centeredSnapshot.messages.compactMap(\.msgId), [148, 149, 150, 151, 152])
        XCTAssertTrue(centeredSnapshot.hasEarlierLocalMessages)
        XCTAssertTrue(
            centeredSnapshot.hasLaterLocalMessages,
            "A centered window must expose that newer local rows exist beyond its rendered edge"
        )
        let timelineStream = await store.observeTimeline(dialogId: dialogId)
        var timelineIterator = timelineStream.makeAsyncIterator()
        let observedValue = try await timelineIterator.next()
        let observed = try XCTUnwrap(observedValue)
        XCTAssertEqual(observed.messages.count, 120)
        XCTAssertEqual(observed.newestServerMsgId, 250)
        let firstUnread = try await store.firstUnreadMessageId(dialogId: dialogId, accountId: accountId)
        XCTAssertEqual(firstUnread, 221)

        let viewport = ChatViewportState(
            dialogId: dialogId,
            accountId: accountId,
            topVisibleMsgId: 180,
            wasAtBottom: false,
            updatedAt: "2026-07-16 10:00:00"
        )
        try await store.saveViewportState(viewport)
        let unreadAnchor = try await store.resolveOpeningAnchor(dialogId: dialogId, accountId: accountId)
        XCTAssertEqual(unreadAnchor, .firstUnread(msgId: 221))
        try await store.markRead(dialogId: dialogId, accountId: accountId, maxReadMsgId: 250)
        let savedAnchor = try await store.resolveOpeningAnchor(dialogId: dialogId, accountId: accountId)
        let loadedViewport = try await store.loadViewportState(dialogId: dialogId, accountId: accountId)
        XCTAssertEqual(savedAnchor, .saved(msgId: 180))
        XCTAssertEqual(loadedViewport, viewport)
    }

    func testSparseBootstrapUsesSemanticUnreadAnchorAndTargetedPagePreservesBackfillCursor() async throws {
        let store = try makeStore()
        let dialogId = "dialog-sparse-bootstrap"
        let accountId = "account-me"
        let peerId = "account-peer"
        try await store.saveMembers(dialogId: dialogId, members: [
            BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 20),
            BootstrapDialogMember(accountId: peerId, role: "member", lastReadMsgId: 0),
        ])

        let recentMessages = (96...100).map { msgId in
            CloudMessage(
                dialogId: dialogId,
                msgId: Int64(msgId),
                senderAccountId: peerId,
                clientMsgId: "recent-\(msgId)",
                kind: "text",
                text: "recent \(msgId)",
                editVersion: 0,
                state: "visible",
                serverTs: "2026-07-16T10:00:\(msgId - 40)Z"
            )
        }
        try await store.applyHistoryPage(HistoryPageResponse(
            dialogId: dialogId,
            messages: recentMessages,
            nextBeforeMsgId: 96,
            hasMore: true
        ))

        let semanticAnchor = try await store.resolveOpeningAnchor(
            dialogId: dialogId,
            accountId: accountId
        )
        XCTAssertEqual(
            semanticAnchor,
            .provisionalFirstUnread(msgId: 21),
            "A five-message bootstrap preview must not mistake its first cached row for first unread"
        )
        let historyStateBeforeTargetedFetch = try await store.loadHistoryState(dialogId: dialogId)
        let cursorBeforeTargetedFetch = try XCTUnwrap(historyStateBeforeTargetedFetch)

        let outgoingCandidate = CloudMessage(
            dialogId: dialogId,
            msgId: 21,
            senderAccountId: accountId,
            clientMsgId: "targeted-outgoing-21",
            kind: "text",
            text: "sent from another device",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-16T09:00:21Z"
        )
        let firstIncoming = CloudMessage(
            dialogId: dialogId,
            msgId: 22,
            senderAccountId: peerId,
            clientMsgId: "targeted-incoming-22",
            kind: "text",
            text: "actual first incoming",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-16T09:00:22Z"
        )
        try await store.applyTargetedHistoryPage(HistoryPageResponse(
            dialogId: dialogId,
            messages: [outgoingCandidate, firstIncoming],
            nextBeforeMsgId: 21,
            nextAfterMsgId: 22,
            hasMore: true
        ))

        let targetedMessages = try await store.messages(
            dialogId: dialogId,
            limit: 10,
            afterMsgId: 20
        )
        let historyStateAfterTargetedFetch = try await store.loadHistoryState(dialogId: dialogId)
        let cursorAfterTargetedFetch = try XCTUnwrap(historyStateAfterTargetedFetch)
        let firstUnreadAfterTargetedFetch = try await store.firstUnreadMessageId(
            dialogId: dialogId,
            accountId: accountId
        )
        let resolvedAnchorAfterTargetedFetch = try await store.resolveOpeningAnchor(
            dialogId: dialogId,
            accountId: accountId
        )
        XCTAssertEqual(targetedMessages.compactMap(\.msgId).prefix(2), [21, 22])
        XCTAssertEqual(firstUnreadAfterTargetedFetch, 22)
        XCTAssertEqual(
            resolvedAnchorAfterTargetedFetch,
            .firstUnread(msgId: 22),
            "A resumed launch must not finalize a cached outgoing semantic candidate as first unread"
        )
        XCTAssertEqual(cursorAfterTargetedFetch, cursorBeforeTargetedFetch)
        XCTAssertEqual(cursorAfterTargetedFetch.nextBeforeMsgId, 96)
    }

    func testOpeningAnchorRejectsMissingOrDeletedSavedRows() async throws {
        let store = try makeStore()
        let dialogId = "dialog-invalid-saved-anchor"
        let accountId = "account-me"
        let peerId = "account-peer"
        try await store.saveMembers(dialogId: dialogId, members: [
            BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 30),
            BootstrapDialogMember(accountId: peerId, role: "member", lastReadMsgId: 0),
        ])
        try await store.applyHistoryPage(HistoryPageResponse(
            dialogId: dialogId,
            messages: [
                CloudMessage(
                    dialogId: dialogId, msgId: 10, senderAccountId: peerId,
                    clientMsgId: "saved-visible-10", kind: "text", text: "visible before",
                    editVersion: 0, state: "visible", serverTs: "2026-07-16T10:00:10Z"
                ),
                CloudMessage(
                    dialogId: dialogId, msgId: 19, senderAccountId: peerId,
                    clientMsgId: "saved-deleted-19", kind: "text", text: "deleted anchor",
                    editVersion: 0, state: "deleted", serverTs: "2026-07-16T10:00:19Z"
                ),
                CloudMessage(
                    dialogId: dialogId, msgId: 30, senderAccountId: peerId,
                    clientMsgId: "saved-visible-30", kind: "text", text: "visible after",
                    editVersion: 0, state: "visible", serverTs: "2026-07-16T10:00:30Z"
                ),
            ],
            nextBeforeMsgId: nil,
            hasMore: false
        ))
        try await store.saveViewportState(ChatViewportState(
            dialogId: dialogId,
            accountId: accountId,
            topVisibleMsgId: 19,
            wasAtBottom: false
        ))

        let deletedFallback = try await store.resolveOpeningAnchor(
            dialogId: dialogId,
            accountId: accountId
        )
        XCTAssertEqual(
            deletedFallback,
            .saved(msgId: 30),
            "A deleted viewport row must prefer the next visible semantic row"
        )

        try await store.saveViewportState(ChatViewportState(
            dialogId: dialogId,
            accountId: accountId,
            topVisibleMsgId: 999,
            wasAtBottom: false
        ))
        let missingFallback = try await store.resolveOpeningAnchor(
            dialogId: dialogId,
            accountId: accountId
        )
        XCTAssertEqual(
            missingFallback,
            .saved(msgId: 30),
            "A missing viewport row must resolve to the nearest remaining visible message"
        )

        let deletedOnlyDialogId = "dialog-saved-anchor-without-visible-row"
        try await store.saveMembers(dialogId: deletedOnlyDialogId, members: [
            BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 1),
            BootstrapDialogMember(accountId: peerId, role: "member", lastReadMsgId: 0),
        ])
        try await store.applyHistoryPage(HistoryPageResponse(
            dialogId: deletedOnlyDialogId,
            messages: [CloudMessage(
                dialogId: deletedOnlyDialogId, msgId: 1, senderAccountId: peerId,
                clientMsgId: "only-deleted-row", kind: "text", text: "deleted",
                editVersion: 0, state: "deleted", serverTs: "2026-07-16T10:00:01Z"
            )],
            nextBeforeMsgId: nil,
            hasMore: false
        ))
        try await store.saveViewportState(ChatViewportState(
            dialogId: deletedOnlyDialogId,
            accountId: accountId,
            topVisibleMsgId: 1,
            wasAtBottom: false
        ))
        let noVisibleFallback = try await store.resolveOpeningAnchor(
            dialogId: deletedOnlyDialogId,
            accountId: accountId
        )
        XCTAssertEqual(noVisibleFallback, .bottom)

        let outgoingOnlyDialogId = "dialog-saved-anchor-outgoing-only"
        try await store.saveMembers(dialogId: outgoingOnlyDialogId, members: [
            BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 0),
            BootstrapDialogMember(accountId: peerId, role: "member", lastReadMsgId: 0),
        ])
        try await store.applyHistoryPage(HistoryPageResponse(
            dialogId: outgoingOnlyDialogId,
            messages: [CloudMessage(
                dialogId: outgoingOnlyDialogId, msgId: 5, senderAccountId: accountId,
                clientMsgId: "outgoing-only-5", kind: "text", text: "sent on another device",
                editVersion: 0, state: "visible", serverTs: "2026-07-16T10:00:05Z"
            )],
            nextBeforeMsgId: nil,
            hasMore: false
        ))
        try await store.saveViewportState(ChatViewportState(
            dialogId: outgoingOnlyDialogId,
            accountId: accountId,
            topVisibleMsgId: 5,
            wasAtBottom: false
        ))
        let outgoingOnlySavedAnchor = try await store.resolveOpeningAnchor(
            dialogId: outgoingOnlyDialogId,
            accountId: accountId
        )
        XCTAssertEqual(
            outgoingOnlySavedAnchor,
            .saved(msgId: 5),
            "A server ceiling made only of outgoing rows must not invent an unread divider"
        )
    }

    func testDestructiveLogoutCountIncludesOfflineDialogPreferences() async throws {
        let store = try makeStore()
        let dialogId = "dialog-pending-logout"
        let accountId = "account-me"
        try await store.upsertDialog(
            dialogId: dialogId,
            title: "Pending logout",
            updatedAt: "2026-07-25T10:00:00.000Z"
        )
        _ = try await store.insertSending(
            dialogId: dialogId,
            clientMsgId: "pending-text",
            text: "unsent text",
            senderAccountId: "account-me"
        )
        try await store.enqueueMessageMutation(
            clientMutationId: "pending-edit",
            operation: "edit",
            dialogId: dialogId,
            msgId: 1,
            body: "unsynced edit",
            expectedEditVersion: 0
        )
        try await store.insertMediaTransfer(
            prepared: PreparedMediaUpload(
                transferId: "pending-media",
                kind: "photo",
                contentType: "image/jpeg",
                fileName: "pending.jpg",
                byteSize: 128,
                sha256: String(repeating: "a", count: 64),
                durationMs: nil,
                width: 10,
                height: 10,
                encryptedSourcePath: "/private/pending-media.tojmedia",
                encryptedThumbnailPath: nil
            ),
            dialogId: dialogId,
            clientMsgId: "pending-media-message",
            caption: "",
            replyToMsgId: nil
        )
        _ = try await store.queueDialogPreference(
            accountId: accountId,
            dialogId: dialogId,
            field: .archived,
            desiredValue: true
        )

        let destructiveLogoutCount = try await store.pendingDestructiveLogoutItemCount()
        XCTAssertEqual(destructiveLogoutCount, 4)
    }

    func testBootstrapAndDifferenceTooLongPreserveReplicaAndEveryDurableOutbox() async throws {
        let store = try makeStore()
        let accountId = "account-me"
        let existingDialogId = "dialog-existing"
        let existing = CloudMessage(
            dialogId: existingDialogId,
            msgId: 1,
            senderAccountId: "account-peer",
            clientMsgId: "existing-message",
            kind: "text",
            text: "keep local history",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-16T10:00:00Z"
        )
        try await store.applyHistoryPage(
            HistoryPageResponse(
                dialogId: existingDialogId,
                messages: [existing],
                nextBeforeMsgId: nil,
                hasMore: false
            )
        )
        try await store.upsertDialog(
            dialogId: existingDialogId,
            type: "direct",
            title: "Old title",
            lastMsgId: 1,
            updatedAt: existing.serverTs
        )
        let staleRecentMessage = CloudMessage(
            dialogId: existingDialogId,
            msgId: 8,
            senderAccountId: "account-peer",
            clientMsgId: "stale-recent-message",
            kind: "text",
            text: "stale snapshot-owned row",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-16T10:00:07Z"
        )
        try await store.applyHistoryPage(
            HistoryPageResponse(
                dialogId: existingDialogId,
                messages: [staleRecentMessage],
                nextBeforeMsgId: nil,
                hasMore: false
            )
        )
        let staleDialogId = "dialog-stale"
        let staleMessage = CloudMessage(
            dialogId: staleDialogId,
            msgId: 4,
            senderAccountId: "account-gone",
            clientMsgId: "stale-message",
            kind: "text",
            text: "hydrated history remains recoverable",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-15T09:00:00Z"
        )
        try await store.applyHistoryPage(
            HistoryPageResponse(
                dialogId: staleDialogId,
                messages: [staleMessage],
                nextBeforeMsgId: nil,
                hasMore: false
            )
        )
        try await store.savePts(17, accountId: accountId)
        let pendingClientId = "pending-message"
        _ = try await store.insertSending(
            dialogId: existingDialogId,
            clientMsgId: pendingClientId,
            text: "still sending",
            senderAccountId: accountId
        )
        try await store.enqueueMessageMutation(
            clientMutationId: "pending-mutation",
            operation: "edit",
            dialogId: existingDialogId,
            msgId: 1,
            body: "edited locally",
            expectedEditVersion: 0
        )
        let transfer = PreparedMediaUpload(
            transferId: "pending-transfer",
            kind: "photo",
            contentType: "image/jpeg",
            fileName: "pending.jpg",
            byteSize: 42,
            sha256: String(repeating: "c", count: 64),
            durationMs: nil,
            width: 10,
            height: 10,
            encryptedSourcePath: "/private/pending-transfer.tojmedia",
            encryptedThumbnailPath: "/private/pending-transfer.thumb"
        )
        try await store.insertMediaTransfer(
            prepared: transfer,
            dialogId: existingDialogId,
            clientMsgId: "pending-media-message",
            caption: "pending",
            replyToMsgId: nil
        )
        let viewport = ChatViewportState(
            dialogId: existingDialogId,
            accountId: accountId,
            topVisibleMsgId: 1,
            wasAtBottom: false
        )
        try await store.saveViewportState(viewport)

        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference_too_long",
                state: .init(pts: 44),
                updates: nil,
                hasMore: nil
            ),
            accountId: accountId
        )
        let rebuildState = try await store.loadBootstrapState(accountId: accountId)
        XCTAssertEqual(rebuildState?.status, "needs_rebuild")
        XCTAssertEqual(rebuildState?.mode, .replacement)
        try await store.beginBootstrap(accountId: accountId, token: "bootstrap-token", snapshotPts: 44)
        let concurrentDialogId = "dialog-created-after-snapshot"
        let concurrentMessage = CloudMessage(
            dialogId: concurrentDialogId,
            msgId: 12,
            senderAccountId: accountId,
            clientMsgId: "post-snapshot-message",
            kind: "text",
            text: "arrived after bootstrap began",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-16T10:00:12Z"
        )
        try await store.applyHistoryPage(
            HistoryPageResponse(
                dialogId: concurrentDialogId,
                messages: [concurrentMessage],
                nextBeforeMsgId: nil,
                hasMore: false
            )
        )
        let refreshedEarlierMessage = CloudMessage(
            dialogId: existingDialogId,
            msgId: 7,
            senderAccountId: "account-peer",
            clientMsgId: "replacement-earlier-message",
            kind: "text",
            text: "replacement earlier row",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-16T10:00:07Z"
        )
        let refreshedMessage = CloudMessage(
            dialogId: existingDialogId,
            msgId: 9,
            senderAccountId: "account-peer",
            clientMsgId: "replacement-message",
            kind: "text",
            text: "replacement recent row",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-16T10:00:08Z"
        )
        let newMessage = CloudMessage(
            dialogId: "dialog-new",
            msgId: 9,
            senderAccountId: "account-other",
            clientMsgId: "snapshot-message",
            kind: "text",
            text: "new snapshot row",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-16T10:00:09Z"
        )
        try await store.applyBootstrapPage(
            BootstrapDialogsPage(
                token: "bootstrap-token",
                state: .init(pts: 44),
                dialogs: [
                    BootstrapDialog(
                        dialogId: existingDialogId,
                        type: "direct",
                        title: "Refreshed title",
                        lastMsgId: 9,
                        updatedAt: "2026-07-16T10:00:08Z",
                        members: [
                            BootstrapDialogMember(
                                accountId: accountId,
                                role: "member",
                                lastReadMsgId: 0
                            ),
                            BootstrapDialogMember(
                                accountId: "account-peer",
                                role: "member",
                                lastReadMsgId: 0
                            )
                        ],
                        messages: [refreshedEarlierMessage, refreshedMessage]
                    ),
                    BootstrapDialog(
                        dialogId: "dialog-new",
                        type: "direct",
                        title: "Other",
                        lastMsgId: 9,
                        updatedAt: "2026-07-16T10:00:09Z",
                        members: [],
                        messages: [newMessage]
                    )
                ],
                nextCursor: "cursor-2",
                hasMore: true
            )
        )

        let retainedMessages = try await store.messages(dialogId: existingDialogId)
        let retainedDialogs = try await store.dialogs(accountId: accountId)
        let retainedOutbox = try await store.pendingOutboxReady()
        let retainedMutations = try await store.pendingMessageMutationsReady()
        let retainedTransfer = try await store.mediaTransfer(id: transfer.transferId)
        let retainedViewport = try await store.loadViewportState(dialogId: existingDialogId, accountId: accountId)
        let retainedHistory = try await store.loadHistoryState(dialogId: existingDialogId)
        let ptsDuringBootstrap = try await store.loadPts(accountId: accountId)
        let progressValue = try await store.loadBootstrapState(accountId: accountId)
        let progress = try XCTUnwrap(progressValue)
        XCTAssertEqual(
            retainedMessages.map(\.text),
            ["keep local history", "stale snapshot-owned row", "still sending"]
        )
        XCTAssertEqual(
            Set(retainedDialogs.map(\.dialogId)),
            [existingDialogId, staleDialogId, concurrentDialogId]
        )
        XCTAssertEqual(
            retainedDialogs.first(where: { $0.dialogId == existingDialogId })?.title,
            "Old title"
        )
        XCTAssertFalse(retainedDialogs.contains(where: { $0.dialogId == "dialog-new" }))
        XCTAssertEqual(retainedOutbox.map(\.clientMsgId), [pendingClientId])
        XCTAssertEqual(retainedMutations.map(\.clientMutationId), ["pending-mutation"])
        XCTAssertNotNil(retainedTransfer)
        XCTAssertEqual(retainedViewport, viewport)
        XCTAssertTrue(try XCTUnwrap(retainedHistory).historyComplete)
        XCTAssertEqual(ptsDuringBootstrap, 17)
        XCTAssertEqual(progress.token, "bootstrap-token")
        XCTAssertEqual(progress.nextCursor, "cursor-2")
        XCTAssertEqual(progress.snapshotPts, 44)
        XCTAssertEqual(progress.mode, .replacement)

        try await store.finishBootstrap(accountId: accountId, pts: 44)
        let finishedPts = try await store.loadPts(accountId: accountId)
        let finishedBootstrap = try await store.loadBootstrapState(accountId: accountId)
        let finishedDialogs = try await store.dialogs(accountId: accountId)
        let finishedMessages = try await store.messages(dialogId: existingDialogId)
        let retainedStaleHistory = try await store.messages(dialogId: staleDialogId)
        let finishedOutbox = try await store.pendingOutboxReady()
        let finishedMutations = try await store.pendingMessageMutationsReady()
        let finishedTransfer = try await store.mediaTransfer(id: transfer.transferId)
        let finishedViewport = try await store.loadViewportState(
            dialogId: existingDialogId,
            accountId: accountId
        )
        let finishedHistory = try await store.loadHistoryState(dialogId: existingDialogId)
        XCTAssertEqual(finishedPts, 44)
        XCTAssertNil(finishedBootstrap)
        XCTAssertEqual(
            Set(finishedDialogs.map(\.dialogId)),
            [existingDialogId, "dialog-new", concurrentDialogId]
        )
        XCTAssertEqual(
            finishedDialogs.first(where: { $0.dialogId == existingDialogId })?.title,
            "Refreshed title"
        )
        XCTAssertEqual(
            finishedMessages.map(\.text),
            [
                "keep local history", "replacement earlier row",
                "replacement recent row", "still sending"
            ]
        )
        XCTAssertEqual(retainedStaleHistory.map(\.text), ["hydrated history remains recoverable"])
        XCTAssertEqual(finishedOutbox.map(\.clientMsgId), [pendingClientId])
        XCTAssertEqual(finishedMutations.map(\.clientMutationId), ["pending-mutation"])
        XCTAssertNotNil(finishedTransfer)
        XCTAssertEqual(finishedViewport, viewport)
        XCTAssertTrue(try XCTUnwrap(finishedHistory).historyComplete)
    }

    func testWrongSQLCipherKeyDoesNotDeleteExistingReplica() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cloud.sqlite").path
        let correctKey = Data("correct-replica-key".utf8)
        do {
            let store = try CloudLocalStore(path: path, key: correctKey)
            _ = try await store.insertSending(
                dialogId: "dialog-preserved",
                clientMsgId: "preserved-client-id",
                text: "must survive",
                senderAccountId: "account-me"
            )
        }
        let sizeBefore = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber
        ).int64Value

        XCTAssertThrowsError(try CloudLocalStore(path: path, key: Data("wrong-replica-key".utf8)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let sizeAfter = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber
        ).int64Value
        XCTAssertEqual(sizeAfter, sizeBefore)

        let reopened = try CloudLocalStore(path: path, key: correctKey)
        let reopenedMessages = try await reopened.messages(dialogId: "dialog-preserved")
        XCTAssertEqual(reopenedMessages.first?.text, "must survive")
    }

    func testPostLaunchIntegrityCheckRejectsCorruptReplicaWithoutDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cloud.sqlite").path
        let key = Data("corrupt-replica-key".utf8)

        do {
            let store = try CloudLocalStore(path: path, key: key)
            for index in 0..<200 {
                _ = try await store.insertSending(
                    dialogId: "dialog-corruption",
                    clientMsgId: "corruption-\(index)",
                    text: String(repeating: "encrypted payload \(index) ", count: 20),
                    senderAccountId: "account-me"
                )
            }
        }

        var corruptedBytes = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(corruptedBytes.count, 8_192)
        // Damage a late data page, not SQLite's schema/migration pages. Opening and migrations
        // should remain on the fast launch path; the deferred whole-store scan must find this.
        let corruptedOffset = corruptedBytes.count - 128
        corruptedBytes[corruptedOffset] ^= 0xff
        try corruptedBytes.write(to: URL(fileURLWithPath: path), options: .atomic)

        let reopened = try CloudLocalStore(path: path, key: key)
        do {
            try await reopened.verifyIntegrity()
            XCTFail("The post-launch integrity check should reject a corrupt encrypted page")
        } catch {
            // Expected: the file remains in place for authenticated quarantine/recovery.
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let preservedBytes = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertGreaterThanOrEqual(preservedBytes.count, corruptedBytes.count)
        XCTAssertEqual(preservedBytes[corruptedOffset], corruptedBytes[corruptedOffset])
    }

    func testQuarantinePreservesSQLiteDatabaseAndSidecarsWithoutDeleting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cloud.sqlite").path
        let payloads: [String: Data] = [
            "": Data("database".utf8),
            "-wal": Data("write-ahead-log".utf8),
            "-shm": Data("shared-memory".utf8),
        ]
        for (suffix, data) in payloads {
            try data.write(to: URL(fileURLWithPath: path + suffix))
        }

        let quarantined = try XCTUnwrap(
            CloudLocalStore.quarantineStore(
                at: path,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        XCTAssertTrue(quarantined.lastPathComponent.hasPrefix("cloud-20231114-221320-"))
        for (suffix, expected) in payloads {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path + suffix))
            let moved = quarantined.appending(path: "cloud.sqlite\(suffix)")
            XCTAssertEqual(try Data(contentsOf: moved), expected)
        }
        let values = try quarantined.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testMediaDownloadClaimIsAtomicAndReenqueueDoesNotDuplicateInflightWork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cloud.sqlite").path
        let key = Data("atomic-media-claim-key".utf8)
        let firstStore = try CloudLocalStore(path: path, key: key)
        let secondStore = try CloudLocalStore(path: path, key: key)
        let mediaId = UUID().uuidString.lowercased()
        let enqueuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await firstStore.enqueueMediaDownloadJob(MediaDownloadJobRecord(
            mediaId: mediaId, variant: "full", dialogId: "dialog-claim",
            priority: 10, state: .queued, userInitiated: false, retryCount: 0,
            nextRetryAt: nil, lastError: nil,
            updatedAt: CloudLocalStore.sqliteTimestamp(enqueuedAt)
        ))

        async let firstClaim = firstStore.claimNextMediaDownloadJob(now: enqueuedAt.addingTimeInterval(1))
        async let secondClaim = secondStore.claimNextMediaDownloadJob(now: enqueuedAt.addingTimeInterval(1))
        let (claimedByFirst, claimedBySecond) = try await (firstClaim, secondClaim)
        let claims = [claimedByFirst, claimedBySecond].compactMap { $0 }
        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(claims.first?.mediaId, mediaId)
        XCTAssertEqual(claims.first?.state, .downloading)

        try await secondStore.enqueueMediaDownloadJob(MediaDownloadJobRecord(
            mediaId: mediaId, variant: "full", dialogId: "dialog-claim",
            priority: 100, state: .queued, userInitiated: true, retryCount: 0,
            nextRetryAt: nil, lastError: nil,
            updatedAt: CloudLocalStore.sqliteTimestamp(enqueuedAt.addingTimeInterval(2))
        ))
        let inflight = try await firstStore.mediaDownloadJob(mediaId: mediaId, variant: "full")
        XCTAssertEqual(inflight?.state, .downloading)
        XCTAssertEqual(inflight?.priority, 100)
        XCTAssertEqual(inflight?.userInitiated, true)
        let readyAfterReenqueue = try await firstStore.mediaDownloadJobsReady()
        XCTAssertTrue(readyAfterReenqueue.isEmpty)
    }

    func testWarmCacheRecoversInterruptedDownloadingJobsForNewProcess() async throws {
        let store = try makeStore()
        let mediaId = UUID().uuidString.lowercased()
        try await store.upsertMediaDownloadJob(MediaDownloadJobRecord(
            mediaId: mediaId, variant: "full", dialogId: "dialog-recovery",
            priority: 10, state: .downloading, userInitiated: false, retryCount: 2,
            nextRetryAt: nil, lastError: nil,
            updatedAt: CloudLocalStore.sqliteTimestamp(Date().addingTimeInterval(-60))
        ))
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = try EncryptedMediaCache(
            root: cacheDirectory, keyData: Data(repeating: 0x71, count: 32), limitBytes: 1_000_000
        )
        let engine = CloudMediaTransferEngine(cache: cache)

        try await engine.warmCache(localStore: store)

        let recovered = try await store.mediaDownloadJob(mediaId: mediaId, variant: "full")
        XCTAssertEqual(recovered?.state, .queued)
        XCTAssertEqual(recovered?.retryCount, 2)
        XCTAssertEqual(recovered?.lastError, "interrupted")
        let readyAfterRecovery = try await store.mediaDownloadJobsReady()
        XCTAssertEqual(readyAfterRecovery.map(\.mediaId), [mediaId])
    }

    func testSelectiveAndAllCacheClearsCancelOnlyInactiveDurableJobs() async throws {
        let store = try makeStore()
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = try EncryptedMediaCache(
            root: cacheDirectory, keyData: Data(repeating: 0x72, count: 32), limitBytes: 1_000_000
        )
        let engine = CloudMediaTransferEngine(cache: cache)
        let activeId = UUID().uuidString.lowercased()
        let inactiveId = UUID().uuidString.lowercased()
        let inflightId = UUID().uuidString.lowercased()
        let uncachedId = UUID().uuidString.lowercased()
        let payload = Data(repeating: 0x73, count: 64)
        try await cache.storeDownloadChunk(payload, mediaId: activeId, offset: 0)
        try await cache.storeDownloadChunk(payload, mediaId: inactiveId, offset: 0)
        for mediaId in [activeId, inactiveId] {
            try await store.upsertMediaCacheEntry(MediaCacheEntry(
                mediaId: mediaId, variant: "full",
                encryptedPath: cacheDirectory.appending(path: "downloads/\(mediaId)").path,
                byteSize: Int64(payload.count), cachedBytes: Int64(payload.count + 28),
                contiguousOffset: Int64(payload.count), state: "complete",
                lastAccessedAt: CloudLocalStore.sqliteTimestamp(Date()), protectedUntil: nil
            ))
        }
        try await engine.warmCache(localStore: store)
        try await cache.beginAccess(mediaId: activeId)
        for (mediaId, state) in [
            (activeId, MediaDownloadJobState.queued),
            (inactiveId, .queued),
            (inflightId, .downloading),
        ] {
            try await store.upsertMediaDownloadJob(MediaDownloadJobRecord(
                mediaId: mediaId, variant: "full", dialogId: "dialog-clear",
                priority: 10, state: state, userInitiated: false, retryCount: 0,
                nextRetryAt: nil, lastError: nil,
                updatedAt: CloudLocalStore.sqliteTimestamp(Date())
            ))
        }

        await engine.clearMediaCache(
            mediaIds: [activeId, inactiveId, inflightId],
            localStore: store
        )

        let activeLedgerAfterSelectiveClear = try await store.mediaCacheEntry(
            mediaId: activeId, variant: "full"
        )
        let inactiveLedgerAfterSelectiveClear = try await store.mediaCacheEntry(
            mediaId: inactiveId, variant: "full"
        )
        let activeJobAfterSelectiveClear = try await store.mediaDownloadJob(
            mediaId: activeId, variant: "full"
        )
        let inactiveJobAfterSelectiveClear = try await store.mediaDownloadJob(
            mediaId: inactiveId, variant: "full"
        )
        let inflightJobAfterSelectiveClear = try await store.mediaDownloadJob(
            mediaId: inflightId, variant: "full"
        )
        XCTAssertNotNil(activeLedgerAfterSelectiveClear)
        XCTAssertNil(inactiveLedgerAfterSelectiveClear)
        XCTAssertNotNil(activeJobAfterSelectiveClear)
        XCTAssertNil(inactiveJobAfterSelectiveClear)
        XCTAssertEqual(inflightJobAfterSelectiveClear?.state, .downloading)

        try await store.enqueueMediaDownloadJob(MediaDownloadJobRecord(
            mediaId: uncachedId, variant: "full", dialogId: "dialog-clear",
            priority: 10, state: .queued, userInitiated: false, retryCount: 0,
            nextRetryAt: nil, lastError: nil,
            updatedAt: CloudLocalStore.sqliteTimestamp(Date())
        ))
        await engine.clearDownloadedCache(localStore: store)

        let activeJobAfterClearAll = try await store.mediaDownloadJob(
            mediaId: activeId, variant: "full"
        )
        let uncachedJobAfterClearAll = try await store.mediaDownloadJob(
            mediaId: uncachedId, variant: "full"
        )
        let inflightJobAfterClearAll = try await store.mediaDownloadJob(
            mediaId: inflightId, variant: "full"
        )
        XCTAssertNotNil(activeJobAfterClearAll)
        XCTAssertNil(uncachedJobAfterClearAll)
        XCTAssertEqual(inflightJobAfterClearAll?.state, .downloading)
        await cache.endAccess(mediaId: activeId)
    }

    func testConversationObservationFirstEmissionIsAuthoritativeAndOwnsLaterUpdates() async throws {
        let store = try makeStore()
        _ = try await store.insertSending(
            dialogId: "dialog-observed",
            clientMsgId: "first-local-message",
            text: "already saved",
            senderAccountId: "account-me"
        )

        let stream = await store.observeConversation(dialogId: "dialog-observed")
        var iterator = stream.makeAsyncIterator()
        let firstValue = try await iterator.next()
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.timeline.messages.map(\.text), ["already saved"])
        XCTAssertTrue(first.mutations.isEmpty)
        XCTAssertTrue(first.transfers.isEmpty)

        _ = try await store.insertSending(
            dialogId: "dialog-observed",
            clientMsgId: "second-local-message",
            text: "arrived through the same observation",
            senderAccountId: "account-me"
        )
        let secondValue = try await iterator.next()
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(
            second.timeline.messages.map(\.text),
            ["already saved", "arrived through the same observation"]
        )
    }

    func testEncryptedRepresentationsPersistAcrossRelaunchCorruptionAndClearing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 0x7a, count: 32)
        let mediaId = UUID().uuidString.lowercased()
        let payload = Data("durable prepared bubble representation".utf8)
        let representationURL = directory.appending(
            path: "representations/\(mediaId)/bubble-720.tojrep"
        )

        let firstCache = try EncryptedMediaCache(
            root: directory,
            keyData: key,
            policy: MediaCachePolicy(sizeLimit: .unlimited, retention: .forever)
        )
        try await firstCache.storeRepresentation(
            payload,
            mediaId: mediaId,
            variant: .bubble720
        )
        let ledgerStore = try makeStore()
        let media = CloudMedia(
            id: mediaId,
            kind: "photo",
            contentType: "image/jpeg",
            fileName: nil,
            byteSize: Int64(payload.count),
            durationMs: nil,
            width: 64,
            height: 64,
            hasThumbnail: false
        )
        for entry in try await firstCache.durableEntries(media: media) {
            try await ledgerStore.upsertMediaCacheEntry(entry)
        }
        let representationLedger = try await ledgerStore.mediaCacheEntry(
            mediaId: mediaId,
            variant: MediaPresentationVariant.bubble720.rawValue
        )
        XCTAssertEqual(representationLedger?.state, "complete")
        let encryptedBytes = try Data(contentsOf: representationURL)
        XCTAssertNotEqual(encryptedBytes, payload)
        XCTAssertNil(encryptedBytes.range(of: payload))

        let relaunchedCache = try EncryptedMediaCache(
            root: directory,
            keyData: key,
            policy: MediaCachePolicy(sizeLimit: .unlimited, retention: .forever)
        )
        let relaunchedRepresentation = try await relaunchedCache.representation(
            mediaId: mediaId,
            variant: .bubble720
        )
        XCTAssertEqual(relaunchedRepresentation, payload)

        try Data("corrupt".utf8).write(to: representationURL, options: .atomic)
        let corruptRepresentation = try await relaunchedCache.representation(
            mediaId: mediaId,
            variant: .bubble720
        )
        XCTAssertNil(corruptRepresentation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: representationURL.path))

        try await relaunchedCache.storeRepresentation(
            payload,
            mediaId: mediaId,
            variant: .bubble720
        )
        _ = try await relaunchedCache.clearDownloaded()
        let clearedRepresentation = try await relaunchedCache.representation(
            mediaId: mediaId,
            variant: .bubble720
        )
        XCTAssertNil(clearedRepresentation)
    }

    func testAccountCatalogEnforcesIsolationLimitGenerationAndDurableRemovalFence() async throws {
        let service = "com.toj.account-catalog.tests.\(UUID().uuidString)"
        let catalog = AccountCatalog(service: service)
        let deployment = try XCTUnwrap(
            URL(string: "https://Cloud.Example.test/Cloud/?ignored=true#fragment")
        )
        let accountIds = (0..<4).map { _ in UUID().uuidString.lowercased() }
        let sessions = accountIds.enumerated().map { index, accountId in
            storedSession(accountId: accountId, deviceId: UUID().uuidString.lowercased(), suffix: index)
        }

        for session in sessions.prefix(3) {
            _ = try await catalog.add(session, deployment: deployment)
        }
        var snapshot = try await catalog.snapshot()
        XCTAssertEqual(snapshot.accounts.map(\.accountId), Array(accountIds.prefix(3)))
        XCTAssertEqual(snapshot.activeAccountId, accountIds[2])
        XCTAssertEqual(Set(snapshot.accounts.map(\.deployment)), ["https://cloud.example.test/Cloud"])
        let firstInstallationId = try await catalog.installationId()
        let secondInstallationId = try await catalog.installationId()
        XCTAssertEqual(firstInstallationId, secondInstallationId)

        do {
            _ = try await catalog.add(sessions[3], deployment: deployment)
            XCTFail("A fourth account must be rejected")
        } catch let error as AccountCatalogError {
            XCTAssertEqual(error, .accountLimitReached)
        }
        do {
            _ = try await catalog.add(sessions[0], deployment: deployment)
            XCTFail("A redundant login must not replace the existing device session")
        } catch let error as AccountCatalogError {
            XCTAssertEqual(
                error,
                .duplicateAccount(existingDeviceId: sessions[0].session.deviceId)
            )
        }

        let activated = try await catalog.activate(accountId: accountIds[0])
        XCTAssertEqual(activated.generation, 2)
        snapshot = try await catalog.snapshot()
        XCTAssertEqual(
            snapshot.accounts.first(where: { $0.accountId == accountIds[2] })?.generation,
            2,
            "Switching must fence callbacks from the old foreground account"
        )
        do {
            _ = try await catalog.replaceSession(
                accountId: accountIds[0],
                expectedGeneration: 1,
                with: sessions[0]
            )
            XCTFail("A stale refresh callback must not replace current credentials")
        } catch let error as AccountCatalogError {
            XCTAssertEqual(error, .staleGeneration)
        }

        snapshot = try await catalog.beginRemoval(accountId: accountIds[0])
        XCTAssertFalse(snapshot.accounts.contains(where: { $0.accountId == accountIds[0] }))
        XCTAssertEqual(snapshot.pendingRemovalAccountIds, [accountIds[0]])
        let relaunched = AccountCatalog(service: service)
        let relaunchedSnapshot = try await relaunched.snapshot()
        XCTAssertEqual(relaunchedSnapshot.pendingRemovalAccountIds, [accountIds[0]])
        snapshot = try await relaunched.finishRemoval(accountId: accountIds[0])
        XCTAssertTrue(snapshot.pendingRemovalAccountIds.isEmpty)
        for accountId in accountIds[1...2] {
            _ = try await relaunched.remove(accountId: accountId)
        }
    }

    func testRemovingForegroundAccountFencesCallbacksBeforeReplacementOwnsForeground() async throws {
        let service = "com.toj.account-removal.tests.\(UUID().uuidString)"
        let catalog = AccountCatalog(service: service)
        let deployment = try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))
        let firstId = UUID().uuidString.lowercased()
        let secondId = UUID().uuidString.lowercased()
        _ = try await catalog.add(
            storedSession(
                accountId: firstId,
                deviceId: UUID().uuidString.lowercased(),
                suffix: 31
            ),
            deployment: deployment
        )
        _ = try await catalog.add(
            storedSession(
                accountId: secondId,
                deviceId: UUID().uuidString.lowercased(),
                suffix: 32
            ),
            deployment: deployment
        )

        let registry = MessagingAccountRuntimeRegistry(
            catalog: catalog,
            config: CloudConfig(baseURL: deployment)
        )
        _ = try await registry.restore()
        let removedCandidate = await registry.runtime(accountId: secondId)
        let replacementCandidate = await registry.runtime(accountId: firstId)
        let removedRuntime = try XCTUnwrap(removedCandidate)
        let replacementRuntime = try XCTUnwrap(replacementCandidate)
        let removedFence = await removedRuntime.callbackFence
        let removedOwnedForegroundBeforeRemoval = await removedRuntime.isForegroundOwner
        let replacementOwnedForegroundBeforeRemoval = await replacementRuntime.isForegroundOwner
        XCTAssertTrue(removedOwnedForegroundBeforeRemoval)
        XCTAssertFalse(replacementOwnedForegroundBeforeRemoval)

        let snapshot = try await registry.removeAccount(accountId: secondId)

        XCTAssertEqual(snapshot.activeAccountId, firstId)
        XCTAssertFalse(snapshot.accounts.contains(where: { $0.accountId == secondId }))
        XCTAssertTrue(snapshot.pendingRemovalAccountIds.isEmpty)
        let removedOwnedForegroundAfterRemoval = await removedRuntime.isForegroundOwner
        let removedAcceptedStaleCallback = await removedRuntime.acceptsCallback(fence: removedFence)
        let replacementOwnedForegroundAfterRemoval = await replacementRuntime.isForegroundOwner
        XCTAssertFalse(removedOwnedForegroundAfterRemoval)
        XCTAssertFalse(removedAcceptedStaleCallback)
        XCTAssertTrue(replacementOwnedForegroundAfterRemoval)

        _ = try await registry.removeAccount(accountId: firstId)
    }

    func testAccountScopedPathsKeysAndRuntimeCallbacksCannotCrossAccounts() async throws {
        let firstId = UUID().uuidString.lowercased()
        let secondId = UUID().uuidString.lowercased()
        let firstPaths = try AccountStoragePaths.resolve(accountId: firstId)
        let secondPaths = try AccountStoragePaths.resolve(accountId: secondId)
        XCTAssertNotEqual(firstPaths.root, secondPaths.root)
        XCTAssertTrue(firstPaths.database.path.contains("/Accounts/\(firstId)/"))
        XCTAssertTrue(secondPaths.media.path.contains("/Accounts/\(secondId)/"))
        XCTAssertThrowsError(try AccountStoragePaths.resolve(accountId: "../shared"))

        let firstKeyStore = try LocalDatabaseKeyStore.accountScoped(accountId: firstId)
        let secondKeyStore = try LocalDatabaseKeyStore.accountScoped(accountId: secondId)
        let firstKey = try firstKeyStore.loadOrCreateKey()
        let secondKey = try secondKeyStore.loadOrCreateKey()
        XCTAssertEqual(firstKey.count, 32)
        XCTAssertEqual(secondKey.count, 32)
        XCTAssertNotEqual(firstKey, secondKey)

        let deployment = try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))
        let account = CatalogAccount(
            accountId: firstId,
            deployment: AccountCatalog.normalizedDeployment(deployment),
            storedSession: storedSession(
                accountId: firstId,
                deviceId: UUID().uuidString.lowercased(),
                suffix: 1
            ),
            state: .authenticated,
            generation: 1,
            addedAt: Date(),
            lastActivatedAt: Date()
        )
        let runtime = try MessagingAccountRuntime(
            account: account,
            config: CloudConfig(baseURL: deployment)
        )
        try await runtime.start(with: account)
        let firstFence = await runtime.claimForeground()
        let acceptedBeforeRelease = await runtime.acceptsCallback(fence: firstFence)
        XCTAssertTrue(acceptedBeforeRelease)
        await runtime.releaseForeground()
        let acceptedAfterRelease = await runtime.acceptsCallback(fence: firstFence)
        XCTAssertFalse(acceptedAfterRelease)
        try await runtime.shutDownForRemoval()

        try? AccountLocalStoreFactory.destroy(accountId: firstId)
        try? AccountLocalStoreFactory.destroy(accountId: secondId)
    }

    func testSignInAgainRuntimeKeepsReplicaButDoesNotRestoreCredentials() async throws {
        let accountId = UUID().uuidString.lowercased()
        let deployment = try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))
        let session = storedSession(
            accountId: accountId,
            deviceId: UUID().uuidString.lowercased(),
            suffix: 41
        )
        let account = CatalogAccount(
            accountId: accountId,
            deployment: AccountCatalog.normalizedDeployment(deployment),
            storedSession: session,
            state: .signInAgain,
            generation: 2,
            addedAt: Date(),
            lastActivatedAt: Date()
        )
        let runtime = try MessagingAccountRuntime(
            account: account,
            config: CloudConfig(baseURL: deployment)
        )
        try await runtime.tokenStore.save(session)

        try await runtime.start(with: account)

        let authorization = await runtime.credentialCoordinator.authorizationToken(
            matching: session.session.token
        )
        XCTAssertNil(authorization)
        let persisted = try await runtime.tokenStore.load()
        XCTAssertNil(persisted)
        let requiresSignIn = await runtime.requiresSignIn
        XCTAssertTrue(requiresSignIn)

        try await runtime.shutDownForRemoval()
        try? AccountLocalStoreFactory.destroy(accountId: accountId)
    }

    private func makeStore() throws -> CloudLocalStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        return try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            key: Data("test-passphrase".utf8)
        )
    }

    private func storedSession(accountId: String, deviceId: String, suffix: Int) -> StoredCloudSession {
        StoredCloudSession(
            session: CloudSession(
                accountId: accountId,
                deviceId: deviceId,
                token: "access-\(suffix)",
                refreshToken: "refresh-\(suffix)",
                accessTokenExpiresAt: "2099-01-01T00:15:00.000Z",
                sessionExpiresAt: "2099-06-01T00:00:00.000Z",
                tokenVersion: 2
            ),
            phone: "+16505550\(String(format: "%03d", suffix))",
            displayName: "Account \(suffix)"
        )
    }
}

private final class CloudAPIMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var deferHandlerExecution = false
    private let stateLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override func startLoading() {
        if Self.deferHandlerExecution {
            let work = DispatchWorkItem { [weak self] in
                self?.runHandler()
            }
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
            return
        }
        runHandler()
    }

    private func runHandler() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            stateLock.lock()
            let shouldDeliver = !stopped
            stateLock.unlock()
            guard shouldDeliver else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class LockedGate: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didRelease = false

    func signalStarted() {
        started.signal()
    }

    func waitUntilStarted() -> Bool {
        started.wait(timeout: .now() + 2) == .success
    }

    func waitForRelease() {
        released.wait()
    }

    func release() {
        lock.lock()
        guard !didRelease else {
            lock.unlock()
            return
        }
        didRelease = true
        lock.unlock()
        released.signal()
    }
}

private final class LockedMediaRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(offset: Int64, bytes: Data)] = []

    func append(offset: Int64, bytes: Data) {
        lock.lock()
        requests.append((offset, bytes))
        lock.unlock()
    }

    func snapshot() -> [(offset: Int64, bytes: Data)] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class LockedMultipartRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(partIndex: Int, bytes: Data)] = []
    private var active = 0
    private(set) var maximumConcurrent = 0

    func begin(partIndex: Int, bytes: Data) {
        lock.lock()
        requests.append((partIndex, bytes))
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        lock.unlock()
    }

    func end() {
        lock.lock()
        active -= 1
        lock.unlock()
    }

    func snapshot() -> [(partIndex: Int, bytes: Data)] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class LockedProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
