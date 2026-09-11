#if os(macOS)
import Foundation
import RxAgentBridge
import RxAgentCore
import RxAgentProcess

// MARK: - Policy

public enum CodexApprovalPolicy: String, Sendable {
    case untrusted
    case onRequest = "on-request"
    case never
}

public enum CodexSandboxMode: String, Sendable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"
}

/// Drives `codex app-server --listen stdio://` over JSON-RPC.
public struct CodexClient: AgentClient {
    public let id: AgentClientID
    public let displayName: String
    public var provider: AgentProvider { .codex }
    public let capabilities: AgentCapabilities

    let binaryPath: String?
    let approvalPolicy: CodexApprovalPolicy
    let sandbox: CodexSandboxMode
    let configOverrides: [String]
    let environmentOverrides: [String: String]

    private let runtime: CodexRuntime

    public init(
        id: AgentClientID = .codex,
        displayName: String = "Codex",
        binaryPath: String? = nil,
        approvalPolicy: CodexApprovalPolicy = .onRequest,
        sandbox: CodexSandboxMode = .workspaceWrite,
        configOverrides: [String] = [],
        environment: [String: String] = [:],
        capabilities: AgentCapabilities = .codexDefaults
    ) {
        self.id = id
        self.displayName = displayName
        self.binaryPath = binaryPath
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
        self.configOverrides = configOverrides
        self.environmentOverrides = environment
        self.capabilities = capabilities
        self.runtime = CodexRuntime()
    }

    public func isAvailable() async -> Bool { await resolveBinary() != nil }

    func resolveBinary() async -> String? {
        if let binaryPath { return binaryPath }
        return await ShellEnvironment.shared.findBinary(named: "codex")
    }

    public func availableModels() async -> [AgentModelOption] {
        [
            AgentModelOption(id: "gpt-5-codex", displayName: "GPT-5 Codex"),
            AgentModelOption(id: "gpt-5", displayName: "GPT-5"),
        ]
    }

    // MARK: - Send

    public func send(_ request: AgentSendRequest) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task { await run(request, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: AgentSendRequest,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async {
        continuation.yield(.turnStarted(turnID: request.turnID))

        guard let binary = await resolveBinary() else {
            continuation.yield(.failed(.binaryNotFound(name: "codex")))
            continuation.finish()
            return
        }

        let mcp = MCPConfigRenderer.codexConfiguration(
            servers: request.mcpServers,
            toolServer: request.toolServer
        )

        var arguments = ["app-server", "--listen", "stdio://"]
        arguments += mcp.overrides
        arguments += configOverrides

        // `mcp.environment` carries the bearer tokens the `-c` overrides name via
        // `bearer_token_env_var`; without merging it in, an authenticated HTTP
        // MCP server gets a config pointing at a variable that does not exist.
        var environment = await ShellEnvironment.shared.environment()
        environment.merge(environmentOverrides) { _, new in new }
        environment.merge(mcp.environment) { _, new in new }
        let process: ManagedProcess
        do {
            process = try ManagedProcess.launch(
                executable: binary,
                arguments: arguments,
                environment: environment,
                workingDirectory: request.workingDirectory.path
            )
        } catch {
            continuation.yield(.failed(.protocolViolation(String(describing: error))))
            continuation.finish()
            return
        }

        await runtime.register(turnID: request.turnID, process: process)
        defer { Task { await runtime.remove(turnID: request.turnID) } }

        let decoder = CodexTurnDecoder(
            turnID: request.turnID,
            continuation: continuation,
            permissions: request.permissions,
            permissionMode: request.permissionMode,
            clientID: id
        )

        let connection = JSONRPCConnection(process: process)
        await connection.start(
            onRequest: { method, params in
                await decoder.handleServerRequest(method: method, params: params)
            },
            onNotification: { method, params in
                await decoder.handleNotification(method: method, params: params)
            }
        )

        do {
            _ = try await connection.request("initialize", params: .object([
                "clientInfo": .object([
                    "name": .string("RxAgentSDK"),
                    "title": .string("RxAgentSDK"),
                    "version": .string("1.0.0"),
                ]),
                "capabilities": .object([:]),
            ]))
            try await connection.notify("initialized", params: .object([:]))

            // Resume the thread this client created earlier, or start a new one.
            let threadID: String
            if let resumeID = request.resumeSessionID {
                let result = try await connection.request("thread/resume", params: .object([
                    "threadId": .string(resumeID),
                    "cwd": .string(request.workingDirectory.path),
                ]))
                threadID = Self.threadID(from: result) ?? resumeID
            } else {
                let result = try await connection.request("thread/start", params: startParams(request))
                threadID = Self.threadID(from: result) ?? UUID().uuidString
            }

            await decoder.recordThreadID(threadID)
            continuation.yield(.sessionStarted(SessionStarted(
                nativeSessionID: threadID,
                model: request.model
            )))

            // `turn/start` returns as soon as the turn is *accepted* — its
            // result carries `status: inProgress`. The turn's content and its
            // completion both arrive later as notifications.
            _ = try await connection.request("turn/start", params: turnParams(request, threadID: threadID))

            // If the child dies mid-turn no completion notification will ever
            // arrive, so a watcher unblocks the wait on process exit.
            //
            // Deliberately not a task group: leaving a group's scope awaits
            // *every* child, and `waitForExit()` doesn't observe cancellation —
            // so a group would keep waiting for a process that is still alive
            // and idle, which is precisely the normal case here.
            let exitWatcher = Task {
                _ = await process.waitForExit()
                await decoder.signalTurnEnd()
            }
            await decoder.waitForTurnEnd()
            exitWatcher.cancel()

            await decoder.finishTurn(threadID: threadID)
        } catch {
            if Task.isCancelled {
                continuation.yield(.failed(.cancelled))
            } else {
                let stderr = await process.collectedStderr()
                continuation.yield(.failed(
                    stderr.isEmpty
                        ? .protocolViolation(String(describing: error))
                        : .processExited(code: -1, stderr: stderr)
                ))
            }
        }

        await connection.close()
        await process.terminate()
        continuation.finish()
    }

    // MARK: - Params

    private func startParams(_ request: AgentSendRequest) -> JSONValue {
        var params: [String: JSONValue] = [
            "cwd": .string(request.workingDirectory.path),
            "approvalPolicy": .string(effectiveApprovalPolicy(request).rawValue),
            "sandbox": .string(effectiveSandbox(request).rawValue),
        ]
        // Codex has no `--append-system-prompt`; context rides on the thread as
        // developer instructions instead.
        var instructions: [String] = []
        if !request.contextText.isEmpty { instructions.append(request.contextText) }
        if request.planMode { instructions.append(Self.planModeInstructions) }
        if !instructions.isEmpty {
            params["developerInstructions"] = .string(instructions.joined(separator: "\n\n"))
        }
        return .object(params)
    }

    private func turnParams(_ request: AgentSendRequest, threadID: String) -> JSONValue {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "cwd": .string(request.workingDirectory.path),
            "input": .array([.object([
                "type": .string("text"),
                "text": .string(composePrompt(request)),
            ])]),
            "approvalPolicy": .string(effectiveApprovalPolicy(request).rawValue),
            "sandboxPolicy": sandboxPolicy(request),
        ]
        if let model = request.model { params["model"] = .string(model) }
        return .object(params)
    }

    /// On a resumed thread the developer instructions were set at `thread/start`,
    /// so context has to travel with the prompt.
    private func composePrompt(_ request: AgentSendRequest) -> String {
        var parts: [String] = []
        if request.resumeSessionID != nil, !request.contextText.isEmpty {
            parts.append(request.contextText)
        }
        parts.append(request.prompt)
        return parts.joined(separator: "\n\n")
    }

    private func effectiveApprovalPolicy(_ request: AgentSendRequest) -> CodexApprovalPolicy {
        if request.planMode { return .onRequest }
        return switch request.permissionMode {
        case .default, .plan: .untrusted
        case .acceptEdits, .auto: .onRequest
        case .bypassPermissions: .never
        }
    }

    private func effectiveSandbox(_ request: AgentSendRequest) -> CodexSandboxMode {
        if request.planMode { return .readOnly }
        return request.permissionMode == .bypassPermissions ? .dangerFullAccess : sandbox
    }

    private func sandboxPolicy(_ request: AgentSendRequest) -> JSONValue {
        switch effectiveSandbox(request) {
        case .readOnly:
            .object(["type": .string("readOnly"), "networkAccess": .bool(false)])
        case .dangerFullAccess:
            .object(["type": .string("dangerFullAccess")])
        case .workspaceWrite:
            .object(["type": .string("workspaceWrite")])
        }
    }

    static let planModeInstructions = """
    Plan mode is enabled. Produce a clear, step-by-step plan using the update_plan tool. \
    Do not modify files; do not run commands that mutate state. Read-only inspection is \
    allowed. End with a concise summary of the proposed plan and wait for the user to \
    disable plan mode before making changes.
    """

    static func threadID(from value: JSONValue) -> String? {
        if let object = value.objectValue {
            for key in ["threadId", "thread_id", "id"] {
                if let id = object[key]?.stringValue { return id }
            }
            if let nested = object["thread"]?.objectValue {
                for key in ["threadId", "thread_id", "id"] {
                    if let id = nested[key]?.stringValue { return id }
                }
            }
        }
        return value.stringValue
    }

    // MARK: - Lifecycle

    public func cancel(turn: UUID) async {
        await runtime.cancel(turnID: turn)
    }

    public func endSession(thread: AgentThreadID) async {}
}

actor CodexRuntime {
    private var processes: [UUID: ManagedProcess] = [:]

    func register(turnID: UUID, process: ManagedProcess) { processes[turnID] = process }
    func remove(turnID: UUID) { processes.removeValue(forKey: turnID) }

    func cancel(turnID: UUID) async {
        guard let process = processes.removeValue(forKey: turnID) else { return }
        await process.interrupt()
    }
}
#endif
