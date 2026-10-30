import Foundation
import RxAgentCore

// MARK: - Session

/// Everything the harness needs to continue a conversation later.
///
/// `messages` is the full history, including turns that compaction has folded
/// away; `compactedThrough` marks how much of it the model no longer sees. Keeping
/// the folded turns means a host can still render the whole scrollback from the
/// store, which is the one copy of the conversation an in-process agent has.
public struct HarnessSession: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public var title: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var workingDirectory: String?
    public var model: String?
    public var messages: [HarnessMessage]
    /// The latest compaction summary, already formatted for replay.
    public var summary: String?
    /// Number of leading `messages` represented by `summary` and therefore not
    /// replayed. Zero when the session has never been compacted.
    public var compactedThrough: Int
    public var todos: [TodoItem]
    /// Cumulative token usage across every model call of the session,
    /// compaction calls included.
    public var usage: UsageInfo
    /// Prompt tokens of the most recent model call — the best measure of how
    /// full the context window currently is.
    public var lastPromptTokens: Int?
    /// Free-form host data. The harness never reads it.
    public var metadata: [String: String]

    public init(
        id: String,
        title: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        workingDirectory: String? = nil,
        model: String? = nil,
        messages: [HarnessMessage] = [],
        summary: String? = nil,
        compactedThrough: Int = 0,
        todos: [TodoItem] = [],
        usage: UsageInfo = UsageInfo(),
        lastPromptTokens: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.workingDirectory = workingDirectory
        self.model = model
        self.messages = messages
        self.summary = summary
        self.compactedThrough = compactedThrough
        self.todos = todos
        self.usage = usage
        self.lastPromptTokens = lastPromptTokens
        self.metadata = metadata
    }

    /// The messages the model still sees, i.e. everything after the summary.
    public var liveMessages: ArraySlice<HarnessMessage> {
        messages.dropFirst(min(compactedThrough, messages.count))
    }

    public var info: HarnessSessionInfo {
        HarnessSessionInfo(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messageCount: messages.count,
            model: model
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, workingDirectory, model, messages
        case summary, compactedThrough, todos, usage, lastPromptTokens, metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        messages = try container.decodeIfPresent([HarnessMessage].self, forKey: .messages) ?? []
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        compactedThrough = try container.decodeIfPresent(Int.self, forKey: .compactedThrough) ?? 0
        todos = try container.decodeIfPresent([TodoItem].self, forKey: .todos) ?? []
        usage = try container.decodeIfPresent(UsageInfo.self, forKey: .usage) ?? UsageInfo()
        lastPromptTokens = try container.decodeIfPresent(Int.self, forKey: .lastPromptTokens)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }
}

/// A session's listing row — enough for a picker without loading every message.
public struct HarnessSessionInfo: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public var title: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var messageCount: Int
    public var model: String?
}

// MARK: - Storage protocol

/// Where harness sessions live.
///
/// The harness owns no persistence of its own: it loads a session at the start
/// of a turn and saves it after every step, through whatever store the host
/// passes in. A host with its own database (RxCode keeps threads under
/// Application Support) implements this protocol over it; anyone else can use
/// ``FileHarnessSessionStore`` or ``InMemoryHarnessSessionStore``.
public protocol HarnessSessionStore: Sendable {
    func load(id: String) async throws -> HarnessSession?
    func save(_ session: HarnessSession) async throws
    func delete(id: String) async throws
    func list() async throws -> [HarnessSessionInfo]
}

// MARK: - In-memory store

/// Keeps sessions for the life of the process. Tests and previews.
public actor InMemoryHarnessSessionStore: HarnessSessionStore {
    private var sessions: [String: HarnessSession] = [:]

    public init(_ sessions: [HarnessSession] = []) {
        for session in sessions { self.sessions[session.id] = session }
    }

    public func load(id: String) async throws -> HarnessSession? { sessions[id] }
    public func save(_ session: HarnessSession) async throws { sessions[session.id] = session }
    public func delete(id: String) async throws { sessions.removeValue(forKey: id) }
    public func list() async throws -> [HarnessSessionInfo] {
        sessions.values.map(\.info).sorted { $0.updatedAt > $1.updatedAt }
    }
}

// MARK: - File store

/// One JSON file per session in a directory.
///
/// Writes are atomic so a crash mid-save leaves the previous version intact
/// rather than a truncated file the next load would reject.
public actor FileHarnessSessionStore: HarnessSessionStore {
    public let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) {
        self.directory = directory
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// `~/Library/Application Support/<appName>/harness-sessions`.
    public static func applicationSupport(appName: String) -> FileHarnessSessionStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FileHarnessSessionStore(
            directory: base.appending(path: appName).appending(path: "harness-sessions")
        )
    }

    public func load(id: String) async throws -> HarnessSession? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(HarnessSession.self, from: Data(contentsOf: url))
    }

    public func save(_ session: HarnessSession) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(session).write(to: fileURL(for: session.id), options: .atomic)
    }

    public func delete(id: String) async throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func list() async throws -> [HarnessSessionInfo] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap { try? decoder.decode(HarnessSession.self, from: $0) }?.info
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Session ids are host-chosen, so anything that could escape the directory
    /// is replaced before it becomes a file name.
    private func fileURL(for id: String) -> URL {
        let safe = id.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
        }
        return directory.appending(path: String(safe) + ".json")
    }
}
