#if os(macOS)
import Foundation
import RxAgentCore
import Testing
@testable import RxAgentClients

@Suite("Reasoning effort")
struct ReasoningEffortTests {

    private func request(effort: String?) -> AgentSendRequest {
        AgentSendRequest(
            threadID: AgentThreadID(),
            prompt: "x",
            workingDirectory: URL(filePath: "/tmp"),
            effort: effort,
            permissionMode: .bypassPermissions
        )
    }

    // MARK: Advertised levels

    @Test("Each CLI client advertises its own vocabulary")
    func vocabularies() async {
        let claude = await ClaudeCodeClient().availableReasoningLevels().map(\.id)
        let codex = await CodexClient().availableReasoningLevels().map(\.id)
        #expect(claude.contains("xhigh"))
        #expect(!claude.contains("minimal"))
        #expect(codex.contains("minimal"))
        #expect(!codex.contains("xhigh"))
    }

    /// The picker keys off an empty list to draw nothing, so a client with no
    /// reasoning dial must report exactly that rather than a plausible guess.
    @Test("An ACP agent advertises nothing until its host says otherwise")
    func acpDefaultsToNoLevels() async {
        let plain = ACPClient(command: "gemini", displayName: "Gemini", id: .acp("gemini"))
        #expect(await plain.availableReasoningLevels().isEmpty)

        let configured = ACPClient(
            command: "gemini",
            displayName: "Gemini",
            id: .acp("gemini"),
            effortEnvVar: "GEMINI_THINKING_LEVEL",
            reasoningLevels: .levels("low", "high")
        )
        #expect(await configured.availableReasoningLevels().map(\.id) == ["low", "high"])
    }

    @Test("A host can narrow a client's levels to what its pinned model accepts")
    func narrowedLevels() async {
        let client = ClaudeCodeClient(reasoningLevels: .levels("low", "medium", "high"))
        #expect(await client.availableReasoningLevels().map(\.displayName)
            == ["Low", "Medium", "High"])
    }

    // MARK: Claude

    @Test("Claude passes the level as --effort")
    func claudeArguments() throws {
        let client = ClaudeCodeClient()
        let chosen = request(effort: "xhigh")
        let files = try ClaudeTurnFiles(request: chosen, preapprovedTools: [])
        let arguments = client.buildArguments(request: chosen, files: files)

        let index = try #require(arguments.firstIndex(of: "--effort"))
        #expect(arguments[index + 1] == "xhigh")

        let unset = request(effort: nil)
        let bare = try ClaudeTurnFiles(request: unset, preapprovedTools: [])
        #expect(!client.buildArguments(request: unset, files: bare).contains("--effort"))
    }

    // MARK: Codex

    /// Codex has no per-turn reasoning field, so the level has to reach the
    /// child as a config override on the command line.
    @Test("Codex passes the level as a model_reasoning_effort override")
    func codexArguments() {
        #expect(CodexClient().launchArguments(effort: "high") == [
            "app-server", "--listen", "stdio://",
            "-c", "model_reasoning_effort=\"high\"",
        ])
        #expect(!CodexClient().launchArguments(effort: nil)
            .contains("model_reasoning_effort=\"high\""))
    }

    /// Two `-c` flags for one key leave the winner up to the CLI's merge order.
    @Test("A configuration that pins the key keeps it")
    func codexPinnedEffortWins() {
        let client = CodexClient(configOverrides: ["model_reasoning_effort=\"low\""])
        #expect(client.launchArguments(effort: "high") == [
            "app-server", "--listen", "stdio://",
            "-c", "model_reasoning_effort=\"low\"",
        ])
    }

    @Test("An unrelated override does not look like a pin")
    func codexUnrelatedOverride() {
        let client = CodexClient(configOverrides: ["model_reasoning_summary=\"detailed\""])
        #expect(client.launchArguments(effort: "low").contains("model_reasoning_effort=\"low\""))
    }
}
#endif
