import AppKit
import XCTest
import CirclesCore
import CirclesKit

/// The first-run journey through the real app, like the GNOME app's
/// `--snapshot` self-test: onboarding, adding a contact by invite, receiving
/// their post through an incoming sync, +1, commenting (pending, then
/// approved), posting, circles, settings and a community. The test runner plays the
/// second person, Bob, with CirclesKit, syncing with the app over loopback.
/// A screenshot of each step is attached to the test result.
@MainActor
final class FirstRunUITests: XCTestCase {
    func testFirstRunJourney() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["CIRCLES_FRESH_HOME"] = "1" // start at onboarding
        app.launch()
        defer { app.terminate() }
        let bobHome = FileManager.default.temporaryDirectory
            .appending(path: "circles-uitest-bob-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: bobHome) }

        // Onboarding.
        let name = app.textFields["onboarding-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15), "an empty home starts at onboarding")
        snapshot(app, "0-onboarding")
        name.click()
        name.typeText("Alice Liddell")
        app.buttons["onboarding-create"].click()

        // The Stream, online.
        let status = app.staticTexts["network-status"]
        try await waitFor(status, "value BEGINSWITH 'Online'", timeout: 30, because: "the network came online")
        let port = try XCTUnwrap(Self.port(in: status), "the status line shows the port")
        try await waitFor(text(app, "Nothing here yet"), because: "the new Stream is empty")
        snapshot(app, "1-stream-empty")

        // People: exchange invites with Bob through the pasteboard.
        app.descendants(matching: .any)["sidebar-people"].click()
        let copy = app.buttons["copy-my-invite"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        NSPasteboard.general.clearContents()
        copy.click()
        let aliceInvite = try await pasteboardString(prefix: "circles-invite:")
        let bob = try await Account.create(home: bobHome, displayName: "Bob Marley")
        _ = try await bob.addContact(invite: aliceInvite)

        let bobInvite = try await bob.invite()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bobInvite, forType: .string)
        let inviteField = app.textFields["invite-field"]
        inviteField.click()
        inviteField.typeKey("v", modifierFlags: .command)
        app.buttons["add-contact"].click()
        try await waitFor(text(app, "Added Bob Marley"), because: "pasting Bob's invite added him")
        snapshot(app, "2-people")

        // Bob posts and syncs in; the Stream updates by itself.
        app.descendants(matching: .any)["sidebar-stream"].click()
        _ = try await bob.post(RichText(plain: "Sunset from the ridge last night."), to: .everyone)
        _ = try await bob.sync(host: "127.0.0.1", port: port)
        try await waitFor(text(app, "Sunset from the ridge"), timeout: 15, because: "an incoming sync from Bob updated the Stream")
        snapshot(app, "3-stream-bob")

        // +1.
        let plusOne = app.buttons["plus-one"].firstMatch
        plusOne.click()
        try await waitFor(plusOne, "label BEGINSWITH 'Remove +1, 1'", because: "the +1 registered")

        // The post page: a comment is pending until Bob approves it.
        app.buttons["open-comments"].firstMatch.click()
        let commentField = app.textFields["comment-field"]
        XCTAssertTrue(commentField.waitForExistence(timeout: 10), "the post page opened")
        commentField.click()
        commentField.typeText("Gorgeous light.")
        commentField.typeKey(.return, modifierFlags: [])
        let pending = text(app, "Only you can see this until it's approved")
        try await waitFor(pending, because: "our comment shows as pending")
        snapshot(app, "4-post-pending")

        _ = try await bob.sync(host: "127.0.0.1", port: port) // Bob receives the comment,
        _ = try await bob.stream() // approves it as he reads his Stream,
        _ = try await bob.sync(host: "127.0.0.1", port: port) // and sends it back.
        try await waitFor(pending, "exists == false", timeout: 15, because: "Bob's approval reached the open post page")
        snapshot(app, "5-post-approved")
        app.toolbars.buttons["Back"].click() // ⌘[ goes to the focused comment field instead

        // The composer.
        app.typeKey("n", modifierFlags: .command)
        let editor = app.textViews["composer-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "⌘N opened the composer")
        editor.click()
        editor.typeText("Posted by the UI test.")
        app.descendants(matching: .any)["audience-public"].firstMatch.click()
        snapshot(app, "6-composer")
        let post = app.buttons["composer-post"]
        try await waitFor(post, "isEnabled == true", because: "Post is enabled with text and an audience")
        post.click()
        try await waitFor(text(app, "Posted by the UI test."), because: "the new post is in the Stream")
        snapshot(app, "7-stream-posted")

        // Circles: create one and put Bob in it.
        app.descendants(matching: .any)["sidebar-circles"].click()
        let circleField = app.textFields["new-circle-field"]
        XCTAssertTrue(circleField.waitForExistence(timeout: 10))
        circleField.click()
        circleField.typeText("Family")
        circleField.typeKey(.return, modifierFlags: [])
        let bobsCircles = app.descendants(matching: .any)["circles-menu-Bob Marley"].firstMatch
        try await waitFor(bobsCircles, "isEnabled == true", because: "creating a circle enabled Bob's circle menu")
        bobsCircles.click()
        app.menuItems["Family"].click()
        try await waitFor(bobsCircles, "title CONTAINS 'Family'", because: "Bob is in Family")
        snapshot(app, "8-circles")

        // Settings.
        app.typeKey(",", modifierFlags: .command)
        let accountTab = app.toolbars.buttons["Account"]
        try await waitFor(accountTab, because: "⌘, opened Settings")
        accountTab.click() // Settings reopens on the last tab used
        try await waitFor(text(app, "Copy User ID"), because: "the Account tab shows the identity")
        snapshot(app, "9-settings")
        app.typeKey("w", modifierFlags: .command) // close Settings

        try await communities(app, bob: bob, port: port)
    }

    /// Alice creates a private community; Bob asks to join with her invite,
    /// is let in, and posts; it all reaches the open community page.
    private func communities(_ app: XCUIApplication, bob: Account, port: Int) async throws {
        app.descendants(matching: .any)["sidebar-communities"].click()
        try await waitFor(text(app, "No communities yet"), because: "Communities starts empty")
        snapshot(app, "10-communities-empty")

        app.buttons["new-community"].click()
        let name = app.textFields["community-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "New Community… opened its sheet")
        name.click()
        name.typeText("Ridge Walkers")
        snapshot(app, "11-new-community")
        app.buttons["create-community"].click()
        try await waitFor(text(app, "Private · Approval needed · Owner"), because: "the new community opened, owned by us")

        NSPasteboard.general.clearContents()
        app.buttons["community-invite"].click()
        let invite = try await pasteboardString(prefix: "circles-community:")
        let community = try await bob.joinCommunity(invite: invite)
        _ = try await bob.sync(host: "127.0.0.1", port: port, target: community)
        let letIn = app.buttons["let-in-Bob Marley"]
        try await waitFor(letIn, timeout: 15, because: "Bob's join request reached the open community page")
        snapshot(app, "12-community-request")

        letIn.click()
        try await waitFor(letIn, "exists == false", because: "letting Bob in cleared the request")
        _ = try await bob.sync(host: "127.0.0.1", port: port, target: community)
        try await bob.processCommunities()
        _ = try await bob.post(RichText(plain: "Count me in for Saturday. I'll bring the good trail mix."), toCommunity: community)
        _ = try await bob.sync(host: "127.0.0.1", port: port, target: community)
        try await waitFor(text(app, "Count me in for Saturday"), timeout: 15, because: "Bob's post reached the community page")
        try await waitFor(text(app, "Bob Marley"), because: "Bob is listed as a member")
        snapshot(app, "13-community")
    }

    // MARK: Helpers

    /// An element showing `string`: SwiftUI text is a static text, or a text
    /// view when it's selectable, with the string as its value.
    private func text(_ app: XCUIApplication, _ string: String) -> XCUIElement {
        let types = [XCUIElement.ElementType.staticText, .textView, .button].map(\.rawValue)
        return app.descendants(matching: .any).matching(NSPredicate(
            format: "elementType IN %@ AND (value CONTAINS %@ OR label CONTAINS %@)", types, string, string)).firstMatch
    }

    private func waitFor(_ element: XCUIElement, _ format: String = "exists == true", timeout: TimeInterval = 10,
                         because description: String) async throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        expectation.expectationDescription = description
        await fulfillment(of: [expectation], timeout: timeout)
    }

    private func pasteboardString(prefix: String) async throws -> String {
        for _ in 0..<50 {
            if let string = NSPasteboard.general.string(forType: .string), string.hasPrefix(prefix) { return string }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("nothing starting with \(prefix) reached the pasteboard")
        throw CancellationError()
    }

    /// "Online · port 41234 · …" → 41234.
    private static func port(in status: XCUIElement) -> Int? {
        let summary = (status.value as? String) ?? status.label
        guard let range = summary.range(of: #"port (\d+)"#, options: .regularExpression) else { return nil }
        return Int(summary[range].dropFirst("port ".count))
    }

    /// The app's front window only: on macOS `app.screenshot()` captures the
    /// whole display, other apps included.
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
