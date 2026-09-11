# RxAgentSDK

A Swift SDK for driving agents behind one API, with SwiftUI views for the chat surface.

Two families of agent, same `AgentClient` protocol and the same event stream:

- **Coding-agent CLIs** — **Claude Code**, **OpenAI Codex**, and any **ACP** agent.
  Each runs in a child process and does its own tool-calling. macOS only.
- **In-process models** — any **OpenAI-compatible** `/chat/completions` endpoint, and
  Apple's on-device **FoundationModels**. No subprocess, so these work on iOS too; the
  SDK runs the tool-calling loop itself.

```swift
let agent = Agent(
    clients: [
        ClaudeCodeClient(),
        CodexClient(),
        OpenAIChatClient(configuration: .apiKey(key, endpoint: url)),
        FoundationModelsClient(),
    ],
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
tools. Write one the way Apple documents it, hand it to `Agent`, and any client can call
it:

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

How the tool is reached depends on who is calling. A **CLI agent** runs in a separate
process, so the SDK publishes your tools as an in-process **MCP server** and wires that
client's config to it. An **in-process client** calls your closure directly — see
[In-process clients](#in-process-clients). Either way your Swift closure is what runs.

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

## In-process clients

A CLI client delegates the hard part — deciding what to call and when — to an agent
binary. `OpenAIChatClient` has no binary, so it *is* the agent: it advertises the turn's
tools, reads back `tool_calls`, dispatches them, feeds the results in, and goes round
again until the model answers without asking for anything.

```swift
OpenAIChatClient(configuration: .apiKey(key, endpoint: URL(string: "https://api.openai.com/v1")!))
```

Two consequences follow from having no agent process:

- **History is replayed, not resumed.** There is no server-side session to hand a
  `resumeSessionID` to, so every turn re-sends the conversation from
  `AgentSendRequest.history`, which `Agent` fills from the thread. That is why
  [compaction](#compaction) matters more here than for a CLI client.
- **Tools have to be reached directly.** `AgentToolSurface` merges the host's Swift
  tools (invoked straight through `AnyAgentTool`, no socket) with the tools of every
  declared HTTP/SSE MCP server (via `MCPHTTPClient`, the mirror image of
  `LocalToolServer`). Stdio MCP servers need a subprocess and so are CLI-only.

`FoundationModelsClient` is **text-only, deliberately**: `AnyAgentTool` carries a JSON
Schema, `LanguageModelSession` wants a concrete `@Generable` arguments type, and on 26.0
there is no way to build one from a schema known at runtime. Half-supporting tool calling
with a schema translator that mangles anything beyond flat strings would be worse than
not supporting it. Its context window is a few thousand tokens shared between prompt and
response, which is less than one `tools/list` for a real application.

### Gateways behind your own auth

"An OpenAI-compatible endpoint" is not always reachable as a URL plus headers. A metered
gateway may sit behind your auth with its own token refresh, want an idempotency key per
call, and return billing information alongside the completion. Hand it the bytes instead:

```swift
OpenAIChatClient(configuration: .hosted(model: model) { body in
    let data = try await MyBackend.shared.post("ai/chat", body: body)
    applyCreditBalance(from: data)
    return data
})
```

Streaming is off for a hosted transport — a `Data`-returning closure has no deltas to
deliver.

## Tool scoping

Independent of `permissions`, and answering a different question: the resolver decides
whether a call the agent *made* goes through, while `allowedTools` decides whether the
agent is told the tool exists at all.

```swift
agent.allowedTools = MyApp.toolNames          // the entire reachable surface
agent.disallowedTools = ["Bash", "Write"]     // refused outright
```

A host whose whole tool surface is its own MCP server wants the latter — there is no
sensible approval UI for `Bash` in an app that never runs shells, and the only honest
answer to a question you cannot ask is no.

Matching is **namespace-insensitive**. A CLI agent sees a tool from an MCP server called
`myapp` as `mcp__myapp__export`; an in-process client, which speaks MCP itself, sees
`export`. Declare `export` once and it holds for both — see `MCPToolName`. For Claude the
names are expanded into every spelling and passed as `--allowedTools` /
`--disallowedTools`.

> An allowlist **replaces** `ClaudeCodeClient.preapprovedTools` rather than extending it.
> Setting one means you enumerated the surface you want reachable; silently re-adding
> `Read` and `Bash` underneath it would defeat the point.

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

## Queued turns

Sending during a turn **queues** rather than being dropped. Discarding a message the user
already sent is never right, and blocking the field while the agent works makes the wait
feel longer than it is.

```swift
agent.send("and also fix the timing")   // queues if a turn is running
agent.queuedTurns                       // shown and editable in the composer
agent.mergeQueuedTurns()                // answer three clarifications together
```

`stop()` discards the queue — draining it after a cancel would restart the very work the
user just interrupted.

## Compaction

Folds older turns into a rolling summary once the replayable transcript outgrows the
window. Compacted messages **stay in `messages`**: a user's scrollback is not the model's
context window, and deleting rows to save tokens is the wrong trade. Only
`replayableHistory()` shrinks, and the summary is added to the rendered context.

```swift
agent.autoCompact = .init(afterMessages: 20, keepingLast: 6)
agent.summarizer = { existing, transcript in await myModel.summarize(existing, transcript) }
```

The summarizer is injected because summarizing is a model call and `Agent` shouldn't
assume which model — a thread running on a CLI still wants its history compressed by
something cheaper than spawning a subprocess. Returning `nil` falls back to bounded
truncation, which is lossy but bounded, and bounded is the whole point.

A thread the active client is resuming natively is skipped: that client keeps a
transcript we don't own, and shrinking ours would only desync the two.

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

### Composer extension points

Everything app-specific enters through parameters, so the composer itself knows nothing
about your domain:

```swift
AgentChatView(
    agent: agent,
    draft: $draft,                       // host-owned, to survive switching conversations
    completions: [commands, mentions],   // `/` and `@` popups
    onDropFiles: { urls in … },
    row: { item in MyRow(item: item) },  // message kinds the SDK doesn't know about
    accessories: { EngineMenu() }        // the row under the field
)
```

Two appearance knobs live on `AgentTheme` rather than in those parameters, because they
are metrics like `cornerRadius` is:

```swift
var theme = AgentTheme.compact
theme.composerLines = 5 ... 12   // rests at 5 lines, grows to 12, then scrolls
theme.listBackground = .clear    // the default — see below
```

`listBackground` is separate from `background` and **clear by default**: the transcript
already sits on top of `background`, so painting it again buys nothing and costs you the
ability to put a material, an image, or the window's own vibrancy behind the
conversation. Set it only when the transcript wants a different ground from the rest of
the surface.

The chat surface also draws a header — the client picker plus token and context readouts
— whenever the agent has more than one client. A host that offers its own engine picker
through `accessories` turns it off:

```swift
AgentChatView(agent: agent, accessories: { EngineMenu() })
    .agentToolbar(.hidden)
```

Worth doing for looks as well as for sense: the header is the one piece of opaque chrome
in the surface, so with it hidden and both grounds clear, a window's own material shows
through from the title bar to the composer.

Hiding it doesn't cost you the token count. The transcript ends in a foot row —
`AgentStreamingIndicator` — that pulses three dots while a turn is in flight and reports
the thread's running total beside them. It is a transcript row rather than chrome, so it
scrolls with the conversation and sits at the end of the last answer, where the eye
already is. `MessageList` counts it as an accessory, so it never gets pinned space
reserved for it the way a real message would. It stays after the turn ends for as long as
there is a total worth showing, dots gone.

The foot row and the composer are both Liquid Glass, and neither is tinted: a fill heavy
enough to read as on-theme is heavy enough to turn the glass back into a slab.

A completion source is a trigger character and a query→rows function. A row either
inserts text (a mention) or runs something (a command); the popup is the same either way.
Triggers only fire at a **word boundary**, so an email address doesn't open the mention
popup and a file path doesn't open the command popup.

Enter sends, Shift+Enter inserts a newline, ↑ walks back through past prompts (only from
an empty draft, so it never eats a half-written message), Tab accepts a completion, Esc
dismisses one. On macOS the field is an `NSTextView` rather than a `TextEditor`:
`TextEditor` overrides `insertText` to enforce binding sync, which races with the input
method and drops composing Hangul and kana on commit.

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
RxAgentCore       models, typed events, AnyAgentTool, PartialBlockAssembler, TranscriptReducer
RxAgentContext    Agent, AgentContext, Skill, the FoundationModels tool bridge
RxAgentLLM        OpenAIChatClient, FoundationModelsClient, MCPHTTPClient, AgentToolSurface
RxAgentProcess    posix_spawn, NDJSON reader, JSONRPCConnection   (macOS)
RxAgentBridge     LocalToolServer, ApprovalServer, MCP config      (macOS)
RxAgentClients    ClaudeCodeClient, CodexClient, ACPClient          (macOS)
RxAgentSessions   CLISessionStore
AgentMarkdownUI · AgentMessageListUI · AgentChatUI
```

`AnyAgentTool` lives in `RxAgentCore`, not next to the DSL that builds it, because both
consumers need it and only one can import FoundationModels: the MCP tool server publishes
tools to an external CLI, and the **in-process clients invoke the closure directly**.
Routing an in-process model's tool call out to a loopback socket and back into the same
process would be absurd. The FoundationModels half — turning a `Tool` into an erased one,
which needs the concrete `Arguments` type — stays in `RxAgentContext`.

`RxAgentLLM` spawns nothing, so it builds and runs on iOS. The process-spawning targets
compile to empty modules off macOS, so `AgentChatView` and the models build there too.

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
