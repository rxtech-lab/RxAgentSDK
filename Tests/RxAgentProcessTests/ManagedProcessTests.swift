#if os(macOS)
import Foundation
import Testing
@testable import RxAgentProcess

@Suite("ManagedProcess")
struct ManagedProcessTests {

    @Test("Spawns, streams stdout lines, and exits")
    func spawnAndRead() async throws {
        let process = try ManagedProcess.launch(
            executable: "/bin/sh",
            arguments: ["-c", "echo one; echo two; echo three"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: "/tmp"
        )

        var lines: [String] = []
        for await line in process.stdoutLines() { lines.append(line) }

        #expect(lines == ["one", "two", "three"])
        #expect(await process.waitForExit() == 0)
    }

    @Test("Runs in the requested working directory")
    func workingDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rxagent-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let process = try ManagedProcess.launch(
            executable: "/bin/sh",
            arguments: ["-c", "pwd"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: directory.path
        )

        var lines: [String] = []
        for await line in process.stdoutLines() { lines.append(line) }
        // /tmp is a symlink to /private/tmp on macOS.
        #expect(lines.first?.hasSuffix(directory.lastPathComponent) == true)
    }

    @Test("Echoes stdin back through stdout")
    func stdinRoundTrip() async throws {
        let process = try ManagedProcess.launch(
            executable: "/bin/cat",
            arguments: [],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: "/tmp"
        )

        try process.write(line: "hello")
        try process.write(line: "world")
        process.closeStdin()

        var lines: [String] = []
        for await line in process.stdoutLines() { lines.append(line) }
        #expect(lines == ["hello", "world"])
    }

    @Test("Captures stderr")
    func stderrCapture() async throws {
        let process = try ManagedProcess.launch(
            executable: "/bin/sh",
            arguments: ["-c", "echo boom 1>&2; echo fine"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: "/tmp"
        )

        for await _ in process.stdoutLines() {}
        _ = await process.waitForExit()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await process.collectedStderr().contains("boom"))
    }

    @Test("Reports a non-zero exit code")
    func exitCode() async throws {
        let process = try ManagedProcess.launch(
            executable: "/bin/sh",
            arguments: ["-c", "exit 3"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: "/tmp"
        )
        for await _ in process.stdoutLines() {}
        #expect(await process.waitForExit() == 3)
    }

    @Test("The child leads its own session, so killpg reaches its children")
    func newSession() async throws {
        let process = try ManagedProcess.launch(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: "/tmp"
        )
        // POSIX_SPAWN_SETSID makes sid == pgid == pid.
        #expect(await process.sid == process.pid)

        await process.terminate(graceSeconds: 0.2)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(await process.isRunning == false)
    }

    @Test("interrupt stops a long-running child")
    func interrupt() async throws {
        let process = try ManagedProcess.launch(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: "/tmp"
        )
        await process.interrupt(graceSeconds: 0.2)
        let code = await process.waitForExit()
        #expect(code != 0)
    }
}

@Suite("ShellEnvironment")
struct ShellEnvironmentTests {

    @Test("Resolves a PATH that includes standard tool directories")
    func resolvesPath() async {
        let path = await ShellEnvironment.shared.resolvedPath()
        #expect(!path.isEmpty)
        #expect(path.contains("/usr/bin") || path.contains("/usr/local/bin") || path.contains("/opt/homebrew/bin"))
    }

    @Test("Finds a binary that exists and not one that doesn't")
    func findsBinaries() async {
        let found = await ShellEnvironment.shared.findBinary(named: "ls")
        #expect(found != nil)
        let missing = await ShellEnvironment.shared.findBinary(named: "definitely-not-a-real-binary-xyz")
        #expect(missing == nil)
    }
}
#endif
