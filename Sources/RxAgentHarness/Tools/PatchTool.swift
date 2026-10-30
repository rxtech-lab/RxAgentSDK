import Foundation
import RxAgentCore

/// opencode's `patch` tool: several file edits in one call, in the
/// `*** Begin Patch` envelope format GPT-family models are trained to write.
public struct PatchTool: HarnessTool {
    public init() {}
    public let name = "patch"

    public var description: String {
        """
        Use the `patch` tool to edit files. Your patch language is a stripped-down, file-oriented diff format designed to be easy to parse and safe to apply. You can think of it as a high-level envelope:

        *** Begin Patch
        [ one or more file sections ]
        *** End Patch

        Each operation starts with one of three headers:

        *** Add File: <path> - create a new file. Every following line is a + line (the initial contents).
        *** Delete File: <path> - remove an existing file. Nothing follows.
        *** Update File: <path> - patch an existing file in place (optionally followed by *** Move to: <new path>).

        In an Update section, each hunk starts with @@ (optionally followed by a line of context such as a function signature), then lines prefixed with ' ' (context), '-' (remove) or '+' (add). Include enough context lines to locate each hunk uniquely.

        Example patch:

        *** Begin Patch
        *** Add File: hello.txt
        +Hello world
        *** Update File: src/app.py
        *** Move to: src/main.py
        @@ def greet():
        -print("Hi")
        +print("Hello, world!")
        *** Delete File: obsolete.txt
        *** End Patch

        It is important to remember:
        - You must include a header with your intended action (Add/Delete/Update)
        - You must prefix new lines with `+` even when creating a new file
        """
    }

    public var parameters: JSONValue {
        Schema.object([
            "patchText": Schema.string("The full patch text describing add, update, and delete operations"),
        ], required: ["patchText"])
    }

    public func execute(_ input: JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        guard let text = (input["patchText"] ?? input["patch"] ?? input["input"])?.stringValue else {
            throw HarnessToolError("`patchText` is required.")
        }
        let operations = try PatchParser.parse(text)
        guard !operations.isEmpty else { throw HarnessToolError("The patch contains no file operations.") }

        // Compute every result before writing anything, so a hunk that fails
        // to apply leaves the tree untouched instead of half-patched.
        var planned: [(op: PatchOperation, url: URL, destination: URL?, old: String, new: String?)] = []
        for operation in operations {
            let url = context.resolve(operation.path)
            switch operation.kind {
            case .add(let content):
                if FileManager.default.fileExists(atPath: url.path) {
                    throw HarnessToolError("Cannot add \(operation.path): the file already exists. Use Update File.")
                }
                planned.append((operation, url, nil, "", content))
            case .delete:
                guard let old = try? String(contentsOf: url, encoding: .utf8) else {
                    throw HarnessToolError("Cannot delete \(operation.path): file not found.")
                }
                planned.append((operation, url, nil, old, nil))
            case .update(let moveTo, let hunks):
                guard let old = try? String(contentsOf: url, encoding: .utf8) else {
                    throw HarnessToolError("Cannot update \(operation.path): file not found.")
                }
                let new = try PatchParser.apply(hunks, to: old, path: operation.path)
                planned.append((operation, url, moveTo.map(context.resolve), old, new))
            }
        }

        let urls = planned.flatMap { [$0.url] + ($0.destination.map { [$0] } ?? []) }
        try await context.authorizePaths(
            urls, permission: HarnessPermissionKey.edit, toolName: name, input: input,
            title: "Patch \(planned.count) file\(planned.count == 1 ? "" : "s")"
        )

        var summary: [String] = []
        for item in planned {
            let target = item.destination ?? item.url
            let relative = HarnessPaths.relative(target, to: context.workingDirectory)
            if let new = item.new {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(new.utf8).write(to: target, options: .atomic)
                if let destination = item.destination, destination != item.url {
                    try? FileManager.default.removeItem(at: item.url)
                }
                await context.emit(.fileChanged(path: target.path, diff: LineDiff.unified(old: item.old, new: new, path: relative)))
                summary.append(item.old.isEmpty && item.op.kind.isAdd ? "A \(relative)" : "M \(relative)")
            } else {
                try FileManager.default.removeItem(at: item.url)
                await context.emit(.fileChanged(path: item.url.path, diff: LineDiff.unified(old: item.old, new: "", path: relative)))
                summary.append("D \(relative)")
            }
        }
        return HarnessToolOutput(text: "Applied patch:\n" + summary.joined(separator: "\n"), title: summary.joined(separator: ", "))
    }
}

public struct PatchOperation: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case add(content: String)
        case delete
        case update(moveTo: String?, hunks: [PatchHunk])

        var isAdd: Bool { if case .add = self { return true }; return false }
    }
    public let path: String
    public let kind: Kind
}

public struct PatchHunk: Sendable, Equatable {
    /// The text after `@@`, used to narrow where the hunk applies.
    public var anchor: String?
    /// Lines with their prefix kept: ' ', '-' or '+'.
    public var lines: [String]
}

public enum PatchParser {
    public static func parse(_ text: String) throws -> [PatchOperation] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // Tolerate a fenced block and missing envelope — common with small models.
        lines = lines.filter { !$0.hasPrefix("```") }
        if let begin = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "*** Begin Patch" }) {
            lines = Array(lines[(begin + 1)...])
        }
        if let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "*** End Patch" }) {
            lines = Array(lines[..<end])
        }

        var operations: [PatchOperation] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let path = header(line, "*** Add File:") {
                index += 1
                var content: [String] = []
                while index < lines.count, !lines[index].hasPrefix("***") {
                    let body = lines[index]
                    content.append(body.hasPrefix("+") ? String(body.dropFirst()) : body)
                    index += 1
                }
                if content.last == "" { content.removeLast() }
                operations.append(PatchOperation(path: path, kind: .add(content: content.joined(separator: "\n") + (content.isEmpty ? "" : "\n"))))
            } else if let path = header(line, "*** Delete File:") {
                index += 1
                operations.append(PatchOperation(path: path, kind: .delete))
            } else if let path = header(line, "*** Update File:") {
                index += 1
                var moveTo: String?
                if index < lines.count, let destination = header(lines[index], "*** Move to:") {
                    moveTo = destination
                    index += 1
                }
                var hunks: [PatchHunk] = []
                var current: PatchHunk?
                while index < lines.count, !lines[index].hasPrefix("*** ") || lines[index].hasPrefix("*** End of File") {
                    let body = lines[index]
                    index += 1
                    if body.hasPrefix("*** End of File") { continue }
                    if body.hasPrefix("@@") {
                        if let current, !current.lines.isEmpty { hunks.append(current) }
                        let anchor = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
                        current = PatchHunk(anchor: anchor.isEmpty ? nil : anchor, lines: [])
                        continue
                    }
                    if current == nil { current = PatchHunk(anchor: nil, lines: []) }
                    if body.isEmpty { current?.lines.append(" "); continue }
                    guard let first = body.first, [" ", "-", "+"].contains(first) else {
                        throw HarnessToolError("Invalid line in Update File \(path): \(body). Every hunk line must start with ' ', '-' or '+'.")
                    }
                    current?.lines.append(body)
                }
                if let current, !current.lines.isEmpty { hunks.append(current) }
                // Drop trailing blank context lines produced by a final newline.
                operations.append(PatchOperation(path: path, kind: .update(moveTo: moveTo, hunks: hunks)))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            } else {
                throw HarnessToolError("Unexpected line in patch: \(line). Each file section must start with *** Add File:, *** Delete File: or *** Update File:.")
            }
        }
        return operations
    }

    public static func apply(_ hunks: [PatchHunk], to content: String, path: String) throws -> String {
        var fileLines = content.components(separatedBy: "\n")
        let hadTrailingNewline = content.hasSuffix("\n")
        if hadTrailingNewline { fileLines.removeLast() }
        var searchFrom = 0

        for hunk in hunks {
            var lines = hunk.lines
            while lines.last == " " { lines.removeLast() }
            let before = lines.filter { !$0.hasPrefix("+") }.map { String($0.dropFirst()) }
            let after = lines.filter { !$0.hasPrefix("-") }.map { String($0.dropFirst()) }

            var start = searchFrom
            if let anchor = hunk.anchor,
               let anchorIndex = fileLines[searchFrom...].firstIndex(where: { $0.contains(anchor) }) {
                start = anchorIndex
            }
            guard let location = locate(before, in: fileLines, from: start)
                ?? locate(before, in: fileLines, from: 0) else {
                throw HarnessToolError("Could not find the lines of a hunk in \(path):\n" + before.prefix(6).joined(separator: "\n") + "\nRead the file again and include exact context lines.")
            }
            fileLines.replaceSubrange(location ..< location + before.count, with: after)
            searchFrom = location + after.count
        }
        return fileLines.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
    }

    /// Exact first, then ignoring surrounding whitespace.
    static func locate(_ needle: [String], in haystack: [String], from start: Int) -> Int? {
        guard !needle.isEmpty else { return min(start, haystack.count) }
        guard needle.count <= haystack.count, start <= haystack.count - needle.count else { return nil }
        for normalize in [{ (s: String) in s }, { (s: String) in s.trimmingCharacters(in: .whitespaces) }] {
            let target = needle.map(normalize)
            for index in start...(haystack.count - needle.count)
                where haystack[index ..< index + needle.count].map(normalize) == target {
                return index
            }
        }
        return nil
    }

    private static func header(_ line: String, _ prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }
}
