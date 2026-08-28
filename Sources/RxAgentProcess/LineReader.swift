#if os(macOS)
import Foundation

public enum LineReader {
    /// Stream newline-delimited lines from a file handle.
    ///
    /// Deliberately *not* `FileHandle.AsyncBytes.lines`. That iterator wedges
    /// when a second concurrent pipe reader is active — the case where one agent
    /// is mid-tool-call while another turn starts — leaving the second process's
    /// output sitting in the pipe, never waking the `for await`. Dispatch's
    /// readability source delivers each chunk on a per-handle queue that shares
    /// no global async state, so concurrent readers don't interfere.
    ///
    /// This is load-bearing, not a style preference. Do not "modernize" it.
    public static func lines(from handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            // `buffer` is touched only from the readabilityHandler, which Dispatch
            // serializes onto one internal queue per FileHandle — no lock needed.
            nonisolated(unsafe) var buffer = Data()

            handle.readabilityHandler = { fileHandle in
                let chunk = fileHandle.availableData
                if chunk.isEmpty {
                    // EOF. Flush a trailing line that had no terminator.
                    if !buffer.isEmpty, let trailing = String(data: buffer, encoding: .utf8) {
                        continuation.yield(trailing)
                        buffer.removeAll(keepingCapacity: false)
                    }
                    fileHandle.readabilityHandler = nil
                    continuation.finish()
                    return
                }

                buffer.append(chunk)
                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<newlineIndex]
                    buffer.removeSubrange(buffer.startIndex...newlineIndex)
                    if let line = String(data: lineData, encoding: .utf8) {
                        continuation.yield(line)
                    }
                }
            }

            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }

    /// Serialize a JSON value and write it as one NDJSON line.
    ///
    /// Uses the throwing `write(contentsOf:)` rather than the legacy `write(_:)`:
    /// the latter raises an Objective-C `NSFileHandleOperationException` on a
    /// broken pipe (the child died before we wrote), which Swift cannot catch
    /// and which would take down the host app instead of surfacing an error.
    public static func writeJSONLine(_ object: Any, to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    public static func writeLine(_ line: String, to handle: FileHandle) throws {
        guard let data = line.data(using: .utf8) else { return }
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }
}
#endif
