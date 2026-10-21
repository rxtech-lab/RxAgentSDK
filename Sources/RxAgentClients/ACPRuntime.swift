#if os(macOS)
import Foundation
import RxAgentBridge
import RxAgentCore
import RxAgentProcess

/// A live ACP agent process plus the session established on it.
struct ACPSession: Sendable {
    let process: ManagedProcess
    let connection: JSONRPCConnection
    let decoder: ACPUpdateDecoder
    let agentSessionID: String
    /// True when this turn created the session, so context still needs sending.
    let isNew: Bool
}

/// Pools one agent process per thread.
///
/// ACP conversations live *inside* the agent process — `session/prompt` sends
/// no history — so the process must outlive a single turn. Everything else in
/// this SDK spawns per turn; this is the deliberate exception.
actor ACPRuntime {
    private struct Entry {
        let process: ManagedProcess
        let connection: JSONRPCConnection
        let decoder: ACPUpdateDecoder
        let agentSessionID: String
        var supportsHTTPMCP: Bool
        var modelSelection: ACPModelSelection?
        let defaultModel: String?
        var activeModel: String?
    }

    private var entries: [AgentThreadID: Entry] = [:]
    private var turnThreads: [UUID: AgentThreadID] = [:]

    // MARK: - Session acquisition

    func session(
        for request: AgentSendRequest,
        client: ACPClient,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async throws -> ACPSession {
        turnThreads[request.turnID] = request.threadID

        // Reuse the pooled process when it's still alive.
        if var existing = entries[request.threadID], await existing.process.isRunning {
            try await applyModel(request.model, to: &existing)
            entries[request.threadID] = existing
            return ACPSession(
                process: existing.process,
                connection: existing.connection,
                decoder: existing.decoder,
                agentSessionID: existing.agentSessionID,
                isNew: false
            )
        }
        entries.removeValue(forKey: request.threadID)

        let (executable, baseArguments) = client.resolvedLaunch()
        var overrides = client.environmentOverrides
        if let variable = client.modelEnvVar, let model = request.model {
            overrides[variable] = model
        }
        if let variable = client.effortEnvVar, let effort = request.effort {
            overrides[variable] = effort
        }
        let environment = await ShellEnvironment.shared.environment(overrides: overrides)

        let process = try ManagedProcess.launch(
            executable: executable,
            arguments: baseArguments,
            environment: environment,
            workingDirectory: request.workingDirectory.path
        )

        let decoder = ACPUpdateDecoder(clientID: client.id)
        let connection = JSONRPCConnection(process: process)
        await connection.start(
            onRequest: { method, params in
                await decoder.handleServerRequest(method: method, params: params)
            },
            onNotification: { method, params in
                await decoder.handleNotification(method: method, params: params)
            }
        )

        // 1. initialize — advertise the filesystem capability so the agent can
        //    ask us to read and write files on its behalf.
        let initResult: JSONValue
        do {
            initResult = try await connection.request("initialize", params: .object([
                "protocolVersion": .number(1),
                "clientCapabilities": .object([
                    "fs": .object([
                        "readTextFile": .bool(true),
                        "writeTextFile": .bool(true),
                    ]),
                ]),
            ]))
        } catch {
            let stderr = await process.collectedStderr()
            await connection.close()
            await process.terminate()
            throw stderr.isEmpty
                ? AgentError.protocolViolation("initialize failed: \(error)")
                : AgentError.processExited(code: -1, stderr: stderr)
        }

        let supportsHTTP = Self.supports(transport: "http", in: initResult)
        let supportsSSE = Self.supports(transport: "sse", in: initResult)

        do {
            // 2. session/new
            let mcpServers = MCPConfigRenderer.acpServers(
                servers: request.mcpServers,
                toolServer: request.toolServer,
                supportsHTTP: supportsHTTP,
                supportsSSE: supportsSSE
            )
            let newResult = try await connection.request("session/new", params: .object([
                "cwd": .string(request.workingDirectory.path),
                "mcpServers": .array(mcpServers),
            ]))

            guard let agentSessionID = newResult["sessionId"]?.stringValue else {
                await connection.close()
                await process.terminate()
                throw AgentError.protocolViolation("session/new returned no sessionId")
            }

            if let models = Self.modelOptions(from: newResult), !models.isEmpty {
                continuation.yield(.modelsDiscovered(models))
            }

            let selection = ACPModelSelection.parse(newResult)
            var entry = Entry(
                process: process,
                connection: connection,
                decoder: decoder,
                agentSessionID: agentSessionID,
                supportsHTTPMCP: supportsHTTP,
                modelSelection: selection,
                defaultModel: selection?.currentModel,
                activeModel: selection?.currentModel ?? (client.modelEnvVar == nil ? nil : request.model)
            )
            try await applyModel(request.model, to: &entry)
            entries[request.threadID] = entry

            return ACPSession(
                process: process,
                connection: connection,
                decoder: decoder,
                agentSessionID: agentSessionID,
                isNew: true
            )
        } catch {
            await connection.close()
            await process.terminate()
            throw error
        }
    }

    private func applyModel(_ requested: String?, to entry: inout Entry) async throws {
        let explicit = requested.flatMap { $0.isEmpty ? nil : $0 }
        let target = explicit ?? entry.defaultModel
        guard target != entry.activeModel else { return }
        guard let target, let selection = entry.modelSelection else {
            throw AgentError.protocolViolation("This ACP client did not advertise support for changing models.")
        }
        guard selection.options.contains(where: { $0.id == target }) else {
            throw AgentError.protocolViolation("The ACP client does not offer model '\(target)'. Refresh its model list.")
        }
        var params: [String: JSONValue] = ["sessionId": .string(entry.agentSessionID)]
        let method: String
        if let configID = selection.configID {
            method = "session/set_config_option"
            params["configId"] = .string(configID)
            params["value"] = .string(target)
        } else {
            method = "session/set_model"
            params["modelId"] = .string(target)
        }
        let result = try await entry.connection.request(method, params: .object(params))
        if let updated = ACPModelSelection.parse(result) {
            guard updated.currentModel == nil || updated.currentModel == target else {
                throw AgentError.protocolViolation("The ACP client did not accept model '\(target)'.")
            }
            entry.modelSelection = updated
        }
        entry.activeModel = target
    }

    // MARK: - Lifecycle

    func cancel(turnID: UUID) async {
        guard let threadID = turnThreads.removeValue(forKey: turnID),
              let entry = entries[threadID]
        else { return }
        // Cancel the turn but keep the process — the conversation lives in it.
        try? await entry.connection.notify("session/cancel", params: .object([
            "sessionId": .string(entry.agentSessionID),
        ]))
    }

    func end(threadID: AgentThreadID) async {
        guard let entry = entries.removeValue(forKey: threadID) else { return }
        await entry.connection.close()
        await entry.process.terminate()
    }

    func endAll() async {
        for threadID in entries.keys { await end(threadID: threadID) }
    }

    // MARK: - Capability parsing

    /// Only offer a transport the agent said it supports; stdio is universal
    /// and always allowed.
    static func supports(transport: String, in initResult: JSONValue) -> Bool {
        initResult["agentCapabilities"]?["mcpCapabilities"]?[transport]?.boolValue ?? false
    }

    static func modelOptions(from result: JSONValue) -> [AgentModelOption]? {
        ACPModelSelection.parse(result)?.options
    }
}

/// ACP's current config-option selector and the older models selector.
struct ACPModelSelection: Sendable {
    let configID: String?
    let currentModel: String?
    let options: [AgentModelOption]

    static func parse(_ result: JSONValue) -> Self? {
        for config in result["configOptions"]?.arrayValue ?? [] {
            guard config["category"]?.stringValue == "model",
                  config["type"]?.stringValue == "select",
                  let id = config["id"]?.stringValue else { continue }
            let options = (config["options"]?.arrayValue ?? []).flatMap { entry in
                (entry["options"]?.arrayValue ?? [entry]).compactMap { value -> AgentModelOption? in
                    guard let id = value["value"]?.stringValue, !id.isEmpty else { return nil }
                    return AgentModelOption(id: id, displayName: value["name"]?.stringValue ?? id,
                        modelDescription: value["description"]?.stringValue)
                }
            }
            return Self(configID: id, currentModel: config["currentValue"]?.stringValue, options: unique(options))
        }
        guard let models = result["models"], let available = models["availableModels"]?.arrayValue else { return nil }
        let options = available.compactMap { value -> AgentModelOption? in
            guard let id = value["modelId"]?.stringValue, !id.isEmpty else { return nil }
            return AgentModelOption(id: id, displayName: value["name"]?.stringValue ?? id,
                modelDescription: value["description"]?.stringValue)
        }
        return Self(configID: nil, currentModel: models["currentModelId"]?.stringValue, options: unique(options))
    }

    private static func unique(_ options: [AgentModelOption]) -> [AgentModelOption] {
        var seen = Set<String>()
        return options.filter { seen.insert($0.id).inserted }
    }
}
#endif
