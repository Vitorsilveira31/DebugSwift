#if os(Android)
import DebugSwiftCore
import Foundation
import Observation
import SkipFuse

// DebugSwift's iOS API on Android.
//
// On iOS `import DebugSwiftUI` re-exports the DebugSwift module; on Android these files declare the
// same types with the same names and signatures, backed by the Android runtime. The same host code
// compiles and behaves alike on both platforms. Members that take UIKit, Core Data or SwiftData
// types have an Android counterpart under the same namespace, documented where it differs.

/// Sends one operation to the Android runtime's host API and returns its JSON reply.
enum DebugSwiftHost {
    @discardableResult
    static func call(_ operation: String, _ arguments: [String: Any] = [:]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
        return DebugSwiftNativeBridge.resource("host." + operation, String(decoding: data, as: UTF8.self))
    }

    static func object(_ operation: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
        guard let data = call(operation, arguments).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func array(_ operation: String, _ arguments: [String: Any] = [:]) -> [Any] {
        guard let data = call(operation, arguments).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return array
    }

    static func message(_ operation: String, _ arguments: [String: Any] = [:]) -> String {
        object(operation, arguments)["message"] as? String ?? ""
    }

    /// A JSON number as a Double. Foundation on Android decodes whole numbers as Int, and org.json
    /// writes 60.0 as 60, so a number may arrive as either.
    static func double(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as Int64: return Double(value)
        case let value as NSNumber: return value.doubleValue
        default: return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: return value
        case let value as Int64: return Int(value)
        case let value as Double: return Int(value)
        case let value as NSNumber: return value.intValue
        default: return nil
        }
    }
}

public enum DebugSwiftFeature: String, CaseIterable, Sendable {
    case network
    case performance
    case interface
    case resources
    case app
}

/// Capture mechanisms a host can turn off in `setup(disable:)`.
public enum DebugSwiftSwizzleFeature: String, CaseIterable, Sendable {
    case network
    case webSocket
    case wkWebView
    case location
    case views
    case crashManager
    case leaksDetector
    case console
    case pushNotifications
    case swiftUIRender
    case orientationForwarding
    case superCallDetector
}

@MainActor
public enum DebugSwiftBetaFeature: String, CaseIterable {
    case swiftUIRenderTracking
    case networkSessionPersistence
    /// Writes network, crash, console and debug events to an NDJSON file a coding agent can read.
    case agentDebugLog
}

/// Whether the shared panel is on screen. `DebugSwift.App.presentDebugger()`, the floating button
/// and `.debugSwiftPanel()` on the host's root view read and change it.
@MainActor
@Observable
final class DebugSwiftPresentation {
    static let shared = DebugSwiftPresentation()
    var isPresented = false
    /// A feature the panel opens directly, for example `measurement`.
    var route: String?
    /// The `.debugSwiftPanel()` presenters on screen, oldest first. The newest one presents the panel.
    private var presenters: [UUID] = []
    /// The host's own floating-button handler, put back when the last presenter leaves the screen.
    private var hostTap: (@MainActor () -> Void)?

    var isAttached: Bool { !presenters.isEmpty }

    /// Called by a `.debugSwiftPanel()` presenter when it appears: the floating button opens the
    /// panel through the presenters from now on.
    func attach(_ id: UUID) {
        if presenters.isEmpty { hostTap = DebugFloatingButton.onTap }
        presenters.removeAll { $0 == id }
        presenters.append(id)
        DebugFloatingButton.onTap = { DebugSwiftPresentation.shared.present(route: nil) }
    }

    /// Called when a presenter disappears. Others still on screen keep presenting; when the last
    /// one leaves, the handler the host had before comes back, so `present` never calls itself.
    func detach(_ id: UUID) {
        guard presenters.contains(id) else { return }
        presenters.removeAll { $0 == id }
        guard presenters.isEmpty else { return }
        DebugFloatingButton.onTap = hostTap
        hostTap = nil
    }

    func present(route: String?) {
        self.route = route
        if isAttached {
            isPresented = true
        } else if let hostTap = DebugFloatingButton.onTap {
            // No presenter on screen: the host shows the panel itself (`DebugFloatingButton.onTap`).
            hostTap()
        }
    }

    func dismiss() {
        isPresented = false
        route = nil
    }
}

public class DebugSwift {
    public init() {}

    @MainActor static var hiddenFeatures: [DebugSwiftFeature] = []
    nonisolated(unsafe) static var disabledMethods: [DebugSwiftSwizzleFeature] = []
    /// True once `setup` ran, from the host or from `DebugSwiftRuntime.install`.
    @MainActor static var isSetUp = false
    @MainActor static var enabledBetaFeatures: [DebugSwiftBetaFeature] = []

    /// Starts the Android runtime: crash, ANR, frame, log and network capture.
    @discardableResult
    @MainActor
    public func setup(
        hideFeatures features: [DebugSwiftFeature] = [],
        disable methods: [DebugSwiftSwizzleFeature] = [],
        enableBetaFeatures betaFeatures: [DebugSwiftBetaFeature] = []
    ) -> Self {
        Self.isSetUp = true
        Self.hiddenFeatures = features
        Self.disabledMethods = methods
        Self.enabledBetaFeatures = betaFeatures
        DebugSwiftRuntime.startRuntime(capturesURLSession: !methods.contains(.network))
        // `.leaksDetector` and `.superCallDetector` are read by the leak and super-call watchers.
        DebugSwiftHost.call("console.enabled", ["enabled": !methods.contains(.console)])
        if methods.contains(.webSocket) { DebugSwift.WebSocket.disableMonitoring() }
        if methods.contains(.wkWebView) { DebugSwift.WKWebView.shared.disable() }
        if betaFeatures.contains(.agentDebugLog) {
            DebugSwiftHost.call("app.agentLog", ["enabled": true])
        }
        return self
    }

    /// Shows the floating button that opens the debugger.
    @discardableResult
    public func show() -> Self {
        if Thread.isMainThread {
            // Right away, so a `hide()` made next on the main actor stays the last word.
            MainActor.assumeIsolated { DebugFloatingButton.setEnabled(true) }
        } else {
            Task { @MainActor in DebugFloatingButton.setEnabled(true) }
        }
        return self
    }

    @discardableResult
    @MainActor
    public func hide() -> Self {
        DebugFloatingButton.setEnabled(false)
        return self
    }

    @discardableResult
    @MainActor
    public func toggle() -> Self {
        DebugFloatingButton.setEnabled(!DebugFloatingButton.isEnabled)
        return self
    }

    @MainActor private static var floatingButtonWasVisible = false

    /// Hides the floating button while a host-presented panel is on screen.
    @MainActor
    public static func debugViewControllerWillPresent() {
        if DebugFloatingButton.isEnabled {
            floatingButtonWasVisible = true
            DebugFloatingButton.setEnabled(false)
        }
    }

    /// Restores the floating button hidden by `debugViewControllerWillPresent()`.
    @MainActor
    public static func debugViewControllerDidDismiss() {
        if floatingButtonWasVisible {
            DebugFloatingButton.setEnabled(true)
            floatingButtonWasVisible = false
        }
    }

    @MainActor
    public static func availableDebugFeatures() -> [DebugSwiftFeature] {
        DebugSwiftFeature.allCases.filter { !hiddenFeatures.contains($0) }
    }
}
#endif
