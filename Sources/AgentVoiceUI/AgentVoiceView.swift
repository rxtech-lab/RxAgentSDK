import SwiftUI
import RxAgentVoice

/// Mode selection is presented separately from the active conversation.
public struct AgentVoiceView: View {
    private let runner: VoiceRunner
    @State private var choosingMode = false
    @State private var error: String?
    @State private var feedback = 0
    public init(runner: VoiceRunner) { self.runner = runner }
    public var body: some View {
        NavigationStack {
            Group {
                if let session = runner.session {
                    List(session.transcript) { entry in
                        Text(entry.text).textSelection(.enabled)
                            .accessibilityLabel("\(entry.isUser ? "You" : "Assistant"): \(entry.text)")
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button(session.isMuted ? "Unmute" : "Mute") { session.setMuted(!session.isMuted); feedback += 1 }
                            Button(session.lifecycle == .paused ? "Resume" : "Pause") {
                                if session.lifecycle == .paused { session.resume() } else { session.pause() }
                                feedback += 1
                            }
                            Button("Interrupt") { session.interrupt(); feedback += 1 }
                            Button("Stop", role: .destructive) { Task { await runner.stop(); feedback += 1 } }
                        }
                    }
                } else { ContentUnavailableView("Voice", systemImage: "waveform", description: Text("Choose a voice mode to begin.")) }
            }
            .navigationTitle("Voice")
            .toolbar { Button("Voice mode") { choosingMode = true; feedback += 1 } }
            .overlay { if runner.isSwitching { ProgressView("Connecting…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 560)
        #endif
        .sensoryFeedback(.selection, trigger: feedback)
        .sheet(isPresented: $choosingMode) {
            NavigationStack {
                List(runner.modes) { mode in
                    Button(mode.title) {
                        choosingMode = false
                        Task { do { try await runner.select(mode.id); feedback += 1 } catch { self.error = String(describing: error) } }
                    }.disabled(runner.isSwitching)
                }
                .navigationTitle("Voice mode")
                .toolbar { Button("Cancel") { choosingMode = false } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 480)
            #endif
        }
        .alert("Voice unavailable", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .onDisappear { Task { await runner.stop() } }
    }
}
public extension View {
    func agentVoiceSheet(isPresented: Binding<Bool>, runner: VoiceRunner) -> some View {
        sheet(isPresented: isPresented) { AgentVoiceView(runner: runner) }
    }
}
