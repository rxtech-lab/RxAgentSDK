import Foundation

/// A scripted sequence of events, replayed with realistic pacing.
public struct AgentEventScript: Sendable, ExpressibleByArrayLiteral {
    public enum Step: Sendable {
        case event(AgentEvent)
        /// Split into per-character deltas so streaming UI actually animates.
        case streamText(String)
        case streamThinking(String)
        case pause(Duration)
    }

    public var steps: [Step]

    public init(_ steps: [Step]) { self.steps = steps }
    public init(arrayLiteral elements: Step...) { self.steps = elements }
}

// MARK: - Built-in scripts

public extension AgentEventScript {
    static let simpleAnswer = AgentEventScript([
        .event(.sessionStarted(SessionStarted(nativeSessionID: "preview-session", model: "preview"))),
        .event(.messageStarted(role: .assistant, id: "m1")),
        .event(.blockStarted(.text)),
        .streamText("Sure — the message list pins your prompt to the top of the viewport and lets the answer grow into the space beneath it."),
        .event(.blockEnded(.text)),
        .event(.messageEnded(id: "m1", usage: UsageInfo(inputTokens: 412, outputTokens: 63))),
        .event(.turnEnded(TurnResult(durationMS: 1_200))),
    ])

    static let thinking = AgentEventScript([
        .event(.sessionStarted(SessionStarted(nativeSessionID: "preview-session"))),
        .event(.messageStarted(role: .assistant, id: "m1")),
        .event(.blockStarted(.thinking)),
        .streamThinking("The spacer height is viewport minus turn height, and the turn height ratchets so a half-settled layout pass can't shrink it."),
        .event(.blockEnded(.thinking)),
        .event(.blockStarted(.text)),
        .streamText("It reserves space below the turn so the pinned message stays put."),
        .event(.blockEnded(.text)),
        .event(.messageEnded(id: "m1", usage: nil)),
        .event(.turnEnded(TurnResult())),
    ])

    static let toolUse = AgentEventScript([
        .event(.sessionStarted(SessionStarted(nativeSessionID: "preview-session"))),
        .event(.messageStarted(role: .assistant, id: "m1")),
        .event(.blockStarted(.text)),
        .streamText("Let me look at the current state of the file."),
        .event(.blockEnded(.text)),
        .event(.toolCallStarted(id: "t1", name: "Bash")),
        .event(.toolCallInput(id: "t1", input: [
            "command": .string("git status --short"),
            "description": .string("Check the working tree"),
        ])),
        .pause(.milliseconds(600)),
        .event(.toolCallResult(id: "t1", content: " M Sources/App/main.swift\n?? Notes.md", isError: false)),
        .event(.toolCallStarted(id: "t2", name: "Edit")),
        .event(.toolCallInput(id: "t2", input: [
            "file_path": .string("/tmp/demo/Sources/App/main.swift"),
            "old_string": .string("print(\"hi\")"),
            "new_string": .string("print(\"hello, world\")"),
        ])),
        .pause(.milliseconds(400)),
        .event(.toolCallResult(id: "t2", content: "Applied 1 edit.", isError: false)),
        .event(.blockStarted(.text)),
        .streamText("Updated the greeting and left `Notes.md` untracked."),
        .event(.blockEnded(.text)),
        .event(.messageEnded(id: "m1", usage: UsageInfo(inputTokens: 1_204, outputTokens: 88))),
        .event(.turnEnded(TurnResult(durationMS: 3_400))),
    ])

    static let longMarkdown = AgentEventScript([
        .event(.sessionStarted(SessionStarted(nativeSessionID: "preview-session"))),
        .event(.messageStarted(role: .assistant, id: "m1")),
        .event(.blockStarted(.text)),
        .streamText("""
        ## Dynamic spacing

        The list reserves a **tail spacer** whose height is:

        ```swift
        max(0, scrollViewHeight - activeTurnHeight - minimumPinnedTailSpacing)
        ```

        Where `activeTurnHeight` is measured as `tailMarkerMinY - latestUserMinY`.

        | Constant | Value |
        | --- | --- |
        | `loadThreshold` | 96 |
        | `minimumPinnedTailSpacing` | 16 |
        | `scrollAnimationSeconds` | 0.18 |

        1. The user message pins to the top.
        2. The answer grows into the reserved space.
        3. Once the space is consumed, the list follows the bottom.

        > The ratchet is committed only from the scroll-geometry callback.
        """),
        .event(.blockEnded(.text)),
        .event(.messageEnded(id: "m1", usage: nil)),
        .event(.turnEnded(TurnResult())),
    ])

    static let todos = AgentEventScript([
        .event(.sessionStarted(SessionStarted(nativeSessionID: "preview-session"))),
        .event(.messageStarted(role: .assistant, id: "m1")),
        .event(.todos([
            TodoItem(id: 0, content: "Port the message list", activeForm: "Porting the message list", status: .completed),
            TodoItem(id: 1, content: "Port the markdown renderer", activeForm: "Porting the markdown renderer", status: .inProgress),
            TodoItem(id: 2, content: "Wire up the chat view", activeForm: "Wiring up the chat view", status: .pending),
        ])),
        .event(.blockStarted(.text)),
        .streamText("Working through the port now."),
        .event(.blockEnded(.text)),
        .event(.messageEnded(id: "m1", usage: nil)),
        .event(.turnEnded(TurnResult())),
    ])

    static let permissionRequest = AgentEventScript([
        .event(.sessionStarted(SessionStarted(nativeSessionID: "preview-session"))),
        .event(.messageStarted(role: .assistant, id: "m1")),
        .event(.toolCallStarted(id: "t1", name: "Bash")),
        .event(.toolCallInput(id: "t1", input: [
            "command": .string("rm -rf build/"),
            "description": .string("Clean the build directory"),
        ])),
        .event(.permissionRequested(PermissionRequest(
            id: "t1",
            toolName: "Bash",
            toolInput: ["command": .string("rm -rf build/")],
            mode: .default
        ))),
    ])

    static let failure = AgentEventScript([
        .event(.sessionStarted(SessionStarted(nativeSessionID: "preview-session"))),
        .event(.messageStarted(role: .assistant, id: "m1")),
        .event(.blockStarted(.text)),
        .streamText("Starting up…"),
        .event(.blockEnded(.text)),
        .event(.failed(.processExited(code: 1, stderr: "error: credit balance is too low"))),
    ])
}

// MARK: - Client

/// Replays an ``AgentEventScript`` instead of launching a process.
///
/// Deliberately not `#if DEBUG` and not confined to a test target: SwiftUI
/// previews, the example app, and downstream users all need it, and previews in
/// a library target cannot see a test-only symbol.
public struct PreviewAgentClient: AgentClient {
    public let id: AgentClientID
    public let displayName: String
    public let provider: AgentProvider
    public let capabilities: AgentCapabilities

    private let script: AgentEventScript
    private let deltaInterval: Duration
    private let reasoningLevels: [AgentReasoningOption]

    public init(
        id: AgentClientID = "preview",
        displayName: String = "Preview",
        provider: AgentProvider = .claudeCode,
        capabilities: AgentCapabilities = .claudeCodeDefaults,
        script: AgentEventScript = .simpleAnswer,
        deltaInterval: Duration = .milliseconds(12),
        reasoningLevels: [AgentReasoningOption] = .claudeCodeEfforts
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.capabilities = capabilities
        self.script = script
        self.deltaInterval = deltaInterval
        self.reasoningLevels = reasoningLevels
    }

    public func isAvailable() async -> Bool { true }

    public func availableModels() async -> [AgentModelOption] {
        [
            AgentModelOption(id: "preview-fast", displayName: "Preview Fast"),
            AgentModelOption(id: "preview-deep", displayName: "Preview Deep"),
        ]
    }

    public func availableReasoningLevels() async -> [AgentReasoningOption] {
        reasoningLevels
    }

    public func send(_ request: AgentSendRequest) -> AsyncStream<AgentEvent> {
        let script = script
        let interval = deltaInterval
        let turnID = request.turnID

        return AsyncStream { continuation in
            let task = Task {
                continuation.yield(.turnStarted(turnID: turnID))
                for step in script.steps {
                    if Task.isCancelled { break }
                    switch step {
                    case .event(let event):
                        continuation.yield(event)
                    case .streamText(let text):
                        await Self.stream(text, interval: interval, into: continuation) {
                            .textDelta($0)
                        }
                    case .streamThinking(let text):
                        await Self.stream(text, interval: interval, into: continuation) {
                            .thinkingDelta($0)
                        }
                    case .pause(let duration):
                        try? await Task.sleep(for: duration)
                    }
                }
                if Task.isCancelled {
                    continuation.yield(.failed(.cancelled))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel(turn: UUID) async {}

    /// Emit in small chunks rather than per character — one yield per character
    /// on a long answer floods the observation system for no visual gain.
    private static func stream(
        _ text: String,
        interval: Duration,
        into continuation: AsyncStream<AgentEvent>.Continuation,
        wrap: (String) -> AgentEvent
    ) async {
        var chunk = ""
        for character in text {
            chunk.append(character)
            if chunk.count >= 3 {
                continuation.yield(wrap(chunk))
                chunk = ""
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
            }
        }
        if !chunk.isEmpty { continuation.yield(wrap(chunk)) }
    }
}
