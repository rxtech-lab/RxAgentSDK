#if os(macOS)
import Foundation
import Testing
import RxAgentCore
@testable import RxAgentClients

/// Tests that spawn the real `claude` binary.
///
/// Skipped unless `RXAGENT_LIVE=1`, because they need the CLI installed, an
/// authenticated account, and real tokens. CI runs the fixture-driven decoder
/// tests instead.
@Suite("Live Claude", .enabled(if: ProcessInfo.processInfo.environment["RXAGENT_LIVE"] == "1"))
struct LiveClaudeTests {

    private func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rxagent-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("The binary is discoverable on the login-shell PATH")
    func discoversBinary() async {
        let client = ClaudeCodeClient()
        #expect(await client.isAvailable())
    }

    @Test("A simple turn streams text and ends cleanly", .timeLimit(.minutes(2)))
    func simpleTurn() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = ClaudeCodeClient()
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

        for await event in client.send(request) {
            if case .sessionStarted = event { sawSessionStart = true }
            if case .turnEnded = event { sawTurnEnd = true }
            if case .failed(let error) = event { Issue.record("turn failed: \(error)") }
            _ = reducer.apply(event)
        }

        #expect(sawSessionStart)
        #expect(sawTurnEnd)
        #expect(reducer.nativeSessionID != nil)
        #expect(reducer.messages.contains { $0.plainText.lowercased().contains("pineapple") })
    }

    @Test("A tool call is approved through the hook and reports a result",
          .timeLimit(.minutes(3)))
    func toolCallThroughApprovalHook() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "hello from rxagent".write(
            to: directory.appending(path: "marker.txt"),
            atomically: true,
            encoding: .utf8
        )

        let recorder = ApprovalRecorder()
        let client = ClaudeCodeClient()
        let request = AgentSendRequest(
            threadID: AgentThreadID(),
            prompt: "Run `cat marker.txt` with the Bash tool and tell me what it says.",
            workingDirectory: directory,
            permissionMode: .default,
            permissions: recorder
        )

        var reducer = TranscriptReducer()
        for await event in client.send(request) {
            _ = reducer.apply(event)
        }

        let calls = reducer.messages.flatMap(\.toolCalls)
        #expect(!calls.isEmpty, "expected at least one tool call")
        #expect(calls.contains { $0.result?.contains("hello from rxagent") == true })
        #expect(await recorder.count > 0, "the PreToolUse hook should have fired")
    }

    @Test("Resuming continues the same native session", .timeLimit(.minutes(3)))
    func resumesSession() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = ClaudeCodeClient()
        let threadID = AgentThreadID()

        var first = TranscriptReducer()
        for await event in client.send(AgentSendRequest(
            threadID: threadID,
            prompt: "Remember the number 8675309. Reply with just: ok",
            workingDirectory: directory,
            permissions: AllowAllPermissions()
        )) { _ = first.apply(event) }

        let sessionID = try #require(first.nativeSessionID)

        var second = TranscriptReducer()
        for await event in client.send(AgentSendRequest(
            threadID: threadID,
            resumeSessionID: sessionID,
            prompt: "What number did I ask you to remember? Reply with digits only.",
            workingDirectory: directory,
            permissions: AllowAllPermissions()
        )) { _ = second.apply(event) }

        let reply = second.messages.map(\.plainText).joined()
        #expect(reply.contains("8675309"))
    }
}

/// Approves everything and counts how many requests came through.
actor ApprovalRecorder: PermissionResolving {
    private(set) var seen: [PermissionRequest] = []

    var count: Int { seen.count }

    nonisolated func resolve(_ request: PermissionRequest) async -> PermissionDecision {
        await record(request)
        return .allow
    }

    private func record(_ request: PermissionRequest) {
        seen.append(request)
    }
}
#endif
