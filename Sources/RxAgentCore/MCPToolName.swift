import Foundation

/// Translates between the two spellings of the same MCP tool.
///
/// A CLI agent namespaces every MCP tool it discovers — `caption_export` on a
/// server called `film_workflow` reaches it as
/// `mcp__film_workflow__caption_export` — while an in-process client, which
/// speaks MCP itself, sees the bare name. Same tool, two names, depending only
/// on who is asking.
///
/// That matters because a host declares its allow/deny lists **once**, per
/// thread, not per client. Without this the same list would admit a tool on
/// Codex and silently withhold it on the OpenAI loop.
public enum MCPToolName {
    public static let prefix = "mcp__"
    public static let separator = "__"

    /// `mcp__film_workflow__caption_export` → `caption_export`.
    /// A name that isn't namespaced comes back unchanged.
    public static func bare(_ name: String) -> String {
        guard name.hasPrefix(prefix) else { return name }
        let body = name.dropFirst(prefix.count)
        guard let range = body.range(of: separator) else { return name }
        return String(body[range.upperBound...])
    }

    /// `caption_export` → `mcp__film_workflow__caption_export`.
    /// An already-namespaced name comes back unchanged.
    public static func prefixed(_ name: String, server: String) -> String {
        guard !name.hasPrefix(prefix) else { return name }
        return prefix + server + separator + name
    }

    /// The MCP server a namespaced name belongs to, if it is namespaced.
    public static func server(of name: String) -> String? {
        guard name.hasPrefix(prefix) else { return nil }
        let body = name.dropFirst(prefix.count)
        guard let range = body.range(of: separator) else { return nil }
        return String(body[..<range.lowerBound])
    }

    /// Every spelling `name` could arrive as, given the servers in play.
    ///
    /// What `--allowedTools` needs: the CLI matches on the namespaced form, and
    /// the host supplied bare names.
    public static func spellings(of name: String, servers: [String]) -> [String] {
        let bareName = bare(name)
        var result = [name]
        for server in servers {
            let candidate = prefixed(bareName, server: server)
            if !result.contains(candidate) { result.append(candidate) }
        }
        if !result.contains(bareName) { result.append(bareName) }
        return result
    }
}
