import RxAgentSDK
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AgentTestbedModel
    /// `Agent` is `@Observable`, so bind to it directly — `model.agent` is a
    /// `let`, which `@Bindable` cannot project through.
    @Bindable private var agent: Agent

    @State private var isChoosingDirectory = false
    @State private var sidebar: SidebarTab = .sessions

    init(model: AgentTestbedModel) {
        self.model = model
        self.agent = model.agent
    }

    enum SidebarTab: String, CaseIterable, Identifiable {
        case sessions = "History"
        case events = "Events"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            // The whole point of the SDK: one line for a working chat surface.
            AgentChatView(agent: model.agent)
                .toolbar { toolbarContent }
        }
        .fileImporter(
            isPresented: $isChoosingDirectory,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                model.setWorkingDirectory(url)
            }
        }
    }

    // MARK: Sidebar

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            Picker("", selection: $sidebar) {
                ForEach(SidebarTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            switch sidebar {
            case .sessions: sessionList
            case .events: eventLog
            }

            Divider()
            workspaceFooter
        }
    }

    private var sessionList: some View {
        List {
            if model.pastSessions.isEmpty {
                ContentUnavailableView(
                    "No past sessions",
                    systemImage: "clock",
                    description: Text("Claude Code transcripts for this directory appear here.")
                )
            }
            ForEach(model.pastSessions) { summary in
                Button {
                    Task { await model.resume(summary) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.title)
                            .lineLimit(2)
                            .font(.callout)
                        Text("\(summary.messageCount) messages · \(summary.modifiedAt.formatted(.relative(presentation: .numeric)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
    }

    /// A live view of the normalized event stream. When a decoder misbehaves,
    /// this is where it shows.
    private var eventLog: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(model.eventLog.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(line.hasPrefix("failed") ? .red : .secondary)
                        .id(index)
                }
            }
            .listStyle(.plain)
            .onChange(of: model.eventLog.count) { _, count in
                guard count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }

    private var workspaceFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isChoosingDirectory = true
            } label: {
                Label(model.agent.workingDirectory.lastPathComponent, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .buttonStyle(.plain)
            .help(model.agent.workingDirectory.path)

            Text(model.agent.workingDirectory.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Mode", selection: $agent.permissionMode) {
                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .help("Permission mode")
        }

        // Reasoning effort. Draws nothing when the active client has no such
        // dial, so it costs the toolbar nothing to keep it here.
        ToolbarItem(placement: .navigation) {
            AgentReasoningPicker(agent: agent)
                .help("Reasoning effort")
        }

        ToolbarItem {
            Toggle("Plan", isOn: $agent.planMode)
                .toggleStyle(.button)
                .help("Ask the agent to plan before acting")
        }

        ToolbarItem {
            Button {
                model.agent.newThread()
                Task { await model.refreshSessions() }
            } label: {
                Label("New Thread", systemImage: "square.and.pencil")
            }
        }

        ToolbarItem {
            Button {
                model.clearLog()
            } label: {
                Label("Clear Log", systemImage: "trash")
            }
            .help("Clear the event log")
        }
    }
}

#Preview {
    ContentView(model: AgentTestbedModel())
        .frame(width: 1000, height: 700)
}
