# Codex realtime voice (experimental)

`CodexClient.startRealtime(workingDirectory:resumeThreadID:voice:model:onRequest:)`
launches a persistent macOS app-server using existing Codex authentication and
opts into experimental APIs. It requests audio output over the WebSocket
transport; audio travels through app-server notifications and append calls.

```swift
let session = try await CodexClient().startRealtime(workingDirectory: projectURL)
let reader = Task {
    for await event in session.events {
        // Route thread/realtime/outputAudio/delta audio to playback.
        // Route transcript events to the transcript view.
        // Handle thread/realtime/error and thread/realtime/closed in the UI.
        // params retains the full experimental payload, including unknown fields.
        print(event.method)
    }
}
try await session.appendText("Explain this project")
// Feed capture buffers using appendAudio(_:sampleRate:channels:samplesPerChannel:).
// On dismissal:
try await session.stop()
reader.cancel()
```

WebSocket requires API key auth: Codex rejects a ChatGPT sign-in with "realtime
conversation requires API key auth". For ChatGPT sign-ins pass
`transport: .webRTC(offer:)` with a complete SDP offer containing an audio
transceiver and an `oai-events` data channel. Apply the answer from the
`thread/realtime/sdp` event. Audio then flows through the host's peer connection, so
`appendAudio` and `outputAudio/delta` aren't used; transcripts still arrive as
notifications. The SDK requests protocol `v3` for WebRTC, since Codex's `v1` default
is rejected by the backend.

The host must configure microphone permission, capture, conversion to the
installed server's PCM format, playback, and a dedicated voice sheet. Use a
full-height macOS sheet and action status overlays. Await audio appends to avoid
unbounded capture tasks. Handle output format metadata rather than assuming the
capture sample rate matches playback. Do not resume the same thread concurrently
in a separate client process.

All notifications, including coding turn notifications, are forwarded. Provide
`onRequest` to implement native approval dialogs; absent a handler, server
requests fail closed. `stop()` waits for the stop RPC; `close()` aborts immediately
and is appropriate for a stalled server. Always close on dismissal or task
cancellation. Unsupported versions and account access errors propagate rather
than falling back to a separately authenticated API.

Protocol reference checked 2026-11-05:
https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/realtime.rs

This SDK transport does not itself implement microphone hardware or a host UI.
Live account entitlement and hardware audio require separate validation.
