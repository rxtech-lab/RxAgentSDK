import Foundation
import RxAgentCore

@testable import RxAgentHarness

/// A model that replays scripted responses, one per call, and records every
/// request it was sent.
final class ScriptedModel: HarnessModel, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [[HarnessModelChunk]]
    private var failures: [Int: HarnessModelError]
    private(set) var requests: [HarnessModelRequest] = []
    let contextWindow: Int?

    init(_ responses: [[HarnessModelChunk]], contextWindow: Int? = nil, failures: [Int: HarnessModelError] = [:]) {
        self.responses = responses
        self.contextWindow = contextWindow
        self.failures = failures
    }

    var recorded: [HarnessModelRequest] { lock.withLock { requests } }

    func send(_ request: HarnessModelRequest) -> AsyncThrowingStream<HarnessModelChunk, Error> {
        let (index, next, failure): (Int, [HarnessModelChunk], HarnessModelError?) = lock.withLock {
            requests.append(request)
            let index = requests.count - 1
            if let failure = failures.removeValue(forKey: index) { return (index, [], failure) }
            return (index, responses.isEmpty ? [.textDelta("(script exhausted)")] : responses.removeFirst(), nil)
        }
        _ = index
        return AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
                return
            }
            for chunk in next { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    static func text(_ text: String, usage: UsageInfo? = nil) -> [HarnessModelChunk] {
        [.textDelta(text)] + (usage.map { [.usage($0)] } ?? []) + [.finished(reason: "stop")]
    }

    static func call(_ name: String, _ arguments: JSONValue, id: String = UUID().uuidString) -> [HarnessModelChunk] {
        [.toolCall(HarnessToolCall(id: id, name: name, argumentsJSON: arguments.jsonString)), .finished(reason: "tool_calls")]
    }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "harness-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

func collect(_ stream: AsyncThrowingStream<HarnessEvent, Error>) async throws -> [HarnessEvent] {
    var events: [HarnessEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

func makeContext(
    root: URL,
    handler: any HarnessPermissionHandler = AllowAllHarnessPermissions(),
    rules: HarnessPermissionRuleset = HarnessPermissionRuleset([.init(permission: "*", action: .allow)]),
    events: EventSink = EventSink()
) -> HarnessToolContext {
    let gate = HarnessPermissionGate(ruleset: rules, handler: handler)
    return HarnessToolContext(
        sessionID: "test", callID: "call", workingDirectory: root,
        terminals: HarnessTerminalManager(),
        emit: { await events.append($0) },
        authorize: { try await gate.authorize($0) }
    )
}

actor EventSink {
    private(set) var events: [HarnessToolEvent] = []
    func append(_ event: HarnessToolEvent) { events.append(event) }
}
