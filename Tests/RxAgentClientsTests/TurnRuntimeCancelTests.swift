#if os(macOS)
import Foundation
import Testing
import RxAgentProcess
@testable import RxAgentClients

private func sleeper() throws -> ManagedProcess {
    try ManagedProcess.launch(
        executable: "/bin/sh",
        arguments: ["-c", "sleep 30"],
        environment: ProcessInfo.processInfo.environment,
        workingDirectory: "/tmp"
    )
}

@Suite("CLI turn runtimes")
struct TurnRuntimeCancelTests {

    @Test("A Codex cancel that beats registration refuses the late process")
    func codexCancelBeforeRegister() async throws {
        let runtime = CodexRuntime()
        let turn = UUID()
        await runtime.cancel(turnID: turn)

        let process = try sleeper()
        #expect(await runtime.register(turnID: turn, process: process) == false)
        await process.terminate(graceSeconds: 0.2)
        _ = await process.waitForExit()
    }

    @Test("A Claude cancel that beats registration refuses the late process")
    func claudeCancelBeforeRegister() async throws {
        let runtime = ClaudeRuntime()
        let turn = UUID()
        await runtime.cancel(turnID: turn)

        let process = try sleeper()
        #expect(await runtime.register(turnID: turn, process: process) == false)
        await process.terminate(graceSeconds: 0.2)
        _ = await process.waitForExit()
    }

    @Test("Cancelling a registered turn returns only once its child has exited")
    func cancelAwaitsExit() async throws {
        let runtime = ClaudeRuntime()
        let turn = UUID()
        let process = try sleeper()
        #expect(await runtime.register(turnID: turn, process: process))

        await runtime.cancel(turnID: turn)
        #expect(await process.isRunning == false)
    }

    @Test("An unrelated turn registers normally")
    func registerWithoutCancel() async throws {
        let runtime = CodexRuntime()
        let process = try sleeper()
        #expect(await runtime.register(turnID: UUID(), process: process))
        await process.terminate(graceSeconds: 0.2)
        _ = await process.waitForExit()
    }
}
#endif
