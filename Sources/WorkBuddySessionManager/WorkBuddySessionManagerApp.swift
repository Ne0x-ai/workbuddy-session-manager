import SwiftUI

struct WorkBuddySessionManagerApp: App {
    var body: some Scene {
        WindowGroup("WorkBuddy 会话管理") {
            ContentView()
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
