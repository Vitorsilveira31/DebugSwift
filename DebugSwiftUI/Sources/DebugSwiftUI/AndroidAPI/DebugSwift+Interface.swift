#if os(Android)
import Foundation

/// Namespace of iOS's SwiftUI render tracker; on Android `SwiftUIRender` counts Compose recompositions.
public final class SwiftUIRenderTracker {
    public enum RenderOverlayStyle {
        case border // Colored border that fades
        case borderWithCount // Border with render count text
        case none // Only logging, no visual
    }
}

extension DebugSwift {
    /// WebSocket capture. On Android it covers OkHttp sockets whose listener is wrapped in
    /// `DebugSwiftWebSocketListener`.
    public enum WebSocket {
        public static func enableMonitoring() {
            DebugSwiftHost.call("websocket.enabled", ["enabled": true])
        }

        public static func disableMonitoring() {
            DebugSwiftHost.call("websocket.enabled", ["enabled": false])
        }

        public static var isMonitoringEnabled: Bool {
            DebugSwiftHost.object("websocket.state")["enabled"] as? Bool ?? false
        }

        @MainActor
        public static var activeConnectionCount: Int {
            DebugSwiftHost.int(DebugSwiftHost.object("websocket.state")["active"]) ?? 0
        }

        @MainActor
        public static var totalUnreadFrames: Int {
            DebugSwiftHost.int(DebugSwiftHost.object("websocket.state")["unread"]) ?? 0
        }

        @MainActor
        public static func clearAllData() {
            DebugSwiftHost.call("network.clearWebSockets")
        }

        @MainActor
        public static func clearFrames(for url: URL) {
            DebugSwiftHost.call("websocket.clearFrames", ["url": url.absoluteString])
        }
    }

    /// Web view capture. On Android it covers WebViews whose client is a `DebugSwiftWebViewClient`.
    public final class WKWebView: @unchecked Sendable {
        public static let shared = WKWebView()

        private init() {}

        private var options = Options()

        private struct Options {
            var isEnabled = true
            var captureRequestBodies = true
            var captureResponseHeaders = true
            var maxStoredRequests = 1000
        }

        public var isEnabled: Bool {
            get { options.isEnabled }
            set {
                options.isEnabled = newValue
                send()
            }
        }

        /// WebViewClient does not expose request bodies on Android; kept for the same code.
        public var captureRequestBodies: Bool {
            get { options.captureRequestBodies }
            set { options.captureRequestBodies = newValue }
        }

        /// WebViewClient does not expose response headers on Android; kept for the same code.
        public var captureResponseHeaders: Bool {
            get { options.captureResponseHeaders }
            set { options.captureResponseHeaders = newValue }
        }

        public var maxStoredRequests: Int {
            get { options.maxStoredRequests }
            set {
                options.maxStoredRequests = max(1, newValue)
                send()
            }
        }

        public func enable() {
            isEnabled = true
        }

        public func disable() {
            isEnabled = false
        }

        /// Turns capture on. Each WebView still needs a `DebugSwiftWebViewClient` on Android.
        @MainActor
        public func install() {
            enable()
        }

        public func getConfiguration() -> [String: Any] {
            [
                "isEnabled": options.isEnabled,
                "captureRequestBodies": options.captureRequestBodies,
                "captureResponseHeaders": options.captureResponseHeaders,
                "maxStoredRequests": options.maxStoredRequests
            ]
        }

        public func resetToDefaults() {
            options = Options()
            send()
        }

        private func send() {
            DebugSwiftHost.call("webview.config", ["enabled": options.isEnabled, "maxStoredRequests": options.maxStoredRequests])
        }
    }

    /// Render tracking. On Android it counts Compose recompositions for the Compose Renders screen.
    @MainActor
    public class SwiftUIRender: @unchecked Sendable {
        public static let shared = SwiftUIRender()

        private init() {}

        private var tracking = false

        public var isEnabled: Bool {
            get { tracking }
            set { tracking = newValue }
        }

        /// iOS draws a border around each re-rendered view. Compose has no per-node border hook, so
        /// the Compose Renders screen shows the counts instead.
        public var overlayStyle: SwiftUIRenderTracker.RenderOverlayStyle = .border

        public var overlayDuration: TimeInterval = 1.0

        public var loggingEnabled = false

        public var persistentOverlays = false

        public func clearPersistentOverlays() {}

        public func cleanupOrphanedOverlays() {}

        public func getRenderStats() -> [String: Any] {
            let stats = DebugSwiftHost.object("interface.compose")
            return [
                "isEnabled": tracking,
                "totalRenders": DebugSwiftHost.int(stats["renders"]) ?? 0,
                "frames": DebugSwiftHost.int(stats["frames"]) ?? 0,
                "slowFrames": DebugSwiftHost.int(stats["slowFrames"]) ?? 0
            ]
        }

        public func clearStats() {
            DebugSwiftHost.call("interface.compose.clear")
        }
    }
}
#endif
