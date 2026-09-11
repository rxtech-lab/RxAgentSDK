#if os(macOS)
import Foundation
import RxAgentCore

/// A JSON-RPC 2.0 peer speaking NDJSON over a child process's stdio.
///
/// Both the Codex app-server and every ACP agent use exactly this framing;
/// RxCode implemented it twice, in `CodexAppServer+Protocol.swift` and
/// `ACPService+Protocol.swift`. One implementation, two clients.
///
/// Full duplex: the connection issues requests *and* serves them, since both
/// protocols have the agent call back into the client (ACP for
/// `fs/read_text_file` and `session/request_permission`, Codex for approvals).
public actor JSONRPCConnection {
    public typealias RequestHandler = @Sendable (String, JSONValue) async -> Result<JSONValue, JSONRPCError>
    public typealias NotificationHandler = @Sendable (String, JSONValue) async -> Void

    public struct JSONRPCError: Error, Sendable {
        public let code: Int
        public let message: String
        public let data: JSONValue?

        public init(code: Int, message: String, data: JSONValue? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }

        public static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
        public static func internalError(_ message: String) -> JSONRPCError {
            JSONRPCError(code: -32603, message: message)
        }
    }

    private let process: ManagedProcess
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var isClosed = false

    private var requestHandler: RequestHandler?
    private var notificationHandler: NotificationHandler?

    public init(process: ManagedProcess) {
        self.process = process
    }

    /// Begin reading. Handlers serve inbound calls from the agent.
    public func start(
        onRequest: RequestHandler? = nil,
        onNotification: NotificationHandler? = nil
    ) {
        requestHandler = onRequest
        notificationHandler = onNotification

        let lines = process.stdoutLines()
        readerTask = Task { [weak self] in
            for await line in lines {
                guard let self, !Task.isCancelled else { break }
                await self.handle(line: line)
            }
            await self?.finishPendingWithDisconnect()
        }
    }

    // MARK: - Outbound

    /// Issue a request and await its result.
    @discardableResult
    public func request(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
        guard !isClosed else { throw AgentError.protocolViolation("connection closed") }

        let id = nextID
        nextID += 1

        var payload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
        ]
        if let params { payload["params"] = params }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try process.write(jsonLine: JSONValue.object(payload).anyValue)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    public func notify(_ method: String, params: JSONValue? = nil) throws {
        guard !isClosed else { return }
        var payload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { payload["params"] = params }
        try process.write(jsonLine: JSONValue.object(payload).anyValue)
    }

    // MARK: - Inbound

    private func handle(line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let message = JSONValue(jsonString: trimmed) else { return }

        let id = message["id"]
        let method = message["method"]?.stringValue

        switch (method, id) {
        case (.some(let method), .some(let id)) where !id.isNull:
            // Agent -> client request; must be answered.
            await serve(method: method, id: id, params: message["params"] ?? .object([:]))

        case (.some(let method), _):
            // Notification.
            await notificationHandler?(method, message["params"] ?? .object([:]))

        case (nil, .some(let id)):
            // Response to one of ours.
            deliver(response: message, id: id)

        default:
            break
        }
    }

    private func serve(method: String, id: JSONValue, params: JSONValue) async {
        let outcome: Result<JSONValue, JSONRPCError>
        if let requestHandler {
            outcome = await requestHandler(method, params)
        } else {
            outcome = .failure(.methodNotFound)
        }

        var response: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": id]
        switch outcome {
        case .success(let value):
            response["result"] = value
        case .failure(let error):
            var errorObject: [String: JSONValue] = [
                "code": .number(Double(error.code)),
                "message": .string(error.message),
            ]
            if let data = error.data { errorObject["data"] = data }
            response["error"] = .object(errorObject)
        }
        try? process.write(jsonLine: JSONValue.object(response).anyValue)
    }

    private func deliver(response: JSONValue, id: JSONValue) {
        guard let numericID = id.intValue, let continuation = pending.removeValue(forKey: numericID) else {
            return
        }
        if let error = response["error"] {
            let message = error["message"]?.stringValue ?? "unknown JSON-RPC error"
            let code = error["code"]?.intValue ?? -32603
            continuation.resume(throwing: JSONRPCError(code: code, message: message, data: error["data"]))
        } else {
            continuation.resume(returning: response["result"] ?? .null)
        }
    }

    /// Fail every in-flight request when the child's stdout closes, so callers
    /// don't hang forever on a dead process.
    private func finishPendingWithDisconnect() {
        let stderr = ""
        for (_, continuation) in pending {
            continuation.resume(throwing: AgentError.processExited(code: -1, stderr: stderr))
        }
        pending.removeAll()
    }

    public func close() {
        isClosed = true
        readerTask?.cancel()
        readerTask = nil
        finishPendingWithDisconnect()
    }
}
#endif
