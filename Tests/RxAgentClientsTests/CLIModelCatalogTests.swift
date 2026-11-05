#if os(macOS)
import Foundation
import Testing
import RxAgentCore
@testable import RxAgentClients

@Suite("CLI model catalogs")
struct CLIModelCatalogTests {
    /// A stand-in for a CLI. Every launch appends a line to `launches`.
    private struct Fixture {
        let root: URL
        let binary: URL
        var launches: Int {
            let text = (try? String(contentsOf: root.appending(path: "launches"), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").count
        }

        init(_ body: String) throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            binary = root.appending(path: "agent")
            let script = """
            #!/usr/bin/python3 -I
            import json, sys
            open(\(String(reflecting: root.appending(path: "launches").path)), 'a').write('launch\\n')
            \(body)
            """
            try script.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
    }

    private static let claudeAnswers = """
    for line in sys.stdin:
        request = json.loads(line)
        print(json.dumps({'type': 'system', 'subtype': 'hook_started'}), flush=True)
        print(json.dumps({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': request['request_id'], 'response': {'models': [
            {'value': 'default', 'displayName': 'Default'},
            {'value': 'opus[1m]', 'displayName': 'Opus (1M context)', 'description': 'Big'},
            {'value': 'haiku'},
        ]}}}), flush=True)
    """

    @Test("Claude Code's own list is used, leaving out its default entry")
    func claudeList() async throws {
        let fixture = try Fixture(Self.claudeAnswers)
        let models = await ClaudeCodeClient(binaryPath: fixture.binary.path).availableModels()
        #expect(models == [
            AgentModelOption(id: "opus[1m]", displayName: "Opus (1M context)", modelDescription: "Big"),
            AgentModelOption(id: "haiku", displayName: "haiku"),
        ])
    }

    @Test("Repeat asks don't launch the CLI again")
    func cached() async throws {
        let fixture = try Fixture(Self.claudeAnswers)
        let client = ClaudeCodeClient(binaryPath: fixture.binary.path)
        async let first = client.availableModels()
        async let second = client.availableModels()
        #expect(await first == second)
        _ = await client.availableModels()
        #expect(fixture.launches == 1)
    }

    @Test("A CLI that can't answer gets the fallback, and is asked again next time")
    func failureFallsBackAndIsNotKept() async throws {
        let fixture = try Fixture("sys.exit(1)")
        let client = ClaudeCodeClient(binaryPath: fixture.binary.path)
        #expect(await client.availableModels() == client.fallbackModels)
        #expect(await client.availableModels() == client.fallbackModels)
        #expect(fixture.launches == 2)
    }

    @Test("A CLI that lists nothing gets the fallback")
    func emptyFallsBack() async throws {
        let fixture = try Fixture("""
        for line in sys.stdin:
            print(json.dumps({'type': 'control_response', 'response': {'request_id': json.loads(line)['request_id'], 'response': {}}}), flush=True)
        """)
        let client = ClaudeCodeClient(binaryPath: fixture.binary.path)
        #expect(await client.availableModels() == client.fallbackModels)
    }

    @Test("Every page of Codex's list is read, leaving out hidden models")
    func codexPages() async throws {
        let fixture = try Fixture("""
        pages = {
            None: {'data': [{'id': 'a', 'displayName': 'A', 'description': 'First', 'hidden': False}, {'id': 'secret', 'hidden': True}], 'nextCursor': 'more'},
            'more': {'data': [{'id': 'b'}], 'nextCursor': None},
        }
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' not in request: continue
            result = pages[request['params'].get('cursor')] if request['method'] == 'model/list' else {}
            print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
        """)
        let models = await CodexClient(binaryPath: fixture.binary.path).availableModels()
        #expect(models == [
            AgentModelOption(id: "a", displayName: "A", modelDescription: "First"),
            AgentModelOption(id: "b", displayName: "b"),
        ])
    }

    @Test("Codex refusing the request gets the fallback")
    func codexRefusal() async throws {
        let fixture = try Fixture("""
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' not in request: continue
            print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'error': {'code': -32601, 'message': 'no'}}), flush=True)
        """)
        let client = CodexClient(binaryPath: fixture.binary.path)
        #expect(await client.availableModels() == client.fallbackModels)
    }

    @Test("A missing CLI gets the fallback without trying to launch anything")
    func missingBinary() async {
        let client = CodexClient(binaryPath: "/nonexistent/codex")
        #expect(await client.availableModels() == client.fallbackModels)
    }

    @Test("Other lines aren't mistaken for the answer")
    func unrelatedLines() {
        #expect(ClaudeModelList.models(fromLine: "noise") == nil)
        #expect(ClaudeModelList.models(fromLine: #"{"type":"system","subtype":"init"}"#) == nil)
        #expect(ClaudeModelList.models(fromLine: #"{"type":"control_response","response":{"request_id":"other"}}"#) == nil)
    }

    @Test("--mcp-config comes last, since it takes every value after it")
    func claudeArguments() {
        let arguments = ClaudeModelList.arguments(extraArguments: ["--settings", "x"])
        #expect(arguments.suffix(2).first == "--mcp-config")
        #expect(arguments.contains("--settings"))
    }

    @Test("The installed CLIs list their models", .enabled(if: ProcessInfo.processInfo.environment["RXAGENT_LIVE"] == "1"))
    func live() async {
        let claude = ClaudeCodeClient(), codex = CodexClient()
        let claudeModels = await claude.availableModels(), codexModels = await codex.availableModels()
        print("Claude Code: \(claudeModels.map(\.id))\nCodex: \(codexModels.map(\.id))")
        #expect(claudeModels != claude.fallbackModels)
        #expect(codexModels != codex.fallbackModels)
    }
}
#endif
