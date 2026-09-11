import Foundation
import FoundationModels
import RxAgentCore

/// Apple's on-device model as an agent client.
///
/// **Text only, deliberately.** `AnyAgentTool` carries a JSON Schema, while
/// `LanguageModelSession` wants a `FoundationModels.Tool` whose `Arguments` is a
/// concrete `@Generable` type — and on 26.0 there is no way to build one from a
/// schema known only at runtime. Rather than half-support tool calling with a
/// hand-rolled schema translator that would silently mangle anything beyond flat
/// string arguments, this client advertises no tools and says so in its
/// capabilities. Hosts that need tools on-device should use a different client
/// for those turns.
///
/// The other reason not to force it: the window here is a few thousand tokens
/// shared between prompt and response, which is less than a single MCP
/// `tools/list` for a real application. See ``contextBudget``.
public struct FoundationModelsClient: AgentClient {

    public let id: AgentClientID
    public let displayName: String
    public var provider: AgentProvider { .foundationModels }
    public let capabilities: AgentCapabilities

    /// Characters of conversation one prompt may carry.
    ///
    /// Conservative on purpose: the window is shared with the response, and CJK
    /// runs close to one token per character, so a budget tuned on English
    /// prose overflows on the first Chinese transcript.
    public let contextBudget: Int

    private let runtime: InProcessTurnRuntime

    public init(
        id: AgentClientID = .foundationModels,
        displayName: String = "Apple Intelligence",
        contextBudget: Int = 2_500,
        capabilities: AgentCapabilities = .foundationModelsDefaults
    ) {
        self.id = id
        self.displayName = displayName
        self.contextBudget = contextBudget
        self.capabilities = capabilities
        self.runtime = InProcessTurnRuntime()
    }

    // MARK: - Availability

    public func isAvailable() async -> Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// Why the model can't be used, phrased as something a user can act on.
    /// `nil` when it is available.
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in Settings to use it here."
        case .unavailable(.modelNotReady):
            "Apple Intelligence is still downloading its model. Try again shortly."
        case .unavailable:
            "Apple Intelligence isn't available right now."
        }
    }

    // MARK: - Turn

    public func send(_ request: AgentSendRequest) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(request, continuation: continuation)
                continuation.finish()
            }
            Task { await runtime.register(turnID: request.turnID, task: task) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: AgentSendRequest,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async {
        defer { Task { await runtime.remove(turnID: request.turnID) } }

        continuation.yield(.turnStarted(turnID: request.turnID))

        guard await isAvailable() else {
            continuation.yield(.failed(.agentReported(
                Self.unavailableReason ?? "Apple Intelligence isn't available."
            )))
            return
        }

        continuation.yield(.sessionStarted(SessionStarted(
            nativeSessionID: request.threadID.rawValue.uuidString,
            model: "system-language-model"
        )))

        let session = LanguageModelSession(instructions: Instructions(request.contextText))
        let prompt = Self.composePrompt(request, budget: contextBudget)

        continuation.yield(.messageStarted(role: .assistant, id: nil))
        continuation.yield(.blockStarted(.text))

        do {
            var emitted = ""
            for try await partial in session.streamResponse(to: Prompt(prompt)) {
                try Task.checkCancellation()
                // `streamResponse` yields the response so far, not a delta, so
                // the new text is whatever extends what we already sent.
                let snapshot = partial.content
                guard snapshot.count > emitted.count, snapshot.hasPrefix(emitted) else {
                    if snapshot != emitted {
                        continuation.yield(.textDelta(String(snapshot.dropFirst(emitted.count))))
                        emitted = snapshot
                    }
                    continue
                }
                continuation.yield(.textDelta(String(snapshot.dropFirst(emitted.count))))
                emitted = snapshot
            }

            continuation.yield(.blockEnded(.text))
            continuation.yield(.messageEnded(id: nil, usage: nil))
            continuation.yield(.turnEnded(TurnResult(
                nativeSessionID: request.threadID.rawValue.uuidString
            )))
        } catch is CancellationError {
            continuation.yield(.blockEnded(.text))
            continuation.yield(.failed(.cancelled))
        } catch {
            continuation.yield(.blockEnded(.text))
            continuation.yield(.failed(.agentReported(String(describing: error))))
        }
    }

    // MARK: - Prompt

    /// Replayed history plus this turn, trimmed to `budget` characters.
    ///
    /// Trims from the **front**: recent turns are what the next reply depends
    /// on, and the thread's rolling summary — already in `contextText` — is what
    /// covers the part dropped here.
    static func composePrompt(_ request: AgentSendRequest, budget: Int) -> String {
        var lines: [String] = []
        for message in request.history {
            let text = message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let role = switch message.role {
            case .user: "User"
            case .assistant: "Assistant"
            case .system: "Note"
            }
            lines.append("\(role): \(text)")
        }

        let headroom = max(budget - request.prompt.count - 64, 0)
        var replayed = lines.joined(separator: "\n\n")
        if replayed.count > headroom {
            replayed = replayed.isEmpty ? "" : "…\n\n" + String(replayed.suffix(headroom))
        }

        return replayed.isEmpty
            ? request.prompt
            : "\(replayed)\n\nUser: \(request.prompt)"
    }

    // MARK: - Lifecycle

    public func cancel(turn: UUID) async {
        await runtime.cancel(turnID: turn)
    }

    public func endSession(thread: AgentThreadID) async {}
}
