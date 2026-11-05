#if os(macOS)
import Foundation
import RxAgentCore
import RxAgentProcess

/// Asks an installed CLI which models it offers.
///
/// Both CLIs answer during their handshake, so no conversation starts and nothing
/// counts against the user's limits. A launch takes seconds, and pickers ask every
/// time they appear, so answers are kept for a few minutes. Failures aren't kept: the
/// next ask may find the user logged in or back online.
enum CLIModelCatalog {
    private static let timeout: Duration = .seconds(30)
    private static let cache = Cache()

    /// `key` identifies everything that can change the answer. `fallback` covers a CLI
    /// that can't answer or lists nothing.
    static func models(
        key: String,
        fallback: [AgentModelOption],
        discover: @escaping @Sendable () async throws -> [AgentModelOption]
    ) async -> [AgentModelOption] {
        let models = await cache.models(for: key) {
            try await withTimeout(discover)
        }
        return models ?? fallback
    }

    /// The operation has to end when cancelled, which both discoveries do.
    private static func withTimeout(
        _ operation: @escaping @Sendable () async throws -> [AgentModelOption]
    ) async throws -> [AgentModelOption] {
        try await withThrowingTaskGroup(of: [AgentModelOption].self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AgentError.timedOut(seconds: Int(timeout.components.seconds))
            }
            defer { group.cancelAll() }
            guard let models = try await group.next() else { throw CancellationError() }
            return models
        }
    }

    private actor Cache {
        private static let lifetime: TimeInterval = 300
        private var entries: [String: (models: [AgentModelOption], date: Date)] = [:]
        private var running: [String: Task<[AgentModelOption]?, Never>] = [:]

        /// Concurrent asks for one key share a single launch.
        func models(
            for key: String,
            discover: @escaping @Sendable () async throws -> [AgentModelOption]
        ) async -> [AgentModelOption]? {
            if let entry = entries[key], Date().timeIntervalSince(entry.date) < Self.lifetime {
                return entry.models
            }
            if let task = running[key] { return await task.value }
            let task = Task<[AgentModelOption]?, Never> {
                guard let models = try? await discover(), !models.isEmpty else { return nil }
                return models
            }
            running[key] = task
            let models = await task.value
            running[key] = nil
            if let models { entries[key] = (models, Date()) }
            return models
        }
    }
}

// MARK: - Claude Code

enum ClaudeModelList {
    private static let requestID = "rxagent-models"

    static func arguments(extraArguments: [String]) -> [String] {
        // The user's MCP servers would only slow the answer down. `--mcp-config` takes
        // every value after it, so nothing can follow it.
        ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
         "--no-session-persistence"]
            + extraArguments
            + ["--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
    }

    static var request: String {
        #"{"type":"control_request","request_id":"\#(requestID)","request":{"subtype":"initialize"}}"#
    }

    /// The models if `line` answers ``request``, otherwise nil.
    static func models(fromLine line: String) -> [AgentModelOption]? {
        guard let message = JSONValue(jsonString: line),
              message["type"]?.stringValue == "control_response",
              let response = message["response"],
              response["request_id"]?.stringValue == requestID else { return nil }
        return (response["response"]?["models"]?.arrayValue ?? []).compactMap { entry in
            // Sending no model is how the CLI's default already gets chosen.
            guard let id = entry["value"]?.stringValue, !id.isEmpty, id != "default" else { return nil }
            return AgentModelOption(
                id: id,
                displayName: entry["displayName"]?.stringValue ?? id,
                modelDescription: entry["description"]?.stringValue
            )
        }
    }

    static func discover(
        binary: String,
        extraArguments: [String],
        environment: [String: String]
    ) async throws -> [AgentModelOption] {
        let process = try ManagedProcess.launch(
            executable: binary,
            arguments: arguments(extraArguments: extraArguments),
            environment: environment,
            workingDirectory: FileManager.default.temporaryDirectory.path
        )
        let lines = process.stdoutLines()
        var models: [AgentModelOption]?
        do {
            try process.write(line: request)
            for await line in lines {
                models = Self.models(fromLine: line)
                if models != nil { break }
            }
        } catch {
            await process.terminate()
            throw error
        }
        await process.terminate()
        guard let models else { throw AgentError.protocolViolation("claude didn't list its models") }
        return models
    }
}

// MARK: - Codex

enum CodexModelList {
    /// Far more than any account has; only here so a misbehaving server can't loop forever.
    private static let maximumPages = 20

    /// One `model/list` page, and the cursor for the next if there is one.
    static func page(fromResult result: JSONValue) -> (models: [AgentModelOption], next: String?) {
        let models = (result["data"]?.arrayValue ?? []).compactMap { entry -> AgentModelOption? in
            guard entry["hidden"]?.boolValue != true,
                  let id = entry["id"]?.stringValue, !id.isEmpty else { return nil }
            return AgentModelOption(
                id: id,
                displayName: entry["displayName"]?.stringValue ?? id,
                modelDescription: entry["description"]?.stringValue
            )
        }
        return (models, result["nextCursor"]?.stringValue)
    }

    static func discover(
        binary: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> [AgentModelOption] {
        let process = try ManagedProcess.launch(
            executable: binary,
            arguments: arguments,
            environment: environment,
            workingDirectory: FileManager.default.temporaryDirectory.path
        )
        let connection = JSONRPCConnection(process: process)
        await connection.start()
        do {
            let models = try await listAll(connection)
            await connection.close()
            await process.terminate()
            return models
        } catch {
            await connection.close()
            await process.terminate()
            throw error
        }
    }

    private static func listAll(_ connection: JSONRPCConnection) async throws -> [AgentModelOption] {
        _ = try await connection.request("initialize", params: .object([
            "clientInfo": .object([
                "name": .string("RxAgentSDK"),
                "title": .string("RxAgentSDK"),
                "version": .string("1.0.0"),
            ]),
            "capabilities": .object([:]),
        ]))
        try await connection.notify("initialized", params: .object([:]))
        var models: [AgentModelOption] = []
        var cursor: String?
        for _ in 0..<maximumPages {
            let params: [String: JSONValue] = cursor.map { ["cursor": .string($0)] } ?? [:]
            let page = page(fromResult: try await connection.request("model/list", params: .object(params)))
            models += page.models
            cursor = page.next
            if cursor == nil { break }
        }
        return models
    }
}
#endif
