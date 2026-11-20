import DebugSwiftCore
import DebugSwiftUI
import Foundation
import SwiftUI

/// Starts DebugSwift and describes the debug panel the Example shows on both platforms.
@MainActor
enum ExampleDebugger {
    private static var isStarted = false

    static func start() {
        guard !isStarted else { return }
        isStarted = true
        install(showsFloatingButton: true)
        #if os(iOS)
        // Sample Core Data and SwiftData stores, the APNS token and other iOS-only integrations.
        ExampleIOSSetup.run()
        #endif
        // The Android instrumented tests look for this line in Console.
        DebugSwiftRuntime.log("Example app launched")
    }

    /// Installs DebugSwift with the Example's panel content. Calling it again keeps everything else.
    static func install(showsFloatingButton: Bool = DebugSwiftRuntime.isFloatingButtonVisible) {
        DebugSwiftRuntime.install(
            title: "DebugSwift",
            actions: actions,
            info: info,
            betaFeatures: [.swiftUIRenderTracking, .networkSessionPersistence, .agentDebugLog],
            showsFloatingButton: showsFloatingButton
        )
    }

    static var actions: [DebugActionGroup] {
        [
            DebugActionGroup(title: "Environment Management", actions: [
                .init(title: "Clear Network History") {
                    clearNetworkHistory()
                    print("✅ Network history cleared!")
                },
                .init(title: "Switch to Development") {
                    clearNetworkHistory()
                    print("✅ Switched to Development & cleared network history")
                },
                .init(title: "Switch to Production") {
                    clearNetworkHistory()
                    print("✅ Switched to Production & cleared network history")
                }
            ]),
            DebugActionGroup(title: "Development Tools", actions: [
                .init(title: "Reset Network Rules") {
                    ExampleNetworkRules.reset()
                },
                .init(title: "Log a Message") {
                    DebugSwiftRuntime.log("Hello from a custom action")
                }
            ])
        ]
    }

    static var info: [DebugInfoGroup] {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return [
            DebugInfoGroup(title: "Example", items: [
                .init(title: "Version", value: "\(version) (\(build))"),
                .init(title: "Platform", value: platformName),
                .init(title: "REST API", value: "https://jsonplaceholder.typicode.com")
            ])
        ]
    }

    static var platformName: String {
        #if os(Android)
        return "Android"
        #else
        return "iOS"
        #endif
    }

    private static func clearNetworkHistory() {
        #if os(iOS)
        ExampleIOSSetup.clearNetworkHistory()
        #endif
        Task { await NetworkRecorder.shared.clear() }
    }
}
