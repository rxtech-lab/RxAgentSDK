import Foundation
import Testing
import RxAgentCore
@testable import RxAgentContext

/// What a client saw, in order.
private actor CallLog {
    enum Entry: Equatable {
        case send(UUID)
        case cancelBegan(UUID)
        case cancelEnded(UUID)
    }

    private(set) var entries: [Entry] = []

    func append(_ entry: Entry) { entries.append(entry) }

    var sends: [UUID] {
        entries.compactMap { if case .send(let id) = $0 { id } else { nil } }
    }

    var cancels: [UUID] {
        entries.compactMap { if case .cancelBegan(let id) = $0 { id } else { nil } }
    }
}

/// A client whose turns never end by themselves and whose cancel takes a
/// while — the shape of a CLI child that has to be signalled and reaped.
private struct HangingClient: AgentClient {
    let id: AgentClientID = "hanging"
    let displayName = "Hanging"
    let provider: AgentProvider = .claudeCode
    let capabilities: AgentCapabilities = .claudeCodeDefaults

    let log: CallLog
    var cancelDelay: Duration = .milliseconds(200)

    func send(_ request: AgentSendRequest) -> AsyncStream<AgentEvent> {
        let log = log
        let turnID = request.turnID
        return AsyncStream { continuation in
            Task { await log.append(.send(turnID)) }
            continuation.yield(.turnStarted(turnID: turnID))
        }
    }

    func cancel(turn: UUID) async {
        await log.append(.cancelBegan(turn))
        try? await Task.sleep(for: cancelDelay)
        await log.append(.cancelEnded(turn))
    }
}

@MainActor
private func eventually(
    timeout: Duration = .seconds(3),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
@Suite("Agent stop")
struct AgentStopTests {

    private func makeAgent(log: CallLog) -> Agent {
        Agent(clients: [HangingClient(log: log)], workingDirectory: URL(filePath: "/tmp"))
    }

    @Test("A turn sent right after a stop waits for the old turn's teardown")
    func nextTurnWaitsForTeardown() async {
        let log = CallLog()
        let agent = makeAgent(log: log)

        agent.send("first")
        #expect(await eventually { await log.sends.count == 1 })

        agent.stop()
        agent.send("second")
        #expect(await eventually { await log.sends.count == 2 })

        let entries = await log.entries
        let first = await log.sends[0]
        let second = await log.sends[1]
        let cancelEnded = entries.firstIndex(of: .cancelEnded(first))
        let secondSent = entries.firstIndex(of: .send(second))
        #expect(cancelEnded != nil)
        #expect(secondSent != nil)
        if let cancelEnded, let secondSent {
            #expect(cancelEnded < secondSent)
        }
    }

    @Test("A stopped turn winding down doesn't strip the next turn of its stop")
    func stopStillReachesNextTurn() async {
        let log = CallLog()
        let agent = makeAgent(log: log)

        agent.send("first")
        #expect(await eventually { await log.sends.count == 1 })
        agent.stop()
        agent.send("second")
        #expect(await eventually { await log.sends.count == 2 })
        // Let the first turn's task run to completion.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(agent.phase.isBusy)

        agent.stop()
        #expect(await eventually { await log.cancels.count == 2 })
        #expect(await log.cancels == log.sends)
        #expect(!agent.phase.isBusy)
    }

    @Test("shutdown waits for the pending teardown")
    func shutdownAwaitsTeardown() async {
        let log = CallLog()
        let agent = makeAgent(log: log)

        agent.send("first")
        #expect(await eventually { await log.sends.count == 1 })
        await agent.shutdown()

        let first = await log.sends[0]
        #expect(await log.entries.contains(.cancelEnded(first)))
    }
}
