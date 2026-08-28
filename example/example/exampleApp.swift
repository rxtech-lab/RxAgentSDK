import RxAgentSDK
import SwiftUI

@main
struct exampleApp: App {
    @State private var model = AgentTestbedModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Thread") { model.agent.newThread() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
