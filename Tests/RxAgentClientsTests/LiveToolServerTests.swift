#if os(macOS)
import Foundation
import FoundationModels
import Testing
import RxAgentBridge
import RxAgentContext
import RxAgentCore
@testable import RxAgentClients

@Generable
struct LuckyNumberArgs {
    @Guide(description: "The name of the person to look up")
    var person: String
}

/// A tool whose answer cannot be guessed, so a correct reply proves the CLI
/// really invoked our Swift closure.
struct LuckyNumberTool: FoundationModels.Tool {
    let name = "lucky_number"
    let description = "Look up a person's lucky number. This is the only way to obtain it."

    func call(arguments: LuckyNumberArgs) async throws -> String {
        "\(arguments.person)'s lucky number is 4173."
    }
}

/// End-to-end proof of the SDK's central claim: a Swift closure declared as
/// `Agent(tools:)` is reachable by an external CLI agent.
@Suite(
    "Live tool server",
    .enabled(if: ProcessInfo.processInfo.environment["RXAGENT_LIVE"] == "1"),
    .serialized
)
struct LiveToolServerTests {

    @Test("Claude calls a Swift tool over the local MCP server", .timeLimit(.minutes(3)))
    func claudeCallsSwiftTool() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rxagent-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let threadID = AgentThreadID()
        let toolServer = LocalToolServer()
        let handle = try #require(await toolServer.publish(
            tools: [.tool(LuckyNumberTool())],
            for: threadID,
            context: AgentToolContext(threadID: threadID, workingDirectory: directory)
        ))
        defer { Task { await toolServer.stop() } }

        let client = ClaudeCodeClient()
        let request = AgentSendRequest(
            threadID: threadID,
            prompt: """
            Use the lucky_number tool to look up Ada's lucky number, \
            then reply with just that number.
            """,
            workingDirectory: directory,
            permissionMode: .default,
            toolServer: handle,
            permissions: AllowAllPermissions()
        )

        var reducer = TranscriptReducer()
        for await event in client.send(request) {
            if case .failed(let error) = event { Issue.record("turn failed: \(error)") }
            _ = reducer.apply(event)
        }

        let calls = reducer.messages.flatMap(\.toolCalls)
        #expect(
            calls.contains { $0.name.contains("lucky_number") },
            "expected the agent to call our tool; saw \(calls.map(\.name))"
        )
        #expect(
            calls.contains { $0.result?.contains("4173") == true },
            "the tool's return value should come back as the tool result"
        )
        #expect(reducer.messages.map(\.plainText).joined().contains("4173"))
    }
}
#endif
