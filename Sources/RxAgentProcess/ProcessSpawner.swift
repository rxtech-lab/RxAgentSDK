#if os(macOS)
import Foundation

public enum ProcessSpawnError: Error, CustomStringConvertible {
    case spawnFailed(String)

    public var description: String {
        switch self {
        case .spawnFailed(let detail): "Failed to spawn process: \(detail)"
        }
    }
}

public enum ProcessSpawner {

    /// Spawn `executable` as the leader of a brand-new session.
    ///
    /// Foundation's `Process` exposes no `posix_spawnattr_t`, so this drops to
    /// the raw POSIX API. `POSIX_SPAWN_SETSID` makes the child a session leader,
    /// giving `sid == pgid == pid`. That matters for cleanup: a session id
    /// survives reparenting, so a subagent orphaned to launchd when its
    /// intermediate parent dies is still findable via `getsid`. Plain
    /// `SETPGROUP` would not survive that.
    ///
    /// Returns the child pid, which is also its pgid.
    public static func spawnInNewSession(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        stdinReadFD: Int32,
        stdoutWriteFD: Int32,
        stderrWriteFD: Int32,
        closeInChild: [Int32] = []
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw ProcessSpawnError.spawnFailed("posix_spawn_file_actions_init failed")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        _ = posix_spawn_file_actions_adddup2(&fileActions, stdinReadFD, 0)
        _ = posix_spawn_file_actions_adddup2(&fileActions, stdoutWriteFD, 1)
        _ = posix_spawn_file_actions_adddup2(&fileActions, stderrWriteFD, 2)

        // `posix_spawn` inherits every descriptor that isn't marked CLOEXEC, so
        // without this the child also holds the *parent's* ends of the pipes.
        // A child holding its own stdin's write end never sees EOF when the
        // parent closes — it waits for input forever. Closing them explicitly is
        // what makes `closeStdin()` actually mean end-of-input.
        for fd in closeInChild where fd > 2 {
            _ = posix_spawn_file_actions_addclose(&fileActions, fd)
        }

        let chdirResult = workingDirectory.withCString { path in
            posix_spawn_file_actions_addchdir(&fileActions, path)
        }
        guard chdirResult == 0 else {
            throw ProcessSpawnError.spawnFailed(
                "posix_spawn_file_actions_addchdir failed (\(chdirResult)) for \(workingDirectory)"
            )
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw ProcessSpawnError.spawnFailed("posix_spawnattr_init failed")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        _ = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { if let pointer = $0 { free(pointer) } } }

        let envEntries: [String] = environment.map { "\($0.key)=\($0.value)" }
        var envp: [UnsafeMutablePointer<CChar>?] = envEntries.map { strdup($0) }
        envp.append(nil)
        defer { envp.forEach { if let pointer = $0 { free(pointer) } } }

        var pid: pid_t = 0
        let result = executable.withCString { path in
            posix_spawn(&pid, path, &fileActions, &attributes, argv, envp)
        }
        guard result == 0 else {
            throw ProcessSpawnError.spawnFailed(
                "posix_spawn failed: \(String(cString: strerror(result))) (\(result))"
            )
        }
        return pid
    }

    // MARK: - Descendant discovery

    /// Every descendant of `root`, excluding `root` itself.
    ///
    /// Two strategies, because neither alone is sufficient:
    ///
    /// 1. **Parent walk** — BFS over `ps -Ao pid,ppid`. Finds anything still
    ///    reachable through ppid links, but breaks the moment an intermediate
    ///    parent dies and its children are reparented to launchd.
    /// 2. **Session match** — compare each pid's `getsid` to `sid`. Survives
    ///    reparenting; misses only processes that called `setsid` themselves.
    ///
    /// Pass `sid: 0` to skip the session match. Capture `sid` while the root is
    /// still alive — `getsid` on a reaped pid returns -1.
    /// `descendantPIDs` off the cooperative thread pool — it runs `ps` and waits
    /// for it, which must never block a pool thread.
    public static func descendantPIDsAsync(of root: pid_t, sid: pid_t) async -> [pid_t] {
        await withCheckedContinuation { continuation in
            ManagedProcess.blockingQueue.async {
                continuation.resume(returning: descendantPIDs(of: root, sid: sid))
            }
        }
    }

    public static func descendantPIDs(of root: pid_t, sid: pid_t) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-Ao", "pid,ppid"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var childrenByParent: [pid_t: [pid_t]] = [:]
        var allPIDs: [pid_t] = []
        for line in text.split(separator: "\n").dropFirst() {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1])
            else { continue }
            childrenByParent[ppid, default: []].append(pid)
            allPIDs.append(pid)
        }

        var result = Set<pid_t>()

        var queue: [pid_t] = [root]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard let children = childrenByParent[next] else { continue }
            for child in children where child != root {
                if result.insert(child).inserted { queue.append(child) }
            }
        }

        if sid > 0 {
            for pid in allPIDs where pid != root && getsid(pid) == sid {
                result.insert(pid)
            }
        }

        return Array(result)
    }

    /// Signal a process group plus a list of escaped descendants.
    /// `ESRCH` on an already-reaped target is expected and harmless.
    public static func signal(_ signalNumber: Int32, pgid: pid_t, escapees: [pid_t]) {
        killpg(pgid, signalNumber)
        for pid in escapees { kill(pid, signalNumber) }
    }

    /// Drop pids that have already been reaped.
    public static func liveOnly(_ pids: some Sequence<pid_t>) -> [pid_t] {
        pids.filter { kill($0, 0) == 0 }
    }
}
#endif
