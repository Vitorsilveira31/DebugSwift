#if os(Android)
import DebugSwiftCore
import Foundation

public struct CustomData {
    public init(title: String, infos: [Info]) {
        self.title = title
        self.infos = infos
    }

    public let title: String
    public let infos: [Info]
}

extension CustomData {
    public struct Info {
        public init(title: String, subtitle: String) {
            self.title = title
            self.subtitle = subtitle
        }

        public let title: String
        public let subtitle: String
    }
}

public struct CustomAction {
    public init(title: String, actions: Actions) {
        self.title = title
        self.actions = actions
    }

    public let title: String
    public let actions: Actions
}

extension CustomAction {
    public typealias Actions = [Action]

    public struct Action {
        public init(title: String, action: (() -> Void)?) {
            self.title = title
            self.action = action
        }

        public let title: String
        public let action: (() -> Void)?
    }
}

extension DebugSwift {
    public class App: @unchecked Sendable {
        public static let shared = App()
        private init() {}

        /// Rows the App → Custom Info screen lists.
        public var customInfo: (() -> [CustomData])?
        /// Buttons the App → Custom Actions screen lists.
        public var customAction: (() -> [CustomAction])?
        /// Extra screens listed at the top of the panel, the Android counterpart of iOS's
        /// `customControllers`.
        @MainActor public var customTools: (() -> [DebugTool])?

        /// Opens the debug panel. The host shows it with `.debugSwiftPanel()` on its root view, or
        /// with its own presentation through `DebugFloatingButton.onTap`.
        @MainActor
        @discardableResult
        public static func presentDebugger() -> App.Type {
            DebugSwiftPresentation.shared.present(route: nil)
            return self
        }

        /// Writes `agent-snapshot.json` next to the agent debug log and returns its location: app,
        /// device, current CPU and memory, and the latest requests with sanitized URLs.
        @MainActor
        @discardableResult
        public static func writeAgentSnapshot() throws -> URL {
            let reply = DebugSwiftHost.object("app.snapshot")
            guard let path = reply["path"] as? String else {
                throw DebugSwiftAgentSnapshotError(message: reply["error"] as? String ?? "The snapshot could not be written.")
            }
            return URL(fileURLWithPath: path)
        }

        @MainActor
        @discardableResult
        public static func removeDebugger() -> App.Type {
            DebugSwiftPresentation.shared.dismiss()
            return self
        }
    }

    public class Console: @unchecked Sendable {
        public static let shared = Console()
        private init() {}

        /// Messages containing any of these strings are left out of the console.
        public var ignoredLogs = [String]() {
            didSet { sendFilters() }
        }

        /// When not empty, only messages containing one of these strings are kept.
        public var onlyLogs = [String]() {
            didSet { sendFilters() }
        }

        /// Returns the captured console entries in their original order.
        public func messages() -> [String] {
            DebugSwiftHost.array("console.messages").compactMap { $0 as? String }
        }

        /// Removes one captured console entry by its current array index.
        public func removeMessage(at index: Int) {
            DebugSwiftHost.call("console.remove", ["index": index])
        }

        /// Removes every captured console entry.
        public func clear() {
            DebugSwiftHost.call("console.clear")
        }

        /// Shares the captured console entries as a text file.
        @MainActor
        public func shareMessages() {
            DebugSwiftHost.call("console.share")
        }

        private func sendFilters() {
            DebugSwiftHost.call("console.filters", ["ignored": ignoredLogs, "only": onlyLogs])
        }
    }

    public class Debugger {
        nonisolated(unsafe) static var isLogEnabled = true
        nonisolated(unsafe) static var isFeedbackEnabled = true

        // Like iOS, no public initializer.
        init() {}

        /// iOS: prints DebugSwift's own diagnostics to the Xcode console. Android keeps the value for
        /// the same code to compile; its runtime reports through Console and Logcat either way.
        public var logEnable: Bool {
            get { Debugger.isLogEnabled }
            set { Debugger.isLogEnabled = newValue }
        }

        /// iOS: haptic feedback on debugger actions. Android keeps the value; its panel has no haptics.
        public var feedbackEnable: Bool {
            get { Debugger.isFeedbackEnabled }
            set { Debugger.isFeedbackEnabled = newValue }
        }
    }

    /// The measurement tool: pick two elements of the screen and read the distances between them.
    public enum Measurement {
        /// Opens the measurement tool.
        @MainActor
        public static func activate() {
            DebugSwiftPresentation.shared.present(route: "measurement")
        }

        @MainActor
        public static func deactivate() {
            if isActive { DebugSwiftPresentation.shared.dismiss() }
        }

        @MainActor
        public static func toggle() {
            if isActive {
                deactivate()
            } else {
                activate()
            }
        }

        @MainActor
        public static var isActive: Bool {
            DebugSwiftPresentation.shared.isPresented && DebugSwiftPresentation.shared.route == "measurement"
        }
    }
}

struct DebugSwiftAgentSnapshotError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
#endif
