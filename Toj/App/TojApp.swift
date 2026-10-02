import SwiftUI

@main
struct TojApp: App {
    @UIApplicationDelegateAdaptor(TojAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
