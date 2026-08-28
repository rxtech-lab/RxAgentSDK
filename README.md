# RxAgentSDK

A Swift SDK for driving coding-agent CLIs — **Claude Code**, **OpenAI Codex**, and any
**ACP** agent — behind one API, with SwiftUI views for the chat surface.

```swift
let agent = Agent(
    clients: [ClaudeCodeClient(), CodexClient(), ACPClient(binaryFile: url)],
    tools: [.tool(GrepTool())],
    skills: [.codeReview],
    mcpServers: []
)

AgentChatView(agent: agent)
```

Requires macOS 26 / iOS 26 and Swift 6.

---

## Tools

Tools are ordinary [FoundationModels](https://developer.apple.com/documentation/foundationmodels)
tools. Write one the way Apple documents it, hand it to `Agent`, and the CLI agent can
call it:

```swift
@Generable
struct GrepArgs {
    @Guide(description: "Regex to search for")
    var pattern: String
    @Guide(description: "Glob restricting the search")
    var include: String?
}

struct GrepTool: Tool {
    let name = "grep_workspace"
    let description = "Search the open workspace for a regex."

    func call(arguments: GrepArgs) async throws -> String {
        // …
    }
}
```

The agent runs in a separate process, so the SDK publishes your tools as an in-process
**MCP server** and wires each client's config to it. Your Swift closure is what actually
runs.

```swift
let handle = try await LocalToolServer.shared.publish(
    tools: agent.effectiveTools,
    for: agent.thread.id,
    context: AgentToolContext(threadID: agent.thread.id, workingDirectory: cwd)
)
agent.toolServer = handle
```

`.tool(_:)` erases the tool: `parameters` is exported to JSON Schema for `tools/list`,
incoming arguments are decoded through `GeneratedContent`, and the return value comes
back as the tool result.

## Context and skills

Instructions and tools are elements of the **same builder**, so one condition can add a
rule and the tools that rule talks about:

```swift
let context = AgentContext {
    "You are working in a Swift package."
    if isEditing {
        "Match the surrounding code style."
        GrepTool()
    }
}
```

A `Skill` bundles both under a name and a "when to use this" description:

```swift
extension Skill {
    static let codeReview = Skill(
        name: "Code Review",
        description: "Use when the user asks for a review of a diff."
    ) {
        "Cite file:line. Focus on correctness and concurrency safety."
        DiffTool()
    }
}
```

> **On FoundationModels versions.** The single-builder shape comes from
> `apple/foundation-models-utilities`, which is built on FoundationModels **27.0**
> (`DynamicInstructions`, `Profile`, `SessionProperty`). Those don't exist on 26.0, and
> `Instructions` there is opaque — there is no way to read its text back, which the SDK
> needs in order to send context down a pipe. So `AgentContext` reimplements the
> ergonomics on 26.0 primitives and keeps its own raw text; `instructions()` is a
> one-way export for callers who also drive a `LanguageModelSession`.

## Multiple clients

Clients are **selectable, one active at a time**. The transcript is continuous across a
switch, and each client resumes only the session it created:

```swift
agent.select(.codex)   // same thread, Codex's own native session id
```

A client joining a thread it has not seen gets a compact summary of what happened before
(`sendsHandoffSummary`).

## Permissions

Approvals are resolved through an injected protocol, so the transport never knows about
your UI:

```swift
public protocol PermissionResolving: Sendable {
    func resolve(_ request: PermissionRequest) async -> PermissionDecision
}
```

Built in: `AllowAllPermissions`, `DenyAllPermissions`,
`ReadOnlyAutoApprovePermissions` (auto-approves provably read-only Bash via
`BashSafety`), and `InteractivePermissionCoordinator`, which drives the SwiftUI sheet.

For Claude the SDK serves its `PreToolUse` HTTP hook and holds the connection open until
you answer; Codex and ACP approvals route to the same resolver.

## SwiftUI

The package vends a **single product**, `RxAgentSDK`, which re-exports everything —
so one `import RxAgentSDK` is usually all you need. The view modules are also
importable individually if you want one without the rest:

| Module | What it is |
| --- | --- |
| `AgentMarkdownUI` | Streaming-aware markdown: fades only newly-appended text, throttles reparsing to ~60fps, never caches a live message. Syntax highlighting included. Depends on nothing but `RxAgentUISupport`. |
| `AgentMessageListUI` | The dynamic-spacing message list. Same — no agent machinery. |
| `AgentChatUI` | `AgentChatView`, tool-call cards, permission sheet, composer. |

### Floating composer

The input floats over the transcript instead of sitting below a divider, so the
conversation runs edge to edge and content passes behind the field as you scroll.
`AgentChatView` measures the floating chrome and hands its height to the list as
`bottomInset`; the list spends that inset **out of** its reserved tail spacing
rather than on top of it, which is what keeps a new turn pinned to the top of the
viewport instead of scrolled up behind the composer by exactly the composer's
height.

```swift
MessageList(messages: items, bottomInset: composerHeight) { … }
```

### Dynamic spacing

When you send a message it pins to the top of the viewport and the reply grows into
reserved space beneath it, instead of the whole list jumping. The reserved height is:

```swift
max(0, scrollViewHeight - bottomInset - activeTurnHeight - minimumPinnedTailSpacing)
```

`activeTurnHeight` is measured as `tailMarkerMinY - latestUserMinY` and **ratchets** —
it only ever grows, and is committed only from the scroll-geometry callback. Reading it
from per-row callbacks can catch a half-settled layout pass and lock in a wrong height
permanently. The constants and that ratchet are a spec, not tunables.

### Previews

Every surface previews without a CLI installed, via `PreviewAgentClient`:

```swift
#Preview("Chat / Tool use") {
    AgentChatView(agent: Agent(clients: [PreviewAgentClient(script: .toolUse)]))
}
```

Scripts: `.simpleAnswer`, `.thinking`, `.toolUse`, `.longMarkdown`, `.todos`,
`.permissionRequest`, `.failure`.

## Session history

Read and resume past Claude Code conversations from `~/.claude/projects`:

```swift
let sessions = await CLISessionStore.shared.summaries(for: workingDirectory)
let messages = await CLISessionStore.shared.load(file: sessions[0].fileURL)
```

## Events

Every client decodes into one typed stream. No client ever synthesizes another's wire
format:

```swift
public enum AgentEvent: Sendable {
    case sessionStarted(SessionStarted)
    case textDelta(String)
    case thinkingDelta(String)
    case toolCallStarted(id: String, name: String)
    case toolCallInput(id: String, input: [String: JSONValue])   // complete, once
    case toolCallResult(id: String, content: String, isError: Bool)
    case todos([TodoItem])
    case permissionRequested(PermissionRequest)
    case turnEnded(TurnResult)
    case failed(AgentError)
    // …
}
```

Claude streams tool arguments as JSON fragments; `PartialBlockAssembler` accumulates
them internally and emits `toolCallInput` exactly once, complete. `TranscriptReducer`
folds events into `[AgentMessage]`. Both are pure value types — testable from a literal
array of events, with no process and no UI.

## Package layout

```
RxAgentCore       models, typed events, PartialBlockAssembler, TranscriptReducer
RxAgentContext    Agent, AnyAgentTool, AgentContext, Skill  (imports FoundationModels)
RxAgentProcess    posix_spawn, NDJSON reader, JSONRPCConnection   (macOS)
RxAgentBridge     LocalToolServer, ApprovalServer, MCP config      (macOS)
RxAgentClients    ClaudeCodeClient, CodexClient, ACPClient          (macOS)
RxAgentSessions   CLISessionStore
AgentMarkdownUI · AgentMessageListUI · AgentChatUI
```

Process-spawning targets compile to empty modules off macOS, so `AgentChatView` and the
models build for iOS.

## Example app

`example/` is a macOS testbed: working-directory picker, permission-mode control, past
sessions, and a live inspector showing the normalized event stream.

```
xcodebuild -project example/example.xcodeproj -scheme example \
  -destination 'platform=macOS,arch=arm64' build
```

The app sandbox is **off** — spawning `claude`/`codex` from the login PATH and binding
loopback ports is impossible under it. Launch with `-RXAgentPreviewClient YES` to run
against scripted events with nothing installed.

## Tests

```
swift test                    # offline: decoders, reducers, DSL, servers, views
RXAGENT_LIVE=1 swift test     # also spawns real claude / codex
RXAGENT_LIVE_ACP=1 swift test # also runs an ACP agent over npx
```

Live tests are opt-in because they need the binaries installed and spend tokens. The
default suite is fixture-driven against recorded wire output.
