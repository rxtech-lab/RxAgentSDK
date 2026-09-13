import Foundation
import RxAgentCore
import Testing
@testable import RxAgentContext

@MainActor
@Suite("Agent reasoning selection")
struct AgentReasoningTests {

    private func agent() -> Agent {
        Agent(clients: [
            PreviewAgentClient(id: "claude", displayName: "Claude"),
            PreviewAgentClient(
                id: "codex",
                displayName: "Codex",
                provider: .codex,
                reasoningLevels: .codexEfforts
            ),
            PreviewAgentClient(
                id: "plain",
                displayName: "Plain",
                provider: .acp,
                reasoningLevels: []
            ),
        ])
    }

    @Test("The active client's levels are what the picker is offered")
    func levelsFollowTheClient() async {
        let agent = agent()
        await agent.refreshClientOptions()
        #expect(agent.availableReasoningLevels.map(\.id).contains("xhigh"))

        agent.select("codex")
        await agent.refreshClientOptions()
        #expect(agent.availableReasoningLevels.map(\.id) == ["minimal", "low", "medium", "high"])

        agent.select("plain")
        await agent.refreshClientOptions()
        #expect(agent.availableReasoningLevels.isEmpty)
    }

    /// Levels are per-provider, so carrying a selection across a switch would
    /// hand the new agent a level it has never heard of and fail the turn.
    @Test("Switching clients clears a level the new client does not offer")
    func selectionResetOnSwitch() async {
        let agent = agent()
        await agent.refreshClientOptions()

        agent.effort = "xhigh"
        agent.select("codex")
        #expect(agent.effort == nil)

        agent.effort = "high"
        await agent.refreshAvailableReasoningLevels()
        // `high` survives: Codex offers it too.
        #expect(agent.effort == "high")

        agent.select("plain")
        await agent.refreshAvailableReasoningLevels()
        #expect(agent.effort == nil)
    }

    @Test("A chosen level reaches the client on the next turn")
    func levelReachesTheRequest() async throws {
        let recorder = EffortRecorder()
        let agent = Agent(clients: [RecordingClient(recorder: recorder)])
        agent.effort = "medium"
        agent.send("hello")

        try await Task.sleep(for: .milliseconds(200))
        #expect(await recorder.effort == "medium")
    }
}

// MARK: - Recording client

private actor EffortRecorder {
    private(set) var effort: String?
    func record(_ value: String?) { effort = value }
}

private struct RecordingClient: AgentClient {
    let id: AgentClientID = "recording"
    let displayName = "Recording"
    let provider: AgentProvider = .claudeCode
    let capabilities: AgentCapabilities = []
    let recorder: EffortRecorder

    func availableReasoningLevels() async -> [AgentReasoningOption] { .claudeCodeEfforts }

    func send(_ request: AgentSendRequest) -> AsyncStream<AgentEvent> {
        let recorder = recorder
        return AsyncStream { continuation in
            Task {
                await recorder.record(request.effort)
                continuation.yield(.turnStarted(turnID: request.turnID))
                continuation.yield(.turnEnded(TurnResult()))
                continuation.finish()
            }
        }
    }

    func cancel(turn: UUID) async {}
}

@Suite("Reasoning option list")
struct ReasoningOptionListTests {

    @Test("levels(_:) titlecases each wire value")
    func titlecasing() {
        let levels = [AgentReasoningOption].levels("low", "extra_high")
        #expect(levels.map(\.id) == ["low", "extra_high"])
        #expect(levels.map(\.displayName) == ["Low", "Extra High"])
    }

    @Test("Provider lists run from least to most effort")
    func ordering() {
        #expect([AgentReasoningOption].claudeCodeEfforts.map(\.id)
            == ["low", "medium", "high", "xhigh", "max"])
        #expect([AgentReasoningOption].codexEfforts.first?.id == "minimal")
    }
}
