#if os(Android)
import Foundation

/// One frame of a captured backtrace.
public struct BacktraceFrame: Sendable, Equatable {
    /// Zero-based position in the stack (0 = deepest / capture call site).
    public let index: Int
    public let symbol: String

    public init(index: Int, symbol: String) {
        self.index = index
        self.symbol = symbol
    }
}

/// A backtrace captured at a specific moment during normal execution.
public struct CapturedBacktrace: Sendable, Equatable {
    public let id: String
    public let timestamp: Date
    public let label: String?
    public let frames: [BacktraceFrame]

    public init(id: String, timestamp: Date, label: String?, frames: [BacktraceFrame]) {
        self.id = id
        self.timestamp = timestamp
        self.label = label
        self.frames = frames
    }
}

/// A lifecycle method that did not call through to its superclass. On Android the platform reports
/// it as a `SuperNotCalledException`.
public struct SuperCallViolation: Sendable {
    public let className: String
    public let methodName: String
    public let revealedBy: String
    public let timestamp: Date

    init(className: String, methodName: String, revealedBy: String, timestamp: Date = Date()) {
        self.className = className
        self.methodName = methodName
        self.revealedBy = revealedBy
        self.timestamp = timestamp
    }

    public var message: String {
        "\(className) does not call super.\(methodName)() — revealed by \(revealedBy)()"
    }
}

/// A screen that stayed in memory after it closed. On Android that is a destroyed Activity a
/// garbage collection could not free.
public struct PerformanceLeak {
    /// The class of the leaked Activity.
    public let className: String
    public let message: String
}

extension DebugSwift {
    public enum Performance {
        public static let shared = PerformanceManager()

        public enum Chart {
            /// How much history the live charts keep, in seconds.
            nonisolated(unsafe) public static var timeWindowSeconds: Double = 120.0

            public static func setTimeWindow(seconds: Double) {
                timeWindowSeconds = max(10.0, seconds)
            }

            public static func setTimeWindow(minutes: Double) {
                setTimeWindow(seconds: minutes * 60.0)
            }
        }

        public class LeakDetector {
            /// Calls `callback` for each Activity that stays in memory `detectionDelay` seconds or
            /// more after it was destroyed.
            public func onDetect(
                detectionDelay: TimeInterval = 1,
                callback: ((PerformanceLeak) -> Void)?
            ) {
                PerformanceEvents.shared.leakCallback = callback
                PerformanceEvents.shared.leakDelay = detectionDelay
                PerformanceEvents.shared.start()
            }

            /// Android has no window classes to ignore; kept for the same code to compile.
            public var ignoredWindowClassNames: [String] {
                get { PerformanceEvents.shared.ignoredWindowClassNames }
                set { PerformanceEvents.shared.ignoredWindowClassNames = newValue }
            }

            /// Activity classes whose leaks are not reported.
            public var ignoredViewControllerClassNames: [String] {
                get { PerformanceEvents.shared.ignoredLeakClassNames }
                set { PerformanceEvents.shared.ignoredLeakClassNames = newValue }
            }

            /// View classes whose leaks are not reported.
            public var ignoredViewClassNames: [String] {
                get { PerformanceEvents.shared.ignoredViewClassNames }
                set { PerformanceEvents.shared.ignoredViewClassNames = newValue }
            }
        }

        /// Main-thread violations, detected on Android by StrictMode.
        public enum ThreadChecker {
            public static func enable() {
                DebugSwiftHost.call("performance.threads.enabled", ["enabled": true])
            }

            public static func disable() {
                DebugSwiftHost.call("performance.threads.enabled", ["enabled": false])
            }

            /// iOS dispatches UIKit calls made off the main thread back to it. Android cannot move a
            /// call that already ran, so it records the violation as in `enable()`.
            public static func enableAutoFix() {
                enable()
            }

            /// Flashes the screen on each violation (StrictMode `penaltyFlashScreen`).
            public static func setShowVisualAlerts(_ enabled: Bool) {
                DebugSwiftHost.call("performance.threads.options", ["flashScreen": enabled])
            }

            /// Writes each violation to Logcat (StrictMode `penaltyLog`).
            public static func setLogToConsole(_ enabled: Bool) {
                DebugSwiftHost.call("performance.threads.options", ["log": enabled])
            }

            nonisolated(unsafe) private static var ignoredClasses: Set<String> = []

            public static func ignoreClass(_ className: String) {
                ignoredClasses.insert(className)
                sendIgnored()
            }

            public static func unignoreClass(_ className: String) {
                ignoredClasses.remove(className)
                sendIgnored()
            }

            public static func setIgnoredClasses(_ classNames: [String]) {
                ignoredClasses = Set(classNames)
                sendIgnored()
            }

            public static func clearViolations() {
                DebugSwiftHost.call("performance.threads.clear")
            }

            private static func sendIgnored() {
                DebugSwiftHost.call("performance.threads.options", ["ignored": Array(ignoredClasses)])
            }
        }

        public enum SuperCallChecker {
            public static func onDetect(_ callback: @escaping (SuperCallViolation) -> Void) {
                PerformanceEvents.shared.superCallCallback = callback
                PerformanceEvents.shared.start()
            }

            public static var violations: [SuperCallViolation] {
                PerformanceEvents.superCallViolations()
            }

            public static func ignoreClass(_ className: String) {
                PerformanceEvents.shared.ignoredSuperCallClasses.insert(className)
                sendIgnored()
            }

            public static func setIgnoredClasses(_ classNames: [String]) {
                PerformanceEvents.shared.ignoredSuperCallClasses = Set(classNames)
                sendIgnored()
            }

            public static func clearViolations() {
                DebugSwiftHost.call("performance.supercalls.clear")
            }

            private static func sendIgnored() {
                DebugSwiftHost.call("performance.supercalls.ignored", ["classes": Array(PerformanceEvents.shared.ignoredSuperCallClasses)])
            }
        }

        public enum Backtrace {
            /// Captures the main thread's call stack, labelled for the Backtraces screen.
            @discardableResult
            public static func capture(label: String? = nil) -> CapturedBacktrace {
                let reply = DebugSwiftHost.object("performance.backtrace.capture", ["label": label ?? ""])
                let capture = PerformanceEvents.backtrace(from: reply, label: label)
                PerformanceEvents.shared.backtraceCallback?(capture)
                return capture
            }

            public static var captured: [CapturedBacktrace] {
                DebugSwiftHost.array("performance.backtraces")
                    .compactMap { $0 as? [String: Any] }
                    .map { PerformanceEvents.backtrace(from: $0, label: nil) }
            }

            public static func onCapture(_ callback: @escaping (CapturedBacktrace) -> Void) {
                PerformanceEvents.shared.backtraceCallback = callback
            }

            public static func clear() {
                DebugSwiftHost.call("performance.backtraces.clear")
            }
        }
    }
}

public class PerformanceManager: @unchecked Sendable {
    public let leakDetector = DebugSwift.Performance.LeakDetector()

    internal init() {}

    nonisolated(unsafe) private static var batteryMonitoring = true

    /// The Battery screen reads the level live on Android; the value is kept for the same code.
    @MainActor
    public var isBatteryMonitoringEnabled: Bool {
        get { Self.batteryMonitoring }
        set { Self.batteryMonitoring = newValue }
    }

    public func onLeakDetected(_ callback: @escaping (LeakData) -> Void) {
        PerformanceEvents.shared.leakDataCallbacks.append(callback)
        PerformanceEvents.shared.start()
    }

    public struct LeakData: Sendable {
        public let message: String
        public let controller: String?
        public let view: String?
        public let isDeallocation: Bool

        public init(message: String, controller: String? = nil, view: String? = nil, isDeallocation: Bool = false) {
            self.message = message
            self.controller = controller
            self.view = view
            self.isDeallocation = isDeallocation
        }
    }
}

extension DebugSwift.Performance {
    public enum AutoFixMode: String, CaseIterable, Sendable {
        case disabled = "Disabled"
        case logOnly = "Log Only"
        case autoFix = "Auto Fix"

        public var description: String {
            switch self {
            case .disabled: return "Detection disabled"
            case .logOnly: return "Log violations without fixing"
            case .autoFix: return "Automatically dispatch to main thread"
            }
        }
    }

    public struct ThreadViolation: Sendable {
        public let id: UUID
        public let timestamp: Date
        public let methodName: String
        public let className: String
        public let threadName: String
        public let stackTrace: [String]
        public let severity: Severity

        public enum Severity: String, CaseIterable, Sendable {
            case warning = "Warning"
            case error = "Error"
            case critical = "Critical"

            public var emoji: String {
                switch self {
                case .warning: return "⚠️"
                case .error: return "❌"
                case .critical: return "🚨"
                }
            }
        }
    }
}

/// Watches the Android runtime for leaks and super-call violations and calls the host's callbacks
/// once per new event.
final class PerformanceEvents: @unchecked Sendable {
    static let shared = PerformanceEvents()

    var leakCallback: ((PerformanceLeak) -> Void)?
    var leakDataCallbacks: [(PerformanceManager.LeakData) -> Void] = []
    var leakDelay: TimeInterval = 1
    var superCallCallback: ((SuperCallViolation) -> Void)?
    var backtraceCallback: ((CapturedBacktrace) -> Void)?
    var ignoredWindowClassNames: [String] = []
    var ignoredLeakClassNames: [String] = []
    var ignoredViewClassNames: [String] = []
    var ignoredSuperCallClasses: Set<String> = []

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var reportedLeaks: Set<String> = []
    private var reportedSuperCalls: Set<String> = []

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func poll() {
        let leaks = DebugSwiftHost.object("performance.leaks")["candidates"] as? [[String: Any]] ?? []
        for leak in leaks {
            let className = leak["className"] as? String ?? ""
            let age = DebugSwiftHost.double(leak["ageSeconds"]) ?? 0
            guard age >= leakDelay,
                  !ignoredLeakClassNames.contains(where: { className.hasSuffix($0) }),
                  markReported(className, in: \.reportedLeaks) else { continue }
            let message = "\(className) was destroyed but is still in memory."
            leakCallback?(PerformanceLeak(className: className, message: message))
            leakDataCallbacks.forEach { $0(PerformanceManager.LeakData(message: message, controller: className)) }
        }
        guard DebugSwift.disabledMethods.contains(.superCallDetector) == false else { return }
        for violation in Self.superCallViolations() where markReported(violation.message, in: \.reportedSuperCalls) {
            superCallCallback?(violation)
        }
    }

    private func markReported(_ key: String, in set: ReferenceWritableKeyPath<PerformanceEvents, Set<String>>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self[keyPath: set].insert(key).inserted
    }

    static func superCallViolations() -> [SuperCallViolation] {
        DebugSwiftHost.array("performance.supercalls").compactMap { $0 as? String }.map { report in
            // "Activity com.example.Main did not call through to super.onResume()"
            let line = report.split(separator: "\n").first { $0.contains("did not call through to super.") } ?? ""
            let className = line.components(separatedBy: "Activity ").dropFirst().first?
                .components(separatedBy: " did not").first ?? "Activity"
            let methodName = line.components(separatedBy: "super.").dropFirst().first?
                .components(separatedBy: "(").first ?? "lifecycle method"
            return SuperCallViolation(className: className, methodName: methodName, revealedBy: "SuperNotCalledException")
        }
    }

    static func backtrace(from reply: [String: Any], label: String?) -> CapturedBacktrace {
        let stack = reply["stack"] as? String ?? ""
        let frames = stack.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("at ") }
            .enumerated()
            .map { BacktraceFrame(index: $0.offset, symbol: String($0.element.dropFirst(3))) }
        let title = reply["title"] as? String ?? ""
        return CapturedBacktrace(
            id: reply["id"] as? String ?? UUID().uuidString,
            timestamp: Date(),
            label: label ?? title.components(separatedBy: " · ").dropFirst().first,
            frames: frames
        )
    }
}
#endif
