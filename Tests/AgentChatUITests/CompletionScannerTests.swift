import SwiftUI
import Testing

@testable import AgentChatUI

@MainActor
@Suite("Composer completion scanning")
struct CompletionScannerTests {

    private let triggers: Set<Character> = ["/", "@"]

    @Test("A bare trigger at the start opens with an empty query")
    func triggerAtStart() {
        let query = AgentCompletionScanner.scan("/", triggers: triggers)
        #expect(query?.trigger == "/")
        #expect(query?.query == "")
    }

    @Test("Characters after the trigger become the query")
    func collectsQuery() {
        #expect(AgentCompletionScanner.scan("/comp", triggers: triggers)?.query == "comp")
        #expect(AgentCompletionScanner.scan("@ope", triggers: triggers)?.query == "ope")
    }

    @Test("A trigger after whitespace still opens")
    func triggerAfterSpace() {
        let query = AgentCompletionScanner.scan("fix @cap", triggers: triggers)
        #expect(query?.trigger == "@")
        #expect(query?.query == "cap")
    }

    @Test("A trigger mid-word does not open")
    func midWordTriggerIgnored() {
        // Otherwise an email address opens the mention popup on every keystroke
        // and a file path opens the command popup.
        #expect(AgentCompletionScanner.scan("me@example.com", triggers: triggers) == nil)
        #expect(AgentCompletionScanner.scan("src/main.swift", triggers: triggers) == nil)
    }

    @Test("Whitespace after the token closes the popup")
    func whitespaceCloses() {
        #expect(AgentCompletionScanner.scan("/clear ", triggers: triggers) == nil)
        #expect(AgentCompletionScanner.scan("@project and then", triggers: triggers) == nil)
    }

    @Test("Empty text and unknown triggers yield nothing")
    func nothingToScan() {
        #expect(AgentCompletionScanner.scan("", triggers: triggers) == nil)
        #expect(AgentCompletionScanner.scan("plain words", triggers: triggers) == nil)
        #expect(AgentCompletionScanner.scan("/clear", triggers: []) == nil)
    }

    @Test("The most recent trigger wins")
    func mostRecentTrigger() {
        let query = AgentCompletionScanner.scan("/compact then @cap", triggers: triggers)
        #expect(query?.trigger == "@")
        #expect(query?.query == "cap")
    }

    @Test("Applying an insertion replaces the trigger and query, and adds a space")
    func applyInsertion() {
        let text = "fix @cap"
        let query = try! #require(AgentCompletionScanner.scan(text, triggers: triggers))
        let result = AgentCompletionScanner.applying(
            "@caption:Opening titles",
            to: text,
            query: query
        )
        #expect(result == "fix @caption:Opening titles ")
    }

    @Test("Removing a query strips the trigger and everything after it")
    func removeQuery() {
        // What running a command does: `/clear` must not stay behind in the
        // draft for the user to delete by hand.
        let text = "/clear"
        let query = try! #require(AgentCompletionScanner.scan(text, triggers: triggers))
        #expect(AgentCompletionScanner.removing(query: query, from: text) == "")

        let trailing = "please /comp"
        let second = try! #require(AgentCompletionScanner.scan(trailing, triggers: triggers))
        #expect(AgentCompletionScanner.removing(query: second, from: trailing) == "please ")
    }

    @Test("Multi-byte queries scan by character, not by byte")
    func unicodeQuery() {
        let text = "@开场"
        let query = try! #require(AgentCompletionScanner.scan(text, triggers: triggers))
        #expect(query.query == "开场")
        #expect(AgentCompletionScanner.applying("@x", to: text, query: query) == "@x ")
    }
}

@MainActor
@Suite("Composer metrics")
struct ComposerMetricsTests {

    @Test("The field rests at the low end of composerLines and grows to the high end")
    func fieldGrowsWithinRange() {
        let lines = AgentTheme.standard.composerLines
        #expect(lines.lowerBound == 5)

        // An empty draft still reserves the resting height…
        #expect(lines.clamping(1) == lines.lowerBound)
        // …a draft in range gets exactly its own height…
        #expect(lines.clamping(7) == 7)
        // …and a long one stops growing and scrolls instead.
        #expect(lines.clamping(500) == lines.upperBound)
    }

    /// The transcript already sits on `background`; painting it again would cost
    /// a host the ability to put a material behind the conversation.
    @Test("The transcript ground is clear by default")
    func listBackgroundIsClearByDefault() {
        #expect(AgentTheme.standard.listBackground == .clear)
        #expect(AgentTheme.compact.listBackground == .clear)
    }
}

@MainActor
@Suite("Chat chrome")
struct ChatChromeTests {

    /// A host that supplies its own engine picker through `accessories` turns
    /// the header off; nothing else in the surface is opaque, so this is what
    /// lets the window's own material show through end to end.
    @Test("Toolbar visibility defaults to automatic")
    func toolbarDefaultsToAutomatic() {
        #expect(EnvironmentValues().agentToolbarVisibility == .automatic)
    }

    @Test("Visibility carries through the environment")
    func visibilityIsSettable() {
        var values = EnvironmentValues()
        values.agentToolbarVisibility = .hidden
        #expect(values.agentToolbarVisibility == .hidden)
        values.agentToolbarVisibility = .visible
        #expect(values.agentToolbarVisibility == .visible)
    }
}

@MainActor
@Suite("Transcript foot")
struct TranscriptFootTests {

    /// The dots-and-tokens row rides in the transcript so it scrolls with the
    /// conversation. `MessageList` must still treat it as chrome: counted as a
    /// row it would be mistaken for the answer and get pinned space reserved
    /// for it.
    @Test("The streaming indicator is an accessory, not a message")
    func indicatorIsAccessory() {
        let foot = AgentTranscriptItem.accessory(.streamingIndicator)
        #expect(foot.isMessageListAccessory)
        #expect(!foot.isUserMessage)
        #expect(AgentTranscriptAccessory.streamingIndicator.kind == .streamingIndicator)
    }

    /// Ids have to be stable across renders, or the row is torn down and
    /// rebuilt on every token and the dots restart their animation.
    @Test("The foot row keeps one id")
    func indicatorIDIsStable() {
        #expect(
            AgentTranscriptItem.accessory(.streamingIndicator).id
                == AgentTranscriptItem.accessory(.streamingIndicator).id
        )
    }
}
