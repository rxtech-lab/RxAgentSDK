#if os(macOS)
import Foundation
import Testing
import RxAgentCore
@testable import RxAgentClients

@Suite("ACP model selection")
struct ACPModelSelectionTests {
    @Test("Models are applied before each prompt, including default reset", arguments: [false, true])
    func switchesModels(legacy: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("agent.py")
        let log = root.appendingPathComponent("requests.jsonl")
        try """
        import json, sys
        current = 'first'
        legacy = \(legacy ? "True" : "False")
        def config():
            if legacy:
                return {'models': {'currentModelId': current, 'availableModels': [{'modelId': m, 'name': m} for m in ['first', 'second', 'reject']]}}
            return {'configOptions': [{'id': 'model-selector', 'category': 'model', 'type': 'select', 'currentValue': current, 'options': [{'group': 'provider', 'name': 'Provider', 'options': [{'value': m, 'name': m} for m in ['first', 'second', 'reject']]}]}]}
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get('method')
            params = request.get('params', {})
            with open(sys.argv[1], 'a') as out:
                out.write(json.dumps({'method': method, 'params': params, 'active': current}) + '\\n')
            if 'id' not in request: continue
            result = {}
            if method == 'session/new': result = dict(config(), sessionId='session-one')
            if method in ['session/set_config_option', 'session/set_model']:
                target = params.get('value', params.get('modelId'))
                if target == 'reject':
                    print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'error': {'code': -32602, 'message': 'Model rejected'}}), flush=True)
                    continue
                current = target
                result = {} if legacy else config()
            if method == 'session/prompt': result = {'stopReason': 'end_turn'}
            print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        let client = ACPClient(command: "/usr/bin/python3", args: [script.path, log.path], displayName: "Fixture", id: .acp("fixture"))
        let thread = AgentThreadID()
        for model: String? in ["second", "first", "second", nil, "missing", "reject"] {
            var failed = false
            for await event in client.send(AgentSendRequest(threadID: thread, prompt: "hello",
                workingDirectory: root, model: model, permissions: AllowAllPermissions())) {
                if case .failed = event { failed = true }
            }
            #expect(failed == (model == "missing" || model == "reject"))
        }
        await client.endSession(thread: thread)
        let rows = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
        #expect(rows.filter { $0["method"]?.stringValue == "session/new" }.count == 1)
        let prompts = rows.filter { $0["method"]?.stringValue == "session/prompt" }
        #expect(prompts.compactMap { $0["active"]?.stringValue } == ["second", "first", "second", "first"])
        let changes = rows.filter { $0["method"]?.stringValue == (legacy ? "session/set_model" : "session/set_config_option") }
        #expect(changes.count == 5)
        #expect(changes.allSatisfy { $0["params"]?["sessionId"]?.stringValue == "session-one" })
        if !legacy { #expect(changes.allSatisfy { $0["params"]?["configId"]?.stringValue == "model-selector" }) }
    }
}
#endif
