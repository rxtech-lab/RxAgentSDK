import Foundation
import RxAgentCore

// MARK: - read

/// opencode's `read`: line-numbered file contents, or a directory listing.
public struct ReadTool: HarnessTool {
    public static let defaultLimit = 2000
    public static let maxLineLength = 2000
    public static let maxBytes = 50 * 1024

    public init() {}
    public let name = "read"
    public var isReadOnly: Bool { true }

    public var description: String {
        """
        Read a file or directory from the local filesystem. If the path does not exist, an error is returned.

        Usage:
        - The path may be absolute or relative to the working directory.
        - By default this returns up to 2000 lines from the start of the file. Use offset (1-based) and limit to read later sections of large files.
        - Each line is prefixed with its line number followed by a tab. Lines longer than 2000 characters are truncated.
        - A directory path returns its entries, one per line, with a trailing / for subdirectories.
        - Image files (png, jpg, gif, webp) are returned as images.
        - Call this tool in parallel when you know there are multiple files you want to read.
        - Read a file before editing it.
        """
    }

    public var parameters: JSONValue {
        Schema.object([
            "path": Schema.string("File or directory to read"),
            "offset": Schema.integer("The line or directory entry to start reading from (1-based)"),
            "limit": Schema.integer("The maximum number of lines or directory entries to read (defaults to and capped at 2000)"),
        ], required: ["path"])
    }

    public func execute(_ input: JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        guard let raw = (input["path"] ?? input["filePath"] ?? input["file_path"])?.stringValue else {
            throw HarnessToolError("`path` is required.")
        }
        let url = context.resolve(raw)
        try await context.authorizePaths(
            [url], permission: HarnessPermissionKey.read, toolName: name, input: input,
            title: "Read \(HarnessPaths.relative(url, to: context.workingDirectory))"
        )
        let offset = max(1, input["offset"]?.intValue ?? 1)
        let limit = min(Self.defaultLimit, max(1, input["limit"]?.intValue ?? Self.defaultLimit))

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            let siblings = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
            let base = url.lastPathComponent.lowercased()
            let suggestions = siblings.filter { $0.lowercased().contains(base) || base.contains($0.lowercased()) }.prefix(3)
            var message = "File not found: \(url.path)"
            if !suggestions.isEmpty { message += "\n\nDid you mean one of these?\n" + suggestions.joined(separator: "\n") }
            throw HarnessToolError(message)
        }
        let relative = HarnessPaths.relative(url, to: context.workingDirectory)

        if isDirectory.boolValue {
            let entries = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey]
            )
            .map { entry -> String in
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return entry.lastPathComponent + (isDir ? "/" : "")
            }
            .sorted()
            let page = entries.dropFirst(offset - 1).prefix(limit)
            var text = page.joined(separator: "\n")
            if entries.count > offset - 1 + page.count {
                text += "\n\n(\(entries.count - (offset - 1 + page.count)) more entries; use offset \(offset + page.count) to continue)"
            }
            return HarnessToolOutput(text: text.isEmpty ? "(empty directory)" : text, title: relative)
        }

        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        if let mime = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"][ext] {
            return HarnessToolOutput(
                text: "Image file \(relative) (\(data.count) bytes) attached.",
                title: relative, images: [HarnessImage(mimeType: mime, data: data)]
            )
        }
        if Self.looksBinary(data) {
            throw HarnessToolError("Cannot read binary file: \(relative)")
        }
        let content = String(decoding: data, as: UTF8.self)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard offset <= max(lines.count, 1) else {
            throw HarnessToolError("Offset \(offset) is beyond the end of the file (\(lines.count) lines).")
        }
        var output: [String] = []
        var bytes = 0
        var last = offset - 1
        for (index, line) in lines.enumerated().dropFirst(offset - 1).prefix(limit) {
            var text = String(line)
            if text.count > Self.maxLineLength { text = String(text.prefix(Self.maxLineLength)) + "… (line truncated)" }
            let rendered = "\(index + 1)\t\(text)"
            bytes += rendered.utf8.count + 1
            if bytes > Self.maxBytes { break }
            output.append(rendered)
            last = index + 1
        }
        var text = output.joined(separator: "\n")
        if last < lines.count {
            text += "\n\n(File has \(lines.count) lines. Showing lines \(offset)-\(last). Use offset \(last + 1) to read more.)"
        }
        return HarnessToolOutput(text: text.isEmpty ? "(empty file)" : text, title: relative,
                                 metadata: ["lines": .number(Double(lines.count))])
    }

    static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8000)
        if sample.isEmpty { return false }
        if sample.contains(0) { return true }
        let control = sample.filter { $0 < 9 || ($0 > 13 && $0 < 32) }.count
        return Double(control) / Double(sample.count) > 0.3
    }
}

// MARK: - write

public struct WriteTool: HarnessTool {
    public init() {}
    public let name = "write"

    public var description: String {
        """
        Write a file to the local filesystem, creating parent directories as needed. Overwrites an existing file.

        Usage:
        - Prefer editing existing files with the edit tool; use write for new files or complete rewrites.
        - If the file exists, read it first so you do not discard content you have not seen.
        - Never create documentation files (*.md, README) unless the user asked for them.
        """
    }

    public var parameters: JSONValue {
        Schema.object([
            "path": Schema.string("Path to the file to write to"),
            "content": Schema.string("Content to write to the file"),
        ], required: ["path", "content"])
    }

    public func execute(_ input: JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        guard let raw = (input["path"] ?? input["filePath"] ?? input["file_path"])?.stringValue else {
            throw HarnessToolError("`path` is required.")
        }
        guard let content = input["content"]?.stringValue else { throw HarnessToolError("`content` is required.") }
        let url = context.resolve(raw)
        let relative = HarnessPaths.relative(url, to: context.workingDirectory)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        try await context.authorizePaths(
            [url], permission: HarnessPermissionKey.edit, toolName: name, input: input,
            title: existing == nil ? "Create \(relative)" : "Overwrite \(relative)"
        )
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
        let diff = LineDiff.unified(old: existing ?? "", new: content, path: relative)
        await context.emit(.fileChanged(path: url.path, diff: diff))
        return HarnessToolOutput(
            text: existing == nil ? "Created \(relative)." : "Wrote \(relative).",
            title: relative, metadata: ["diff": .string(diff)]
        )
    }
}

// MARK: - edit

public struct EditTool: HarnessTool {
    public init() {}
    public let name = "edit"

    public var description: String {
        """
        Perform an exact string replacement in a file.

        Usage:
        - Read the file before editing it.
        - oldString must match the file exactly, including indentation. Do not include the line-number prefix from read output.
        - The edit fails if oldString is not found, or if it occurs more than once and replaceAll is not set. Add surrounding lines to make it unique.
        - Use replaceAll to change every occurrence, e.g. renaming a variable.
        - An empty oldString creates the file with newString as its content.
        """
    }

    public var parameters: JSONValue {
        Schema.object([
            "path": Schema.string("File to edit"),
            "oldString": Schema.string("Exact text to find and replace"),
            "newString": Schema.string("Text to replace oldString with (must differ from oldString)"),
            "replaceAll": Schema.boolean("Replace every occurrence of oldString (default false)"),
        ], required: ["path", "oldString", "newString"])
    }

    public func execute(_ input: JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        guard let raw = (input["path"] ?? input["filePath"] ?? input["file_path"])?.stringValue else {
            throw HarnessToolError("`path` is required.")
        }
        guard let oldString = (input["oldString"] ?? input["old_string"])?.stringValue,
              let newString = (input["newString"] ?? input["new_string"])?.stringValue else {
            throw HarnessToolError("`oldString` and `newString` are required.")
        }
        guard oldString != newString else { throw HarnessToolError("oldString and newString must differ.") }
        let replaceAll = (input["replaceAll"] ?? input["replace_all"])?.boolValue ?? false
        let url = context.resolve(raw)
        let relative = HarnessPaths.relative(url, to: context.workingDirectory)

        let original: String
        if FileManager.default.fileExists(atPath: url.path) {
            original = try String(contentsOf: url, encoding: .utf8)
        } else if oldString.isEmpty {
            original = ""
        } else {
            throw HarnessToolError("File not found: \(url.path)")
        }

        let updated = try Self.replace(in: original, old: oldString, new: newString, all: replaceAll)
        try await context.authorizePaths(
            [url], permission: HarnessPermissionKey.edit, toolName: name, input: input, title: "Edit \(relative)"
        )
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(updated.utf8).write(to: url, options: .atomic)
        let diff = LineDiff.unified(old: original, new: updated, path: relative)
        await context.emit(.fileChanged(path: url.path, diff: diff))
        return HarnessToolOutput(text: "Edited \(relative).", title: relative, metadata: ["diff": .string(diff)])
    }

    /// Exact match first. When that fails, retry ignoring trailing whitespace
    /// and indentation per line — the two mistakes small models make most —
    /// and replace the span of the *file's* text that matched.
    static func replace(in content: String, old: String, new: String, all: Bool) throws -> String {
        if old.isEmpty { return content.isEmpty ? new : content + new }
        let exactCount = content.components(separatedBy: old).count - 1
        if exactCount == 1 || (all && exactCount > 0) {
            return all ? content.replacingOccurrences(of: old, with: new)
                : content.replacingCharacters(in: content.range(of: old)!, with: new)
        }
        if exactCount > 1 {
            throw HarnessToolError("Found \(exactCount) matches for oldString. Provide more surrounding context to make it unique, or set replaceAll.")
        }
        if let range = fuzzyRange(of: old, in: content) {
            return content.replacingCharacters(in: range, with: new)
        }
        throw HarnessToolError("oldString was not found in the file. Read the file again and copy the exact text, including whitespace.")
    }

    static func fuzzyRange(of needle: String, in haystack: String) -> Range<String.Index>? {
        let needleLines = needle.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let hayLines = haystack.split(separator: "\n", omittingEmptySubsequences: false)
        guard !needleLines.isEmpty, needleLines.count <= hayLines.count else { return nil }
        var matches: [Int] = []
        for start in 0...(hayLines.count - needleLines.count) {
            let window = hayLines[start ..< start + needleLines.count].map { $0.trimmingCharacters(in: .whitespaces) }
            if window == needleLines { matches.append(start) }
        }
        guard matches.count == 1, let start = matches.first else { return nil }
        let startIndex = hayLines[start].startIndex
        let endIndex = hayLines[start + needleLines.count - 1].endIndex
        return startIndex ..< endIndex
    }
}

// MARK: - glob

public struct GlobTool: HarnessTool {
    public static let defaultLimit = 100

    public init() {}
    public let name = "glob"
    public var isReadOnly: Bool { true }
    public let description = "Search file paths using a glob pattern (examples: \"**/*.ts\", \"src/**/*.tsx\"). Returns matching paths sorted by modification time, newest first. Respects .gitignore when ripgrep is installed."

    public var parameters: JSONValue {
        Schema.object([
            "pattern": Schema.string("Glob pattern to match files against"),
            "path": Schema.string("Directory to search. Defaults to the current working directory."),
            "limit": Schema.integer("Maximum number of matching files to return (default: 100)"),
        ], required: ["pattern"])
    }

    public func execute(_ input: JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        guard let pattern = input["pattern"]?.stringValue, !pattern.isEmpty else {
            throw HarnessToolError("`pattern` is required.")
        }
        let root = input["path"]?.stringValue.map(context.resolve) ?? context.workingDirectory
        try await context.authorizePaths([root], permission: HarnessPermissionKey.glob, toolName: name, input: input, title: "Find \(pattern)")
        let limit = max(1, input["limit"]?.intValue ?? Self.defaultLimit)
        let files = try await FileSearch.files(in: root, glob: pattern)
        let sorted = files.sorted { FileSearch.modified($0) > FileSearch.modified($1) }
        let shown = sorted.prefix(limit).map { HarnessPaths.relative($0, to: context.workingDirectory) }
        var text = shown.isEmpty ? "No files found." : shown.joined(separator: "\n")
        if sorted.count > limit { text += "\n\n(\(sorted.count - limit) more results; narrow the pattern or raise limit)" }
        return HarnessToolOutput(text: text, title: pattern, metadata: ["count": .number(Double(sorted.count))])
    }
}

// MARK: - grep

public struct GrepTool: HarnessTool {
    public static let defaultLimit = 100

    public init() {}
    public let name = "grep"
    public var isReadOnly: Bool { true }
    public let description = "Search file contents with a regular expression. Returns matching lines as path:line:text. Use include to filter files by glob (e.g. \"*.swift\"). Respects .gitignore when ripgrep is installed."

    public var parameters: JSONValue {
        Schema.object([
            "pattern": Schema.string("Regular expression or literal text to match in file contents."),
            "path": Schema.string("File or directory to search. Defaults to the current working directory."),
            "include": Schema.string("Glob pattern to filter files (for example, \"*.js\" or \"*.{ts,tsx}\")"),
            "literal": Schema.boolean("Treat pattern as exact text instead of a regular expression (default: false)."),
            "caseSensitive": Schema.boolean("Use case-sensitive matching (default: true)."),
            "limit": Schema.integer("Maximum number of matching lines to return (default: 100)"),
        ], required: ["pattern"])
    }

    public func execute(_ input: JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        guard let pattern = input["pattern"]?.stringValue, !pattern.isEmpty else {
            throw HarnessToolError("`pattern` is required.")
        }
        let root = input["path"]?.stringValue.map(context.resolve) ?? context.workingDirectory
        try await context.authorizePaths([root], permission: HarnessPermissionKey.grep, toolName: name, input: input, title: "Search for \(pattern)")
        let limit = max(1, input["limit"]?.intValue ?? Self.defaultLimit)
        let matches = try await FileSearch.grep(
            pattern: pattern, in: root,
            include: input["include"]?.stringValue,
            literal: input["literal"]?.boolValue ?? false,
            caseSensitive: input["caseSensitive"]?.boolValue ?? true,
            limit: limit + 1
        )
        let shown = matches.prefix(limit).map { match in
            "\(HarnessPaths.relative(match.file, to: context.workingDirectory)):\(match.line):\(match.text.prefix(500))"
        }
        var text = shown.isEmpty ? "No matches found." : shown.joined(separator: "\n")
        if matches.count > limit { text += "\n\n(More matches exist; narrow the pattern or path.)" }
        return HarnessToolOutput(text: text, title: pattern, metadata: ["count": .number(Double(shown.count))])
    }
}

// MARK: - Search backend

/// ripgrep when it is installed (fast, honours .gitignore), a FileManager walk
/// otherwise.
enum FileSearch {
    static let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".swiftpm", "Pods", ".next", "dist", "build", ".venv", "__pycache__"]

    struct Match: Sendable { let file: URL; let line: Int; let text: String }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func files(in root: URL, glob: String) async throws -> [URL] {
        #if os(macOS)
        if let rg = await ripgrep() {
            let output = try await runCapture(rg, ["--files", "--hidden", "--glob", "!.git", "--glob", glob, root.path])
            return output.split(separator: "\n").map { URL(filePath: String($0)) }
        }
        #endif
        let regex = try GlobPattern.regex(glob)
        return walk(root).filter { url in
            let relative = HarnessPaths.relative(url, to: root)
            return relative.wholeMatch(of: regex) != nil
                || (!glob.contains("/") && url.lastPathComponent.wholeMatch(of: regex) != nil)
        }
    }

    static func grep(
        pattern: String, in root: URL, include: String?, literal: Bool, caseSensitive: Bool, limit: Int
    ) async throws -> [Match] {
        #if os(macOS)
        if let rg = await ripgrep() {
            var args = ["-n", "--no-heading", "--with-filename", "--color", "never", "--hidden", "--glob", "!.git", "-m", "50"]
            if literal { args.append("-F") }
            if !caseSensitive { args.append("-i") }
            if let include { args += ["--glob", include] }
            args += ["-e", pattern, root.path]
            let output = try await runCapture(rg, args, allowExitCodes: [0, 1])
            var matches: [Match] = []
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let number = Int(parts[1]) else { continue }
                matches.append(Match(file: URL(filePath: String(parts[0])), line: number, text: String(parts[2])))
                if matches.count >= limit { break }
            }
            return matches
        }
        #endif
        let expression = literal ? NSRegularExpression.escapedPattern(for: pattern) : pattern
        var regex: Regex<AnyRegexOutput>
        do {
            regex = try Regex(expression)
            if !caseSensitive { regex = regex.ignoresCase() }
        } catch {
            throw HarnessToolError("Invalid regular expression: \(error)")
        }
        let includeRegex = try include.map(GlobPattern.regex)
        var matches: [Match] = []
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        let candidates = isDirectory.boolValue ? walk(root) : [root]
        for file in candidates {
            if let includeRegex, file.lastPathComponent.wholeMatch(of: includeRegex) == nil { continue }
            guard let data = try? Data(contentsOf: file), !ReadTool.looksBinary(data) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if (try? regex.firstMatch(in: String(line))) != nil {
                    matches.append(Match(file: file, line: index + 1, text: String(line)))
                    if matches.count >= limit { return matches }
                }
            }
        }
        return matches
    }

    static func walk(_ root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            if values?.isRegularFile == true { files.append(url) }
            if files.count > 50_000 { break }
        }
        return files
    }

    #if os(macOS)
    static func ripgrep() async -> String? {
        for candidate in ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"]
            where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    static func runCapture(_ executable: String, _ arguments: [String], allowExitCodes: Set<Int32> = [0]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard allowExitCodes.contains(process.terminationStatus) else {
                throw HarnessToolError("Search failed (exit \(process.terminationStatus)). Check the pattern.")
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
    #endif
}

/// Glob → regex: `**` crosses directories, `*` and `?` do not, `{a,b}` alternates.
enum GlobPattern {
    static func regex(_ glob: String) throws -> Regex<AnyRegexOutput> {
        var output = ""
        var characters = Array(glob)[...]
        var inBraces = false
        while let character = characters.popFirst() {
            switch character {
            case "*":
                if characters.first == "*" {
                    characters.removeFirst()
                    if characters.first == "/" { characters.removeFirst(); output += "(?:.*/)?" } else { output += ".*" }
                } else {
                    output += "[^/]*"
                }
            case "?": output += "[^/]"
            case "{": inBraces = true; output += "(?:"
            case "}" where inBraces: inBraces = false; output += ")"
            case "," where inBraces: output += "|"
            case ".", "(", ")", "+", "|", "^", "$", "[", "]", "\\": output += "\\\(character)"
            default: output.append(character)
            }
        }
        return try Regex(output)
    }
}

// MARK: - Diff

/// A compact unified diff for UI display — not for `patch(1)`.
public enum LineDiff {
    public static func unified(old: String, new: String, path: String, context: Int = 3) -> String {
        let a = old.isEmpty ? [] : old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Trim the common prefix and suffix so the LCS table stays small for
        // the usual case of a localized edit in a large file.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let midA = Array(a[prefix ..< a.count - suffix]), midB = Array(b[prefix ..< b.count - suffix])
        var lines: [String] = ["--- a/\(path)", "+++ b/\(path)"]
        guard !(midA.isEmpty && midB.isEmpty) else { return lines.joined(separator: "\n") }

        var body: [String] = []
        if midA.count * midB.count > 4_000_000 {
            body = midA.map { "-" + $0 } + midB.map { "+" + $0 }
        } else {
            var table = Array(repeating: Array(repeating: 0, count: midB.count + 1), count: midA.count + 1)
            for i in stride(from: midA.count - 1, through: 0, by: -1) {
                for j in stride(from: midB.count - 1, through: 0, by: -1) {
                    table[i][j] = midA[i] == midB[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
            var i = 0, j = 0
            while i < midA.count || j < midB.count {
                if i < midA.count, j < midB.count, midA[i] == midB[j] {
                    body.append(" " + midA[i]); i += 1; j += 1
                } else if j < midB.count, i == midA.count || table[i][j + 1] >= table[i + 1][j] {
                    body.append("+" + midB[j]); j += 1
                } else {
                    body.append("-" + midA[i]); i += 1
                }
            }
        }
        let leading = a[max(0, prefix - context) ..< prefix].map { " " + $0 }
        let trailing = a[(a.count - suffix) ..< min(a.count, a.count - suffix + context)].map { " " + $0 }
        let start = max(0, prefix - context)
        let oldCount = leading.count + midA.count + trailing.count
        let newCount = leading.count + midB.count + trailing.count
        lines.append("@@ -\(start + 1),\(oldCount) +\(start + 1),\(newCount) @@")
        lines += leading + body + trailing
        return lines.joined(separator: "\n")
    }
}
