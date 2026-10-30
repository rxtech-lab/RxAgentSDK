import Foundation
import RxAgentCore
#if os(macOS)
import RxAgentProcess
#endif

/// The result of a foreground shell command.
public struct HarnessShellResult: Sendable, Hashable {
    public var output: String
    public var exitCode: Int32?
    public var timedOut: Bool
    public var cancelled: Bool
    /// Set when `output` is a shortened preview; the full text is at this path.
    public var fullOutputPath: String?
}

/// A command left running in the background.
public struct HarnessBackgroundShell: Sendable, Hashable, Identifiable {
    public let id: String
    public let command: String
    public let workingDirectory: String
    public let startedAt: Date
    public var exitCode: Int32?
    public var isRunning: Bool { exitCode == nil }
    /// Where the combined output is being written.
    public let logPath: String
}

/// Owns every shell process a session starts.
///
/// One per session, so background jobs outlive the turn that started them —
/// a dev server keeps running while the user asks the next question — and are
/// all killed together when the session ends.
public actor HarnessTerminalManager {
    /// Characters of output handed back to the model before the rest is cut
    /// to a file. opencode's limit.
    public static let maxOutputCharacters = 30_000

    public let shellPath: String
    public let environmentOverrides: [String: String]

    private var background: [String: BackgroundJob] = [:]
    private var pendingNotifications: [String] = []
    private var nextID = 1

    public init(shellPath: String = "/bin/zsh", environment: [String: String] = [:]) {
        self.shellPath = shellPath
        self.environmentOverrides = environment
    }

    public static var isSupported: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    // MARK: Foreground

    /// Runs `command` to completion, streaming output through `onOutput` as it
    /// arrives. Cancelling the calling task terminates the process.
    public func run(
        _ command: String,
        workingDirectory: URL,
        timeout: TimeInterval?,
        onOutput: @escaping @Sendable (String, HarnessToolEvent.OutputStream) async -> Void
    ) async throws -> HarnessShellResult {
        #if os(macOS)
        let process = try await makeProcess(command, workingDirectory: workingDirectory)
        let collector = OutputCollector()
        let chunks = Self.attachPipes(to: process)

        try process.run()
        let timedOut = OneShot()
        let timer: Task<Void, Never>? = timeout.flatMap { $0 > 0 ? $0 : nil }.map { seconds in
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, process.isRunning else { return }
                timedOut.set()
                Self.terminate(process)
            }
        }

        let cancelled = OneShot()
        await withTaskCancellationHandler {
            for await (text, stream) in chunks {
                collector.append(text)
                await onOutput(text, stream)
            }
        } onCancel: {
            cancelled.set()
            Self.terminate(process)
        }
        process.waitUntilExit()
        timer?.cancel()

        var output = collector.text
        var fullPath: String?
        if output.count > Self.maxOutputCharacters {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "rxagent-shell-\(UUID().uuidString.prefix(8)).log")
            try? Data(output.utf8).write(to: url)
            fullPath = url.path
            output = Self.preview(output)
        }
        return HarnessShellResult(
            output: output,
            exitCode: process.terminationReason == .exit ? process.terminationStatus : nil,
            timedOut: timedOut.isSet,
            cancelled: cancelled.isSet,
            fullOutputPath: fullPath
        )
        #else
        throw HarnessToolError("Shell commands are only available on macOS.")
        #endif
    }

    // MARK: Background

    /// Starts `command` and returns at once. `onExit` fires when it finishes.
    public func startBackground(
        _ command: String,
        workingDirectory: URL,
        onExit: @escaping @Sendable (HarnessBackgroundShell) async -> Void = { _ in }
    ) async throws -> HarnessBackgroundShell {
        #if os(macOS)
        let id = "shell_\(nextID)"
        nextID += 1
        let logURL = FileManager.default.temporaryDirectory.appending(path: "rxagent-\(id)-\(UUID().uuidString.prefix(6)).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let process = try await makeProcess(command, workingDirectory: workingDirectory)
        let chunks = Self.attachPipes(to: process)
        let collector = OutputCollector()
        let shell = HarnessBackgroundShell(
            id: id, command: command, workingDirectory: workingDirectory.path,
            startedAt: Date(), exitCode: nil, logPath: logURL.path
        )
        try process.run()

        let pump = Task { [weak self] in
            let handle = try? FileHandle(forWritingTo: logURL)
            for await (text, _) in chunks {
                collector.append(text)
                try? handle?.write(contentsOf: Data(text.utf8))
            }
            try? handle?.close()
            process.waitUntilExit()
            let code = process.terminationStatus
            if let finished = await self?.markFinished(id: id, exitCode: code) {
                await onExit(finished)
            }
        }
        background[id] = BackgroundJob(shell: shell, process: process, collector: collector, pump: pump)
        return shell
        #else
        throw HarnessToolError("Shell commands are only available on macOS.")
        #endif
    }

    /// Output a background job has written since the last read (or all of it).
    public func output(of id: String, sinceLastRead: Bool = true) -> (HarnessBackgroundShell, String)? {
        guard var job = background[id] else { return nil }
        let text = job.collector.text
        let start = sinceLastRead ? min(job.readOffset, text.count) : 0
        let slice = String(text.dropFirst(start))
        job.readOffset = text.count
        background[id] = job
        return (job.shell, slice.count > Self.maxOutputCharacters ? Self.preview(slice) : slice)
    }

    public func kill(_ id: String) -> Bool {
        guard let job = background[id], job.shell.isRunning else { return false }
        #if os(macOS)
        Self.terminate(job.process)
        #endif
        return true
    }

    public func backgroundShells() -> [HarnessBackgroundShell] {
        background.values.map(\.shell).sorted { $0.startedAt < $1.startedAt }
    }

    /// Ids of background jobs that finished since the last call. The harness
    /// turns these into a reminder for the model at its next step.
    public func drainFinishedNotifications() -> [HarnessBackgroundShell] {
        defer { pendingNotifications.removeAll() }
        return pendingNotifications.compactMap { background[$0]?.shell }
    }

    /// Kills everything. Called when the session is released.
    public func shutdown() {
        #if os(macOS)
        for job in background.values where job.shell.isRunning { Self.terminate(job.process) }
        #endif
    }

    private func markFinished(id: String, exitCode: Int32) -> HarnessBackgroundShell? {
        guard var job = background[id] else { return nil }
        job.shell.exitCode = exitCode
        background[id] = job
        pendingNotifications.append(id)
        return job.shell
    }

    static func preview(_ text: String) -> String {
        let head = text.prefix(maxOutputCharacters / 3)
        let tail = text.suffix(maxOutputCharacters * 2 / 3)
        let omitted = text.count - head.count - tail.count
        return head + "\n\n… \(omitted) characters omitted …\n\n" + tail
    }

    // MARK: Process plumbing

    private struct BackgroundJob {
        var shell: HarnessBackgroundShell
        #if os(macOS)
        let process: Process
        #endif
        let collector: OutputCollector
        let pump: Task<Void, Never>
        var readOffset = 0
    }

    #if os(macOS)

    private func makeProcess(_ command: String, workingDirectory: URL) async throws -> Process {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw HarnessToolError("Working directory does not exist: \(workingDirectory.path)")
        }
        let process = Process()
        process.executableURL = URL(filePath: shellPath)
        process.arguments = ["-c", command]
        process.currentDirectoryURL = workingDirectory
        var environment = await ShellEnvironment.shared.environment(overrides: environmentOverrides)
        // Keep interactive tools from waiting on a pager or a prompt nobody sees.
        environment["PAGER"] = "cat"
        environment["GIT_PAGER"] = "cat"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        return process
    }

    /// Wires stdout/stderr into one stream of decoded text. The stream ends
    /// when both pipes reach EOF.
    private static func attachPipes(to process: Process) -> AsyncStream<(String, HarnessToolEvent.OutputStream)> {
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let (stream, continuation) = AsyncStream<(String, HarnessToolEvent.OutputStream)>.makeStream()
        let open = EOFCounter(count: 2) { continuation.finish() }
        for (pipe, kind) in [(stdout, HarnessToolEvent.OutputStream.stdout), (stderr, .stderr)] {
            let decoder = UTF8ChunkDecoder()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if let rest = decoder.flush() { continuation.yield((rest, kind)) }
                    open.close()
                } else if let text = decoder.decode(data) {
                    continuation.yield((text, kind))
                }
            }
        }
        return stream
    }

    /// Ends the shell and, best effort, the processes it started.
    static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let pkill = Process()
        pkill.executableURL = URL(filePath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", String(pid)]
        try? pkill.run()
        pkill.waitUntilExit()
        process.terminate()
    }
    #endif
}

// MARK: - Small synchronization helpers

/// Thread-safe text accumulator for pipe callbacks.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    func append(_ text: String) { lock.withLock { storage += text } }
    var text: String { lock.withLock { storage } }
}

final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

final class EOFCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private let onZero: @Sendable () -> Void
    init(count: Int, onZero: @escaping @Sendable () -> Void) {
        self.remaining = count
        self.onZero = onZero
    }
    func close() {
        let done = lock.withLock { () -> Bool in
            remaining -= 1
            return remaining == 0
        }
        if done { onZero() }
    }
}

/// Decodes UTF-8 across chunk boundaries: a multi-byte character split
/// between two reads is held until its remaining bytes arrive.
final class UTF8ChunkDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func decode(_ data: Data) -> String? {
        lock.withLock {
            pending.append(data)
            for trim in 0...min(3, pending.count) {
                let candidate = pending.prefix(pending.count - trim)
                if let text = String(data: candidate, encoding: .utf8) {
                    pending = Data(pending.suffix(trim))
                    return text.isEmpty ? nil : text
                }
            }
            // Not UTF-8 at all; fall back to a lossy decode rather than stall.
            let text = String(decoding: pending, as: UTF8.self)
            pending.removeAll()
            return text
        }
    }

    func flush() -> String? {
        lock.withLock {
            defer { pending.removeAll() }
            return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
        }
    }
}
