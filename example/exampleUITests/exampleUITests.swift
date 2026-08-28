import XCTest

/// Drives the real app against ``PreviewAgentClient``, so the whole stack —
/// Agent, transcript reducer, MessageList, markdown renderer — is exercised
/// without spawning a CLI or spending tokens.
final class ExampleUITests: XCTestCase {

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-RXAgentPreviewClient", "YES"]
        app.launch()
        return app
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testComposerSendsAndAssistantReplies() throws {
        let app = launchApp()

        let field = app.textFields["agent-composer-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "composer should be present")

        field.click()
        field.typeText("How does the message list work?")

        let send = app.buttons["agent-composer-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.click()

        // The scripted reply streams in a few hundred milliseconds.
        let reply = app.staticTexts.containing(
            NSPredicate(format: "value CONTAINS[c] %@", "pins your prompt")
        ).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "the assistant reply should render")

        // And the prompt itself is still on screen.
        let prompt = app.staticTexts.containing(
            NSPredicate(format: "value CONTAINS[c] %@", "How does the message list work?")
        ).firstMatch
        XCTAssertTrue(prompt.exists, "the user message should remain in the transcript")
    }

    func testToolCallRendersAsACard() throws {
        let app = launchApp()

        // The second preview client is scripted to make tool calls.
        let picker = app.popUpButtons["agent-client-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.click()
        app.menuItems["Preview (tools)"].click()

        let field = app.textFields["agent-composer-field"]
        field.click()
        field.typeText("Clean up the greeting")
        app.buttons["agent-composer-send"].click()

        let bashCard = app.buttons["tool-call-Bash"]
        XCTAssertTrue(bashCard.waitForExistence(timeout: 20), "a Bash tool card should appear")

        // Expanding shows the command and its output.
        bashCard.click()
        let command = app.staticTexts.containing(
            NSPredicate(format: "value CONTAINS[c] %@", "git status")
        ).firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: 5))

        XCTAssertTrue(
            app.buttons["tool-call-Edit"].waitForExistence(timeout: 20),
            "the Edit tool card should appear too"
        )
    }

    func testEventInspectorRecordsTheStream() throws {
        let app = launchApp()

        let field = app.textFields["agent-composer-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("Hello")
        app.buttons["agent-composer-send"].click()

        // Switch the sidebar to the event log.
        app.radioButtons["Events"].firstMatch.click()

        let sessionStarted = app.staticTexts.containing(
            NSPredicate(format: "value CONTAINS[c] %@", "sessionStarted")
        ).firstMatch
        XCTAssertTrue(
            sessionStarted.waitForExistence(timeout: 20),
            "the normalized event stream should be visible in the inspector"
        )
    }
}
