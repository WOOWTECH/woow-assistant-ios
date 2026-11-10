import SwiftUI

@main
struct WoowAssistantApp: App {
    @UIApplicationDelegateAdaptor(TaskNotificationAppDelegate.self) private var notificationDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
