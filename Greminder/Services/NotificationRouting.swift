import Foundation
import UserNotifications

enum NotificationRouting {
    static let taskKeyField = "greminder.task-key"
    static let taskPrefix = "greminder.task."

    static func isSampleTask(_ key: String) -> Bool {
        key.hasPrefix(NotificationPlanner.scope(nil) + ".")
    }

    static func key(identifier: String) -> String? {
        guard identifier.hasPrefix(taskPrefix) else { return nil }
        let key = String(identifier.dropFirst(taskPrefix.count))
        return key.isEmpty ? nil : key
    }

    static func key(request: UNNotificationRequest, actionIdentifier: String) -> String? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return nil }
        if let key = request.content.userInfo[taskKeyField] as? String, !key.isEmpty { return key }
        // Existing scheduled and delivered notifications already contain this identity.
        return key(identifier: request.identifier)
    }
}

/// Retains a cold-launch tap until the root view subscribes. Only the latest tap is relevant.
@MainActor
final class NotificationResponseBuffer {
    private let channel = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var stream: AsyncStream<String> { channel.stream }

    func receive(_ key: String) { channel.continuation.yield(key) }
}

// Register before launch finishes, including when a notification starts a terminated app.
#if os(iOS)
    import UIKit

    public final class GreminderNotificationAppDelegate: NSObject, UIApplicationDelegate {
        public func application(
            _ application: UIApplication,
            willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil,
        ) -> Bool {
            LocalNotificationSystem.shared.start()
            return true
        }
    }
#else
    import AppKit

    public final class GreminderNotificationAppDelegate: NSObject, NSApplicationDelegate {
        public func applicationWillFinishLaunching(_ notification: Notification) {
            LocalNotificationSystem.shared.start()
        }
    }
#endif
