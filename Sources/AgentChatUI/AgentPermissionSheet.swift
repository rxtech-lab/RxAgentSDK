import RxAgentCore
import SwiftUI

/// Presents a pending tool-call approval and collects the answer.
public struct AgentPermissionSheet: View {
    private let request: PermissionRequest
    private let onDecide: (PermissionDecision) -> Void

    @State private var feedback = ""
    @State private var isWritingFeedback = false
    @Environment(\.agentTheme) private var theme

    public init(
        request: PermissionRequest,
        onDecide: @escaping (PermissionDecision) -> Void
    ) {
        self.request = request
        self.onDecide = onDecide
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            detail
            Divider()
            actions
        }
        .padding(20)
        .frame(width: 460)
        .background(theme.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: request.category.systemImage)
                .font(.system(size: 18))
                .foregroundStyle(isDestructive ? theme.danger : theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow \(request.toolName)?")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        switch request.category {
        case .execution: "The agent wants to run a command."
        case .fileModification: "The agent wants to modify a file."
        case .mcp: "The agent wants to call an external tool."
        case .readOnly: "The agent wants to read from your workspace."
        case .unknown: "The agent wants to use a tool."
        }
    }

    private var isDestructive: Bool {
        request.category == .execution || request.category == .fileModification
    }

    @ViewBuilder
    private var detail: some View {
        if let command = request.command {
            ScrollView {
                Text(command)
                    .font(theme.monoFont)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .padding(10)
            .background(theme.toolChrome, in: .rect(cornerRadius: 8))
        } else if !request.toolInput.isEmpty {
            ScrollView {
                Text(JSONValue.object(request.toolInput).jsonString)
                    .font(theme.monoFont)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .padding(10)
            .background(theme.toolChrome, in: .rect(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var actions: some View {
        if isWritingFeedback {
            VStack(alignment: .leading, spacing: 8) {
                TextField("What should it do instead?", text: $feedback, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                HStack {
                    Button("Back") { isWritingFeedback = false }
                    Spacer()
                    Button("Send feedback") {
                        onDecide(.denyWithReason(reason: feedback))
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } else {
            HStack(spacing: 10) {
                Button("Deny") { onDecide(.deny) }
                    .accessibilityIdentifier("permission-deny")

                Button("Deny with feedback…") { isWritingFeedback = true }

                Spacer(minLength: 0)

                // Only offered for commands, where "this exact string" is a
                // meaningful unit to remember.
                if let command = request.command {
                    Button("Always allow this command") {
                        onDecide(.allowAlwaysCommand(command: command))
                    }
                }

                Button("Allow") { onDecide(.allow) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("permission-allow")
            }
        }
    }
}

// MARK: - Interactive resolver

/// Bridges the transport's `await` to a SwiftUI presentation.
///
/// The continuation lives here rather than in the approval server, which is
/// what keeps the transport layer free of UI coupling. `ApprovalServer` simply
/// awaits `resolve(_:)` and this decides when to answer.
@MainActor @Observable
public final class InteractivePermissionCoordinator: PermissionResolving {
    /// The request currently awaiting an answer, for the UI to present.
    public private(set) var pending: PermissionRequest?

    /// Tools allowed for the rest of this run.
    @ObservationIgnored private var allowedTools: Set<String> = []
    /// Commands allowed for the rest of this run.
    @ObservationIgnored private var allowedCommands: Set<String> = []
    @ObservationIgnored private var continuation: CheckedContinuation<PermissionDecision, Never>?
    @ObservationIgnored private var queue: [(PermissionRequest, CheckedContinuation<PermissionDecision, Never>)] = []

    public init() {}

    nonisolated public func resolve(_ request: PermissionRequest) async -> PermissionDecision {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                enqueue(request, continuation)
            }
        }
    }

    private func enqueue(
        _ request: PermissionRequest,
        _ continuation: CheckedContinuation<PermissionDecision, Never>
    ) {
        // Standing allowances answer immediately, without a prompt.
        if allowedTools.contains(request.toolName) {
            continuation.resume(returning: .allow)
            return
        }
        if let command = request.command, allowedCommands.contains(command) {
            continuation.resume(returning: .allow)
            return
        }
        if request.mode == .bypassPermissions {
            continuation.resume(returning: .allow)
            return
        }

        guard pending == nil else {
            queue.append((request, continuation))
            return
        }
        pending = request
        self.continuation = continuation
    }

    /// Answer the pending request and present the next queued one, if any.
    public func respond(_ decision: PermissionDecision) {
        guard let continuation else { return }
        self.continuation = nil

        switch decision {
        case .allowSessionTool:
            if let pending { allowedTools.insert(pending.toolName) }
        case .allowAlwaysCommand(let command):
            allowedCommands.insert(command)
        default:
            break
        }

        pending = nil
        continuation.resume(returning: decision)

        if !queue.isEmpty {
            let (request, next) = queue.removeFirst()
            enqueue(request, next)
        }
    }

    /// Deny everything outstanding — used when a turn is cancelled.
    public func cancelAll() {
        continuation?.resume(returning: .deny)
        continuation = nil
        pending = nil
        for (_, waiting) in queue { waiting.resume(returning: .deny) }
        queue.removeAll()
    }
}
