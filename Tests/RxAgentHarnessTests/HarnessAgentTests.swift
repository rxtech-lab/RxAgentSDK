import Foundation
import RxAgentCore
import Testing

@testable import RxAgentHarness

@Suite("Harness agent loop")
struct HarnessAgentTests {

    func input(_ prompt: String, model: ScriptedModel, root: URL, session: String = "s1",
               mode: HarnessGenerationMode = .streaming,
               handler: any HarnessPermissionHandler = AllowAllHarnessPermissions()) -> HarnessTurnInput {
        HarnessTurnInput(
            sessionID: session, prompt: prompt, workingDirectory: root,
            model: model, modelName: "test-model", mode: mode, permissionHandler: handler
        )
    }

    @Test("A tool call runs, its result is replayed, and the session is stored")
    func toolLoop() async throws {
        let root = try temporaryDirectory()
        try "hello world\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let model = ScriptedModel([
            ScriptedModel.call("read", ["path": "a.txt"], id: "c1"),
            ScriptedModel.text("The file says hello.", usage: UsageInfo(inputTokens: 100, outputTokens: 5)),
        ])
        let store = InMemoryHarnessSessionStore()
        let agent = HarnessAgent(configuration: HarnessConfiguration(store: store))

        let events = try await collect(await agent.run(input("read a.txt", model: model, root: root)))

        #expect(events.contains { if case .toolCallCompleted(let id, "read", let output) = $0 { return id == "c1" && output.text.contains("hello world") }; return false })
        let final = events.compactMap { if case .turnFinished(let result) = $0 { return result }; return nil }.first
        #expect(final?.text == "The file says hello.")
        #expect(final?.steps == 2)

        // Second request replays assistant tool call + tool result in order.
        let second = model.recorded[1].messages
        #expect(second.map(\.role) == [.user, .assistant, .tool])
        #expect(second[1].toolCalls.first?.id == "c1")
        #expect(second[2].toolCallID == "c1")

        let saved = try #require(try await store.load(id: "s1"))
        #expect(saved.messages.count == 4)
        #expect(saved.title == "read a.txt")
        #expect(saved.usage.inputTokens >= 100)
    }

    @Test("A second turn continues the stored session")
    func resumes() async throws {
        let root = try temporaryDirectory()
        let store = InMemoryHarnessSessionStore()
        let agent = HarnessAgent(configuration: HarnessConfiguration(store: store))
        let model = ScriptedModel([ScriptedModel.text("one"), ScriptedModel.text("two")])
        _ = try await collect(await agent.run(input("first", model: model, root: root)))
        _ = try await collect(await agent.run(input("second", model: model, root: root)))
        #expect(model.recorded[1].messages.map(\.text) == ["first", "one", "second"])
    }

    @Test("Generation mode returns one result and sends non-streaming requests")
    func generation() async throws {
        let root = try temporaryDirectory()
        let model = ScriptedModel([ScriptedModel.text("done")])
        let agent = HarnessAgent()
        let result = try await agent.generate(input("go", model: model, root: root))
        #expect(result.text == "done")
        #expect(model.recorded.first?.mode == .generation)
    }

    @Test("Streaming emits estimated token usage before the measured numbers")
    func streamingUsage() async throws {
        let root = try temporaryDirectory()
        let long = String(repeating: "word ", count: 200)
        let model = ScriptedModel([
            [.textDelta(long), .usage(UsageInfo(inputTokens: 50, outputTokens: 210)), .finished(reason: "stop")],
        ], contextWindow: 8_000)
        let events = try await collect(await HarnessAgent().run(input("hi", model: model, root: root)))
        let usages = events.compactMap { if case .usage(let usage) = $0 { return usage }; return nil }
        #expect(usages.contains { $0.isEstimate })
        #expect(usages.last?.isEstimate == false)
        #expect(usages.last?.step.outputTokens == 210)
        #expect(events.contains { if case .contextWindow(let window) = $0 { return window.maxTokens == 8_000 }; return false })
    }

    @Test("A rejected permission without a message ends the turn")
    func rejectionStops() async throws {
        let root = try temporaryDirectory()
        let model = ScriptedModel([
            ScriptedModel.call("write", ["path": "x.txt", "content": "x"]),
            ScriptedModel.text("should not be reached"),
        ])
        let agent = HarnessAgent()
        let events = try await collect(await agent.run(input("write", model: model, root: root, handler: RejectAllHarnessPermissions())))
        #expect(model.recorded.count == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "x.txt").path))
        #expect(events.contains { if case .permissionAsked = $0 { return true }; return false })
        let final = events.compactMap { if case .turnFinished(let result) = $0 { return result }; return nil }.first
        #expect(final?.finishReason == "permission_rejected")
    }

    @Test("Unknown tools and invalid JSON come back to the model as errors")
    func badCalls() async throws {
        let root = try temporaryDirectory()
        let model = ScriptedModel([
            [.toolCall(HarnessToolCall(id: "a", name: "nope", argumentsJSON: "{}")),
             .toolCall(HarnessToolCall(id: "b", name: "read", argumentsJSON: "{not json")), .finished(reason: nil)],
            ScriptedModel.text("ok"),
        ])
        _ = try await collect(await HarnessAgent().run(input("x", model: model, root: root)))
        let results = model.recorded[1].messages.filter { $0.role == .tool }
        #expect(results.count == 2)
        #expect(results[0].text.contains("Unknown tool"))
        #expect(results[1].text.contains("not valid JSON"))
    }

    @Test("Context overflow triggers compaction and a retry")
    func overflowCompacts() async throws {
        let root = try temporaryDirectory()
        let store = InMemoryHarnessSessionStore([HarnessSession(id: "s1", messages: [.user("old question"), .assistant("old answer")])])
        let model = ScriptedModel(
            [ScriptedModel.text("## Objective\n- earlier work"), ScriptedModel.text("fresh answer")],
            failures: [0: .contextOverflow("too long")]
        )
        let agent = HarnessAgent(configuration: HarnessConfiguration(store: store))
        let events = try await collect(await agent.run(input("new question", model: model, root: root)))
        #expect(events.contains { if case .compactionFinished(.overflow, _, true) = $0 { return true }; return false })
        let saved = try #require(try await store.load(id: "s1"))
        #expect(saved.summary?.contains("earlier work") == true)
        #expect(saved.compactedThrough == 2)
        // The retried request carries the summary in the system prompt and only the new turn.
        let retry = model.recorded[2]
        #expect(retry.system.contains("earlier work"))
        #expect(retry.messages.map(\.text) == ["new question"])
    }

    @Test("Busy sessions reject a concurrent turn")
    func busy() async throws {
        let root = try temporaryDirectory()
        let agent = HarnessAgent()
        let slow = SlowModel()
        let first = await agent.run(HarnessTurnInput(sessionID: "s", prompt: "a", workingDirectory: root, model: slow, modelName: "m"))
        let second = await agent.run(HarnessTurnInput(sessionID: "s", prompt: "b", workingDirectory: root, model: slow, modelName: "m"))
        await #expect(throws: HarnessError.busy(sessionID: "s")) { _ = try await collect(second) }
        await agent.cancel(sessionID: "s")
        await #expect(throws: HarnessError.cancelled) { _ = try await collect(first) }
    }
}

struct SlowModel: HarnessModel {
    var contextWindow: Int? { nil }
    func send(_ request: HarnessModelRequest) -> AsyncThrowingStream<HarnessModelChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .seconds(30))
                continuation.finish(throwing: CancellationError())
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
