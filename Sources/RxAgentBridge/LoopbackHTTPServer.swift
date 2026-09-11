#if os(macOS)
import Foundation

/// A minimal HTTP/1.1 server bound to 127.0.0.1.
///
/// Built on POSIX sockets rather than Network.framework. The requirements are
/// small and unusual — loopback only, a few routes, and the ability to hold a
/// connection open indefinitely while a human decides whether to approve a tool
/// call (Claude's PreToolUse hook blocks on that response for up to 300s).
/// Plain sockets also avoid Network.framework's entitlement requirements, which
/// makes this work identically in a signed app, in `swift test`, and in CI.
public actor LoopbackHTTPServer {

    public struct Request: Sendable {
        public let method: String
        public let path: String
        public let headers: [String: String]
        public let body: Data

        public var bodyString: String { String(decoding: body, as: UTF8.self) }
    }

    public struct Response: Sendable {
        public var status: Int
        public var contentType: String
        public var body: Data

        public init(status: Int = 200, contentType: String = "application/json", body: Data = Data()) {
            self.status = status
            self.contentType = contentType
            self.body = body
        }

        public static func json(_ object: Any, status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            return Response(status: status, contentType: "application/json", body: data)
        }

        public static func json(string: String, status: Int = 200) -> Response {
            Response(status: status, contentType: "application/json", body: Data(string.utf8))
        }

        public static let notFound = Response(
            status: 404, contentType: "text/plain", body: Data("not found".utf8)
        )
        public static let noContent = Response(status: 204, contentType: "text/plain")
    }

    public typealias Handler = @Sendable (Request) async -> Response

    public private(set) var port: UInt16?

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(
        label: "rxagent.http", qos: .userInitiated, attributes: .concurrent
    )

    public init() {}

    // MARK: - Lifecycle

    /// Bind the first free port in `range`.
    public func start(portRange: ClosedRange<UInt16>, handler: @escaping Handler) throws {
        guard listenFD < 0 else { return }

        for candidate in portRange {
            guard let fd = Self.bind(port: candidate) else { continue }
            listenFD = fd
            port = candidate

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [queue] in
                var address = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let connectionFD = withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(fd, $0, &length)
                    }
                }
                guard connectionFD >= 0 else { return }
                queue.async { Self.serve(connectionFD: connectionFD, handler: handler) }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            acceptSource = source
            return
        }

        throw AgentBridgeError.couldNotBind(portRange)
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        port = nil
    }

    private static func bind(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        // Otherwise a client vanishing mid-write raises SIGPIPE and kills the host app.
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 32) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    // MARK: - Connection handling

    /// Reads happen on a concurrent dispatch queue; only the handler runs in a
    /// Task, because it can block for as long as a human takes to decide and
    /// must not occupy a dispatch thread while it waits.
    private static func serve(connectionFD: Int32, handler: @escaping Handler) {
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(connectionFD, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(connectionFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                   socklen_t(MemoryLayout<Int32>.size))

        guard let request = readRequest(from: connectionFD) else {
            close(connectionFD)
            return
        }

        Task {
            let response = await handler(request)
            write(response, to: connectionFD)
            close(connectionFD)
        }
    }

    private static func readRequest(from fd: Int32) -> Request? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 {
                return buffer.isEmpty ? nil : parse(buffer)
            }
            buffer.append(contentsOf: chunk[0..<count])

            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { continue }
            guard let request = parse(buffer) else { return nil }

            let expected = request.headers["content-length"].flatMap(Int.init) ?? 0
            if buffer.count - headerEnd.upperBound >= expected { return request }
        }
    }

    private static func parse(_ raw: Data) -> Request? {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: raw[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        return Request(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(raw[headerEnd.upperBound...])
        )
    }

    private static func write(_ response: Response, to fd: Int32) {
        var head = "HTTP/1.1 \(response.status) \(statusText(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(response.body)

        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Foundation.write(fd, base + offset, raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        default: "Status"
        }
    }
}

public enum AgentBridgeError: Error, CustomStringConvertible {
    case couldNotBind(ClosedRange<UInt16>)

    public var description: String {
        switch self {
        case .couldNotBind(let range):
            "Could not bind a loopback port in \(range.lowerBound)–\(range.upperBound)."
        }
    }
}
#endif
