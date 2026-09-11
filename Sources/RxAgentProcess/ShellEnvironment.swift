#if os(macOS)
import Foundation

/// Resolves the PATH and binaries a GUI-launched process would otherwise miss.
///
/// An app launched from Finder inherits a minimal PATH that typically excludes
/// Homebrew, nvm, and npm-global — exactly where `claude`, `codex`, and `node`
/// live. Everything here exists to bridge that gap.
public actor ShellEnvironment {
    public static let shared = ShellEnvironment()

    private var cachedPath: String?
    private var binaryCache: [String: String] = [:]

    public init() {}

    // MARK: - PATH

    /// A PATH combining, in priority order: the user's interactive login shell
    /// PATH (which captures nvm/asdf init from `.zshrc`), well-known tool
    /// directories, and finally the GUI process's own PATH.
    public func resolvedPath() async -> String {
        if let cachedPath { return cachedPath }

        var entries: [String] = []
        var seen: Set<String> = []
        func add(_ entry: String) {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            entries.append(trimmed)
        }

        if let shellPath = await readLoginShellPath() {
            shellPath.split(separator: ":").forEach { add(String($0)) }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for directory in [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
        ] { add(directory) }

        if let nvmBin = latestNVMBinDirectory(home: home) { add(nvmBin) }

        if let existing = ProcessInfo.processInfo.environment["PATH"] {
            existing.split(separator: ":").forEach { add(String($0)) }
        }

        // Re-check: a reentrant caller may have populated the cache across the await.
        if let cachedPath { return cachedPath }

        let combined = entries.joined(separator: ":")
        cachedPath = combined
        return combined
    }

    /// The full environment for a spawned child: the GUI environment with PATH
    /// replaced, plus any caller-supplied overrides.
    public func environment(overrides: [String: String] = [:]) async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = await resolvedPath()
        for (key, value) in overrides { env[key] = value }
        return env
    }

    /// Populate the PATH cache so the first turn doesn't pay the `/bin/zsh -ilc`
    /// round trip in its critical path. Idempotent.
    public func prewarm() async {
        _ = await resolvedPath()
    }

    /// `-ilc` so the login shell sources `.zshrc` and whatever version manager
    /// it initializes — that's the whole point, since nvm/asdf only put `node`
    /// on PATH from there.
    ///
    /// Bounded at 5s: this runs a user-authored script, and returning a
    /// well-known-directories PATH is far better than never returning at all.
    private func readLoginShellPath() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let output = try? await run(
            shell,
            arguments: ["-ilc", "printf %s \"$PATH\""],
            timeout: .seconds(5)
        ) else { return nil }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // A broken profile can emit noise on stdout before the PATH; only accept
        // something that actually looks like a PATH.
        guard trimmed.contains("/"), !trimmed.contains("\n") else { return nil }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The bin directory of the newest nvm-installed Node, as a backstop for
    /// when the shell readout fails.
    private func latestNVMBinDirectory(home: String) -> String? {
        let root = "\(home)/.nvm/versions/node"
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else { return nil }
        for entry in entries.sorted(by: >) {
            let bin = "\(root)/\(entry)/bin"
            if fileManager.isExecutableFile(atPath: "\(bin)/node") { return bin }
        }
        return nil
    }

    // MARK: - Binary discovery

    /// Locate an executable by name: well-known locations first, then `which`
    /// under the resolved login-shell PATH.
    public func findBinary(named name: String, extraCandidates: [String] = []) async -> String? {
        if let cached = binaryCache[name] { return cached }

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = extraCandidates + [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "\(home)/.npm-global/bin/\(name)",
            "\(home)/.bun/bin/\(name)",
        ]

        for candidate in candidates {
            let resolved = (try? fileManager.destinationOfSymbolicLink(atPath: candidate)) ?? candidate
            let absolute = resolved.hasPrefix("/")
                ? resolved
                : URL(filePath: candidate).deletingLastPathComponent().appending(path: resolved).path
            if fileManager.isExecutableFile(atPath: absolute) {
                binaryCache[name] = candidate
                return candidate
            }
        }

        let path = await resolvedPath()
        if let output = try? await run("/usr/bin/env", arguments: ["which", name], path: path) {
            let found = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !found.isEmpty, fileManager.isExecutableFile(atPath: found) {
                binaryCache[name] = found
                return found
            }
        }

        return nil
    }

    // MARK: - One-shot command

    /// Run a command to completion and return its stdout.
    ///
    /// The work happens on a dispatch queue, not the cooperative pool: reading
    /// to EOF and `waitUntilExit` both block.
    ///
    /// `timeout` is not optional in practice. These commands include an
    /// *interactive login shell*, and a user's `.zshrc` can prompt, hang, or
    /// wait on a network mount. Without a deadline one bad profile wedges every
    /// agent turn forever, which is exactly the failure this guards against.
    @discardableResult
    public func run(
        _ executable: String,
        arguments: [String],
        path: String? = nil,
        workingDirectory: String? = nil,
        timeout: Duration = .seconds(10)
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            ManagedProcess.blockingQueue.async {
                let process = Process()
                process.executableURL = URL(filePath: executable)
                process.arguments = arguments
                if let workingDirectory {
                    process.currentDirectoryURL = URL(filePath: workingDirectory)
                }
                if let path {
                    var env = ProcessInfo.processInfo.environment
                    env["PATH"] = path
                    process.environment = env
                }

                let pipe = Pipe()
                process.standardOutput = pipe
                // Discard stderr: a noisy profile writing warnings must not be
                // mistaken for output, nor fill the pipe.
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Read with a hard deadline rather than `readDataToEndOfFile`.
                //
                // EOF on a pipe requires *every* writer to close. A login shell
                // spawns grandchildren that inherit the write end, so killing
                // the shell is not enough — `readDataToEndOfFile` would block
                // indefinitely even after the child is dead. Polling the
                // descriptor bounds the wait no matter what the child leaves
                // behind.
                let data = Self.readWithDeadline(
                    fd: pipe.fileHandleForReading.fileDescriptor,
                    timeout: timeout
                )

                if process.isRunning {
                    process.terminate()
                    Self.timerQueue.asyncAfter(deadline: .now() + 0.5) { [weak process] in
                        guard let process, process.isRunning else { return }
                        kill(process.processIdentifier, SIGKILL)
                    }
                }

                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    private static let timerQueue = DispatchQueue(label: "rxagent.shell.timeout")

    /// Read a descriptor until EOF or `timeout`, whichever comes first.
    private static func readWithDeadline(fd: Int32, timeout: Duration) -> Data {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeout.components.seconds) * 1_000_000_000

        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return output }
            let remainingMS = Int32((deadline - now) / 1_000_000)

            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, max(remainingMS, 1))
            if ready < 0 {
                if errno == EINTR { continue }
                return output
            }
            if ready == 0 { return output }  // deadline

            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                output.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                return output  // EOF
            } else if errno != EINTR && errno != EAGAIN {
                return output
            }
        }
    }
}
#endif
