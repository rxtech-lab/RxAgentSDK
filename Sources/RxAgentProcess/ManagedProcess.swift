#if os(macOS)
import Foundation

/// A spawned agent child process: its pipes, its descendant bookkeeping, and
/// its shutdown cascade.
///
/// RxCode duplicated this logic three times — once per backend, each with
/// slightly different signal handling. One implementation, used by all three
/// clients, is the main structural win of the extraction.
public actor ManagedProcess {
    public let pid: pid_t
    /// Session id captured at spawn, while the root is definitely alive.
    /// `getsid` on a reaped pid returns -1, so it cannot be read later.
    public let sid: pid_t

    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle

    private var stderrBuffer = ""
    private var trackedDescendants: Set<pid_t> = []
    private var descendantTracker: Task<Void, Never>?
    private var hasTerminated = false
    private var exitContinuations: [CheckedContinuation<Int32, Never>] = []
    private var exitStatus: Int32?

    // MARK: - Launch

    public static func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) throws -> ManagedProcess {
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        let pid = try ProcessSpawner.spawnInNewSession(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            stdinReadFD: stdin.fileHandleForReading.fileDescriptor,
            stdoutWriteFD: stdout.fileHandleForWriting.fileDescriptor,
            stderrWriteFD: stderr.fileHandleForWriting.fileDescriptor,
            closeInChild: [
                stdin.fileHandleForWriting.fileDescriptor,
                stdout.fileHandleForReading.fileDescriptor,
                stderr.fileHandleForReading.fileDescriptor,
            ]
        )

        // The parent must release the child's ends or EOF never propagates.
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let process = ManagedProcess(
            pid: pid,
            stdinHandle: stdin.fileHandleForWriting,
            stdoutHandle: stdout.fileHandleForReading,
            stderrHandle: stderr.fileHandleForReading
        )
        Task { await process.start() }
        return process
    }

    private init(
        pid: pid_t,
        stdinHandle: FileHandle,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle
    ) {
        self.pid = pid
        self.sid = getsid(pid)
        self.stdinHandle = stdinHandle
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
    }

    private func start() {
        startDescendantTracker()
        startStderrReader()
        startExitWatcher()
    }

    // MARK: - I/O

    /// Lines from the child's stdout. Call once — the underlying handle has a
    /// single readability handler.
    public nonisolated func stdoutLines() -> AsyncStream<String> {
        LineReader.lines(from: stdoutHandle)
    }

    /// Writes are `nonisolated` because `FileHandle` serializes them itself, and
    /// the JSON-RPC layer needs to write from inside a synchronous continuation
    /// body where it cannot await.
    public nonisolated func write(jsonLine object: Any) throws {
        try LineReader.writeJSONLine(object, to: stdinHandle)
    }

    public nonisolated func write(line: String) throws {
        try LineReader.writeLine(line, to: stdinHandle)
    }

    /// Close stdin so a CLI reading `--input-format stream-json` knows the turn
    /// is over and can flush and exit.
    public nonisolated func closeStdin() {
        try? stdinHandle.close()
    }

    public func collectedStderr() -> String {
        stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startStderrReader() {
        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            Task { await self?.appendStderr(text) }
        }
    }

    private func appendStderr(_ text: String) {
        // Bound the buffer: a chatty child shouldn't be able to grow this without limit.
        stderrBuffer += text
        if stderrBuffer.count > 64_000 {
            stderrBuffer = String(stderrBuffer.suffix(32_000))
        }
    }

    // MARK: - Exit

    /// `waitpid` blocks until the child exits, so it must run on a dedicated
    /// thread rather than the cooperative pool. Blocking a pool thread here
    /// starves every other async operation in the process — with several agents
    /// running at once that is a deadlock, not a slowdown.
    private func startExitWatcher() {
        let pid = pid
        Self.blockingQueue.async { [weak self] in
            var status: Int32 = 0
            var result: pid_t = 0
            repeat {
                result = waitpid(pid, &status, 0)
            } while result < 0 && errno == EINTR
            Task { await self?.recordExit(status: status) }
        }
    }

    /// Somewhere to park genuinely blocking POSIX calls.
    static let blockingQueue = DispatchQueue(
        label: "rxagent.process.blocking",
        qos: .utility,
        attributes: .concurrent
    )

    private func recordExit(status: Int32) {
        guard exitStatus == nil else { return }
        let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : status & 0x7F
        exitStatus = code
        for continuation in exitContinuations { continuation.resume(returning: code) }
        exitContinuations.removeAll()
        descendantTracker?.cancel()
        descendantTracker = nil
    }

    /// Await the child's exit code.
    public func waitForExit() async -> Int32 {
        if let exitStatus { return exitStatus }
        return await withCheckedContinuation { continuation in
            exitContinuations.append(continuation)
        }
    }

    public var isRunning: Bool { exitStatus == nil }

    // MARK: - Descendant tracking

    /// Poll for descendants and accumulate them.
    ///
    /// The accumulated set is the safety net for a child that exists as a
    /// findable descendant only briefly before detaching itself with
    /// `setsid`/`setpgid` and getting reparented out of reach. 500 ms is short
    /// enough to catch those transient ppid links and cheap enough (~5 ms per
    /// `ps`) not to register on a CPU graph.
    private func startDescendantTracker() {
        let root = pid
        let sid = sid
        descendantTracker = Task.detached { [weak self] in
            while !Task.isCancelled {
                // `descendantPIDs` shells out to `ps` and waits for it, so it
                // runs off the cooperative pool.
                let pids = await ProcessSpawner.descendantPIDsAsync(of: root, sid: sid)
                if !pids.isEmpty {
                    await self?.mergeDescendants(pids)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func mergeDescendants(_ pids: [pid_t]) {
        trackedDescendants.formUnion(pids)
    }

    /// Live descendants: everything ever seen, plus a fresh snapshot.
    private func allKnownDescendants() -> [pid_t] {
        var union = trackedDescendants
        union.formUnion(ProcessSpawner.descendantPIDs(of: pid, sid: sid))
        return ProcessSpawner.liveOnly(union)
    }

    // MARK: - Shutdown

    /// User-initiated stop: SIGINT the group, then SIGKILL anything left after
    /// the grace period.
    public func interrupt(graceSeconds: Double = 5.0) {
        signalAndEscalate(first: SIGINT, graceSeconds: graceSeconds)
    }

    /// Turn-finished sweep: SIGTERM, then SIGKILL. Guarantees no subagent
    /// outlives the parent CLI.
    public func terminate(graceSeconds: Double = 1.5) {
        signalAndEscalate(first: SIGTERM, graceSeconds: graceSeconds)
    }

    private func signalAndEscalate(first: Int32, graceSeconds: Double) {
        guard !hasTerminated else { return }
        hasTerminated = true

        ProcessSpawner.signal(first, pgid: pid, escapees: allKnownDescendants())

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(graceSeconds))
            guard let self else { return }
            // Re-snapshot: this catches anything that appeared during the grace
            // window, and by now the root may be reaped — the accumulated set is
            // the only way to reach session-escaped, reparented children.
            let remaining = await self.allKnownDescendants()
            ProcessSpawner.signal(SIGKILL, pgid: self.pid, escapees: remaining)
            await self.cleanUpHandles()
        }
    }

    private func cleanUpHandles() {
        descendantTracker?.cancel()
        descendantTracker = nil
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        try? stdinHandle.close()
    }
}
#endif
