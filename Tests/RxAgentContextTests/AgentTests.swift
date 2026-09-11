import Foundation
import Testing
import RxAgentCore
@testable import RxAgentContext

@MainActor
private func waitUntilIdle(_ agent: Agent, timeout: Duration = .seconds(5)) async {
    let deadline = ContinuousClock.now + timeout
    while agent.phase.isBusy, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
@Suite("Agent")
struct AgentTests {

    private func makeAgent(
        script: AgentEventScript = .simpleAnswer,
        clients: [any AgentClient]? = nil
    ) -> Agent {
        Agent(
            clients: clients ?? [PreviewAgentClient(script: script, deltaInterval: .zero)],
            workingDirectory: URL(filePath: "/tmp")
        )
    }

    @Test("A turn produces a user message and a streamed assistant reply")
    func basicTurn() async {
        let agent = makeAgent()
        agent.send("How does the message list work?")
        await waitUntilIdle(agent)

        #expect(agent.thread.messages.count == 2)
        #expect(agent.thread.messages[0].role == .user)
        #expect(agent.thread.messages[0].plainText == "How does the message list work?")
        #expect(agent.thread.messages[1].role == .assistant)
        #expect(agent.thread.messages[1].plainText.contains("pins your prompt"))
        #expect(agent.phase == .idle)
    }

    @Test("The client's native session id is recorded against the client, not the provider")
    func recordsNativeSessionID() async {
        let agent = makeAgent()
        agent.send("hi")
        await waitUntilIdle(agent)

        #expect(agent.thread.resumeID(for: "preview") == "preview-session")
        #expect(agent.thread.hasRun(client: "preview"))
    }

    @Test("Tool calls land in the transcript with input and result")
    func toolCalls() async {
        let agent = makeAgent(script: .toolUse)
        agent.send("clean this up")
        await waitUntilIdle(agent)

        let calls = agent.thread.messages.flatMap(\.toolCalls)
        #expect(calls.count == 2)
        #expect(calls[0].name == "Bash")
        #expect(calls[0].input["command"]?.stringValue == "git status --short")
        #expect(calls[0].result?.contains("main.swift") == true)
        #expect(calls[1].name == "Edit")
        #expect(calls[1].isComplete)
    }

    @Test("Todos surface on the thread")
    func todos() async {
        let agent = makeAgent(script: .todos)
        agent.send("plan the work")
        await waitUntilIdle(agent)

        #expect(agent.thread.todos.count == 3)
        #expect(agent.thread.todos[1].status == .inProgress)
    }

    @Test("A failure is recorded on the agent and the message")
    func failure() async {
        let agent = makeAgent(script: .failure)
        agent.send("go")
        await waitUntilIdle(agent)

        #expect(agent.lastError != nil)
        #expect(agent.thread.messages.last?.error?.contains("credit balance") == true)
    }

    @Test("A permission request moves the agent into awaitingPermission")
    func permissionRequest() async {
        let agent = makeAgent(script: .permissionRequest)
        agent.send("clean the build dir")

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if case .awaitingPermission(let request) = agent.phase {
                #expect(request.toolName == "Bash")
                #expect(request.command == "rm -rf build/")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("never entered awaitingPermission")
    }

    @Test("Empty and whitespace-only prompts are ignored")
    func ignoresEmptyPrompts() async {
        let agent = makeAgent()
        agent.send("   \n  ")
        #expect(agent.thread.messages.isEmpty)
        #expect(agent.phase == .idle)
    }

    @Test("A second send while streaming is ignored")
    func ignoresConcurrentSend() async {
        let agent = Agent(
            clients: [PreviewAgentClient(script: .longMarkdown, deltaInterval: .milliseconds(5))],
            workingDirectory: URL(filePath: "/tmp")
        )
        agent.send("first")
        agent.send("second")
        await waitUntilIdle(agent, timeout: .seconds(20))

        let userMessages = agent.thread.messages.filter { $0.role == .user }
        #expect(userMessages.count == 1)
        #expect(userMessages[0].plainText == "first")
    }

    @Test("newThread clears the transcript and session ids")
    func newThread() async {
        let agent = makeAgent()
        agent.send("hi")
        await waitUntilIdle(agent)
        let firstID = agent.thread.id

        agent.newThread()
        #expect(agent.thread.messages.isEmpty)
        #expect(agent.thread.id != firstID)
        #expect(agent.thread.resumeID(for: "preview") == nil)
    }

    // MARK: Client selection

    @Test("select switches the active client")
    func selectClient() {
        let agent = makeAgent(clients: [
            PreviewAgentClient(id: "a", displayName: "A", deltaInterval: .zero),
            PreviewAgentClient(id: "b", displayName: "B", deltaInterval: .zero),
        ])

        #expect(agent.activeClientID == "a")
        agent.select("b")
        #expect(agent.activeClientID == "b")
        #expect(agent.activeClient.displayName == "B")
    }

    @Test("Selecting an unknown client is a no-op")
    func selectUnknownClient() {
        let agent = makeAgent()
        agent.select("nope")
        #expect(agent.activeClientID == "preview")
    }

    /// The point of per-client session ids: each client resumes only its own.
    @Test("Each client keeps its own resume id across a switch")
    func perClientResumeIDs() async {
        let agent = makeAgent(clients: [
            PreviewAgentClient(
                id: "a", displayName: "A",
                script: AgentEventScript([
                    .event(.sessionStarted(SessionStarted(nativeSessionID: "session-A"))),
                    .event(.messageStarted(role: .assistant, id: "m")),
                    .streamText("from A"),
                    .event(.messageEnded(id: "m", usage: nil)),
                    .event(.turnEnded(TurnResult())),
                ]),
                deltaInterval: .zero
            ),
            PreviewAgentClient(
                id: "b", displayName: "B",
                script: AgentEventScript([
                    .event(.sessionStarted(SessionStarted(nativeSessionID: "session-B"))),
                    .event(.messageStarted(role: .assistant, id: "m")),
                    .streamText("from B"),
                    .event(.messageEnded(id: "m", usage: nil)),
                    .event(.turnEnded(TurnResult())),
                ]),
                deltaInterval: .zero
            ),
        ])

        agent.send("first")
        await waitUntilIdle(agent)
        agent.select("b")
        agent.send("second")
        await waitUntilIdle(agent)

        #expect(agent.thread.resumeID(for: "a") == "session-A")
        #expect(agent.thread.resumeID(for: "b") == "session-B")
        // One continuous transcript across both clients.
        #expect(agent.thread.messages.count == 4)
    }

    // MARK: Context

    @Test("Declared context and skills render into the turn's context text")
    func contextRendering() {
        let agent = Agent(
            clients: [PreviewAgentClient(deltaInterval: .zero)],
            skills: [Skill(name: "Review", description: "Review a diff.") { "Cite file:line." }],
            context: AgentContext { "Prefer server actions." },
            workingDirectory: URL(filePath: "/tmp")
        )

        let text = agent.renderContextText(for: agent.activeClient)
        #expect(text.contains("Prefer server actions."))
        #expect(text.contains("## Skill: Review"))
        #expect(text.contains("Cite file:line."))
    }

    @Test("effectiveTools unions direct tools, context tools and skill tools")
    func effectiveTools() {
        let agent = Agent(
            clients: [PreviewAgentClient(deltaInterval: .zero)],
            tools: [.dynamic(name: "direct", description: "", inputSchema: .object([:])) { _, _ in .text("") }],
            skills: [Skill(name: "S", description: "d") { GrepTool() }],
            context: AgentContext {
                AnyAgentTool.dynamic(name: "from-context", description: "", inputSchema: .object([:])) { _, _ in .text("") }
            },
            workingDirectory: URL(filePath: "/tmp")
        )

        #expect(Set(agent.effectiveTools.map(\.name)) == ["direct", "from-context", "grep_workspace"])
    }

    /// A client joining an in-progress thread otherwise gets a prompt with no
    /// history at all — RxCode had this gap.
    @Test("A handoff to a fresh client includes a conversation summary")
    func handoffSummary() async {
        let agent = makeAgent(clients: [
            PreviewAgentClient(id: "a", displayName: "A", deltaInterval: .zero),
            PreviewAgentClient(id: "b", displayName: "B", deltaInterval: .zero),
        ])

        agent.send("what is the spacer for?")
        await waitUntilIdle(agent)

        agent.select("b")
        let text = agent.renderContextText(for: agent.activeClient)
        #expect(text.contains("## Conversation so far"))
        #expect(text.contains("what is the spacer for?"))
    }

    @Test("The first client on a fresh thread gets no handoff summary")
    func noHandoffOnFirstTurn() {
        let agent = makeAgent()
        let text = agent.renderContextText(for: agent.activeClient)
        #expect(!text.contains("## Conversation so far"))
    }

    @Test("Handoff summaries can be switched off")
    func handoffCanBeDisabled() async {
        let agent = makeAgent(clients: [
            PreviewAgentClient(id: "a", displayName: "A", deltaInterval: .zero),
            PreviewAgentClient(id: "b", displayName: "B", deltaInterval: .zero),
        ])
        agent.sendsHandoffSummary = false

        agent.send("hello")
        await waitUntilIdle(agent)
        agent.select("b")

        #expect(!agent.renderContextText(for: agent.activeClient).contains("Conversation so far"))
    }
}
