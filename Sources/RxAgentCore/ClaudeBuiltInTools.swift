import Foundation

/// Claude Code's own built-in tools, by name.
///
/// A host that hands a turn an `allowedTools` list is enumerating the tools
/// *it* owns — its MCP surface. Claude's built-ins are not on that list and
/// never can be, because the host does not define them. Naming them here is
/// what lets a host offer them without keeping a hand-written copy of the
/// CLI's tool table, and without discovering one refused call at a time that
/// it forgot `TodoWrite`.
public extension [String] {

    /// Everything Claude Code can do on its own: read and write files, run
    /// shell commands, search, reach the web, and spawn subagents.
    ///
    /// This is the default for ``ClaudeCodeClient/init(id:displayName:binaryPath:extraArguments:environment:preapprovedTools:reasoningLevels:capabilities:)``,
    /// and the pre-approved set is *added* to a turn's allowlist rather than
    /// replaced by it. An app whose agent has no business touching the
    /// filesystem passes `preapprovedTools: []` and gets exactly its own list
    /// — the lockdown is still available, it is just no longer the default.
    ///
    /// The flags are for a host that wants most of the set and not all of it.
    /// Letting the agent read the disk but not write to it is
    /// `fileWrites: false`, which is a smaller thing to get right than an
    /// allowlist typed out by hand.
    static func claudeDefaultTools(
        fileReads: Bool = true,
        fileWrites: Bool = true,
        shell: Bool = true,
        web: Bool = true,
        subagents: Bool = true,
        bookkeeping: Bool = true
    ) -> [String] {
        var tools: [String] = []
        if fileReads { tools += ["Read", "Glob", "Grep", "LS", "Notebook"] }
        if fileWrites { tools += ["Write", "Edit", "MultiEdit", "NotebookEdit"] }
        if shell { tools += ["Bash", "BashOutput", "KillShell"] }
        if web { tools += ["WebFetch", "WebSearch"] }
        if subagents { tools += ["Task", "Agent", "TaskOutput"] }
        // The CLI drives these itself. A refused `TodoWrite` buys nothing and
        // costs the turn a retry.
        if bookkeeping { tools += ["TodoRead", "TodoWrite", "ExitPlanMode", "AskUserQuestion"] }
        return tools
    }

    /// The corner of ``claudeDefaultTools(fileReads:fileWrites:shell:web:subagents:bookkeeping:)``
    /// that only ever looks: reading and searching files, and fetching pages.
    ///
    /// For a host that wants the agent able to orient itself — read its own
    /// output, check what a file actually contains — without being able to
    /// change anything on the machine.
    static func claudeReadOnlyTools() -> [String] {
        claudeDefaultTools(fileWrites: false, shell: false, subagents: false)
    }
}
