# Voice SDK plan

**Status: SDK migration in progress.** Implemented:
- `GeminiVoiceEngine` for Chippy's normalized gateway WebSocket protocol, with server-minted credentials.
- `PipelineVoiceEngine`, `AgentVoiceResponder`, and local recognizer/synthesizer closure adapters.
- `CodexVoiceEngine` wrapping the existing realtime transport on macOS.
- `VoiceRunner` for exclusive mode switching and `AgentVoiceView` with a dedicated mode sheet.
- Session tool routing with duplicate-call suppression and fail-closed defaults.

The app-side migration in `summary-chip-ios` is **not implemented here**. Hosts must
still supply PCM capture/playback, recognition, synthesis, permission-aware tool
routing, and an AgentSendRequest factory carrying thread history. Local synthesis
currently begins after the agent turn ends. The direct OpenAI engine, native Apple
speech/audio implementations, echo recovery and transcript persistence remain open.
The proposal examples below describe the target API, not all shipped signatures.
No microphone, device route, live provider, or UI testing has been performed.

This plan adds voice chat with different agents to RxAgentSDK: a `VoiceEngine`
protocol, a `VoiceSession` that owns audio and state, and SwiftUI components for
the voice UI.

Sources checked on 2026-11-05: the voice code in `summary-chip-ios`, the OpenAI
Realtime docs, and the Codex
[`realtime.rs`](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/realtime.rs)
protocol source.

## Goals

- Support OpenAI-style realtime endpoints, local speech recognition and TTS, and
  Codex realtime through one API.
- Give any `AgentClient` a voice, including Claude Code, ACP agents and the harness.
- Let users interrupt the agent by speaking, without the agent responding to its
  own voice.
- Provide a default voice UI and building blocks for custom layouts: waveform,
  status, tool calls, text response, session duration, and start, pause and stop.

## Design

A single `VoiceEngine` protocol sits under one `VoiceSession` and one UI. There are
three engine types:

| Engine | Used for | Who runs tools |
|---|---|---|
| `RealtimeVoiceEngine` | OpenAI-style WebSocket endpoints, using a wire dialect | `VoiceSession` |
| `PipelineVoiceEngine` | Speech recognition → any `AgentClient` → TTS | The agent |
| `CodexVoiceEngine` (macOS only) | Wraps `CodexRealtimeSession` | Codex |

The session owns audio, echo handling, interruption, tool routing and state, so
engines only deal with their protocol.

## Usage

```swift
let voice = VoiceSession(
    engine: RealtimeVoiceEngine(
        dialect: .openAI,
        model: "gpt-realtime-2.1",
        voice: "marin",
        connection: { try await api.mintRealtimeConnection() } // never ships an API key
    ),
    agent: agent,                     // tools, permissions, context, transcript
    audio: .init(echo: .automatic, interruption: .voiceAndTap)
)

// Any AgentClient, fully on-device speech
PipelineVoiceEngine(
    recognizer: AppleSpeechRecognizer(locale: .current),
    synthesizer: AppleSpeechSynthesizer(),   // or the host's Kokoro worker
    responder: .agent(agent)
)

// macOS only
CodexVoiceEngine(client: CodexClient(), workingDirectory: url, voice: nil)
```

## Session API

```swift
@MainActor @Observable
public final class VoiceSession {
    public private(set) var lifecycle: VoiceLifecycle
    public private(set) var activity: VoiceActivity
    public private(set) var transcript: [VoiceTranscriptEntry]
    public private(set) var tools: [VoiceToolActivity]
    public private(set) var duration: Duration        // excludes paused time
    public private(set) var isMuted: Bool
    public private(set) var warning: VoiceWarning?    // e.g. no mic signal
    public private(set) var effectiveAudio: VoiceEffectiveAudio // echo mode actually in use
    public let capabilities: VoiceEngineCapabilities
    public let meters: VoiceMeters // separate object, so 30 Hz updates only redraw the waveform

    public func start() async throws
    public func pause()
    public func resume()
    public func stop() async
    public func interrupt()
    public func setMuted(_ muted: Bool)
    public func send(text: String) async throws
}

public enum VoiceLifecycle {
    case idle, preparing(VoicePreparationStep), connecting, active, paused
    case reconfiguringAudio, stopping, stopped(VoiceStopReason), failed(VoiceError)
}

public enum VoiceActivity {
    case listening, userSpeaking, thinking, usingTools, agentSpeaking
}
```

Lifecycle and activity are separate because a paused session can still have a tool
running.

## Engine protocol

```swift
public protocol VoiceEngine: Sendable {
    var displayName: String { get }
    var capabilities: VoiceEngineCapabilities { get }
    func readiness() async -> VoiceEngineReadiness          // ready, needs setup, needs download
    func connect(_ config: VoiceSessionConfig) async throws -> any VoiceConnection
}

public protocol VoiceConnection: Sendable {
    var inputFormat: VoicePCMFormat { get }
    var events: AsyncStream<VoiceEngineEvent> { get }

    func send(audio: VoiceAudioFrame) async throws
    func send(text: String) async throws
    func interrupt(_ interruption: VoiceInterruption) async throws
    func submitToolResult(callID: String, result: AgentToolResult) async throws
    func close() async
}

public struct VoiceInterruption: Sendable {
    public let itemID: String?
    public let heardDuration: Duration  // from the playback clock
}

public enum VoiceEngineEvent: Sendable {
    case ready
    case userSpeechStarted, userSpeechStopped
    case userTranscript(itemID: String?, text: String, isFinal: Bool)
    case assistantAudio(itemID: String?, VoiceAudioFrame)  // carries its own format
    case assistantText(itemID: String?, delta: String)
    case assistantDone(itemID: String?)
    case toolCallRequested(id: String, name: String, input: [String: JSONValue]) // session runs it
    case toolActivity(AgentEvent)                          // agent ran it; display only
    case permissionRequested(PermissionRequest)
    case usage(UsageInfo)
    case closed(reason: String?)
    case failed(VoiceError)
}
```

The other pluggable parts are small:

```swift
public protocol SpeechRecognizing: Sendable { /* append PCM, finishUtterance, discard */ }
public protocol SpeechSynthesizing: Sendable { /* enqueue text, stream PCM, cancelAll */ }
public protocol VoiceResponder: Sendable { /* respond → AsyncStream<AgentEvent>, cancel */ }
public protocol RealtimeWireDialect: Sendable { /* encode commands, decode frames */ }
public protocol VoiceAudioProcessor: Sendable { /* optional capture hook, e.g. RNNoise */ }
```

The dialects are `.openAI` and `.aiGateway`. Chippy's Gemini traffic uses different
event names (`audio-delta`, `speech-started`), so it needs its own dialect to
migrate.

## Interruption and echo

```swift
public struct VoiceAudioConfiguration: Sendable {
    public var echo: VoiceEchoPolicy = .automatic
    public var interruption: VoiceInterruptionPolicy = .voiceAndTap
    public var noiseSuppression: VoiceNoiseSuppression = .system
    public var processor: (any VoiceAudioProcessor)? = nil
}

public enum VoiceEchoPolicy { case automatic, voiceProcessing, halfDuplex(tail: Duration), none }
public enum VoiceInterruptionPolicy { case voiceAndTap, tapOnly, disabled }
```

### Interrupting the agent

1. **Possible speech:** local VAD on the cleaned mic signal, or the server's speech
   event, immediately ducks playback without discarding it.
2. **Confirmed speech:** after sustained speech, a server event or real words in
   the transcript, the session flushes playback, reads the heard duration and calls
   `connection.interrupt`.
3. **False alarm:** a cough or door slam restores the volume, and the reply
   continues.

### Stopping the agent from responding to itself

1. **Echo cancellation:** voice processing uses the same audio engine for capture
   and playback, so speech, TTS and tool cues all share one echo reference. The SDK
   therefore has to own playback.
2. **Half-duplex fallback:** if voice processing fails, the mic is gated during
   playback plus a 500 ms tail. Voice interruption can't work in this mode, so the
   session reports it through `effectiveAudio` and the UI offers tap to interrupt.
3. **Transcript guard (pipeline only):** text recognized during or just after
   playback is dropped if it closely matches what was just spoken. This can
   occasionally drop a user who repeats the agent's words, so it needs a
   conservative threshold.

### What each engine can do

| | OpenAI | AI Gateway (Gemini) | Pipeline | Codex |
|---|---|---|---|---|
| **Speech detection** | Server VAD | Provider VAD | Local VAD | Not typed; needs a live test |
| **Cancel a response** | `response.cancel` | Provider-driven | `AgentClient.cancel` | **No RPC, only `stop`** |
| **Truncate to heard audio** | `conversation.item.truncate` | Not used in Chippy | N/A | **None** |
| **Noise reduction** | Server option + system | System | System | System |

On Codex, an interruption can stop local playback and drop later audio by `item_id`,
but the backend may keep generating until something else stops it.

## UI: `AgentVoiceUI`

```swift
// Default experience
AgentVoiceView(session: voice)

// Custom layout using the same building blocks
AgentVoiceView(session: voice) { context in
    MyGlobe(level: context.meters.output, activity: context.activity)
    VoiceResponseText()
    VoiceToolActivityList { tool in MyToolChip(tool) }
    HStack {
        VoiceDurationLabel()
        VoiceWaveform(source: .input)
        VoiceControlBar()      // pause/resume, mute, interrupt, stop
    }
    VoiceStatusLabel()
}
.voiceWaveformStyle(.bars)     // .bars, .rings, or a custom style

// Sheet presentation and composer entry point
.agentVoiceSheet(isPresented: $showVoice, session: voice)
AgentVoiceButton(session: voice)
```

- **Customizing:** the default view uses these same public components, which read
  the session from the environment, so hosts can replace one piece without forking.
  It also uses the existing `agentTheme`.
- **Presentation:** voice gets a dedicated sheet that is full height on macOS.
  Status changes use overlays, permissions reuse `AgentPermissionSheet`, and mobile
  interactions get haptics.
- **Host-only UI:** Chippy's globe and tool cards stay in the app and plug in
  through the builder.

## Package layout

- **`RxAgentVoice`:** session, protocols, audio, the realtime and pipeline engines,
  and the Apple speech adapters.
- **`RxAgentClients`:** gains `CodexVoiceEngine`.
- **`AgentVoiceUI`:** views only.
- **Kokoro:** stays outside the SDK behind `SpeechSynthesizing`, since Chippy runs
  it in a separate worker. This keeps ML dependencies out of the package.
- **`Agent`:** needs a small new API for appending voice turns to the thread, so the
  full transcript is there when the session ends.

## What comes from Chippy

**Worth porting**

- `LiveVoiceAudio`: the shared playback and capture graph.
- `UtteranceDetector` and `SpokenTextChunker`.
- `LocalSpeechRecognizer`: one analyzer per utterance.
- The credential shape: a server-minted URL, subprotocols and config.

**Gaps the SDK should fix**

- **Late local interruption:** `accept()` only interrupts after the utterance ends
  and is transcribed, so the agent talks over the user for that whole time.
- **No truncation:** the cloud path stops playback but never tells the server how
  much was heard, so the model assumes the user heard everything.
- **Fixed audio formats:** 16 kHz in and 24 kHz out are hard-coded, but OpenAI
  defaults to 24 kHz in and Codex sends its format with each chunk.
- **Device changes:** a route change that stops the audio engine ends the session.
- **Main-thread audio work:** each capture buffer is metered and sent from a
  main-actor task.

**Chippy's docs and code disagree**

- **Mac echo handling:** `docs/agent-voice-chat.md` says Mac uses playback
  suppression and has no spoken interruption, because voice processing caused
  faults. The code enables voice processing on every platform, while the Mac UI
  still says "microphone pauses during replies".
- **Tool timing:** the docs say tools wait for queued speech, but the cloud path
  runs them immediately.

## Still to verify

- **Codex:** whether the backend handles barge-in on its own, and whether
  `appendText` needs the `role` field our transport doesn't send.
- **OpenAI:** where `noise_reduction` sits in the session config, and whether
  `response.function_call_arguments.done` exists. Until then, read final tool
  arguments from `response.done`.
- **GPT-Live:** OpenAI also has this separate API at `/v1/live/sessions`. It is out
  of scope for v1 and can be added later as another dialect.
- **Apple speech:** `SpeechAnalyzer` is only used on macOS today, so iOS and
  visionOS still need checking.

## Open decisions

| Decision | Recommendation | Why it needs an answer |
|---|---|---|
| What should `.automatic` echo handling do on Mac? | Try voice processing and fall back to half-duplex if it fails at startup | A fault mid-session needs its own recovery, and Chippy's docs report DSP faults on desktop. This is the biggest unknown behind voice interruption on Mac. |
| Should tools be blocked while the agent is speaking its announcement? | Run them immediately, with a setting to opt out | Waiting keeps speech and work in order, but slow narration delays the work. |
| What should happen to permission prompts during voice? | Show the existing sheet, and deny by default if no resolver is set | Chippy's local voice currently denies approval-gated tools. Spoken approval is riskier, so it is out of v1. |

## Build order

1. `RxAgentVoice` with a scripted fake engine, so interruption and echo logic can be
   tested without audio hardware.
2. OpenAI engine.
3. Pipeline engine.
4. `AgentVoiceUI`.
5. Codex engine.
