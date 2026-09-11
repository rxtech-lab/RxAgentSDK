// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "RxAgentSDK",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        // One product. `import RxAgentSDK` re-exports every module, and the
        // individual modules (AgentMarkdownUI, AgentMessageListUI, …) remain
        // importable by name for anyone who wants just one of them.
        .library(name: "RxAgentSDK", targets: ["RxAgentSDK"]),
    ],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),
    ],
    targets: [
        // MARK: - Pure models & streaming reducers (all platforms)

        .target(name: "RxAgentCore"),

        // MARK: - Tool / context / skill DSL. The only target importing FoundationModels.

        .target(name: "RxAgentContext", dependencies: ["RxAgentCore"]),

        // MARK: - macOS-only machinery. Contents are `#if os(macOS)`; empty module elsewhere.

        .target(name: "RxAgentProcess", dependencies: ["RxAgentCore"]),
        .target(
            name: "RxAgentBridge",
            dependencies: ["RxAgentCore", "RxAgentContext", "RxAgentProcess"]
        ),
        .target(
            name: "RxAgentClients",
            dependencies: ["RxAgentCore", "RxAgentContext", "RxAgentProcess", "RxAgentBridge"]
        ),

        // MARK: - CLI transcript history (unguarded; simply finds nothing on iOS)

        .target(name: "RxAgentSessions", dependencies: ["RxAgentCore"]),

        // MARK: - SwiftUI

        .target(name: "RxAgentUISupport"),
        .target(name: "AgentMarkdownUI", dependencies: ["RxAgentUISupport"]),
        .target(
            name: "AgentMessageListUI",
            dependencies: ["RxAgentUISupport"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .target(
            name: "AgentChatUI",
            dependencies: [
                "RxAgentCore",
                "RxAgentContext",
                "AgentMarkdownUI",
                "AgentMessageListUI",
                "RxAgentUISupport",
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),

        // MARK: - Umbrella

        .target(
            name: "RxAgentSDK",
            dependencies: [
                "RxAgentCore",
                "RxAgentContext",
                "RxAgentProcess",
                "RxAgentBridge",
                "RxAgentClients",
                "RxAgentSessions",
                "AgentMarkdownUI",
                "AgentMessageListUI",
                "AgentChatUI",
            ]
        ),

        // MARK: - Tests

        .testTarget(name: "RxAgentCoreTests", dependencies: ["RxAgentCore"]),
        .testTarget(name: "RxAgentContextTests", dependencies: ["RxAgentContext"]),
        .testTarget(name: "RxAgentProcessTests", dependencies: ["RxAgentProcess"]),
        .testTarget(name: "RxAgentBridgeTests", dependencies: ["RxAgentBridge"]),
        .testTarget(name: "RxAgentSessionsTests", dependencies: ["RxAgentSessions"]),
        .testTarget(name: "RxAgentClientsTests", dependencies: ["RxAgentClients"]),
        .testTarget(name: "AgentMarkdownUITests", dependencies: ["AgentMarkdownUI"]),
        .testTarget(
            name: "AgentChatUITests",
            dependencies: [
                "AgentChatUI",
                .product(name: "ViewInspector", package: "ViewInspector"),
            ]
        ),
        .testTarget(
            name: "AgentMessageListUITests",
            dependencies: [
                "AgentMessageListUI",
                .product(name: "ViewInspector", package: "ViewInspector"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
