import Foundation
import RxAgentCore
import Testing

@testable import RxAgentHarness

/// Runs the harness against a real OpenAI-compatible server, e.g.
///
///     llama-server --model qwen3.gguf --jinja --port 18731
///     RXAGENT_HARNESS_LIVE_URL=http://127.0.0.1:18731/v1 swift test --filter LiveHarness
///
/// Skipped unless the variable is set.
@Suite("Live harness", .enabled(if: ProcessInfo.processInfo.environment["RXAGENT_HARNESS_LIVE_URL"] != nil))
struct LiveHarnessTests {
    var model: OpenAICompatibleHarnessModel {
        OpenAICompatibleHarnessModel(
            baseURL: URL(string: ProcessInfo.processInfo.environment["RXAGENT_HARNESS_LIVE_URL"]!)!,
            contextWindow: Int(ProcessInfo.processInfo.environment["RXAGENT_HARNESS_LIVE_CONTEXT"] ?? "8192")
        )
    }

    @Test("A local model reads a file with a tool and answers", arguments: [HarnessGenerationMode.streaming, .generation])
    func readsFile(mode: HarnessGenerationMode) async throws {
        let root = try temporaryDirectory()
        try "The secret word is PINEAPPLE.\n".write(to: root.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        let store = InMemoryHarnessSessionStore()
        let agent = HarnessAgent(configuration: HarnessConfiguration(store: store, maxSteps: 8, temperature: 0))
        let events = try await collect(await agent.run(HarnessTurnInput(
            sessionID: "live-\(mode.rawValue)",
            prompt: "Use the read tool to open notes.txt, then tell me the secret word.",
            workingDirectory: root, model: model, modelName: "test", mode: mode,
            permissionHandler: AllowAllHarnessPermissions()
        )))
        let readCalls = events.filter { if case .toolCallCompleted(_, "read", let output) = $0 { return !output.isError }; return false }
        #expect(!readCalls.isEmpty)
        let final = events.compactMap { if case .turnFinished(let result) = $0 { return result }; return nil }.first
        #expect(final?.text.uppercased().contains("PINEAPPLE") == true)
        #expect((final?.usage.inputTokens ?? 0) > 0)
    }

    @Test("A local model edits a file through the edit tool")
    func editsFile() async throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "greeting.txt")
        try "Hello, world\n".write(to: file, atomically: true, encoding: .utf8)
        let agent = HarnessAgent(configuration: HarnessConfiguration(maxSteps: 8, temperature: 0))
        _ = try await collect(await agent.run(HarnessTurnInput(
            sessionID: "live-edit",
            prompt: "In greeting.txt, replace the word world with RxCode. Read the file first, then use the edit tool.",
            workingDirectory: root, model: model, modelName: "test",
            permissionHandler: AllowAllHarnessPermissions()
        )))
        #expect(try String(contentsOf: file, encoding: .utf8).contains("RxCode"))
    }
}
