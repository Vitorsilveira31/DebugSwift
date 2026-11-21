import DebugSwiftUI
import Foundation
import SwiftUI

/// Starts DebugSwift with the same calls on iOS and Android: `import DebugSwiftUI` gives
/// DebugSwift's API on both.
@MainActor
enum ExampleDebugger {
    private static var isStarted = false

    static func start() {
        guard !isStarted else { return }
        isStarted = true

        DebugSwiftRuntime.install(
            title: "DebugSwift",
            betaFeatures: [.swiftUIRenderTracking, .networkSessionPersistence, .agentDebugLog]
        )
        DebugSwift.Network.configureSessionHistory(retentionDays: 14, batchSize: 1)
        DebugSwift.PushNotification.enableSimulation()
        DebugSwift.App.shared.customInfo = { info }
        DebugSwift.App.shared.customAction = { actions }
        #if os(iOS)
        // Sample Core Data and SwiftData stores, the APNS token request and the disk tracker.
        ExampleIOSSetup.run()
        #endif

        // The Android instrumented tests look for this line in Console.
        DebugSwiftRuntime.log("Example app launched")
    }

    nonisolated static var actions: [CustomAction] {
        [
            CustomAction(title: "Environment Management", actions: [
                .init(title: "Clear Network History") {
                    DebugSwift.Network.shared.clearNetworkHistory()
                    print("✅ Network history cleared!")
                },
                .init(title: "Clear All Network Data") {
                    Task { @MainActor in
                        DebugSwift.Network.shared.clearAllNetworkData()
                        print("✅ All network data cleared!")
                    }
                },
                .init(title: "Switch to Development") {
                    DebugSwift.Network.shared.clearNetworkHistory()
                    print("✅ Switched to Development & cleared network history")
                },
                .init(title: "Switch to Production") {
                    DebugSwift.Network.shared.clearNetworkHistory()
                    print("✅ Switched to Production & cleared network history")
                }
            ]),
            CustomAction(title: "Development Tools", actions: [
                .init(title: "Reset Network Rules") {
                    DebugSwift.Network.shared.disableRequestDelay()
                    DebugSwift.Network.shared.disableFailureInjection()
                    DebugSwift.Network.shared.disableResponseBodyRewrite()
                },
                .init(title: "Delay Requests by 3 Seconds") {
                    DebugSwift.Network.shared.enableRequestDelay(3)
                },
                .init(title: "Log a Message") {
                    DebugSwiftRuntime.log("Hello from a custom action")
                }
            ])
        ]
    }

    nonisolated static var info: [CustomData] {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return [
            CustomData(title: "Example", infos: [
                .init(title: "Version", subtitle: "\(version) (\(build))"),
                .init(title: "Platform", subtitle: platformName),
                .init(title: "REST API", subtitle: "https://jsonplaceholder.typicode.com")
            ])
        ]
    }

    nonisolated static var platformName: String {
        #if os(Android)
        return "Android"
        #else
        return "iOS"
        #endif
    }
}
