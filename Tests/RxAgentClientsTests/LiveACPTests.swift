#if os(macOS)
import Foundation
import Testing
import RxAgentCore
@testable import RxAgentClients

/// Runs a real ACP agent over npx.
///
/// Gated behind `RXAGENT_LIVE_ACP=1` separately from the other live tests: the
/// first run downloads an npm package, which is far slower than spawning an
/// already-installed CLI.
@Suite(
    "Live ACP",
    .enabled(if: ProcessInfo.processInfo.environment["RXAGENT_LIVE_ACP"] == "1"),
    .serialized
)
struct LiveACPTests {

    private func makeClient() -> ACPClient {
        // `claude-code-acp` refuses to start when `CLAUDECODE` is set, to stop
        // nested sessions sharing runtime resources. That variable is present
        // whenever these tests are run from inside a Claude Code session, so
        // clear it for the whole test process before spawning.
        unsetenv("CLAUDECODE")
        unsetenv("CLAUDE_CODE_ENTRYPOINT")

        return ACPClient(
            npx: "@zed-industries/claude-code-acp",
            displayName: "Claude Code (ACP)"
        )
    }

    @Test("npx is available")
    func npxAvailable() async {
        #expect(await makeClient().isAvailable())
    }

    @Test("A turn streams text through the ACP session", .timeLimit(.minutes(10)))
    func simpleTurn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rxagent-acp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = makeClient()
        let threadID = AgentThreadID()
        let request = AgentSendRequest(
            threadID: threadID,
            prompt: "Reply with exactly the word: pineapple. No other text.",
            workingDirectory: directory,
            permissionMode: .default,
            permissions: AllowAllPermissions()
        )

        var reducer = TranscriptReducer()
        var failure: AgentError?
        var sawSessionStart = false

        for await event in client.send(request) {
            if case .sessionStarted = event { sawSessionStart = true }
            if case .failed(let error) = event { failure = error }
            _ = reducer.apply(event)
        }
        await client.endSession(thread: threadID)

        if let failure { Issue.record("turn failed: \(failure)") }
        #expect(sawSessionStart)
        #expect(reducer.nativeSessionID != nil)
        #expect(reducer.messages.contains { $0.plainText.lowercased().contains("pineapple") })
    }

    /// The pooled process is what makes this work — ACP sends no history, so a
    /// second turn only remembers if it reaches the same live agent.
    @Test("A second turn reuses the pooled process and keeps context",
          .timeLimit(.minutes(10)))
    func pooledProcessKeepsContext() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rxagent-acp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = makeClient()
        let threadID = AgentThreadID()

        var first = TranscriptReducer()
        for await event in client.send(AgentSendRequest(
            threadID: threadID,
            prompt: "Remember the number 8675309. Reply with just: ok",
            workingDirectory: directory,
            permissions: AllowAllPermissions()
        )) { _ = first.apply(event) }

        var second = TranscriptReducer()
        for await event in client.send(AgentSendRequest(
            threadID: threadID,
            resumeSessionID: first.nativeSessionID,
            prompt: "What number did I ask you to remember? Reply with digits only.",
            workingDirectory: directory,
            permissions: AllowAllPermissions()
        )) { _ = second.apply(event) }

        await client.endSession(thread: threadID)
        #expect(second.messages.map(\.plainText).joined().contains("8675309"))
    }
}
#endif
