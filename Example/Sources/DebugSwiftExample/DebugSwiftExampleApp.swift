import Foundation
import SwiftUI

/// The app's root view, shared by both hosts: `Darwin/Example/Main.swift` on iOS and
/// `Android/app/src/main/kotlin/Main.kt` on Android.
public struct DebugSwiftExampleRootView: View {
    public init() {}

    public var body: some View {
        ContentView()
    }
}

/// App lifecycle callbacks, called by both hosts.
public final class DebugSwiftExampleAppDelegate: Sendable {
    public static let shared = DebugSwiftExampleAppDelegate()

    private init() {}

    public func onInit() {}

    public func onLaunch() {
        Task { @MainActor in
            ExampleDebugger.start()
        }
    }

    public func onResume() {}

    public func onPause() {}

    public func onStop() {}

    public func onDestroy() {}

    public func onLowMemory() {}

    #if os(iOS)
    /// Forwarded by the iOS app delegate for the APNS token tool.
    // SKIP @nobridge
    public func didRegisterForRemoteNotifications(deviceToken: Data) {
        Task { @MainActor in
            ExampleIOSSetup.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    // SKIP @nobridge
    public func didFailToRegisterForRemoteNotifications(error: any Error) {
        Task { @MainActor in
            ExampleIOSSetup.didFailToRegisterForRemoteNotifications(error: error)
        }
    }
    #endif
}
