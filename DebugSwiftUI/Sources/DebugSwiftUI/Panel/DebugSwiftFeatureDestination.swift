import DebugSwiftCore
import Foundation

import SwiftUI

#if os(iOS)
@_spi(DebugSwiftUI) import DebugSwift
import UIKit
#endif

struct DebugSwiftFeatureDestination: View {
    let feature: DebugSwiftTool

    @ViewBuilder
    var body: some View {
        #if os(iOS)
        if feature.id == "security_audit" {
            DebugSwiftSecurityAuditView()
        } else if feature.id == "grid" {
            DebugSwiftGridOverlaySettingsView()
        } else if feature.id == "network_thresholds" {
            DebugSwiftNetworkThresholdView()
        } else if feature.id == "network_injection" {
            DebugSwiftNetworkInjectionView()
        } else if feature.id == "console" {
            DebugSwiftConsoleView()
        } else if feature.id == "custom_actions" {
            // The same screen as Android: one button per action from `DebugSwift.App.shared.customAction`.
            DebugCustomActionsView()
        } else if feature.id == "custom_info" {
            DebugKeyValueView(featureID: feature.id, title: feature.title)
        } else if ["http", "graphql", "network_encryption", "har_export", "webview_network"].contains(feature.id) {
            DebugSwiftNetworkInspectorView(featureID: feature.id)
        } else if feature.id == "websocket" {
            DebugSwiftWebSocketInspectorView()
        } else if feature.id == "network_history" {
            DebugSwiftNetworkSessionHistoryView()
        } else if DebugPerformanceDestination.featureIDs.contains(feature.id) {
            DebugPerformanceDestination(featureID: feature.id)
        } else if ["touches", "view_borders", "animations", "dark_mode", "measurement"].contains(feature.id) {
            DebugSwiftInterfaceSettingView(featureID: feature.id)
        } else if feature.id == "view_hierarchy" {
            DebugViewHierarchyView()
        } else if feature.id == "render_tracking" {
            DebugComposeRendersView()
        } else if feature.id == "doc_recorder" {
            DebugDocRecorderView()
        } else if feature.id == "color_palette" {
            DebugColorPaletteView()
        } else if DebugAppDestination.featureIDs.contains(feature.id) {
            DebugAppDestination(feature: feature)
        } else if feature.id == "files" {
            DebugFilesView(path: "")
        } else if feature.id == "preferences" {
            DebugPreferencesView(includesKeystore: false)
        } else if feature.id == "http_cookies" {
            DebugCookiesView()
        } else if feature.id == "keychain" {
            DebugKeystoreView()
        } else if feature.id == "persistent_data" {
            DebugPreferencesView(includesKeystore: true)
        } else if ["core_data", "swift_data", "database"].contains(feature.id) {
            // Core Data and SwiftData stores are SQLite files: the database browser opens them.
            DebugDatabasesView(title: feature.title)
        } else {
            DebugSwiftFeatureDetail(feature: feature)
        }
        #else
        if feature.id == "view_hierarchy" {
            DebugViewHierarchyView()
        } else if feature.id == "measurement" {
            DebugMeasurementView()
        } else if feature.id == "color_palette" {
            DebugColorPaletteView()
        } else if feature.id == "animation_control" {
            DebugAnimationControlView()
        } else if DebugPerformanceDestination.featureIDs.contains(feature.id) {
            DebugPerformanceDestination(featureID: feature.id)
        } else if DebugAppDestination.featureIDs.contains(feature.id) {
            DebugAppDestination(feature: feature)
        } else if feature.id == "device_info" || feature.id == "custom_info" {
            DebugKeyValueView(featureID: feature.id, title: feature.title)
        } else if feature.id == "custom_actions" {
            DebugCustomActionsView()
        } else if feature.id == "push_token" {
            DebugPushTokenView()
        } else if feature.id == "realm" {
            DebugRealmView()
        } else if feature.id == "render_tracking" {
            DebugComposeRendersView()
        } else if feature.id == "doc_recorder" {
            DebugDocRecorderView()
        } else if feature.id == "files" {
            DebugFilesView(path: "")
        } else if feature.id == "preferences" || feature.id == "persistent_data" {
            DebugPreferencesView(includesKeystore: feature.id == "persistent_data")
        } else if feature.id == "keychain" {
            DebugKeystoreView()
        } else if ["database", "core_data", "swift_data"].contains(feature.id) {
            DebugDatabasesView(title: feature.title)
        } else if feature.id == "http_cookies" {
            DebugCookiesView()
        } else if feature.id == "security_audit" {
            DebugSwiftSecurityAuditView()
        } else if feature.id == "grid" {
            DebugSwiftGridOverlaySettingsView()
        } else if feature.id == "network_thresholds" {
            DebugSwiftNetworkThresholdView()
        } else if feature.id == "network_injection" {
            DebugSwiftNetworkInjectionView()
        } else if feature.id == "websocket" {
            DebugSwiftWebSocketInspectorView()
        } else if feature.id == "console" {
            DebugSwiftConsoleView()
        } else if ["http", "graphql", "network_encryption", "har_export", "webview_network"].contains(feature.id) {
            DebugSwiftNetworkInspectorView(featureID: feature.id)
        } else if feature.id == "network_history" {
            DebugSwiftNetworkSessionHistoryView()
        } else if ["touches", "view_borders", "dark_mode"].contains(feature.id) {
            DebugSwiftInterfaceSettingView(featureID: feature.id)
        } else {
            DebugSwiftFeatureDetail(feature: feature)
        }
        #endif
    }
}
/// The Performance tools: the same screens on iOS and Android, each reading its platform's data.
struct DebugPerformanceDestination: View {
    static let featureIDs: Set<String> = [
        "performance_overview", "performance_widget", "battery", "disk", "memory_warning",
        "frame_drops", "hangs", "backtraces", "leaks", "thread_checker", "super_calls"
    ]

    let featureID: String

    @ViewBuilder
    var body: some View {
        switch featureID {
        case "performance_overview": DebugLiveMetricsView()
        case "performance_widget": DebugPerformanceWidgetView()
        case "frame_drops": DebugFrameDropsView()
        case "hangs": DebugHangsView()
        case "backtraces": DebugBacktracesView()
        case "leaks": DebugLeaksView()
        case "thread_checker": DebugThreadCheckerView()
        case "super_calls": DebugSuperCallsView()
        case "memory_warning": DebugMemoryWarningView()
        case "battery": DebugBatteryView()
        case "disk": DebugDiskView()
        default: EmptyView()
        }
    }
}
/// The App tools that use the same screens on iOS and Android, each reading its platform's data.
struct DebugAppDestination: View {
    static let featureIDs: Set<String> = [
        "crashes", "oslog_console", "location", "deep_links", "event_bus", "agent_debug_log",
        "loaded_libraries", "push_simulator"
    ]

    let feature: DebugSwiftTool

    @ViewBuilder
    var body: some View {
        switch feature.id {
        case "crashes": DebugCrashesView()
        case "oslog_console": DebugLogcatView()
        case "location": DebugLocationView()
        case "deep_links": DebugDeepLinksView()
        case "event_bus": DebugLinesView(featureID: feature.id, title: feature.title)
        case "agent_debug_log": DebugAgentLogView()
        case "loaded_libraries": DebugLibrariesView()
        case "push_simulator": DebugPushNotificationsView()
        default: EmptyView()
        }
    }
}
