#if DEBUG
import SwiftUI

// MARK: - Sample documents

enum MarkdownPreviewSamples {
    static let kitchenSink = """
    # Dynamic spacing

    The list reserves a **tail spacer** so the pinned message stays put while the
    answer streams in. See `MessageList.swift` for the *ratcheting* detail.

    ## How it works

    1. The user message pins to the top of the viewport.
    2. The answer grows into the reserved space below it.
    3. Once that space is consumed, the list follows the bottom.

    - Measured in a named coordinate space
    - Committed only from the scroll-geometry callback
    - [Read the source](https://example.com/message-list)

    | Constant | Value | Why |
    | --- | --- | --- |
    | `loadThreshold` | 96 | Distance before paging fires |
    | `minimumPinnedTailSpacing` | 16 | Gap kept below the turn |
    | `scrollAnimationSeconds` | 0.18 | Matches the pin animation |

    > The ratchet is monotonic: a half-settled layout pass must never be able to
    > shrink the measured turn height.

    ---

    Inline `code spans` sit alongside prose without breaking the line rhythm.
    """

    static let codeBlocks = #"""
    A Swift declaration:

    ```swift
    public struct MessageList<Message: MessageListItem, RowContent: View>: View {
        public init(messages: [Message], isStreaming: Bool = false) { /* ... */ }
    }
    ```

    Some Python:

    ```python
    def spacer_height(viewport: float, turn: float, minimum: float = 16) -> float:
        """Height of the reserved tail spacer."""
        return max(0, viewport - turn - minimum)
    ```

    JSON, as an agent would emit it:

    ```json
    {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "hi"}}
    ```

    And a fence with no language tag at all:

    ```
    plain preformatted text
    ```
    """#

    /// Streamed in pieces so the fade and the 16 ms coalescer are both visible.
    static let streamingChunks: [String] = [
        "## Streaming\n\n",
        "Text fades in as it arrives. ",
        "Only the **newly appended** range animates — ",
        "the prefix stays fully opaque, which is what stops a growing ",
        "block from re-blinking on every token.\n\n",
        "```swift\nlet spacer = max(0, viewport - turn - 16)\n```\n\n",
        "| Token | Fades |\n| --- | --- |\n| prefix | no |\n| suffix | yes |\n",
    ]
}

// MARK: - Streaming harness

/// Appends text on a timer so the fade-in and stream throttle can be watched.
struct MarkdownStreamingPreview: View {
    @State private var text = ""
    @State private var chunkIndex = 0
    @State private var isRunning = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(isRunning ? "Pause" : "Resume") { isRunning.toggle() }
                Button("Restart") {
                    text = ""
                    chunkIndex = 0
                    isRunning = true
                }
                Spacer()
                Text("\(text.count) chars").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            Divider()

            ScrollView {
                MarkdownView(
                    text: text,
                    showsTrailingCursor: chunkIndex < MarkdownPreviewSamples.streamingChunks.count,
                    fadeNewText: true
                )
                .padding()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(220))
                guard isRunning else { continue }
                guard chunkIndex < MarkdownPreviewSamples.streamingChunks.count else { continue }
                text += MarkdownPreviewSamples.streamingChunks[chunkIndex]
                chunkIndex += 1
            }
        }
    }
}

// MARK: - Previews

#Preview("Markdown / Kitchen sink") {
    ScrollView {
        MarkdownView(text: MarkdownPreviewSamples.kitchenSink)
            .padding()
    }
}

#Preview("Markdown / Code blocks") {
    ScrollView {
        MarkdownView(text: MarkdownPreviewSamples.codeBlocks)
            .padding()
    }
}

#Preview("Markdown / Streaming") {
    MarkdownStreamingPreview()
}

#Preview("Markdown / Dark") {
    ScrollView {
        MarkdownView(text: MarkdownPreviewSamples.kitchenSink)
            .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Markdown / Custom style") {
    var style = MarkdownStyle()
    style.bodyFontSize = 17
    style.accentColor = .purple
    style.blockSpacing = 18
    return ScrollView {
        MarkdownView(text: MarkdownPreviewSamples.kitchenSink, style: style)
            .padding()
    }
}
#endif
