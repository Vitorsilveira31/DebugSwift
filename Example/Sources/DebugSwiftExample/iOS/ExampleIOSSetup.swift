#if os(iOS)
import CoreData
import DebugSwift
import Foundation
import UIKit
import UserNotifications

/// iOS-only sample data and system integrations: Core Data and SwiftData stores for the database
/// browser, and the push permission request behind the APNS token tool. Android's equivalents
/// (Room, FCM) are host hooks described in the README.
@MainActor
enum ExampleIOSSetup {
    static func run() {
        DiskWriteTracker.install()
        setupCoreData()
        setupSwiftData()
        requestPushNotificationPermissions()
    }

    private static func setupCoreData() {
        CoreDataExample.shared.setupDebugSwift()
        let context = CoreDataExample.shared.viewContext
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Person")
        if (try? context.count(for: request)) == 0 {
            CoreDataExample.shared.createSampleData()
        }
    }

    private static func setupSwiftData() {
        SwiftDataExample.shared.setupDebugSwift()
        SwiftDataExample.shared.createSampleDataIfNeeded()
    }

    private static func requestPushNotificationPermissions() {
        Task { @MainActor in
            DebugSwift.APNSToken.willRequestPermissions()
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                } else {
                    DebugSwift.APNSToken.didDenyPermissions()
                }
            } catch {
                print("Failed to request notification permissions: \(error)")
                DebugSwift.APNSToken.didFailToRegister(error: error)
            }
        }
    }

    /// Called by the iOS app delegate in `Darwin/Example/Main.swift`.
    static func didRegisterForRemoteNotifications(deviceToken: Data) {
        DebugSwift.APNSToken.didRegister(deviceToken: deviceToken)
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("📱 Registered for push notifications with token: \(token)")
    }

    static func didFailToRegisterForRemoteNotifications(error: Error) {
        DebugSwift.APNSToken.didFailToRegister(error: error)
        print("❌ Failed to register for push notifications: \(error.localizedDescription)")
    }
}
#endif
