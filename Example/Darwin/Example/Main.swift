import DebugSwiftExample
import SwiftUI

private typealias AppRootView = DebugSwiftExampleRootView
private typealias AppDelegate = DebugSwiftExampleAppDelegate

/// The iOS entry point: it only hosts the shared app from the DebugSwiftExample module.
@main struct AppMain: App {
    @UIApplicationDelegateAdaptor(AppMainDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                AppDelegate.shared.onResume()
            case .inactive:
                AppDelegate.shared.onPause()
            case .background:
                AppDelegate.shared.onStop()
            @unknown default:
                print("unknown app phase: \(newPhase)")
            }
        }
    }
}

/// The few callbacks iOS delivers only to an application delegate.
@MainActor final class AppMainDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppDelegate.shared.onInit()
        return true
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppDelegate.shared.onLaunch()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppDelegate.shared.onDestroy()
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        AppDelegate.shared.onLowMemory()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppDelegate.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        AppDelegate.shared.didFailToRegisterForRemoteNotifications(error: error)
    }
}
