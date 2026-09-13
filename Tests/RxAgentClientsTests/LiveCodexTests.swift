#if os(macOS)
import Foundation
import Testing
import RxAgentCore
@testable import RxAgentClients

/// Tests that spawn the real `codex` binary. See `LiveClaudeTests` for the
/// `RXAGENT_LIVE` opt-in rationale.
@Suite(
    "Live Codex",
    .enabled(if: ProcessInfo.processInfo.environment["RXAGENT_LIVE"] == "1"),
    .serialized
)
struct LiveCodexTests {

    private func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rxagent-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("The binary is discoverable")
    func discoversBinary() async {
        #expect(await CodexClient().isAvailable())
    }

    @Test("A simple turn streams text and ends cleanly", .timeLimit(.minutes(3)))
    func simpleTurn() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = CodexClient(
            sandbox: .readOnly,
            configOverrides: ["model_reasoning_effort=\"low\""]
        )
        let request = AgentSendRequest(
            threadID: AgentThreadID(),
            prompt: "Reply with exactly the word: pineapple. No other text.",
            workingDirectory: directory,
            permissionMode: .default,
            permissions: AllowAllPermissions()
        )

        var reducer = TranscriptReducer()
        var sawSessionStart = false
        var sawTurnEnd = false
        var failure: AgentError?

        for await event in client.send(request) {
            if case .sessionStarted = event { sawSessionStart = true }
            if case .turnEnded = event { sawTurnEnd = true }
            if case .failed(let error) = event { failure = error }
            _ = reducer.apply(event)
        }

        if let failure { Issue.record("turn failed: \(failure)") }
        #expect(sawSessionStart)
        #expect(sawTurnEnd)
        #expect(reducer.nativeSessionID != nil)
        #expect(reducer.messages.contains { $0.plainText.lowercased().contains("pineapple") })
    }

    @Test("Resuming continues the same Codex thread", .timeLimit(.minutes(4)))
    func resumesThread() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = CodexClient()
        let threadID = AgentThreadID()

        var first = TranscriptReducer()
        for await event in client.send(AgentSendRequest(
            threadID: threadID,
            prompt: "Remember the number 8675309. Reply with just: ok",
            workingDirectory: directory,
            permissions: AllowAllPermissions()
        )) {
            if case .failed(let error) = event { Issue.record("Initial turn failed: \(error)") }
            _ = first.apply(event)
        }

        let nativeID = try #require(first.nativeSessionID)

        var second = TranscriptReducer()
        for await event in client.send(AgentSendRequest(
            threadID: threadID,
            resumeSessionID: nativeID,
            prompt: "What number did I ask you to remember? Reply with digits only.",
            workingDirectory: directory,
            permissions: AllowAllPermissions()
        )) {
            if case .failed(let error) = event { Issue.record("Resume failed: \(error)") }
            _ = second.apply(event)
        }

        #expect(second.messages.map(\.plainText).joined().contains("8675309"))
    }
}
#endif
