import Foundation
import RxAgentCore

/// A past Claude Code CLI conversation on disk.
public struct CLISessionSummary: Identifiable, Sendable, Hashable {
    /// The CLI's own session id — pass this as `resumeSessionID` to continue it.
    public let id: String
    public let title: String
    public let workingDirectory: String?
    public let modifiedAt: Date
    public let messageCount: Int
    public let fileURL: URL

    public init(
        id: String,
        title: String,
        workingDirectory: String?,
        modifiedAt: Date,
        messageCount: Int,
        fileURL: URL
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.modifiedAt = modifiedAt
        self.messageCount = messageCount
        self.fileURL = fileURL
    }
}

/// Reads the Claude Code CLI's transcript files under `~/.claude/projects`.
///
/// The CLI persists every conversation as JSONL; this makes those readable so a
/// host app can list past sessions and resume one. RxCode's equivalent also
/// carried AI-generated titles, a metadata cache, and a session-picker export —
/// all product features, all left behind.
public actor CLISessionStore {
    public static let shared = CLISessionStore()

    private let projectsDirectory: URL
    private let fileManager = FileManager.default
    /// Directory-name encoding is lossy, so the mapping is built by reading the
    /// `cwd` recorded inside the files. Cached because it costs a read per file.
    private var directoryCWDCache: [URL: String] = [:]

    public init(projectsDirectory: URL? = nil) {
        self.projectsDirectory = projectsDirectory ?? Self.defaultProjectsDirectory
    }

    /// `~/.claude/projects`.
    ///
    /// `homeDirectoryForCurrentUser` is unavailable on iOS, where there is no
    /// such directory anyway — the store simply finds nothing there, which is
    /// the correct behaviour for a device that never ran the CLI.
    static var defaultProjectsDirectory: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
        #else
        URL(filePath: NSHomeDirectory()).appending(path: ".claude/projects")
        #endif
    }

    // MARK: - Discovery

    /// Every session file recorded for `workingDirectory`, newest first.
    ///
    /// The CLI encodes the path into a directory name by replacing separators,
    /// which collides for paths differing only in `/` versus `.`. So candidate
    /// directories are confirmed by reading the `cwd` field out of a file rather
    /// than trusting the name.
    public func sessionFiles(for workingDirectory: URL) async -> [URL] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let target = workingDirectory.resolvingSymlinksInPath().path
        var matches: [URL] = []

        for directory in directories {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }

            guard let recorded = await recordedCWD(in: directory) else { continue }
            guard URL(filePath: recorded).resolvingSymlinksInPath().path == target else { continue }

            matches += jsonlFiles(in: directory)
        }

        return matches.sorted {
            (modificationDate(of: $0) ?? .distantPast) > (modificationDate(of: $1) ?? .distantPast)
        }
    }

    /// The `cwd` a directory's transcripts were recorded against.
    private func recordedCWD(in directory: URL) async -> String? {
        if let cached = directoryCWDCache[directory] { return cached }
        for file in jsonlFiles(in: directory).prefix(3) {
            guard let cwd = firstRecordedCWD(in: file) else { continue }
            directoryCWDCache[directory] = cwd
            return cwd
        }
        return nil
    }

    private func firstRecordedCWD(in file: URL) -> String? {
        for line in Self.readLines(of: file, limit: 40) {
            guard let value = JSONValue(jsonString: line),
                  let cwd = value["cwd"]?.stringValue
            else { continue }
            return cwd
        }
        return nil
    }

    private func jsonlFiles(in directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "jsonl" } ?? []
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Summaries

    /// List past sessions for a directory, newest first.
    public func summaries(for workingDirectory: URL, limit: Int = 50) async -> [CLISessionSummary] {
        var result: [CLISessionSummary] = []
        for file in await sessionFiles(for: workingDirectory).prefix(limit) {
            if let summary = summary(of: file) { result.append(summary) }
        }
        return result
    }

    func summary(of file: URL) -> CLISessionSummary? {
        var sessionID: String?
        var cwd: String?
        var title: String?
        var messageCount = 0

        for line in Self.readLines(of: file) {
            guard let value = JSONValue(jsonString: line) else { continue }
            if sessionID == nil { sessionID = value["sessionId"]?.stringValue }
            if cwd == nil { cwd = value["cwd"]?.stringValue }

            let type = value["type"]?.stringValue
            guard type == "user" || type == "assistant" else { continue }
            // Meta and sidechain lines are bookkeeping, not conversation.
            guard value["isMeta"]?.boolValue != true,
                  value["isSidechain"]?.boolValue != true
            else { continue }

            messageCount += 1
            if title == nil, type == "user" {
                let text = Self.text(from: value["message"]?["content"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { title = Self.shortTitle(from: text) }
            }
        }

        guard let sessionID, messageCount > 0 else { return nil }
        return CLISessionSummary(
            id: sessionID,
            title: title ?? "Untitled session",
            workingDirectory: cwd,
            modifiedAt: modificationDate(of: file) ?? .distantPast,
            messageCount: messageCount,
            fileURL: file
        )
    }

    // MARK: - Loading

    /// Decode a session file into transcript messages.
    public func load(sessionID: String, workingDirectory: URL) async -> [AgentMessage] {
        guard let file = await sessionFiles(for: workingDirectory).first(where: {
            $0.deletingPathExtension().lastPathComponent == sessionID
        }) else { return [] }
        return load(file: file)
    }

    public func load(file: URL) -> [AgentMessage] {
        var messages: [AgentMessage] = []
        /// Tool results arrive on later `user` lines, keyed by tool_use_id.
        var toolResults: [String: (content: String, isError: Bool)] = [:]

        for line in Self.readLines(of: file) {
            guard let value = JSONValue(jsonString: line),
                  let type = value["type"]?.stringValue,
                  value["isMeta"]?.boolValue != true,
                  value["isSidechain"]?.boolValue != true
            else { continue }

            let content = value["message"]?["content"]

            switch type {
            case "user":
                // A `user` line carrying tool_result blocks is the CLI reporting
                // results, not something the person typed.
                let results = Self.toolResults(in: content)
                if !results.isEmpty {
                    for (id, result) in results { toolResults[id] = result }
                    continue
                }
                let text = Self.text(from: content).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                messages.append(AgentMessage(
                    role: .user,
                    blocks: [.text(id: UUID(), text)],
                    timestamp: Self.timestamp(value) ?? Date()
                ))

            case "assistant":
                let blocks = Self.blocks(from: content)
                guard !blocks.isEmpty else { continue }
                messages.append(AgentMessage(
                    role: .assistant,
                    blocks: blocks,
                    timestamp: Self.timestamp(value) ?? Date()
                ))

            default:
                continue
            }
        }

        // Attach the results collected along the way.
        for index in messages.indices {
            for blockIndex in messages[index].blocks.indices {
                guard case .toolCall(var call) = messages[index].blocks[blockIndex],
                      let result = toolResults[call.id]
                else { continue }
                call.result = result.content
                call.isError = result.isError
                messages[index].blocks[blockIndex] = .toolCall(call)
            }
        }

        return messages
    }

    // MARK: - Parsing

    static func blocks(from content: JSONValue?) -> [AgentBlock] {
        guard let entries = content?.arrayValue else {
            let text = text(from: content)
            return text.isEmpty ? [] : [.text(id: UUID(), text)]
        }

        return entries.compactMap { entry in
            switch entry["type"]?.stringValue {
            case "text":
                guard let text = entry["text"]?.stringValue, !text.isEmpty else { return nil }
                return .text(id: UUID(), text)
            case "thinking":
                guard let text = entry["thinking"]?.stringValue, !text.isEmpty else { return nil }
                return .thinking(id: UUID(), text)
            case "tool_use":
                guard let id = entry["id"]?.stringValue,
                      let name = entry["name"]?.stringValue
                else { return nil }
                return .toolCall(AgentToolCall(
                    id: id,
                    name: name,
                    input: entry["input"]?.objectValue ?? [:],
                    hasCompleteInput: true
                ))
            default:
                return nil
            }
        }
    }

    static func toolResults(in content: JSONValue?) -> [String: (content: String, isError: Bool)] {
        guard let entries = content?.arrayValue else { return [:] }
        var results: [String: (content: String, isError: Bool)] = [:]
        for entry in entries where entry["type"]?.stringValue == "tool_result" {
            guard let id = entry["tool_use_id"]?.stringValue else { continue }
            results[id] = (
                text(from: entry["content"]),
                entry["is_error"]?.boolValue ?? false
            )
        }
        return results
    }

    static func text(from content: JSONValue?) -> String {
        guard let content else { return "" }
        if let text = content.stringValue { return text }
        guard let entries = content.arrayValue else { return "" }
        return entries.compactMap { $0["text"]?.stringValue ?? $0.stringValue }
            .joined(separator: "\n")
    }

    static func timestamp(_ value: JSONValue) -> Date? {
        guard let raw = value["timestamp"]?.stringValue else { return nil }
        return Self.parseTimestamp(raw)
    }

    /// The CLI writes fractional seconds; `Date.ISO8601FormatStyle` handles both
    /// forms and, unlike `ISO8601DateFormatter`, is `Sendable`.
    static func parseTimestamp(_ raw: String) -> Date? {
        if let date = try? Date(raw, strategy: .iso8601.time(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(raw, strategy: .iso8601)
    }

    static func shortTitle(from text: String, limit: Int = 60) -> String {
        let firstLine = text.components(separatedBy: .newlines).first ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Read a file line by line without loading it entirely — transcripts of a
    /// long session run to tens of megabytes.
    static func readLines(of url: URL, limit: Int? = nil) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        var lines: [String] = []
        var buffer = Data()

        while let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if !lineData.isEmpty {
                    lines.append(String(decoding: lineData, as: UTF8.self))
                    if let limit, lines.count >= limit { return lines }
                }
            }
        }
        if !buffer.isEmpty {
            lines.append(String(decoding: buffer, as: UTF8.self))
        }
        return lines
    }
}
