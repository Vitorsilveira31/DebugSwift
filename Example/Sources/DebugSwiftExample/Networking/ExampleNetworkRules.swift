import DebugSwiftCore
import DebugSwiftUI
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(iOS)
import DebugSwift
#endif

/// The delay, failure and rewrite rules the Network Injection demo turns on.
///
/// On iOS they go to DebugSwift's URL protocol, the same rules the panel edits. On Android they
/// apply to the Swift `URLSession` requests DebugSwift captures: while any demo rule is on it
/// replaces the rules set in the panel, and `reset()` hands injection back to the panel.
@MainActor
enum ExampleNetworkRules {
    enum Failure {
        case timeout
        case connectionLost
    }

    static func setDelay(_ seconds: Double) {
        #if os(iOS)
        DebugSwift.Network.shared.enableRequestDelay(seconds)
        #else
        update { $0.delay = seconds...seconds }
        #endif
    }

    static func setDelay(min: Double, max: Double) {
        #if os(iOS)
        DebugSwift.Network.shared.enableRequestDelay(min: min, max: max)
        #else
        update { $0.delay = min...max }
        #endif
    }

    static func clearDelay() {
        #if os(iOS)
        DebugSwift.Network.shared.disableRequestDelay()
        #else
        update { $0.delay = nil }
        #endif
    }

    static func setFailure(_ failure: Failure, rate: Double) {
        #if os(iOS)
        let type: NetworkFailureConfig.FailureType = switch failure {
        case .timeout: .timeout
        case .connectionLost: .connectionLost
        }
        DebugSwift.Network.shared.enableFailureInjection(failureRate: rate, failureType: type)
        #else
        let kind = switch failure {
        case .timeout: "timeout"
        case .connectionLost: "connectionLost"
        }
        update {
            $0.failureKind = kind
            $0.httpErrorCodes = []
            $0.failureRate = rate
        }
        #endif
    }

    static func setHTTPError(statusCodes: [Int], rate: Double) {
        #if os(iOS)
        DebugSwift.Network.shared.enableHTTPErrorInjection(failureRate: rate, statusCodes: statusCodes)
        #else
        update {
            $0.failureKind = nil
            $0.httpErrorCodes = statusCodes
            $0.failureRate = rate
        }
        #endif
    }

    static func clearFailure() {
        #if os(iOS)
        DebugSwift.Network.shared.disableFailureInjection()
        #else
        update {
            $0.failureKind = nil
            $0.httpErrorCodes = []
            $0.failureRate = 0
        }
        #endif
    }

    static func setRewrite(urlPattern: String, body: String) {
        let rule = ResponseBodyRewriteRule(urlPattern: urlPattern, responseBody: body)
        #if os(iOS)
        DebugSwift.Network.shared.enableResponseBodyRewrite(rules: [rule])
        #else
        update { $0.rewrite = rule }
        #endif
    }

    static func clearRewrite() {
        #if os(iOS)
        DebugSwift.Network.shared.disableResponseBodyRewrite()
        #else
        update { $0.rewrite = nil }
        #endif
    }

    static func reset() {
        clearDelay()
        clearFailure()
        clearRewrite()
    }

    #if os(Android)
    private struct Rules: Sendable {
        var delay: ClosedRange<Double>?
        var failureKind: String?
        var httpErrorCodes: [Int] = []
        var failureRate: Double = 0
        var rewrite: ResponseBodyRewriteRule?

        var isEmpty: Bool {
            delay == nil && failureKind == nil && httpErrorCodes.isEmpty && rewrite == nil
        }

        func decision(for url: String) -> NetworkInjectionDecision {
            var decision = NetworkInjectionDecision()
            if let delay {
                decision.delaySeconds = Double.random(in: delay)
            }
            if failureRate > 0, Double.random(in: 0..<1) < failureRate {
                if let failureKind {
                    decision.failure = .init(kind: failureKind)
                } else if let statusCode = httpErrorCodes.randomElement() {
                    decision.failure = .init(kind: "httpError", statusCode: statusCode)
                }
            }
            if let rewrite, let requestURL = URL(string: url) {
                let config = ResponseBodyRewriteConfig(isEnabled: true, rules: [rewrite])
                if config.matchingRule(for: URLRequest(url: requestURL)) != nil {
                    decision.rewrite = .init(statusCode: rewrite.responseStatusCode, body: rewrite.responseBody, shortCircuit: false)
                }
            }
            return decision
        }
    }

    private final class RulesBox: @unchecked Sendable {
        private let lock = NSLock()
        private var rules = Rules()

        var current: Rules {
            get { lock.lock(); defer { lock.unlock() }; return rules }
            set { lock.lock(); defer { lock.unlock() }; rules = newValue }
        }
    }

    private static let box = RulesBox()

    private static func update(_ change: (inout Rules) -> Void) {
        var rules = box.current
        change(&rules)
        box.current = rules
        if rules.isEmpty {
            // Installing again puts back the provider that reads the panel's rules.
            ExampleDebugger.install()
        } else {
            let box = box
            NetworkInjection.install { url, _ in box.current.decision(for: url) }
        }
    }
    #endif
}
