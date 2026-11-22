import DebugSwiftCore
import Foundation

import SwiftUI

#if os(iOS)
@_spi(DebugSwiftUI) import DebugSwift
import UIKit
#endif

extension DebugSwiftArea {
    /// The areas `DebugSwift().setup(hideFeatures:)` did not hide, on both platforms.
    @MainActor
    static var visible: [DebugSwiftArea] {
        let visibleIDs = Set(DebugSwift.availableDebugFeatures().map(\.rawValue))
        return allCases.filter { visibleIDs.contains($0.id) }
    }
}
enum DebugSwiftArea: String, CaseIterable, Identifiable, Hashable {
    case network
    case performance
    case interface
    case resources
    case app

    var id: String { rawValue }

    var title: String {
        switch self {
        case .network: "Network"
        case .performance: "Performance"
        case .interface: "Interface"
        case .resources: "Resources"
        case .app: "App"
        }
    }

    var symbol: String {
        switch self {
        case .network: "point.3.connected.trianglepath.dotted"
        case .performance: "speedometer"
        case .interface: "rectangle.3.group"
        case .resources: "folder"
        case .app: "app.badge"
        }
    }

    @MainActor
    var features: [DebugSwiftTool] {
        switch self {
        case .network:
            let features: [DebugSwiftTool] = [
                .init("http", "HTTP Inspector", "Capture requests and responses, inspect bodies, filter traffic, and export request history."),
                .init("websocket", "WebSocket Inspector", "Inspect WebSocket connections, sent frames, and received frames."),
                .init("network_injection", "Network Injection", "Add request delay, failure, HTTP errors, and response body rewrite rules."),
                .init("network_thresholds", "Request Thresholds", "Count requests in a time window and optionally block after the limit."),
                .init("graphql", "GraphQL Inspector", "Identify GraphQL operations and inspect operation names and variables."),
                .init("network_encryption", "Response Decryption", "Register a URL-matched AES-GCM key for base64 response bodies."),
                .init("har_export", "HAR Export", "Export captured requests and responses as an HTTP Archive."),
                .init("webview_network", "WebView Network", "Capture navigation and resource requests made by embedded browser views."),
                .init("network_history", "Session History", "Search saved network sessions and export or clear their request history.")
            ]
            #if os(iOS)
            let availableIDs = Set(DebugSwift.availableNetworkFeatureIDs())
            return features.filter { availableIDs.contains($0.id) }
            #else
            return features
            #endif
        case .performance:
            let features: [DebugSwiftTool] = [
                .init("performance_overview", "Live Metrics", "Track CPU, memory, frames per second, and process activity."),
                .init("performance_widget", "Performance Widget", "Show live CPU, memory, and slow-frame metrics over the host app."),
                .init("battery", "Battery", "Inspect battery level, charging state, and power source."),
                .init("disk", "Disk I/O", "Inspect app storage size and process read/write byte counters."),
                .init("memory_warning", "Memory Warning", "Trigger the platform's low-memory callback path and inspect its response."),
                .init("frame_drops", "Frame Drops", "Record slow frames and inspect their timing on a timeline."),
                .init("hangs", DebugPlatform.isAndroid ? "Hangs and ANRs" : "Hangs", "Detect main thread stalls and inspect captured stack traces."),
                .init("backtraces", "Backtraces", "Capture and browse call stacks on demand."),
                .init("leaks", "Leak Detection", "Find UI objects that remain reachable after their expected lifetime."),
                .init("thread_checker", "Thread Checker", "Capture thread violations, inspect details, and configure dispatch handling."),
                .init("super_calls", "Lifecycle Super Calls", "Review lifecycle callback violations reported by the platform.")
            ]
            #if os(iOS)
            let availableIDs = Set(DebugSwift.availablePerformanceFeatureIDs())
            return features.filter { availableIDs.contains($0.id) }
            #else
            return features
            #endif
        case .interface:
            #if os(iOS)
            let availableIDs = Set(DebugSwift.availableInterfaceFeatureIDs())
            return [
                .init("view_hierarchy", "View Hierarchy", "Inspect the app window's UIKit and SwiftUI views, their frames and text."),
                .init("touches", "Showing touches", "Show touch feedback in the active app window."),
                .init("grid", "Grid overlay", "Draw a configurable alignment grid over the active app window."),
                .init("view_borders", "Colorized view borders", "Colorize native view borders to help identify layout boundaries."),
                .init("animations", "Slow animations", "Slow app animations to inspect transitions and motion."),
                .init("dark_mode", "Dark Mode", "Override the active app window appearance."),
                .init("measurement", "UI measurements", "Show element positions, sizes, and spacing."),
                .init("render_tracking", "SwiftUI render tracking", "Count SwiftUI renders and outline each view as it renders."),
                .init("doc_recorder", "Documentation Recorder", "Capture taps and scrolls, then save a screenshot annotated with numbered markers and arrows."),
                .init("color_palette", "Color Palette", "Sample the colors of the app's screen, ranked by how much of it they cover.")
            ].filter { availableIDs.contains($0.id) }
            #else
            return [
                .init("view_hierarchy", "View Hierarchy", "Inspect the active Android view tree and its measured bounds."),
                .init("grid", "Grid Overlay", "Draw a configurable alignment grid over the current app window."),
                .init("touches", "Touch Indicators", "Record touch locations and show visual feedback during interactions."),
                .init("view_borders", "View Borders", "Outline visible native views to locate spacing and clipping issues."),
                .init("animation_control", "Animation Settings", "Inspect the system animation scales and open Android Developer options to change them."),
                .init("dark_mode", "Dark Mode", "Override the host app appearance or follow the Android system setting."),
                .init("render_tracking", "Compose Render Tracking", "Record Compose composition activity and retain render counts."),
                .init("doc_recorder", "Documentation Recorder", "Capture taps and scrolls, then save a screenshot annotated with numbered markers and arrows."),
                .init("measurement", "Measurement Tool", "Inspect element positions, sizes, and spacing in the active window."),
                .init("color_palette", "Color Palette", "Sample colors from a captured screen image and export the palette.")
            ]
            #endif
        case .resources:
            #if os(iOS)
            let availableIDs = Set(DebugSwift.availableResourceFeatureIDs())
            return [
                .init("files", "Files", "Browse files in the app sandbox and shared containers."),
                .init("preferences", "User Defaults", "Inspect and compare registered preferences."),
                .init("keychain", "Keychain", "Browse app keychain items."),
                .init("persistent_data", "Persistent Data", "Inspect persistent app data."),
                .init("core_data", "Core Data", "Browse Core Data stores and entities."),
                .init("swift_data", "SwiftData Browser", "Inspect SwiftData models and records."),
                .init("http_cookies", "HTTP Cookies", "Inspect cookies stored by the app."),
                .init("database", "Database Browser", "Browse SQLite tables and rows."),
                .init("security_audit", "Security Audit", "Scan app resources for sensitive data.")
            ].filter { availableIDs.contains($0.id) }
            #else
            return [
                .init("files", "File Browser", "Browse the app sandbox, databases, cache, and exported files."),
                .init("preferences", "Preferences", "View and manage registered Android SharedPreferences values."),
                .init("keychain", "Secure Storage", "Inspect aliases in Android Keystore without exposing private key material."),
                .init("persistent_data", "Persistent Data", "Inspect app preferences and Android Keystore aliases together."),
                .init("database", "Database Browser", "Browse SQLite tables, rows, and run SQL queries."),
                .init("realm", "Realm Browser", "Inspect Realm databases registered by the host app."),
                .init("core_data", "Room Database", "Browse the Android database layer, including registered Room databases."),
                .init("swift_data", "Object Store", "Inspect SQLite or Room storage used in place of SwiftData on Android."),
                .init("http_cookies", "HTTP Cookies", "Inspect WebView cookies for app-owned domains."),
                .init("security_audit", "Security Audit", "Check app preferences, manifest metadata, bundled credentials, and private text files for sensitive data.")
            ]
            #endif
        case .app:
            /// The same tool described for the platform it runs on.
            func platform(_ ios: String, _ android: String) -> String {
                #if os(Android)
                android
                #else
                ios
                #endif
            }
            let features: [DebugSwiftTool] = [
                .init("crashes", "Crash Reports", "Save uncaught application crashes with stack traces and timestamps."),
                .init("console", "Console", "View, clear, and export messages written through the DebugSwift logger."),
                .init("oslog_console", "System Log", platform(
                    "Browse this app's OSLog entries, filter messages, and export the results.",
                    "Browse this app's Android Logcat records, filter messages, and export the results."
                )),
                .init("device_info", "Device Info", platform(
                    "Inspect app version, iOS version, device, display, and memory details.",
                    "Inspect app version, Android version, device, display, and memory details."
                )),
                .init("push_token", "Push Token", platform(
                    "Display the APNS device token the app registered.",
                    "Register and display an app-provided Firebase Cloud Messaging token."
                )),
                .init("push_simulator", "Push Notifications", "Manage notification permissions, templates, test scenarios, settings, and delivery history."),
                .init("custom_actions", "Custom Actions", "Register host-app actions and run them from the debugger."),
                .init("custom_info", "Custom Info", "Display diagnostic values supplied by the host app."),
                .init("deep_links", "Deep Links", platform(
                    "Open URLs and universal links in the app.",
                    "Inspect the current intent URI and registered app link information."
                )),
                .init("loaded_libraries", "Installed Libraries", platform(
                    "Inspect the frameworks and dynamic libraries loaded into the app.",
                    "Inspect installed DEX splits, native library paths, ABIs, and the runtime class loader."
                )),
                .init("location", "Location", "Inspect the last location reported by the host app."),
                .init("event_bus", "Event Timeline", "Browse network, performance, interface, app, and resource events."),
                .init("agent_debug_log", "Agent Debug Log", "Stream app events, network activity, console messages, and crashes to an NDJSON file.")
            ]
            #if os(iOS)
            let availableIDs = Set(DebugSwift.availableAppFeatureIDs())
            return features.filter { availableIDs.contains($0.id) }
            #else
            return features
            #endif
        }
    }
}
struct DebugSwiftTool: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String

    init(_ id: String, _ title: String, _ summary: String) {
        self.id = id
        self.title = title
        self.summary = summary
    }
}
struct DebugSwiftFeatureList: View {
    let area: DebugSwiftArea

    var body: some View {
        List(area.features) { feature in
            NavigationLink {
                DebugSwiftFeatureDestination(feature: feature)
                    .navigationTitle(feature.title)
            } label: {
                VStack(alignment: HorizontalAlignment.leading, spacing: 5) {
                    Text(feature.title)
                        .font(Font.headline)
                    Text(feature.summary)
                        .font(Font.caption)
                        .foregroundColor(Color.secondary)
                }
                .padding(Edge.Set.vertical, 4)
            }
        }
    }
}
