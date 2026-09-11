import RxAgentCore
import SwiftUI

/// The foot of the transcript: pulsing dots while a turn is in flight, and the
/// thread's running token total.
///
/// It is a transcript row rather than chrome so it scrolls with the
/// conversation — parked at the end of the last answer, which is where the eye
/// already is when it is waiting for the next one.
public struct AgentStreamingIndicator: View {
    private let isStreaming: Bool
    private let usage: UsageInfo?

    @State private var animating = false
    @Environment(\.agentTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(isStreaming: Bool, usage: UsageInfo? = nil) {
        self.isStreaming = isStreaming
        self.usage = usage
    }

    public var body: some View {
        HStack(spacing: 8) {
            if isStreaming { dots }
            if let tokens, tokens > 0 {
                Text("\(tokens.formatted()) tokens")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isStreaming ? "Working" : "")
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(theme.secondaryText.opacity(0.6))
                    .frame(width: 6, height: 6)
                    .scaleEffect(animating ? 1.0 : 0.5)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        // Reduce Motion still gets the row — it just holds still, so the reader
        // keeps the "something is happening" signal without the pulse.
        .onAppear { animating = !reduceMotion }
        .accessibilityHidden(true)
    }

    /// What the turn has cost so far. Cache reads are excluded: they are the
    /// cheap half and folding them in makes a resumed thread look far more
    /// expensive than it was.
    private var tokens: Int? {
        guard let usage else { return nil }
        return usage.inputTokens + usage.outputTokens
    }
}
