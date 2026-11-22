import DebugSwiftCore
import Foundation

import SwiftUI

#if os(iOS)
@_spi(DebugSwiftUI) import DebugSwift
import UIKit
#endif

struct DebugSwiftFeatureDetail: View {
    let feature: DebugSwiftTool
    @State var output = ""
    @State var command = ""

    var body: some View {
        ScrollView {
            VStack(alignment: HorizontalAlignment.leading, spacing: 16) {
                Text(feature.summary)
                    .font(Font.body)

                if let inputHint {
                    TextField(inputHint, text: $command)
                }

                ForEach(actionIDs, id: \.self) { actionID in
                    Button(actionTitle(actionID)) {
                        if actionID == "refresh" {
                            refresh()
                        } else {
                            output = DebugSwiftRuntime.perform(featureID: feature.id, actionID: actionID, value: command)
                        }
                    }
                }

                Text("Live data")
                    .font(Font.headline)
                Text(output.isEmpty ? "Loading…" : output)
                    .font(Font.system(Font.TextStyle.footnote, design: Font.Design.monospaced))
                    .frame(maxWidth: CGFloat.infinity, alignment: Alignment.leading)
                    .padding(12)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

            }
            .padding()
        }
        .onAppear { refresh() }
    }

    func refresh() {
        output = DebugSwiftRuntime.snapshot(featureID: feature.id)
    }

    var actionIDs: [String] {
        switch feature.id {
        case "http":
            ["refresh", "filter_requests", "select_request", "clear", "export"]
        case "websocket":
            ["refresh", "filter_websockets", "select_connection", "select_frame", "filter_sent", "filter_received", "filter_all_frames", "copy_url", "copy_payload", "send_frame", "resend_frame", "close_connection", "clear_frames", "back_connections", "clear", "export"]
        case "har_export", "console", "crashes", "backtraces", "event_bus":
            ["refresh", "capture", "clear", "export"]
        case "oslog_console":
            ["refresh", "filter_logs", "export"]
        case "agent_debug_log":
            ["refresh", "toggle", "clear", "export"]
        case "memory_warning":
            ["refresh", "simulate_memory_warning"]
        case "graphql", "network_history":
            ["refresh", "filter_requests", "select_request", "clear", "export"]
        case "network_injection":
            ["refresh", "set_delay", "inject_failure", "set_http_error", "rewrite_response", "block_url", "toggle"]
        case "network_thresholds":
            ["refresh", "set_threshold", "toggle"]
        case "network_encryption":
            ["refresh", "register_key", "clear_keys"]
        case "preferences":
            ["refresh", "set_preference", "delete_preference", "clear_preferences", "export"]
        case "persistent_data":
            ["refresh", "set_preference", "delete_preference", "clear_preferences", "export"]
        case "files":
            ["refresh", "browse_files", "export"]
        case "realm":
            ["refresh", "export"]
        case "database", "core_data", "swift_data":
            ["refresh", "run_query", "export"]
        case "grid":
            ["refresh", "set_grid", "toggle", "capture"]
        case "doc_recorder":
            ["refresh", "capture", "clear", "export"]
        case "color_palette":
            ["refresh", "capture", "clear", "export"]
        case "animation_control":
            ["refresh", "open_animation_settings"]
        case "dark_mode":
            ["refresh", "toggle", "reset_dark_mode"]
        case "security_audit":
            ["refresh"]
        case "touches", "view_borders", "thread_checker", "performance_widget":
            ["refresh", "toggle", "capture"]
        case "push_simulator":
            ["refresh", "toggle", "notify", "simulate_template", "run_scenario", "set_notification_config", "add_template", "remove_template", "history_page", "interact_notification", "resend_notification", "remove_notification", "clear_push_history", "export", "open_notification_settings"]
        case "device_info", "push_token":
            ["refresh", "copy_token"]
        case "custom_info":
            #if os(Android)
            ["refresh", "report_info"]
            #else
            ["refresh"]
            #endif
        case "custom_actions":
            ["refresh", "run_custom"]
        default:
            ["refresh", "capture"]
        }
    }

    var inputHint: String? {
        switch feature.id {
        case "http", "graphql", "network_history": "Filter by URL, method, or body; enter a list number for details"
        case "websocket": "Filter URL/payload; enter #connection, #frame, text, or base64:<data>"
        case "oslog_console": "Filter log message or tag"
        case "network_injection": "Value: ms, status, pattern=>body, or URL pattern"
        case "network_thresholds": "Request limit,window seconds"
        case "network_encryption": "URL regex:base64 AES key (body is base64 nonce + AES-GCM ciphertext)"
        case "grid": "Spacing dp, optional color: 24,#663399FF"
        case "preferences", "persistent_data": "Store|key=value to write; Store|key to remove; Store|CLEAR to delete all"
        case "files": "App path: files/, cache/, or databases/"
        case "push_simulator": "Notification command or ID"
        case "database", "core_data", "swift_data": "Database name|SQL statement"
        case "custom_actions": "Registered action title"
        #if os(Android)
        case "custom_info": "Name=value"
        #endif
        default: nil
        }
    }

    func actionTitle(_ actionID: String) -> String {
        switch actionID {
        case "refresh": "Refresh"
        case "capture": "Capture"
        case "clear": "Clear history"
        case "export": "Export"
        case "filter_requests": "Apply filter"
        case "select_request": "Open request details"
        case "filter_websockets": "Filter connections and frames"
        case "select_connection": "Open connection"
        case "select_frame": "Open frame details"
        case "filter_sent": "Show sent frames"
        case "filter_received": "Show received frames"
        case "filter_all_frames": "Show all frames"
        case "copy_url": "Copy connection URL"
        case "copy_payload": "Copy selected payload"
        case "copy_token": "Copy push token"
        case "send_frame": "Send text or binary frame"
        case "resend_frame": "Resend selected frame"
        case "close_connection": "Close connection"
        case "clear_frames": "Clear selected connection frames"
        case "back_connections": "Back to connections"
        case "filter_logs": "Apply log filter"
        case "toggle": feature.id == "network_thresholds" ? "Toggle request blocking" : feature.id == "agent_debug_log" ? "Start / stop capture" : feature.id == "dark_mode" ? "Toggle dark appearance" : feature.id == "push_simulator" ? "Enable / disable simulation" : "Enable / disable"
        case "reset_dark_mode": "Follow system appearance"
        case "set_delay": "Set request delay"
        case "inject_failure": "Fail next request"
        case "set_http_error": "Set HTTP error code"
        case "rewrite_response": "Add response rewrite"
        case "block_url": "Block URL pattern"
        case "clear_keys": "Clear decryption keys"
        case "set_threshold": "Set request threshold"
        case "register_key": "Register AES key"
        case "set_grid": "Set grid spacing and color"
        case "simulate_memory_warning": "Simulate memory warning"
        case "set_preference": "Write preference"
        case "delete_preference": "Remove preference"
        case "clear_preferences": "Clear store (enter Store|CLEAR)"
        case "browse_files": "Open path"
        case "notify": "Post test notification"
        case "simulate_template": "Simulate from template"
        case "run_scenario": "Run test scenario"
        case "set_notification_config": "Update notification setting"
        case "add_template": "Add notification template"
        case "remove_template": "Remove notification template"
        case "history_page": "History page"
        case "interact_notification": "Simulate notification tap"
        case "resend_notification": "Send notification again"
        case "remove_notification": "Remove notification by ID"
        case "clear_push_history": "Clear history (enter CLEAR)"
        case "open_notification_settings": "Open notification permissions"
        case "open_animation_settings": "Open Developer options"
        case "run_query": "Run SQL query"
        case "run_custom": "Run registered action"
        case "report_info": "Save diagnostic value"
        default: actionID
        }
    }
}

@available(*, deprecated, renamed: "DebugSwiftRuntime")
public typealias DebugSwiftAndroidRuntime = DebugSwiftRuntime
