import Foundation
import Testing

@testable import RxAgentCore

@MainActor
@Suite("Thread compaction")
struct CompactionTests {

    private func thread(turns: Int) -> AgentThread {
        let thread = AgentThread()
        var messages: [AgentMessage] = []
        for index in 0 ..< turns {
            messages.append(.text("question \(index)", role: .user))
            messages.append(.text("answer \(index)", role: .assistant))
        }
        thread.load(messages: messages)
        return thread
    }

    @Test("A short thread is left alone")
    func shortThreadUntouched() async {
        let thread = thread(turns: 2)
        let didCompact = await thread.compact(keepingLast: 6) { _, _ in "digest" }

        #expect(!didCompact)
        #expect(thread.summary.isEmpty)
        #expect(thread.replayableHistory().count == 4)
    }

    @Test("Compaction shrinks what is replayed without touching the transcript")
    func compactionKeepsScrollback() async {
        // The user's scrollback is not the model's context window: rows stay
        // visible, only `replayableHistory` shrinks.
        let thread = thread(turns: 6)
        let didCompact = await thread.compact(keepingLast: 4) { _, _ in "they discussed things" }

        #expect(didCompact)
        #expect(thread.messages.count == 12)
        #expect(thread.replayableHistory().count == 4)
        #expect(thread.summary == "they discussed things")
    }

    @Test("The tail is what survives, in order")
    func keepsTheTail() async {
        let thread = thread(turns: 5)
        await thread.compact(keepingLast: 3) { _, _ in "digest" }

        let kept = thread.replayableHistory().map(\.plainText)
        #expect(kept == ["answer 3", "question 4", "answer 4"])
    }

    @Test("A summarizer that declines falls back to bounded truncation")
    func truncationFallback() async {
        // Summarizing can fail — no engine configured, network down. Replaying
        // the whole conversation anyway would eventually exceed the window, so
        // a lossy-but-bounded digest beats no digest.
        let thread = thread(turns: 20)
        let didCompact = await thread.compact(
            keepingLast: 2,
            maxSummaryCharacters: 200
        ) { _, _ in nil }

        #expect(didCompact)
        #expect(!thread.summary.isEmpty)
        #expect(thread.summary.count <= 200)
    }

    @Test("The transcript folded in mentions the tools that ran")
    func summaryIncludesToolNames() async {
        let thread = AgentThread()
        let call = AgentToolCall(id: "c1", name: "caption_export", hasCompleteInput: true)
        thread.load(messages: [
            .text("export it", role: .user),
            AgentMessage(role: .assistant, blocks: [
                .toolCall(call),
                .text(id: UUID(), "Exported."),
            ]),
            .text("thanks", role: .user),
        ])

        var seen = ""
        await thread.compact(keepingLast: 1) { _, transcript in
            seen = transcript
            return "digest"
        }

        #expect(seen.contains("caption_export"))
        #expect(seen.contains("Exported."))
    }

    @Test("Compacting twice accumulates rather than restarting")
    func repeatedCompaction() async {
        let thread = thread(turns: 8)
        await thread.compact(keepingLast: 6) { _, _ in "first digest" }
        let afterFirst = thread.compactedMessageIDs.count

        await thread.compact(keepingLast: 2) { existing, _ in existing + " + second" }

        #expect(thread.compactedMessageIDs.count > afterFirst)
        #expect(thread.summary == "first digest + second")
        #expect(thread.replayableHistory().count == 2)
    }

    @Test("Clearing a thread drops the summary and every resume id")
    func clearResetsCompaction() async {
        // A client resuming its own native session after a clear would bring
        // back exactly what the user just deleted.
        let thread = thread(turns: 8)
        thread.record(client: .claudeCode, nativeID: "session-1")
        await thread.compact(keepingLast: 2) { _, _ in "digest" }

        thread.clear()

        #expect(thread.summary.isEmpty)
        #expect(thread.compactedMessageIDs.isEmpty)
        #expect(thread.nativeSessionIDs.isEmpty)
        #expect(thread.messages.isEmpty)
    }

    @Test("The immediate form needs no model")
    func compactWithoutSummarizing() {
        let thread = thread(turns: 6)
        #expect(thread.compactWithoutSummarizing(keepingLast: 4))
        #expect(thread.replayableHistory().count == 4)
        #expect(!thread.summary.isEmpty)
    }

    @Test("Loading restores a persisted compaction state")
    func loadRestoresState() {
        // Compaction has to survive a relaunch, or a reopened thread re-sends
        // everything the last session had already folded away.
        let thread = AgentThread()
        let messages: [AgentMessage] = [
            .text("old", role: .user),
            .text("recent", role: .user),
        ]
        thread.load(
            messages: messages,
            summary: "earlier: they said old things",
            compactedMessageIDs: [messages[0].id]
        )

        #expect(thread.summary == "earlier: they said old things")
        #expect(thread.replayableHistory().map(\.plainText) == ["recent"])
    }
}
