import Foundation
import RxAgentCore

// MARK: - Configuration

/// Settings shared by every turn an agent runs.
public struct HarnessConfiguration: Sendable {
    public var tools: [any HarnessTool]
    public var store: any HarnessSessionStore
    public var permissionRules: HarnessPermissionRuleset
    public var systemPrompt: HarnessSystemPrompt
    public var compaction: HarnessCompactionPolicy
    /// Model calls per turn before the harness stops the loop.
    public var maxSteps: Int
    public var temperature: Double?
    public var maxOutputTokens: Int?
    /// Tool calls the model asks for in one step that are all read-only run
    /// concurrently, up to this many at a time.
    public var maxParallelReadOnlyTools: Int

    public init(
        tools: [any HarnessTool] = HarnessToolset.standard(),
        store: any HarnessSessionStore = InMemoryHarnessSessionStore(),
        permissionRules: HarnessPermissionRuleset = .defaults,
        systemPrompt: HarnessSystemPrompt = HarnessSystemPrompt(),
        compaction: HarnessCompactionPolicy = .default,
        maxSteps: Int = 50,
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil,
        maxParallelReadOnlyTools: Int = 4
    ) {
        self.tools = tools
        self.store = store
        self.permissionRules = permissionRules
        self.systemPrompt = systemPrompt
        self.compaction = compaction
        self.maxSteps = maxSteps
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.maxParallelReadOnlyTools = maxParallelReadOnlyTools
    }
}

/// One turn's inputs.
public struct HarnessTurnInput: Sendable {
    public var sessionID: String
    public var prompt: String
    public var images: [HarnessImage]
    public var workingDirectory: URL
    public var model: any HarnessModel
    public var modelName: String
    public var mode: HarnessGenerationMode
    public var permissionMode: PermissionMode
    public var permissionHandler: any HarnessPermissionHandler
    public var questionHandler: (any HarnessQuestionHandler)?
    /// Appended to the configured system prompt for this turn only.
    public var instructions: String
    /// Host tools for this turn, added to the configured ones.
    public var extraTools: [any HarnessTool]
    /// When non-nil, only these tool names are offered.
    public var allowedTools: Set<String>?
    public var disallowedTools: Set<String>

    public init(
        sessionID: String,
        prompt: String,
        images: [HarnessImage] = [],
        workingDirectory: URL,
        model: any HarnessModel,
        modelName: String,
        mode: HarnessGenerationMode = .streaming,
        permissionMode: PermissionMode = .default,
        permissionHandler: any HarnessPermissionHandler = RejectAllHarnessPermissions(),
        questionHandler: (any HarnessQuestionHandler)? = nil,
        instructions: String = "",
        extraTools: [any HarnessTool] = [],
        allowedTools: Set<String>? = nil,
        disallowedTools: Set<String> = []
    ) {
        self.sessionID = sessionID
        self.prompt = prompt
        self.images = images
        self.workingDirectory = workingDirectory
        self.model = model
        self.modelName = modelName
        self.mode = mode
        self.permissionMode = permissionMode
        self.permissionHandler = permissionHandler
        self.questionHandler = questionHandler
        self.instructions = instructions
        self.extraTools = extraTools
        self.allowedTools = allowedTools
        self.disallowedTools = disallowedTools
    }
}

public enum HarnessError: Error, Sendable, CustomStringConvertible, Equatable {
    case busy(sessionID: String)
    case cancelled
    case model(String)

    public var description: String {
        switch self {
        case .busy(let id): "Session \(id) is already running a turn."
        case .cancelled: "Cancelled."
        case .model(let detail): detail
        }
    }
}

// MARK: - Agent

/// An in-process coding agent: an opencode-style loop over a ``HarnessModel``.
///
/// ```swift
/// let agent = HarnessAgent(configuration: .init(store: FileHarnessSessionStore(directory: dir)))
/// for try await event in await agent.run(input) { … }      // streaming
/// let result = try await agent.generate(input)              // one result
/// ```
///
/// Each session keeps a permission gate (so "always allow" answers persist
/// across turns) and a terminal manager (so background shells outlive the turn
/// that started them) until ``release(sessionID:)``.
public actor HarnessAgent {
    public private(set) var configuration: HarnessConfiguration

    private struct SessionRuntime {
        let gate: HarnessPermissionGate
        let terminals: HarnessTerminalManager
        var task: Task<Void, Never>?
        var lastUsed: Date
    }

    private var runtimes: [String: SessionRuntime] = [:]

    public init(configuration: HarnessConfiguration = HarnessConfiguration()) {
        self.configuration = configuration
    }

    public func updateConfiguration(_ update: (inout HarnessConfiguration) -> Void) {
        update(&configuration)
    }

    // MARK: Public API

    /// Runs one turn, streaming every event.
    public func run(_ input: HarnessTurnInput) -> AsyncThrowingStream<HarnessEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<HarnessEvent, Error>.makeStream()
        if runtimes[input.sessionID]?.task != nil {
            continuation.finish(throwing: HarnessError.busy(sessionID: input.sessionID))
            return stream
        }
        let runtime = runtime(for: input.sessionID, handler: input.permissionHandler)
        let configuration = configuration
        let task = Task {
            await runtime.gate.setMode(input.permissionMode)
            await runtime.gate.setRuleset(configuration.permissionRules)
            await runtime.gate.setHandler(input.permissionHandler)
            let turn = HarnessTurn(
                configuration: configuration, input: input,
                gate: runtime.gate, terminals: runtime.terminals,
                emit: { continuation.yield($0) }
            )
            do {
                try await turn.run()
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: HarnessError.cancelled)
            } catch {
                continuation.finish(throwing: error)
            }
            self.turnEnded(sessionID: input.sessionID)
        }
        runtimes[input.sessionID]?.task = task
        continuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
        return stream
    }

    /// Generation mode: runs the turn without streaming and returns its result.
    /// Model calls use ``HarnessGenerationMode/generation`` unless the input
    /// says otherwise.
    public func generate(_ input: HarnessTurnInput) async throws -> HarnessTurnResult {
        var input = input
        if input.mode == .streaming { input.mode = .generation }
        var result: HarnessTurnResult?
        for try await event in run(input) {
            if case .turnFinished(let finished) = event { result = finished }
            if case .failed(let message) = event { throw HarnessError.model(message) }
        }
        guard let result else { throw HarnessError.cancelled }
        return result
    }

    public func cancel(sessionID: String) {
        runtimes[sessionID]?.task?.cancel()
    }

    public func isRunning(sessionID: String) -> Bool {
        runtimes[sessionID]?.task != nil
    }

    /// Compacts a session now, outside a turn — `/compact`.
    public func compact(sessionID: String, model: any HarnessModel, modelName: String) async throws -> Bool {
        guard var session = try await configuration.store.load(id: sessionID) else { return false }
        let compactor = HarnessCompactor(policy: configuration.compaction)
        compactor.prune(&session, contextWindow: model.contextWindow)
        var usage = UsageInfo()
        let summarized = try await compactor.summarize(&session, model: model, modelName: modelName) { usage = $0 }
        session.usage = HarnessTurn.add(usage, to: session.usage)
        session.updatedAt = Date()
        try await configuration.store.save(session)
        return summarized
    }

    /// Ends a session's runtime: kills its background shells and forgets its
    /// "always allow" answers. The stored session is untouched.
    public func release(sessionID: String) async {
        guard let runtime = runtimes.removeValue(forKey: sessionID) else { return }
        runtime.task?.cancel()
        await runtime.terminals.shutdown()
    }

    /// Releases every idle session last used before `date`.
    public func releaseIdle(before date: Date) async {
        for (id, runtime) in runtimes where runtime.task == nil && runtime.lastUsed < date {
            await release(sessionID: id)
        }
    }

    public func backgroundShells(sessionID: String) async -> [HarnessBackgroundShell] {
        await runtimes[sessionID]?.terminals.backgroundShells() ?? []
    }

    // MARK: Private

    /// The session's runtime, created on first use. The gate is kept across
    /// turns so its "always allow" answers persist; only its handler, which
    /// carries the turn's resolver, is swapped.
    private func runtime(for sessionID: String, handler: any HarnessPermissionHandler) -> SessionRuntime {
        if var existing = runtimes[sessionID] {
            existing.lastUsed = Date()
            runtimes[sessionID] = existing
            return existing
        }
        let runtime = SessionRuntime(
            gate: HarnessPermissionGate(ruleset: configuration.permissionRules, handler: handler),
            terminals: HarnessTerminalManager(),
            task: nil,
            lastUsed: Date()
        )
        runtimes[sessionID] = runtime
        return runtime
    }

    private func turnEnded(sessionID: String) {
        runtimes[sessionID]?.task = nil
        runtimes[sessionID]?.lastUsed = Date()
    }
}

// MARK: - Turn

/// The loop for one turn. A value type driven from the agent's task; all
/// session mutation happens on its local copy, which is saved after every step.
struct HarnessTurn {
    let configuration: HarnessConfiguration
    let input: HarnessTurnInput
    let gate: HarnessPermissionGate
    let terminals: HarnessTerminalManager
    let emit: @Sendable (HarnessEvent) -> Void

    private var store: any HarnessSessionStore { configuration.store }

    func run() async throws {
        let started = Date()
        let tools = activeTools()
        let toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let specs = tools.map(\.spec)
        let compactor = HarnessCompactor(policy: configuration.compaction)

        var session = try await store.load(id: input.sessionID)
            ?? HarnessSession(id: input.sessionID, workingDirectory: input.workingDirectory.path)
        session.model = input.modelName
        session.workingDirectory = input.workingDirectory.path
        if session.title == nil {
            let firstLine = input.prompt.split(separator: "\n").first.map(String.init) ?? input.prompt
            session.title = String(firstLine.prefix(80))
        }
        session.messages.append(.user(input.prompt, images: input.images))
        session.updatedAt = Date()
        try await store.save(session)
        emit(.sessionLoaded(session.info))

        var turnUsage = UsageInfo()
        var finalText = ""
        var finishReason: String?
        var step = 0

        while step < configuration.maxSteps {
            try Task.checkCancellation()
            step += 1

            // Background shells that finished since the last step.
            let finished = await terminals.drainFinishedNotifications()
            if !finished.isEmpty {
                let lines = finished.map { "Background shell \($0.id) (`\($0.command)`) finished with exit code \($0.exitCode ?? -1). Read its output with bash_output." }
                session.messages.append(.user("<system-reminder>\n" + lines.joined(separator: "\n") + "\n</system-reminder>"))
            }

            if configuration.compaction.automatic, let window = input.model.contextWindow {
                let estimate = promptEstimate(session, specs: specs)
                if estimate > configuration.compaction.threshold(contextWindow: window) {
                    try await compact(&session, compactor: compactor, reason: .auto, specs: specs, turnUsage: &turnUsage)
                }
            }

            emit(.stepStarted(step: step))
            let outcome: StepOutcome
            do {
                outcome = try await callModel(session, specs: specs, turnUsage: turnUsage)
            } catch HarnessModelError.contextOverflow {
                try await compact(&session, compactor: compactor, reason: .overflow, specs: specs, turnUsage: &turnUsage)
                outcome = try await callModel(session, specs: specs, turnUsage: turnUsage)
            }

            turnUsage = Self.add(outcome.usage, to: turnUsage)
            session.usage = Self.add(outcome.usage, to: session.usage)
            if outcome.usage.inputTokens > 0 { session.lastPromptTokens = outcome.usage.inputTokens + outcome.usage.outputTokens }
            emit(.usage(HarnessTokenUsage(step: outcome.usage, turn: turnUsage, session: session.usage, isEstimate: !outcome.measured)))
            if let window = input.model.contextWindow {
                let used = session.lastPromptTokens ?? promptEstimate(session, specs: specs)
                emit(.contextWindow(ContextWindowInfo(usedTokens: used, maxTokens: window)))
            }

            let assistant = HarnessMessage(
                role: .assistant,
                text: outcome.text,
                reasoning: outcome.reasoning.isEmpty ? nil : outcome.reasoning,
                toolCalls: outcome.toolCalls
            )
            session.messages.append(assistant)
            session.updatedAt = Date()
            try await store.save(session)
            emit(.messageCompleted(assistant))
            finishReason = outcome.finishReason
            if !outcome.text.isEmpty { finalText = outcome.text }

            guard !outcome.toolCalls.isEmpty else { break }

            let results = try await executeTools(outcome.toolCalls, toolsByName: toolsByName, session: &session)
            session.messages.append(contentsOf: results.messages)
            session.updatedAt = Date()
            try await store.save(session)
            if results.stop {
                finishReason = "permission_rejected"
                break
            }
            if step == configuration.maxSteps { finishReason = "max_steps" }
        }

        emit(.turnFinished(HarnessTurnResult(
            sessionID: session.id,
            text: finalText,
            steps: step,
            usage: turnUsage,
            durationMS: Int(Date().timeIntervalSince(started) * 1000),
            finishReason: finishReason
        )))
    }

    // MARK: Model call

    struct StepOutcome {
        var text = ""
        var reasoning = ""
        var toolCalls: [HarnessToolCall] = []
        var usage = UsageInfo()
        var measured = false
        var finishReason: String?
    }

    private func callModel(_ session: HarnessSession, specs: [HarnessToolSpec], turnUsage: UsageInfo) async throws -> StepOutcome {
        let system = systemPrompt(session, specs: specs)
        let request = HarnessModelRequest(
            model: input.modelName,
            system: system,
            messages: replayMessages(session),
            tools: specs,
            mode: input.mode,
            maxOutputTokens: configuration.maxOutputTokens,
            temperature: configuration.temperature
        )
        let promptEstimate = TokenEstimator.estimate(system: system, messages: request.messages, tools: specs)

        var outcome = StepOutcome()
        var lastEmittedEstimate = 0
        var streamedCharacters = 0
        for try await chunk in input.model.send(request) {
            try Task.checkCancellation()
            switch chunk {
            case .textDelta(let delta):
                outcome.text += delta
                streamedCharacters += delta.utf8.count
                emit(.textDelta(delta))
            case .reasoningDelta(let delta):
                outcome.reasoning += delta
                streamedCharacters += delta.utf8.count
                emit(.reasoningDelta(delta))
            case .toolCall(let call):
                outcome.toolCalls.append(call)
                streamedCharacters += call.argumentsJSON.utf8.count
            case .usage(let usage):
                outcome.usage = usage
                outcome.measured = true
            case .finished(let reason):
                outcome.finishReason = reason
            }
            // Live token counter while streaming: an estimate every ~16 tokens,
            // replaced by the server's numbers once they arrive.
            let estimatedOutput = streamedCharacters / 4
            if !outcome.measured, estimatedOutput - lastEmittedEstimate >= 16 {
                lastEmittedEstimate = estimatedOutput
                let step = UsageInfo(inputTokens: promptEstimate, outputTokens: estimatedOutput)
                emit(.usage(HarnessTokenUsage(
                    step: step, turn: Self.add(step, to: turnUsage),
                    session: Self.add(step, to: session.usage), isEstimate: true
                )))
            }
        }
        // A cancelled task ends `for try await` quietly rather than throwing;
        // without this the partial response would be saved as a finished step.
        try Task.checkCancellation()
        if !outcome.measured {
            outcome.usage = UsageInfo(inputTokens: promptEstimate, outputTokens: max(1, streamedCharacters / 4))
        }
        outcome.text = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some local models name tools with stray whitespace or a namespace.
        outcome.toolCalls = outcome.toolCalls.map { call in
            var call = call
            call.name = call.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if call.name.hasPrefix("functions.") { call.name = String(call.name.dropFirst("functions.".count)) }
            return call
        }
        return outcome
    }

    private func systemPrompt(_ session: HarnessSession, specs: [HarnessToolSpec]) -> String {
        var prompt = configuration.systemPrompt
        if !input.instructions.isEmpty {
            prompt.additionalInstructions = [prompt.additionalInstructions, input.instructions]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        return prompt.render(
            workingDirectory: input.workingDirectory,
            toolNames: specs.map(\.name),
            model: input.modelName,
            planMode: input.permissionMode == .plan,
            summary: session.summary
        )
    }

    /// The live history as the model sees it: pruned results as placeholders,
    /// tool images as a follow-up user message.
    private func replayMessages(_ session: HarnessSession) -> [HarnessMessage] {
        var messages: [HarnessMessage] = []
        var pendingImages: [HarnessImage] = []
        for message in session.liveMessages {
            if message.role != .tool, !pendingImages.isEmpty {
                messages.append(.user("Images returned by the previous tool calls:", images: pendingImages))
                pendingImages.removeAll()
            }
            var replay = message
            replay.text = HarnessCompactor.replayText(message)
            if message.role == .tool {
                if !message.isPruned { pendingImages += message.images }
                replay.images = []
            }
            messages.append(replay)
        }
        if !pendingImages.isEmpty {
            messages.append(.user("Images returned by the previous tool calls:", images: pendingImages))
        }
        return messages
    }

    private func promptEstimate(_ session: HarnessSession, specs: [HarnessToolSpec]) -> Int {
        TokenEstimator.estimate(system: systemPrompt(session, specs: specs), messages: replayMessages(session), tools: specs)
    }

    // MARK: Compaction

    private func compact(
        _ session: inout HarnessSession,
        compactor: HarnessCompactor,
        reason: HarnessCompactionReason,
        specs: [HarnessToolSpec],
        turnUsage: inout UsageInfo
    ) async throws {
        emit(.compactionStarted(reason: reason))
        let pruned = compactor.prune(&session, contextWindow: input.model.contextWindow)
        var summarized = false
        let window = input.model.contextWindow
        let stillOver = window.map { promptEstimate(session, specs: specs) > configuration.compaction.threshold(contextWindow: $0) } ?? true
        if reason != .auto || stillOver {
            var usage = UsageInfo()
            summarized = try await compactor.summarize(&session, model: input.model, modelName: input.modelName) { usage = $0 }
            turnUsage = Self.add(usage, to: turnUsage)
            session.usage = Self.add(usage, to: session.usage)
        }
        session.updatedAt = Date()
        try await store.save(session)
        emit(.compactionFinished(reason: reason, prunedToolOutputs: pruned, summarized: summarized))
        if let window {
            emit(.contextWindow(ContextWindowInfo(usedTokens: promptEstimate(session, specs: specs), maxTokens: window)))
        }
    }

    // MARK: Tools

    private func activeTools() -> [any HarnessTool] {
        var seen = Set<String>()
        return (configuration.tools + input.extraTools).filter { tool in
            guard seen.insert(tool.name).inserted else { return false }
            if input.disallowedTools.contains(tool.name) { return false }
            if let allowed = input.allowedTools { return allowed.contains(tool.name) }
            return true
        }
    }

    private struct ToolResults {
        var messages: [HarnessMessage]
        /// A person rejected a request without a message — opencode ends the
        /// turn there rather than letting the model try something else.
        var stop: Bool
    }

    private func executeTools(
        _ calls: [HarnessToolCall],
        toolsByName: [String: any HarnessTool],
        session: inout HarnessSession
    ) async throws -> ToolResults {
        for call in calls {
            emit(.toolCallStarted(id: call.id, name: call.name))
            emit(.toolCallInput(id: call.id, input: call.arguments ?? .object([:])))
        }

        let allReadOnly = calls.allSatisfy { toolsByName[$0.name]?.isReadOnly == true }
        var outputs: [String: (HarnessToolOutput, stop: Bool)] = [:]
        if allReadOnly && calls.count > 1 {
            try await withThrowingTaskGroup(of: (String, HarnessToolOutput, Bool).self) { group in
                var iterator = calls.makeIterator()
                var running = 0
                func next() {
                    guard let call = iterator.next() else { return }
                    running += 1
                    group.addTask { let (output, stop) = await self.execute(call, toolsByName: toolsByName); return (call.id, output, stop) }
                }
                for _ in 0..<max(1, configuration.maxParallelReadOnlyTools) { next() }
                while let (id, output, stop) = try await group.next() {
                    outputs[id] = (output, stop)
                    running -= 1
                    next()
                }
            }
        } else {
            for call in calls {
                try Task.checkCancellation()
                outputs[call.id] = await execute(call, toolsByName: toolsByName)
                if outputs[call.id]?.stop == true { break }
            }
        }

        var messages: [HarnessMessage] = []
        var stop = false
        for call in calls {
            let (output, shouldStop) = outputs[call.id]
                ?? (HarnessToolOutput.error("Skipped: an earlier tool call in this step was rejected."), false)
            stop = stop || shouldStop
            var message = HarnessMessage.toolResult(callID: call.id, name: call.name, text: output.text, isError: output.isError)
            message.images = output.images
            messages.append(message)
            emit(.toolCallCompleted(id: call.id, name: call.name, output: output))
        }
        if let todos = todoBox.value { session.todos = todos }
        return ToolResults(messages: messages, stop: stop)
    }

    /// The todo list `todowrite` reported during this turn, if any.
    private let todoBox = TodoHolder()

    private func execute(_ call: HarnessToolCall, toolsByName: [String: any HarnessTool]) async -> (HarnessToolOutput, Bool) {
        guard let tool = toolsByName[call.name] else {
            let names = toolsByName.keys.sorted().joined(separator: ", ")
            return (.error("Unknown tool `\(call.name)`. Available tools: \(names)."), false)
        }
        guard let arguments = call.arguments else {
            return (.error("The arguments for `\(call.name)` were not valid JSON: \(call.argumentsJSON.prefix(300)). Retry with valid JSON matching the schema."), false)
        }

        let gate = self.gate
        let emit = self.emit
        let callID = call.id
        let sessionID = input.sessionID
        let todoBox = self.todoBox
        let context = HarnessToolContext(
            sessionID: sessionID,
            callID: callID,
            workingDirectory: input.workingDirectory,
            terminals: terminals,
            questioner: input.questionHandler,
            emit: { event in
                if case .todos(let todos) = event {
                    todoBox.set(todos)
                    emit(.todos(todos))
                }
                emit(.toolProgress(callID: callID, event: event))
            },
            authorize: { ask in
                try await gate.authorize(
                    ask,
                    onAsk: { emit(.permissionAsked($0)) },
                    onReply: { ask, reply in emit(.permissionReplied(id: ask.id, reply: reply)) }
                )
            }
        )

        do {
            if await gate.recordCall(name: call.name, argumentsJSON: call.argumentsJSON) {
                try await context.authorize(
                    HarnessPermissionKey.doomLoop, resources: [call.name], toolName: call.name,
                    input: arguments,
                    title: "\(call.name) has been called \(HarnessPermissionGate.doomLoopThreshold) times in a row with identical input. Allow it again?"
                )
            }
            return (try await tool.execute(arguments, context: context), false)
        } catch let denied as HarnessPermissionDenied {
            return (.error(denied.description), !denied.byRule && (denied.message ?? "").isEmpty)
        } catch is CancellationError {
            return (.error("Cancelled."), true)
        } catch {
            return (.error(String(describing: error)), false)
        }
    }

    static func add(_ increment: UsageInfo, to total: UsageInfo) -> UsageInfo {
        UsageInfo(
            inputTokens: total.inputTokens + increment.inputTokens,
            outputTokens: total.outputTokens + increment.outputTokens,
            cacheReadTokens: total.cacheReadTokens + increment.cacheReadTokens,
            cacheCreationTokens: total.cacheCreationTokens + increment.cacheCreationTokens,
            totalCostUSD: (total.totalCostUSD ?? increment.totalCostUSD).map { _ in
                (total.totalCostUSD ?? 0) + (increment.totalCostUSD ?? 0)
            }
        )
    }
}

/// Collects the todo list a tool reports from inside its (concurrent) context.
final class TodoHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var todos: [TodoItem]?
    func set(_ todos: [TodoItem]) { lock.withLock { self.todos = todos } }
    var value: [TodoItem]? { lock.withLock { todos } }
}
