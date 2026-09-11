import Foundation
import Testing
import RxAgentCore
@testable import RxAgentSessions

/// Builds a fake `~/.claude/projects` tree so the tests don't depend on the
/// developer's real history.
private struct Fixture {
    let root: URL
    let workingDirectory: URL

    init(sessionID: String = "sess-1", lines: [String]) throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "rxagent-sessions-\(UUID().uuidString)")
        root = base.appending(path: "projects")
        workingDirectory = base.appending(path: "workspace")

        let projectDirectory = root.appending(path: "-encoded-workspace-path")
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        try lines.joined(separator: "\n").write(
            to: projectDirectory.appending(path: "\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

/// Line shapes taken from a real `~/.claude/projects` transcript.
private func userLine(_ text: String, cwd: String, sessionID: String = "sess-1") -> String {
    """
    {"type":"user","uuid":"u1","sessionId":"\(sessionID)","cwd":"\(cwd)",\
    "timestamp":"2026-08-27T12:10:28.696Z","isSidechain":false,\
    "message":{"role":"user","content":[{"type":"text","text":"\(text)"}]}}
    """
}

private func assistantLine(_ text: String, cwd: String, sessionID: String = "sess-1") -> String {
    """
    {"type":"assistant","uuid":"a1","sessionId":"\(sessionID)","cwd":"\(cwd)",\
    "timestamp":"2026-08-27T12:10:40.746Z","isSidechain":false,\
    "message":{"role":"assistant","content":[{"type":"text","text":"\(text)"}]}}
    """
}

@Suite("CLISessionStore")
struct CLISessionStoreTests {

    @Test("Finds sessions by the cwd recorded inside the file")
    func findsSessionsByRecordedCWD() async throws {
        let fixture = try Fixture(lines: [
            userLine("hello", cwd: "/does/not/matter"),
        ])
        defer { fixture.cleanUp() }

        // The directory name is deliberately wrong for the path; only the
        // recorded `cwd` should be trusted.
        let store = CLISessionStore(projectsDirectory: fixture.root)
        let wrongDirectory = await store.sessionFiles(for: fixture.workingDirectory)
        #expect(wrongDirectory.isEmpty, "must not match on directory name alone")

        let matching = await store.sessionFiles(for: URL(filePath: "/does/not/matter"))
        #expect(matching.count == 1)
    }

    @Test("Summarizes a session with a title from the first user message")
    func summarize() async throws {
        let cwd = "/tmp/rxagent-summary"
        let fixture = try Fixture(lines: [
            userLine("Explain the dynamic spacing behaviour", cwd: cwd),
            assistantLine("It reserves a tail spacer.", cwd: cwd),
        ])
        defer { fixture.cleanUp() }

        let store = CLISessionStore(projectsDirectory: fixture.root)
        let summaries = await store.summaries(for: URL(filePath: cwd))

        #expect(summaries.count == 1)
        #expect(summaries[0].id == "sess-1")
        #expect(summaries[0].title == "Explain the dynamic spacing behaviour")
        #expect(summaries[0].messageCount == 2)
        #expect(summaries[0].workingDirectory == cwd)
    }

    @Test("Loads a transcript into messages")
    func loadTranscript() async throws {
        let cwd = "/tmp/rxagent-load"
        let fixture = try Fixture(lines: [
            userLine("hello", cwd: cwd),
            assistantLine("hi there", cwd: cwd),
        ])
        defer { fixture.cleanUp() }

        let store = CLISessionStore(projectsDirectory: fixture.root)
        let messages = await store.load(sessionID: "sess-1", workingDirectory: URL(filePath: cwd))

        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[0].plainText == "hello")
        #expect(messages[1].role == .assistant)
        #expect(messages[1].plainText == "hi there")
    }

    /// A `user` line carrying `tool_result` blocks is the CLI reporting a
    /// result, not something the person typed — rendering it as a user bubble
    /// would be wrong.
    @Test("Tool results attach to their call instead of becoming user messages")
    func toolResultsAttachToCalls() async throws {
        let cwd = "/tmp/rxagent-tools"
        let toolUse = """
        {"type":"assistant","uuid":"a1","sessionId":"sess-1","cwd":"\(cwd)",\
        "timestamp":"2026-08-27T12:10:40.746Z","isSidechain":false,\
        "message":{"role":"assistant","content":[\
        {"type":"text","text":"Checking."},\
        {"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}
        """
        let toolResult = """
        {"type":"user","uuid":"u2","sessionId":"sess-1","cwd":"\(cwd)",\
        "timestamp":"2026-08-27T12:10:41.000Z","isSidechain":false,\
        "message":{"role":"user","content":[\
        {"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"a.swift"}],\
        "is_error":false}]}}
        """

        let fixture = try Fixture(lines: [userLine("list files", cwd: cwd), toolUse, toolResult])
        defer { fixture.cleanUp() }

        let store = CLISessionStore(projectsDirectory: fixture.root)
        let messages = await store.load(sessionID: "sess-1", workingDirectory: URL(filePath: cwd))

        #expect(messages.count == 2, "the tool_result line must not become a message")
        let call = try #require(messages[1].toolCalls.first)
        #expect(call.name == "Bash")
        #expect(call.input["command"]?.stringValue == "ls")
        #expect(call.result == "a.swift")
        #expect(!call.isError)
    }

    @Test("Thinking blocks are preserved")
    func thinkingBlocks() async throws {
        let cwd = "/tmp/rxagent-thinking"
        let line = """
        {"type":"assistant","uuid":"a1","sessionId":"sess-1","cwd":"\(cwd)",\
        "timestamp":"2026-08-27T12:10:40.746Z","isSidechain":false,\
        "message":{"role":"assistant","content":[\
        {"type":"thinking","thinking":"weighing options"},{"type":"text","text":"done"}]}}
        """
        let fixture = try Fixture(lines: [line])
        defer { fixture.cleanUp() }

        let store = CLISessionStore(projectsDirectory: fixture.root)
        let messages = await store.load(sessionID: "sess-1", workingDirectory: URL(filePath: cwd))
        #expect(messages[0].blocks.first?.thinking == "weighing options")
        #expect(messages[0].plainText == "done")
    }

    @Test("Meta and sidechain lines are skipped")
    func skipsMetaAndSidechain() async throws {
        let cwd = "/tmp/rxagent-meta"
        let meta = """
        {"type":"user","uuid":"m1","sessionId":"sess-1","cwd":"\(cwd)","isMeta":true,\
        "message":{"role":"user","content":[{"type":"text","text":"system boilerplate"}]}}
        """
        let sidechain = """
        {"type":"assistant","uuid":"s1","sessionId":"sess-1","cwd":"\(cwd)","isSidechain":true,\
        "message":{"role":"assistant","content":[{"type":"text","text":"subagent chatter"}]}}
        """
        let fixture = try Fixture(lines: [meta, sidechain, userLine("real prompt", cwd: cwd)])
        defer { fixture.cleanUp() }

        let store = CLISessionStore(projectsDirectory: fixture.root)
        let messages = await store.load(sessionID: "sess-1", workingDirectory: URL(filePath: cwd))
        #expect(messages.count == 1)
        #expect(messages[0].plainText == "real prompt")
    }

    @Test("Non-conversation line types are ignored")
    func ignoresBookkeepingLines() async throws {
        let cwd = "/tmp/rxagent-bookkeeping"
        let fixture = try Fixture(lines: [
            #"{"type":"queue-operation","sessionId":"sess-1","cwd":"\#(cwd)"}"#,
            #"{"type":"attachment","sessionId":"sess-1","cwd":"\#(cwd)"}"#,
            userLine("hello", cwd: cwd),
            "not json at all",
        ])
        defer { fixture.cleanUp() }

        let store = CLISessionStore(projectsDirectory: fixture.root)
        let messages = await store.load(sessionID: "sess-1", workingDirectory: URL(filePath: cwd))
        #expect(messages.count == 1)
    }

    @Test("A missing projects directory yields nothing rather than throwing")
    func missingDirectory() async {
        let store = CLISessionStore(projectsDirectory: URL(filePath: "/nope/not/here"))
        #expect(await store.summaries(for: URL(filePath: "/tmp")).isEmpty)
    }

    // MARK: Parsing helpers

    @Test("Long titles are truncated on the first line")
    func titleTruncation() {
        let long = String(repeating: "a", count: 200)
        #expect(CLISessionStore.shortTitle(from: long).count <= 61)
        #expect(CLISessionStore.shortTitle(from: "first\nsecond") == "first")
    }

    @Test("Timestamps parse with and without fractional seconds")
    func timestampParsing() {
        #expect(CLISessionStore.parseTimestamp("2026-08-27T12:10:28.696Z") != nil)
        #expect(CLISessionStore.parseTimestamp("2026-08-27T12:10:28Z") != nil)
        #expect(CLISessionStore.parseTimestamp("nonsense") == nil)
    }
}
