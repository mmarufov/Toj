import XCTest

@MainActor
final class TelegramFastLocalFirstUITests: XCTestCase {
    private enum Fixture {
        static let primaryDialog = "00000000-0000-4000-8000-000000000201"
        static let secondDialog = "00000000-0000-4000-8000-000000000202"
        static let savedDialog = "00000000-0000-4000-8000-000000000203"
        static let photo = "00000000-0000-4000-8000-000000000301"
        static let video = "00000000-0000-4000-8000-000000000302"
    }

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        if name.contains("testAcknowledgedSingleAttachmentCreatesOptimisticMessageBeforeNetworking") {
            app.launchEnvironment["TOJ_UI_FIXTURE_SINGLE_DRAFT"] = "1"
        }
        if name.contains("testPresenceOnline") {
            app.launchEnvironment["TOJ_UI_FIXTURE_PRESENCE"] = "online"
        } else if name.contains("testPresenceTyping") {
            app.launchEnvironment["TOJ_UI_FIXTURE_PRESENCE"] = "typing"
        } else if name.contains("testPresenceUnsupported") {
            app.launchEnvironment["TOJ_UI_FIXTURE_PRESENCE"] = "unsupported"
        } else if name.contains("testPresenceConnectionTrouble") {
            app.launchEnvironment["TOJ_UI_FIXTURE_PRESENCE"] = "offline_override"
        }
        launch(reset: true)
    }

    func testPresenceOnlineUsesAuthenticatedFixtureState() {
        openChat(Fixture.primaryDialog)
        XCTAssertEqual(element("conversation-subtitle").label, "online")
    }

    func testPresenceTypingAppearsInListAndConversation() {
        XCTAssertTrue(app.staticTexts["typing…"].waitForExistence(timeout: 5))
        openChat(Fixture.primaryDialog)
        XCTAssertEqual(element("conversation-subtitle").label, "typing…")
    }

    func testPresenceUnsupportedShowsUnavailableInsteadOfAnApproximation() {
        openChat(Fixture.primaryDialog)
        XCTAssertEqual(element("conversation-subtitle").label, "status unavailable")
    }

    func testPresenceConnectionTroubleOverridesOnline() {
        openChat(Fixture.primaryDialog)
        XCTAssertEqual(element("conversation-subtitle").label, "Offline — showing saved chats")
    }

    func testColdOfflineOpenAndRapidChatSwitching() {
        XCTAssertTrue(
            app.staticTexts["Offline — showing saved chats"].waitForExistence(timeout: 15),
            "The fixture must remain explicitly offline while rendering the local replica."
        )

        openChat(Fixture.primaryDialog)
        XCTAssertTrue(element("conversation-\(Fixture.primaryDialog)").waitForExistence(timeout: 15))
        XCTAssertTrue(element("message-ui-fixture-text").waitForExistence(timeout: 15))
        XCTAssertTrue(element("message-ui-fixture-latest").exists)

        goBackToChats()
        openChat(Fixture.secondDialog)
        XCTAssertTrue(element("conversation-\(Fixture.secondDialog)").waitForExistence(timeout: 15))
        XCTAssertTrue(element("message-ui-fixture-second-chat").waitForExistence(timeout: 15))

        goBackToChats()
        openChat(Fixture.primaryDialog)
        XCTAssertTrue(element("conversation-\(Fixture.primaryDialog)").waitForExistence(timeout: 15))
        XCTAssertTrue(element("message-ui-fixture-latest").waitForExistence(timeout: 15))
    }

    func testSavedPhotoAndVideoOpenOfflineAcrossProcessRelaunch() {
        openChat(Fixture.primaryDialog)

        openMedia(Fixture.photo, towardOlderMessages: true)
        XCTAssertTrue(element("media-viewer-\(Fixture.photo)").waitForExistence(timeout: 15))
        dismissViewer()

        openMedia(Fixture.video, towardOlderMessages: false)
        XCTAssertTrue(element("media-viewer-\(Fixture.video)").waitForExistence(timeout: 15))

        // Kill while the cached video viewer is active. A new process must recover the same
        // encrypted bytes and durable representations without fixture reseeding or a server.
        app.terminate()
        launch(reset: false)
        openChat(Fixture.primaryDialog)
        openMedia(Fixture.photo, towardOlderMessages: true)
        XCTAssertTrue(
            element("media-viewer-\(Fixture.photo)").waitForExistence(timeout: 15),
            "A cached fullscreen photo must reopen from encrypted disk after process death."
        )
    }

    func testSavedMessagesSettingsRouteOpensEncryptedOfflineConversation() {
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 15))
        settingsTab.tap()

        let savedMessages = app.buttons["settings-saved-messages"]
        XCTAssertTrue(savedMessages.waitForExistence(timeout: 15))
        savedMessages.tap()

        XCTAssertTrue(element("conversation-\(Fixture.savedDialog)").waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Saved Messages"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("message-ui-fixture-saved-note").waitForExistence(timeout: 15))
    }

    func testGlobalMessageSearchJumpsToAndFlashesTheMatchedMessage() {
        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 15))
        searchTab.tap()

        let field = app.textFields["global-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("entirely")

        let messagesScope = app.buttons["Messages"]
        XCTAssertTrue(messagesScope.waitForExistence(timeout: 15))
        messagesScope.tap()

        let result = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'search-message-'"))
            .firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        XCTAssertTrue(result.label.contains("Mehrona Offline"), result.label)
        result.tap()

        // Observe the short-lived accessibility contract before asking XCTest for another full
        // hierarchy snapshot. On slower hosted runners, checking the conversation container first
        // can consume the entire 2.8-second flash even though the app behaved correctly.
        let flash = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", "Search match highlighted"))
            .firstMatch
        XCTAssertTrue(
            flash.waitForExistence(timeout: 15),
            "Opening a global hit must visibly connect the result to its message."
        )
        XCTAssertTrue(element("conversation-\(Fixture.primaryDialog)").waitForExistence(timeout: 15))
        XCTAssertTrue(element("message-ui-fixture-text").waitForExistence(timeout: 15))
    }

    func testInChatSearchMovesPreviousAndNextBetweenMatches() {
        openChat(Fixture.primaryDialog)

        let profile = app.buttons["Open Mehrona Offline profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 15))
        profile.tap()
        let search = app.buttons["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()

        // The conversation container intentionally carries a stable accessibility identifier,
        // so locate overlay controls by their user-facing accessibility contract.
        let field = app.textFields
            .matching(NSPredicate(format: "placeholderValue == %@", "Search in chat"))
            .firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("Saved")

        XCTAssertTrue(app.staticTexts["1 of 3"].waitForExistence(timeout: 15))

        let next = app.buttons["Go Down"]
        XCTAssertTrue(next.isHittable)
        next.tap()
        XCTAssertTrue(app.staticTexts["2 of 3"].waitForExistence(timeout: 15))

        let previous = app.buttons["Go Up"]
        XCTAssertTrue(previous.isHittable)
        previous.tap()
        XCTAssertTrue(app.staticTexts["1 of 3"].waitForExistence(timeout: 15))
    }

    func testDraftTextReplyAndThreeReorderedAttachmentsRestoreAfterTermination() {
        openChat(Fixture.primaryDialog)
        let composer = app.textFields["Message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        XCTAssertEqual(composer.value as? String, "Persistent exact draft  ")
        XCTAssertTrue(app.staticTexts["Replying"].exists)
        for index in 0..<3 {
            XCTAssertTrue(element("draft-attachment-ui-draft-\(index)").exists)
        }

        let lastMenu = element("draft-attachment-menu-ui-draft-2")
        XCTAssertTrue(lastMenu.exists)
        lastMenu.tap()
        app.buttons["Move earlier"].tap()
        lastMenu.tap()
        app.buttons["Move earlier"].tap()
        XCTAssertTrue(
            element("draft-attachment-ui-draft-2").label.contains("Attachment 1 of 3")
        )

        composer.tap()
        composer.typeText("edited")
        XCTAssertTrue(
            app.staticTexts["Draft saved locally"].waitForExistence(timeout: 15),
            "The encrypted local draft write must finish before simulating process death."
        )
        app.terminate()
        launch(reset: false)
        openChat(Fixture.primaryDialog)
        XCTAssertEqual(app.textFields["Message"].value as? String, "editedPersistent exact draft  ")
        XCTAssertTrue(element("draft-attachment-ui-draft-2").label.contains("Attachment 1 of 3"))
        XCTAssertTrue(app.staticTexts["Replying"].exists)
    }

    func testRemoteDeviceClearConvergesAfterRelaunch() {
        openChat(Fixture.primaryDialog)
        XCTAssertTrue(element("draft-attachment-ui-draft-0").waitForExistence(timeout: 15))
        app.terminate()
        app.launchEnvironment["TOJ_UI_FIXTURE_REMOTE_CLEAR"] = "1"
        launch(reset: false)
        openChat(Fixture.primaryDialog)
        XCTAssertTrue(element("draft-attachment-ui-draft-0").waitForNonExistence(timeout: 15))
        XCTAssertEqual(app.textFields["Message"].value as? String, "Message")
    }

    func testDraftComposerAccessibilityAtLargestTypeAndReducedMotion() {
        app.terminate()
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
            "-UIAccessibilityReduceMotionEnabled",
            "YES",
        ]
        launch(reset: false)
        openChat(Fixture.primaryDialog)
        XCTAssertTrue(app.textFields["Message"].isHittable)
        XCTAssertTrue(element("draft-attachment-ui-draft-0").label.contains("ready"))
        XCTAssertFalse(element("draft-attachment-ui-draft-0").label.isEmpty)
    }

    func testAcknowledgedAttachmentsCreateOneOptimisticGroupBeforeNetworking() {
        openChat(Fixture.primaryDialog)
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 15))
        send.tap()
        let pendingGroup = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'media-group-' AND identifier ENDSWITH '-pending'"))
            .firstMatch
        for _ in 0..<4 where !pendingGroup.exists {
            app.swipeUp()
        }
        XCTAssertTrue(pendingGroup.waitForExistence(timeout: 15))
        XCTAssertFalse(element("draft-attachment-ui-draft-0").exists)
    }

    func testAcknowledgedSingleAttachmentCreatesOptimisticMessageBeforeNetworking() {
        openChat(Fixture.primaryDialog)
        XCTAssertTrue(element("draft-attachment-ui-draft-0").waitForExistence(timeout: 15))
        XCTAssertFalse(element("draft-attachment-ui-draft-1").exists)
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 15))
        send.tap()
        XCTAssertTrue(element("media-bubble-\(Fixture.photo)").waitForExistence(timeout: 15))
        XCTAssertFalse(element("draft-attachment-ui-draft-0").exists)
    }

    func testPartialAndFailedAlbumsExposeStableAccessiblePresentation() {
        openChat(Fixture.primaryDialog)
        let partial = element("media-group-00000000-0000-4000-8000-000000000601")
        XCTAssertTrue(partial.waitForExistence(timeout: 15))
        XCTAssertTrue(partial.label.localizedCaseInsensitiveContains("2 of 3"))

        goBackToChats()
        openChat(Fixture.secondDialog)
        let failed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'media-group-'"))
            .matching(NSPredicate(format: "label CONTAINS[c] 'failed'"))
            .firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout: 15))
        XCTAssertTrue(failed.label.localizedCaseInsensitiveContains("2 of 2"))
    }

    private func launch(reset: Bool) {
        app.launchEnvironment["TOJ_UI_FIXTURE"] = "telegram-fast"
        app.launchEnvironment["TOJ_UI_FIXTURE_RESET"] = reset ? "1" : "0"
        app.launch()
        XCTAssertTrue(
            app.buttons["chat-row-\(Fixture.primaryDialog)"].waitForExistence(timeout: 45),
            "The encrypted local chat list did not become ready."
        )
    }

    private func openChat(_ dialogID: String) {
        let row = app.buttons["chat-row-\(dialogID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let conversation = element("conversation-\(dialogID)")
        if !conversation.waitForExistence(timeout: 5), row.waitForExistence(timeout: 15) {
            row.tap()
        }
        XCTAssertTrue(
            conversation.waitForExistence(timeout: 15),
            "The chat row tap did not complete navigation to \(dialogID)."
        )
    }

    private func goBackToChats() {
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15))
        back.tap()
        XCTAssertTrue(app.buttons["chat-row-\(Fixture.primaryDialog)"].waitForExistence(timeout: 15))
    }

    private func openMedia(_ mediaID: String, towardOlderMessages: Bool) {
        let bubble = element("media-bubble-\(mediaID)")
        for _ in 0..<8 where !bubble.isHittable {
            towardOlderMessages ? app.swipeDown() : app.swipeUp()
        }
        XCTAssertTrue(bubble.waitForExistence(timeout: 15), "Media bubble \(mediaID) was not rendered.")
        XCTAssertTrue(bubble.isHittable, "Media bubble \(mediaID) could not be brought on screen.")
        bubble.tap()
    }

    private func dismissViewer() {
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15))
        back.tap()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

}
