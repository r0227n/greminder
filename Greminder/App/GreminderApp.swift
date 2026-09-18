import GreminderKit
import SwiftUI

@main
struct GreminderApp: App {
    #if os(iOS)
        @UIApplicationDelegateAdaptor(GreminderNotificationAppDelegate.self) private var appDelegate
    #else
        @NSApplicationDelegateAdaptor(GreminderNotificationAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
            // One account/session store owns the shared Google and notification services.
            Window("greminder", id: "main") {
                GreminderRootView()
            }
            .defaultSize(width: 1100, height: 850)
            .windowStyle(.hiddenTitleBar)
        #else
            WindowGroup {
                GreminderRootView()
            }
        #endif
    }
}
