import DebugSwiftCore
import Foundation

import SwiftUI

#if os(iOS)
@_spi(DebugSwiftUI) import DebugSwift
import UIKit
#endif

/// DebugSwift's entry point on iOS and Android: one `install` at launch, and the panel to show.
///
///     DebugSwiftRuntime.install(actions: [...], betaFeatures: [.agentDebugLog])
///     .sheet(isPresented: $showsDebugger) { DebugSwiftRuntime.panel { showsDebugger = false } }
///
/// On iOS it sets up the DebugSwift debugger and makes its floating ball open the shared panel. On
/// Android it starts the Kotlin runtime (crash, ANR, frame and log capture), the capture of Swift
/// `URLSession` traffic, and the floating button.
public enum DebugSwiftRuntime {
    @MainActor static var panelTitle = "Debug"
    @MainActor static var panelTools: [DebugTool] = []
    @MainActor static var panelActions: [DebugActionGroup] = []
    @MainActor static var panelInfo: [DebugInfoGroup] = []

    #if os(iOS)
    /// Settable within the module so tests can open the panel as for the first time.
    @MainActor static var isIOSDebuggerPrepared = false
    @MainActor private static var isIOSFloatingBallVisible = false

    @MainActor
    static func prepareIOSDebugger(betaFeatures: [DebugSwiftBetaFeature] = []) {
        guard !isIOSDebuggerPrepared else { return }
        // The host's own setup keeps its hidden features and disabled methods; only set up when
        // nothing did.
        if !SharedPanelData.isDebugSwiftSetUp {
            DebugSwift().setup(enableBetaFeatures: betaFeatures)
        }
        SharedPanelData.prepare()
        isIOSDebuggerPrepared = true
    }

    /// Records that the host already ran `DebugSwift().setup()`, so the hosted UIKit screens do not run it again.
    @MainActor
    static func markIOSDebuggerPrepared() {
        SharedPanelData.prepare()
        isIOSDebuggerPrepared = true
    }
    #endif

    /// Starts DebugSwift. Call it once at launch; calling it again only updates the panel's content.
    ///
    /// - Parameters:
    ///   - title: The panel's title.
    ///   - tools: The host's own screens, listed at the top of the panel.
    ///   - actions: Buttons that run host code, for example "Clear user data".
    ///   - info: Read-only rows, for example the API URL.
    ///   - betaFeatures: Features still in beta to turn on.
    ///   - showsFloatingButton: Shows the floating button that opens the panel.
    /// - Returns: Whether the platform runtime is running.
    @discardableResult
    @MainActor
    public static func install(
        title: String = "Debug",
        tools: [DebugTool] = [],
        actions: [DebugActionGroup] = [],
        info: [DebugInfoGroup] = [],
        betaFeatures: [DebugSwiftBetaFeature] = [],
        showsFloatingButton: Bool = true
    ) -> Bool {
        panelTitle = title
        panelTools = tools
        panelActions = actions
        panelInfo = info
        #if os(iOS)
        prepareIOSDebugger(betaFeatures: betaFeatures)
        // The floating ball and `DebugSwift.App.presentDebugger()` open the same panel Android shows.
        DebugSwift.App.shared.panelProvider = {
            DebugSwiftSharedPanelController(
                rootView: AnyView(DebugSwiftRuntimePanel(managesFloatingBall: false) {
                    _ = DebugSwift.App.removeDebugger()
                })
            )
        }
        isFloatingButtonVisible = showsFloatingButton
        return true
        #else
        // A setup the host already made with `DebugSwift().setup(...)`, or an earlier install, stays:
        // later calls only update the panel's content. The runtime's own install is retried until
        // it succeeds.
        if !DebugSwift.isSetUp {
            DebugSwift().setup(enableBetaFeatures: betaFeatures)
        }
        if !isAndroidSetUp {
            isAndroidSetUp = DebugSwiftNativeBridge.install()
        }
        isFloatingButtonVisible = showsFloatingButton
        return isAndroidSetUp
        #endif
    }

    #if os(Android)
    @MainActor private static var isAndroidSetUp = false
    #endif

    /// Starts the platform services without touching the panel's content. The panel calls it when it
    /// opens, so a host that never called `install` still gets the Android runtime, or on iOS
    /// DebugSwift's setup (the monitors and swizzles the Performance and App tools read).
    @discardableResult
    @MainActor
    static func startRuntime(capturesURLSession: Bool = true) -> Bool {
        #if os(Android)
        let installed = DebugSwiftNativeBridge.install()
        DebugSwiftNetworkForwarder.start()
        if capturesURLSession && !DebugSwift.disabledMethods.contains(.network) {
            DebugSwiftURLSessionCapture.install()
        }
        DebugFloatingButton.startListening()
        return installed
        #else
        prepareIOSDebugger()
        return false
        #endif
    }

    /// The debug panel with the content given to `install`. Present it as a sheet or a full screen.
    @MainActor
    public static func panel(onDone: (@MainActor () -> Void)? = nil) -> some View {
        DebugSwiftRuntimePanel(onDone: onDone)
    }

    /// The floating ball on iOS, the floating button on Android. Both open the panel.
    @MainActor
    public static var isFloatingButtonVisible: Bool {
        get {
            #if os(iOS)
            return isIOSFloatingBallVisible
            #else
            return DebugFloatingButton.isEnabled
            #endif
        }
        set {
            #if os(iOS)
            isIOSFloatingBallVisible = newValue
            if newValue {
                DebugSwift().show()
            } else {
                DebugSwift().hide()
            }
            #else
            DebugFloatingButton.setEnabled(newValue)
            #endif
        }
    }

    /// Sets the rules that mask credentials and personal data in captured traffic, on every capture
    /// path: the shared `NetworkRecorder`, the iOS HAR and cURL exports, and on Android the OkHttp
    /// capture, its saved history and its exports. On Android the Kotlin capture masks through this
    /// same DebugSwiftCore sanitizer, so `customBodyRedactor` runs there too.
    public static func configureNetworkSanitizer(_ sanitizer: NetworkSanitizer) async {
        await NetworkRecorder.shared.setSanitizer(sanitizer)
        #if os(iOS)
        await MainActor.run { DebugSwift.Network.shared.sanitizer = sanitizer }
        #elseif os(Android)
        DebugSwiftCoreBridge.networkSanitizer = sanitizer
        #endif
    }

    /// Gives the Push Token screen the app's Firebase registration token. Call it where the app learns the token.
    public static func reportPushToken(_ token: String) {
        #if os(Android)
        DebugSwiftNativeBridge.reportPushToken(token)
        #endif
    }

    public static func log(_ message: String) {
        #if os(Android)
        DebugSwiftNativeBridge.log(message)
        #else
        NSLog("[DebugSwiftAndroid] %@", message)
        #endif
    }

    @MainActor
    static func networkInjectionSettingsJSON() -> String {
        #if os(Android)
        return DebugSwiftNativeBridge.networkInjectionSettingsJSON()
        #else
        return DebugSwift.Network.shared.networkInjectionSettingsJSON()
        #endif
    }

    @MainActor
    static func applyNetworkInjectionSettingsJSON(_ json: String) -> String {
        #if os(Android)
        return DebugSwiftNativeBridge.applyNetworkInjectionSettingsJSON(json)
        #else
        return DebugSwift.Network.shared.applyNetworkInjectionSettingsJSON(json)
            ? "Network injection settings applied."
            : "Could not apply network injection settings."
        #endif
    }

    @MainActor
    static func importNetworkInjectionRulesCSV(_ csv: String) -> String {
        #if os(Android)
        return DebugSwiftNativeBridge.importNetworkInjectionRulesCSV(csv)
        #else
        return DebugSwift.Network.shared.importResponseRewriteRulesCSV(csv)
        #endif
    }

    @MainActor
    static func exportNetworkInjectionRulesCSV() -> String {
        #if os(Android)
        return DebugSwiftNativeBridge.exportNetworkInjectionRulesCSV()
        #else
        DebugSwift.Network.shared.shareResponseRewriteRulesCSV()
        return "Sharing response modifier rules."
        #endif
    }

    @MainActor
    public static func snapshot(featureID: String) -> String {
        #if os(Android)
        let native = DebugSwiftNativeBridge.snapshot(featureID)
        switch featureID {
        case "custom_info":
            // What the host set on `DebugSwift.App.shared.customInfo`, then what Kotlin registered.
            let lines = (DebugSwift.App.shared.customInfo?() ?? []).flatMap { section in
                [section.title] + section.infos.map { "  \($0.title): \($0.subtitle)" }
            }
            return lines.isEmpty ? native : (lines + (native.hasPrefix("No ") ? [] : [native])).joined(separator: "\n")
        case "custom_actions":
            let titles = (DebugSwift.App.shared.customAction?() ?? []).flatMap { $0.actions.map(\.title) }
            return titles.isEmpty ? native : (titles + (native.hasPrefix("No ") ? [] : [native])).joined(separator: "\n")
        default:
            return native
        }
        #else
        if let text = SharedPanelData.snapshot(featureID: featureID) { return text }
        switch featureID {
        case "console":
            guard let data = try? JSONEncoder().encode(DebugSwift.Console.shared.messages()),
                  let json = String(data: data, encoding: String.Encoding.utf8) else {
                return "[]"
            }
            return json
        case "network_thresholds":
            let snapshot = DebugSwift.Network.shared.getThresholdSnapshot()
            let endpointRows = snapshot.endpointLimits.map { "\($0.endpoint) — \($0.limit) per \(Int($0.timeWindow))s" }
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .short
            dateFormatter.timeStyle = .short
            let breachRows = snapshot.recentBreaches.map { "\(dateFormatter.string(from: $0.timestamp)) · \($0.message)" }
            let endpoints = endpointRows.isEmpty ? "No endpoint limits configured." : endpointRows.joined(separator: "\n")
            let breaches = breachRows.isEmpty ? "No threshold breaches." : breachRows.joined(separator: "\n")
            return "threshold|\(snapshot.isEnabled)|\(snapshot.limit)|\(Int(snapshot.timeWindow))|\(snapshot.shouldBlockRequests)|\(snapshot.currentRequestCount)|\(snapshot.totalBreaches)\n" +
                "ENDPOINT LIMITS\n\(endpoints)\n\nRECENT BREACHES\n\(breaches)"
        case "device_info":
            return UserInfo.infos.map { "\($0.title) \($0.detail)" }.joined(separator: "\n")
        case "push_token":
            let token = DebugSwift.APNSToken.deviceToken ?? "No APNS token has been reported."
            return "Registration: \(DebugSwift.APNSToken.registrationState.rawValue)\nEnvironment: \(DebugSwift.APNSToken.environment.rawValue)\nToken: \(token)"
        case "custom_info":
            let sections = DebugSwift.App.shared.customInfo?() ?? []
            let lines = sections.flatMap { section in
                [section.title] + section.infos.map { "  \($0.title): \($0.subtitle)" }
            }
            return lines.isEmpty ? "No custom diagnostic data provided." : lines.joined(separator: "\n")
        case "custom_actions":
            let sections = DebugSwift.App.shared.customAction?() ?? []
            let lines = sections.flatMap { section in
                [section.title] + section.actions.map { "  \($0.title)" }
            }
            return lines.isEmpty ? "No custom actions registered by the host app." : lines.joined(separator: "\n")
        default:
            return "Open the UIKit debugger on iOS to inspect live app data."
        }
        #endif
    }

    @MainActor
    static func securityAuditSnapshot() -> DebugSwiftSecurityAuditSnapshot {
        let json: String
        #if os(Android)
        json = DebugSwiftNativeBridge.securityAuditSnapshot()
        #else
        let findings = DebugSwift.Resources.shared.securityAuditFindings().map { finding in
            DebugSwiftSecurityAuditFinding(
                severity: finding.severity.rawValue,
                source: finding.source.rawValue,
                key: finding.key,
                message: finding.message
            )
        }
        let criticalCount = findings.filter { $0.severity == "critical" }.count
        let warningCount = findings.filter { $0.severity == "warning" }.count
        let infoCount = findings.filter { $0.severity == "info" }.count
        let summary = "Potentially sensitive references: \(findings.count) · \(criticalCount) critical · \(warningCount) warnings · \(infoCount) info. Matched values are never displayed."
        let snapshot = DebugSwiftSecurityAuditSnapshot(findings: findings, summary: summary)
        guard let data = try? JSONEncoder().encode(snapshot),
              let encoded = String(data: data, encoding: String.Encoding.utf8) else {
            return DebugSwiftSecurityAuditSnapshot(findings: [], summary: "Security audit data could not be encoded.")
        }
        json = encoded
        #endif

        guard let data = json.data(using: String.Encoding.utf8),
              let snapshot = try? JSONDecoder().decode(DebugSwiftSecurityAuditSnapshot.self, from: data) else {
            return DebugSwiftSecurityAuditSnapshot(findings: [], summary: "Security audit data could not be loaded.")
        }
        return snapshot
    }

    @MainActor
    public static func perform(featureID: String, actionID: String, value: String = "") -> String {
        #if os(Android)
        if featureID == "custom_actions", actionID == "run_custom",
           let action = (DebugSwift.App.shared.customAction?() ?? []).flatMap(\.actions).first(where: { $0.title == value }) {
            guard let run = action.action else { return "No registered action named '\(value)'." }
            run()
            return "Action '\(value)' completed."
        }
        return DebugSwiftNativeBridge.perform(featureID, actionID, value)
        #else
        if let message = SharedPanelData.perform(featureID: featureID, actionID: actionID, value: value) {
            return message
        }
        if featureID == "console" {
            switch actionID {
            case "clear":
                DebugSwift.Console.shared.clear()
                return "Console cleared."
            case "delete_console_entry":
                guard let index = Int(value), DebugSwift.Console.shared.messages().indices.contains(index) else {
                    return "Console entry no longer exists."
                }
                DebugSwift.Console.shared.removeMessage(at: index)
                return "Console entry removed."
            case "export":
                DebugSwift.Console.shared.shareMessages()
                return "Sharing console log."
            case "refresh":
                return snapshot(featureID: featureID)
            default:
                return "Unknown Console action: \(actionID)."
            }
        }
        if featureID == "network_thresholds" {
            let network = DebugSwift.Network.shared
            switch actionID {
            case "set_threshold_tracking":
                if value == "true" { network.enableRequestTracking() } else if value == "false" { network.disableRequestTracking() }
                else { return "Set request tracking to true or false." }
                return "Request tracking updated."
            case "set_threshold_blocking":
                guard value == "true" || value == "false" else { return "Set request blocking to true or false." }
                network.setRequestBlocking(value == "true")
                return "Request blocking updated."
            case "set_threshold":
                let parts = value.split(separator: ",", omittingEmptySubsequences: false)
                guard parts.count == 2, let limit = Int(parts[0]), let window = Double(parts[1]), limit > 0, window > 0 else {
                    return "Enter request limit,window seconds."
                }
                network.setThreshold(limit, timeWindow: window)
                return "Request threshold set to \(limit) per \(Int(window))s."
            case "clear_threshold_history":
                network.clearThresholdHistory()
                return "Request threshold history cleared."
            case "export":
                network.exportThresholdLogs()
                return "Sharing request threshold logs."
            default:
                break
            }
        }
        if actionID == "copy_token", ["device_info", "push_token"].contains(featureID) {
            return DebugSwift.APNSToken.copyToClipboard() ? "APNS token copied to the clipboard." : "No registered APNS token is available to copy."
        }
        if featureID == "custom_actions", actionID == "run_custom" {
            let actionGroups = DebugSwift.App.shared.customAction?() ?? []
            let action = actionGroups.flatMap { $0.actions }.first { $0.title == value }
            guard let action, let run = action.action else { return "No registered action named '\(value)'." }
            run()
            return "Action '\(value)' completed."
        }
        return "This action is not available for \(featureID)."
        #endif
    }

    @MainActor
    static func gridOverlaySettings() -> DebugSwiftGridOverlayState {
        #if os(Android)
        let parts = DebugSwiftNativeBridge.gridSettings().components(separatedBy: "|")
        guard parts.count == 4 else { return DebugSwiftGridOverlayState() }
        return DebugSwiftGridOverlayState(
            isEnabled: parts[0] == "true",
            size: Double(parts[1]) ?? 28.0,
            opacity: Double(parts[2]) ?? 0.5,
            colorIndex: Int(parts[3]) ?? 0
        )
        #else
        let settings = DebugSwift.gridOverlaySettings()
        return DebugSwiftGridOverlayState(
            isEnabled: settings.isEnabled,
            size: settings.size,
            opacity: settings.opacity,
            colorIndex: settings.colorIndex
        )
        #endif
    }

    @MainActor
    @discardableResult
    static func setGridOverlaySettings(_ settings: DebugSwiftGridOverlayState) -> String {
        #if os(Android)
        return DebugSwiftNativeBridge.setGridSettings(
            "\(settings.isEnabled)|\(settings.size)|\(settings.opacity)|\(settings.colorIndex)"
        )
        #else
        DebugSwift.setGridOverlaySettings(
            DebugSwiftGridOverlaySettings(
                isEnabled: settings.isEnabled,
                size: settings.size,
                opacity: settings.opacity,
                colorIndex: settings.colorIndex
            )
        )
        return "Grid settings updated."
        #endif
    }

    @MainActor
    static func interfaceSettingIsEnabled(featureID: String) -> Bool {
        #if os(Android)
        return DebugSwiftNativeBridge.interfaceToolEnabled(featureID)
        #else
        guard let setting = iosInterfaceSetting(for: featureID) else { return false }
        return DebugSwift.interfaceSettingIsEnabled(setting)
        #endif
    }

    @MainActor
    @discardableResult
    static func setInterfaceSetting(featureID: String, enabled: Bool) -> String {
        #if os(Android)
        return DebugSwiftNativeBridge.setInterfaceToolEnabled(featureID, enabled)
        #else
        guard let setting = iosInterfaceSetting(for: featureID) else {
            return "Unknown interface setting: \(featureID)"
        }
        DebugSwift.setInterfaceSetting(setting, enabled: enabled)
        return "\(featureID) \(enabled ? "enabled" : "disabled")."
        #endif
    }

    #if os(iOS)
    @MainActor
    private static func iosInterfaceSetting(for featureID: String) -> DebugSwiftInterfaceSetting? {
        switch featureID {
        case "touches": .touches
        case "view_borders": .colorizedBorders
        case "animations": .slowAnimations
        case "dark_mode": .darkMode
        case "measurement": .measurement
        case "render_tracking": .swiftUIRenderTracking
        default: nil
        }
    }
    #endif
}
