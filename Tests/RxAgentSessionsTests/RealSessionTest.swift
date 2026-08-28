import Foundation
import Testing
import RxAgentCore
@testable import RxAgentSessions

/// Reads the developer's actual `~/.claude/projects` history. Opt-in.
@Suite(
    "Live session history",
    .enabled(if: ProcessInfo.processInfo.environment["RXAGENT_LIVE"] == "1")
)
struct LiveSessionHistoryTests {

    @Test("Reads a real CLI transcript from disk")
    func readsRealTranscript() async throws {
        let probe = URL(filePath: "/tmp/rxagent-probe")
        let store = CLISessionStore()
        let summaries = await store.summaries(for: probe)

        try #require(!summaries.isEmpty, "expected a transcript under /tmp/rxagent-probe")
        let first = summaries[0]
        #expect(!first.id.isEmpty)
        #expect(first.messageCount > 0)
        // macOS resolves /tmp to /private/tmp; the CLI records the resolved
        // path, and the store matches on resolved paths for exactly this reason.
        #expect(first.workingDirectory?.hasSuffix("/tmp/rxagent-probe") == true)

        let messages = await store.load(file: first.fileURL)
        #expect(!messages.isEmpty)
        #expect(messages.contains { $0.role == .user })
    }
}
