import Foundation
import Synchronization
import Testing
import RxAgentCore
@testable import RxAgentContext

private final class HandoffClient: AgentClient, Sendable {
    let id: AgentClientID
    let displayName = "Test agent"
    let provider: AgentProvider = .codex
    let capabilities = AgentCapabilities.codexDefaults
    let requests = Mutex<[AgentSendRequest]>([])
    let recordsSession: Bool

    init(_ id: AgentClientID, recordsSession: Bool = true) {
        self.id = id
        self.recordsSession = recordsSession
    }

    func send(_ request: AgentSendRequest) -> AsyncStream<AgentEvent> {
        requests.withLock { $0.append(request) }
        return AsyncStream { continuation in
            continuation.yield(.turnStarted(turnID: request.turnID))
            if recordsSession {
                continuation.yield(.sessionStarted(SessionStarted(nativeSessionID: "session-\(id.rawValue)")))
            }
            let messageID = UUID().uuidString
            continuation.yield(.messageStarted(role: .assistant, id: messageID))
            continuation.yield(.textDelta("Reply from \(id.rawValue)"))
            continuation.yield(.messageEnded(id: messageID, usage: nil))
            continuation.yield(.turnEnded(TurnResult()))
            continuation.finish()
        }
    }

    func cancel(turn: UUID) async {}
}

@MainActor
@Suite("Agent handoff")
struct AgentHandoffTests {
    private func finish(_ agent: Agent) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while agent.phase.isBusy, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!agent.phase.isBusy)
    }

    @Test("A to B to A keeps one thread and catches up the returning native session")
    func returningClient() async throws {
        let a = HandoffClient("a")
        let b = HandoffClient("b")
        let agent = Agent(clients: [a, b])
        let threadID = agent.thread.id
        agent.send("Make a title")
        await finish(agent)
        #expect(a.requests.withLock { $0[0].contextText.isEmpty })

        agent.select(b.id)
        agent.send("Make it yellow")
        await finish(agent)
        let firstB = b.requests.withLock { $0[0] }
        #expect(firstB.resumeSessionID == nil)
        #expect(firstB.contextText.contains("Make a title"))
        #expect(!firstB.contextText.contains("Make it yellow"))

        agent.select(a.id)
        agent.send("Keep that color")
        await finish(agent)
        let returningA = a.requests.withLock { $0[1] }
        #expect(returningA.threadID == threadID)
        #expect(returningA.resumeSessionID == "session-a")
        #expect(returningA.contextText.contains("Make it yellow"))
        #expect(returningA.contextText.contains("Reply from b"))
        #expect(!returningA.contextText.contains("Keep that color"))
        #expect(agent.thread.messages.count == 6)

        agent.send("Continue")
        await finish(agent)
        #expect(!a.requests.withLock { $0[2].contextText.contains("Conversation so far") })
    }

    @Test("An agent without a native session can hand off its conversation")
    func fromStatelessClient() async {
        let a = HandoffClient("local", recordsSession: false)
        let b = HandoffClient("codex")
        let agent = Agent(clients: [a, b])
        agent.send("The title is Hello World")
        await finish(agent)
        agent.select(b.id)
        agent.send("Use that title")
        await finish(agent)
        #expect(b.requests.withLock { $0[0].contextText.contains("The title is Hello World") })
    }

    @Test("Reloaded native sessions receive the saved conversation before resuming")
    func reloadedThread() async {
        let a = HandoffClient("a")
        let thread = AgentThread()
        thread.load(messages: [AgentMessage(role: .user, blocks: [.text(id: UUID(), "Use yellow")])],
                    nativeSessionIDs: [a.id: "saved-a"])
        let agent = Agent(clients: [a])
        agent.resume(thread)
        agent.send("Continue")
        await finish(agent)
        let request = a.requests.withLock { $0[0] }
        #expect(request.resumeSessionID == "saved-a")
        #expect(request.contextText.contains("Use yellow"))
        #expect(!request.contextText.contains("User: Continue"))
    }
}
