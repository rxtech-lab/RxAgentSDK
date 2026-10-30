import Foundation
import RxAgentCore
import Testing

@testable import RxAgentHarness

@Suite("Harness permissions")
struct HarnessPermissionTests {
    @Test("Last matching rule wins, with wildcards")
    func lastMatchWins() {
        let rules = HarnessPermissionRuleset([
            .init(permission: "bash", action: .ask),
            .init(permission: "bash", pattern: "git *", action: .allow),
            .init(permission: "bash", pattern: "git push *", action: .deny),
        ])
        #expect(rules.evaluate(permission: "bash", resource: "git status") == .allow)
        #expect(rules.evaluate(permission: "bash", resource: "git push origin main") == .deny)
        #expect(rules.evaluate(permission: "bash", resource: "npm test") == .ask)
        #expect(rules.evaluate(permission: "bash", resources: ["git status", "rm -rf x"]) == .ask)
    }

    @Test("Default rules ask for .env reads but allow .env.example")
    func envDefaults() {
        let rules = HarnessPermissionRuleset.defaults
        #expect(rules.evaluate(permission: "read", resource: "src/main.swift") == .allow)
        #expect(rules.evaluate(permission: "read", resource: ".env") == .ask)
        #expect(rules.evaluate(permission: "read", resource: "config/.env.local") == .ask)
        #expect(rules.evaluate(permission: "read", resource: ".env.example") == .allow)
    }

    @Test("Shell commands split on operators but not inside quotes")
    func shellParsing() {
        #expect(ShellCommandParser.commands(in: "git status && rm -rf build; ls | wc -l")
                == ["git status", "rm -rf build", "ls", "wc -l"])
        #expect(ShellCommandParser.commands(in: "echo \"a && b\"") == ["echo \"a && b\""])
        #expect(ShellCommandParser.commands(in: "FOO=1 npm test") == ["npm test"])
        #expect(ShellCommandParser.alwaysPattern(for: "git status --porcelain") == "git status *")
        #expect(ShellCommandParser.alwaysPattern(for: "ls -la") == "ls *")
        #expect(Wildcard.matches("git status *", "git status"))
    }

    @Test("Always answers are remembered for matching requests")
    func alwaysRemembered() async throws {
        let counter = Counter()
        let gate = HarnessPermissionGate(
            ruleset: HarnessPermissionRuleset([.init(permission: "*", action: .ask)]),
            handler: ClosureHarnessPermissionHandler { _ in await counter.increment(); return .always }
        )
        let ask = HarnessPermissionAsk(sessionID: "s", permission: "bash", resources: ["npm test"], alwaysPatterns: ["npm *"], toolName: "bash", title: "")
        try await gate.authorize(ask)
        try await gate.authorize(HarnessPermissionAsk(sessionID: "s", permission: "bash", resources: ["npm run build"], toolName: "bash", title: ""))
        #expect(await counter.value == 1)
    }

    @Test("Plan mode denies edits; bypass allows asks but not rule denies")
    func modes() async throws {
        let rules = HarnessPermissionRuleset([.init(permission: "*", action: .ask), .init(permission: "bash", pattern: "rm *", action: .deny)])
        let gate = HarnessPermissionGate(ruleset: rules, mode: .plan, handler: AllowAllHarnessPermissions())
        await #expect(throws: HarnessPermissionDenied.self) {
            try await gate.authorize(HarnessPermissionAsk(sessionID: "s", permission: "edit", resources: ["a"], toolName: "edit", title: ""))
        }
        // Read-only shell is fine in plan mode.
        try await gate.authorize(HarnessPermissionAsk(sessionID: "s", permission: "bash", resources: ["ls -la"], toolName: "bash", title: ""))

        await gate.setMode(.bypassPermissions)
        await gate.setHandler(RejectAllHarnessPermissions())
        try await gate.authorize(HarnessPermissionAsk(sessionID: "s", permission: "edit", resources: ["a"], toolName: "edit", title: ""))
        await #expect(throws: HarnessPermissionDenied.self) {
            try await gate.authorize(HarnessPermissionAsk(sessionID: "s", permission: "bash", resources: ["rm -rf /"], toolName: "bash", title: ""))
        }
    }

    @Test("Identical calls three times in a row are a doom loop")
    func doomLoop() async {
        let gate = HarnessPermissionGate(handler: AllowAllHarnessPermissions())
        #expect(await gate.recordCall(name: "read", argumentsJSON: "{\"path\":\"a\"}") == false)
        #expect(await gate.recordCall(name: "read", argumentsJSON: "{\"path\": \"a\"}") == false)
        #expect(await gate.recordCall(name: "read", argumentsJSON: "{\"path\":\"a\"}") == true)
        #expect(await gate.recordCall(name: "read", argumentsJSON: "{\"path\":\"b\"}") == false)
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@Suite("Harness file tools")
struct HarnessFileToolTests {
    @Test("read numbers lines and pages with offset")
    func read() async throws {
        let root = try temporaryDirectory()
        try (1...10).map { "line \($0)" }.joined(separator: "\n").write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        let output = try await ReadTool().execute(["path": "f.txt", "offset": 3, "limit": 2], context: makeContext(root: root))
        #expect(output.text.hasPrefix("3\tline 3\n4\tline 4"))
        #expect(output.text.contains("Use offset 5"))
    }

    @Test("read outside the project asks for external_directory")
    func externalDirectory() async throws {
        let root = try temporaryDirectory()
        let other = try temporaryDirectory()
        try "x".write(to: other.appending(path: "y.txt"), atomically: true, encoding: .utf8)
        let rules = HarnessPermissionRuleset([.init(permission: "*", action: .allow), .init(permission: "external_directory", action: .deny)])
        await #expect(throws: HarnessPermissionDenied.self) {
            _ = try await ReadTool().execute(["path": .string(other.appending(path: "y.txt").path)], context: makeContext(root: root, rules: rules))
        }
    }

    @Test("edit replaces a unique match, tolerates indentation drift, rejects ambiguity")
    func edit() async throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "a.swift")
        try "func a() {\n    return 1\n}\nlet x = 1\nlet x = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let sink = EventSink()
        _ = try await EditTool().execute(["path": "a.swift", "oldString": "return 1", "newString": "return 2"], context: makeContext(root: root, events: sink))
        #expect(try String(contentsOf: file, encoding: .utf8).contains("return 2"))
        #expect(await sink.events.contains { if case .fileChanged = $0 { return true }; return false })

        _ = try await EditTool().execute(["path": "a.swift", "oldString": "func a() {\n  return 2", "newString": "func a() {\n    return 3"], context: makeContext(root: root))
        #expect(try String(contentsOf: file, encoding: .utf8).contains("return 3"))

        await #expect(throws: HarnessToolError.self) {
            _ = try await EditTool().execute(["path": "a.swift", "oldString": "let x = 1", "newString": "let y = 1"], context: makeContext(root: root))
        }
    }

    @Test("patch adds, updates with move, and deletes")
    func patch() async throws {
        let root = try temporaryDirectory()
        try "def greet():\n    print(\"Hi\")\n".write(to: root.appending(path: "app.py"), atomically: true, encoding: .utf8)
        try "gone".write(to: root.appending(path: "old.txt"), atomically: true, encoding: .utf8)
        let patch = """
        *** Begin Patch
        *** Add File: hello.txt
        +Hello world
        *** Update File: app.py
        *** Move to: main.py
        @@ def greet():
        -    print("Hi")
        +    print("Hello, world!")
        *** Delete File: old.txt
        *** End Patch
        """
        let output = try await PatchTool().execute(["patchText": .string(patch)], context: makeContext(root: root))
        #expect(output.text.contains("A hello.txt"))
        #expect(try String(contentsOf: root.appending(path: "hello.txt"), encoding: .utf8) == "Hello world\n")
        #expect(try String(contentsOf: root.appending(path: "main.py"), encoding: .utf8).contains("Hello, world!"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "app.py").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "old.txt").path))
    }

    @Test("glob and grep find files and lines")
    func search() async throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root.appending(path: "src/deep"), withIntermediateDirectories: true)
        try "let needle = 1".write(to: root.appending(path: "src/deep/a.swift"), atomically: true, encoding: .utf8)
        try "nothing".write(to: root.appending(path: "src/b.txt"), atomically: true, encoding: .utf8)
        let glob = try await GlobTool().execute(["pattern": "**/*.swift"], context: makeContext(root: root))
        #expect(glob.text.contains("src/deep/a.swift"))
        #expect(!glob.text.contains("b.txt"))
        let grep = try await GrepTool().execute(["pattern": "needle"], context: makeContext(root: root))
        #expect(grep.text.contains("src/deep/a.swift:1:"))
    }

    @Test("todowrite emits todos and drops cancelled items")
    func todos() async throws {
        let sink = EventSink()
        _ = try await TodoWriteTool().execute(["todos": [
            ["content": "a", "status": "completed"], ["content": "b", "status": "in_progress"], ["content": "c", "status": "cancelled"],
        ]], context: makeContext(root: try temporaryDirectory(), events: sink))
        let todos = await sink.events.compactMap { if case .todos(let items) = $0 { return items }; return nil }.first
        #expect(todos?.map(\.status) == [.completed, .inProgress])
    }

    @Test("Unified diff marks changed lines")
    func diff() {
        let diff = LineDiff.unified(old: "a\nb\nc\n", new: "a\nB\nc\n", path: "f")
        #expect(diff.contains("-b"))
        #expect(diff.contains("+B"))
    }
}

@Suite("Harness shell")
struct HarnessShellTests {
    @Test("bash streams output events and reports exit codes")
    func streams() async throws {
        let root = try temporaryDirectory()
        let sink = EventSink()
        let output = try await ShellTool().execute(["command": "echo one; echo two >&2; exit 3"], context: makeContext(root: root, events: sink))
        #expect(output.text.contains("one"))
        #expect(output.text.contains("Exit code: 3"))
        let streamed = await sink.events.compactMap { if case .output(let text, _) = $0 { return text }; return nil }.joined()
        #expect(streamed.contains("one") && streamed.contains("two"))
    }

    @Test("bash times out long commands")
    func timeout() async throws {
        let output = try await ShellTool().execute(["command": "sleep 5", "timeout": 300], context: makeContext(root: try temporaryDirectory()))
        #expect(output.isError)
        #expect(output.text.contains("timed out"))
    }

    @Test("Background shells report output and completion")
    func background() async throws {
        let root = try temporaryDirectory()
        let terminals = HarnessTerminalManager()
        let shell = try await terminals.startBackground("echo started; sleep 0.2; echo done", workingDirectory: root)
        try await Task.sleep(for: .seconds(1))
        let finished = await terminals.drainFinishedNotifications()
        #expect(finished.map(\.id) == [shell.id])
        let (_, output) = try #require(await terminals.output(of: shell.id))
        #expect(output.contains("started") && output.contains("done"))
    }
}

@Suite("Harness compaction")
struct HarnessCompactionTests {
    @Test("Threshold leaves room on small windows")
    func threshold() {
        let policy = HarnessCompactionPolicy.default
        #expect(policy.threshold(contextWindow: 200_000) == 170_000)
        #expect(policy.threshold(contextWindow: 8_192) >= 4_096)
        #expect(policy.threshold(contextWindow: 8_192) < 8_192)
    }

    @Test("Pruning clears old tool output but protects recent and current-turn output")
    func prune() {
        let big = String(repeating: "x", count: 40_000) // ~10k tokens
        var session = HarnessSession(id: "s", messages: [
            .user("q1"), .assistant("", toolCalls: [HarnessToolCall(id: "1", name: "read", argumentsJSON: "{}")]),
            .toolResult(callID: "1", name: "read", text: big),
            .assistant("", toolCalls: [HarnessToolCall(id: "2", name: "read", argumentsJSON: "{}")]),
            .toolResult(callID: "2", name: "read", text: big),
            .user("q2"), .toolResult(callID: "3", name: "read", text: big),
        ])
        let compactor = HarnessCompactor(policy: HarnessCompactionPolicy(pruneProtectTokens: 12_000, pruneMinimumTokens: 1_000))
        let pruned = compactor.prune(&session, contextWindow: nil)
        #expect(pruned == 1)
        #expect(session.messages[2].isPruned)
        #expect(!session.messages[4].isPruned)
        #expect(!session.messages[6].isPruned)
        #expect(HarnessCompactor.replayText(session.messages[2]) == HarnessCompactor.prunedPlaceholder)
        #expect(session.messages[2].text == big)
    }

    @Test("Automatic compaction summarizes when the estimate crosses the threshold")
    func automatic() async throws {
        let root = try temporaryDirectory()
        let history = (0..<20).flatMap { [HarnessMessage.user("question \($0) " + String(repeating: "y", count: 400)), .assistant("answer \($0)")] }
        let store = InMemoryHarnessSessionStore([HarnessSession(id: "s", messages: history)])
        let model = ScriptedModel([ScriptedModel.text("## Objective\n- summarized"), ScriptedModel.text("ok")], contextWindow: 3_000)
        let agent = HarnessAgent(configuration: HarnessConfiguration(tools: [], store: store, systemPrompt: HarnessSystemPrompt(loadProjectInstructions: false)))
        let events = try await collect(await agent.run(HarnessTurnInput(sessionID: "s", prompt: "next", workingDirectory: root, model: model, modelName: "m")))
        #expect(events.contains { if case .compactionFinished(.auto, _, true) = $0 { return true }; return false })
        #expect(model.recorded.first?.tools.isEmpty == true)
        #expect(model.recorded.first?.messages.first?.text.contains("Objective") == true)
    }
}

@Suite("Harness model wire")
struct HarnessModelWireTests {
    @Test("Streamed tool-call fragments are stitched and think tags split out")
    func streamDecoding() throws {
        var decoder = OpenAICompatibleHarnessModel.StreamDecoder()
        var chunks: [HarnessModelChunk] = []
        let lines = [
            #"data: {"choices":[{"delta":{"content":"<thi"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"nk>plan</think>Hello"}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read","arguments":"{\"pa"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"a\"}"}}]},"finish_reason":"tool_calls"}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":7}}"#,
            "data: [DONE]",
        ]
        for line in lines {
            let (next, done) = try decoder.consume(line: line)
            chunks += next
            if done { break }
        }
        chunks += decoder.finish()
        #expect(chunks.contains(.reasoningDelta("plan")))
        #expect(chunks.contains(.textDelta("Hello")))
        #expect(chunks.contains(.toolCall(HarnessToolCall(id: "c1", name: "read", argumentsJSON: #"{"path":"a"}"#))))
        #expect(chunks.contains(.usage(UsageInfo(inputTokens: 12, outputTokens: 7))))
        #expect(chunks.last == .finished(reason: "tool_calls"))
    }

    @Test("Assistant tool calls encode with null content and tool results with their call id")
    func encoding() {
        let encoded = OpenAICompatibleHarnessModel.encodeMessages(system: "sys", messages: [
            .user("hi"),
            .assistant("", toolCalls: [HarnessToolCall(id: "c1", name: "read", argumentsJSON: "{bad")]),
            .toolResult(callID: "c1", name: "read", text: "out"),
        ])
        #expect(encoded.count == 4)
        #expect(encoded[2]["content"]?.isNull == true)
        #expect(encoded[2]["tool_calls"]?[0]?["function"]?["arguments"]?.stringValue == "{}")
        #expect(encoded[3]["tool_call_id"]?.stringValue == "c1")
    }

    @Test("Context overflow bodies are recognized")
    func overflow() {
        #expect(HarnessModelError.mentionsContextOverflow("the request exceeds the available context size (n_ctx 4096)"))
        #expect(!HarnessModelError.mentionsContextOverflow("rate limited"))
    }
}

@Suite("Harness session storage")
struct HarnessSessionStoreTests {
    @Test("File store round-trips sessions and lists newest first")
    func fileStore() async throws {
        let store = FileHarnessSessionStore(directory: try temporaryDirectory())
        var older = HarnessSession(id: "a/../b", messages: [.user("x")])
        older.updatedAt = Date(timeIntervalSinceNow: -100)
        try await store.save(older)
        try await store.save(HarnessSession(id: "new", messages: [.user("y"), .assistant("z")]))
        #expect(try await store.list().map(\.id) == ["new", "a/../b"])
        #expect(try await store.load(id: "new")?.messages.count == 2)
        try await store.delete(id: "new")
        #expect(try await store.load(id: "new") == nil)
    }

    @Test("Old session JSON without newer keys still decodes")
    func tolerantDecoding() throws {
        let json = #"{"id":"s","messages":[{"role":"user","text":"hi"}]}"#
        let session = try JSONDecoder().decode(HarnessSession.self, from: Data(json.utf8))
        #expect(session.messages.first?.text == "hi")
        #expect(session.compactedThrough == 0)
    }
}

@Suite("Harness AgentClient mapping")
struct HarnessAgentClientTests {
    @Test("A harness turn maps onto balanced AgentEvents")
    func mapping() async throws {
        let root = try temporaryDirectory()
        let model = ScriptedModel([
            ScriptedModel.call("todowrite", ["todos": [["content": "a", "status": "pending"]]], id: "t"),
            ScriptedModel.text("done", usage: UsageInfo(inputTokens: 3, outputTokens: 1)),
        ])
        let client = HarnessAgentClient(agent: HarnessAgent()) { _ in .init(model: model, name: "m") }
        let thread = AgentThreadID()
        var events: [AgentEvent] = []
        for await event in client.send(AgentSendRequest(threadID: thread, prompt: "go", workingDirectory: root, permissions: AllowAllPermissions())) {
            events.append(event)
        }
        var started = 0, ended = 0
        for event in events {
            if case .messageStarted = event { started += 1 }
            if case .messageEnded = event { ended += 1 }
        }
        #expect(started == 2 && ended == 2)
        #expect(events.contains { if case .todos(let todos) = $0 { return todos.count == 1 }; return false })
        #expect(events.contains { if case .toolCallResult(id: "t", _, false) = $0 { return true }; return false })
        guard case .turnEnded(let result)? = events.last else { Issue.record("expected turnEnded last"); return }
        #expect(result.nativeSessionID == thread.rawValue.uuidString)
    }
}
