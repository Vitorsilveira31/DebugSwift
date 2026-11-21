import DebugSwiftCore
import Foundation

/// The delay, failure and response rewrite rules the panel's Network Injection screen edits.
///
/// It is the settings format both platforms already share: DebugSwift's URL protocol applies it on
/// iOS, and the Android runtime applies it to OkHttp traffic and to Swift `URLSession` requests.
/// `DebugSwift.Network.shared` changes it on Android through `DebugSwiftRuntime.networkInjection`.
struct DebugSwiftNetworkInjection: Codable, Sendable, Equatable {
    public struct Delay: Codable, Sendable, Equatable {
        public var isEnabled = false
        /// Every request waits this long. When `nil`, each waits a random time in `minDelay...maxDelay`.
        public var fixedDelay: Double?
        public var minDelay = 1.0
        public var maxDelay = 3.0
        /// Wildcard URL patterns the rule applies to; empty means every request.
        public var urlPatterns: [String] = []
        /// HTTP methods the rule applies to; empty means every method.
        public var httpMethods: [String] = []

        public init() {}
    }

    public struct Failure: Codable, Sendable, Equatable {
        public var isEnabled = false
        /// The share of matching requests that fail, from 0 to 1.
        public var failureRate = 0.5
        /// `timeout`, `connectionLost`, `notConnectedToInternet`, `cannotFindHost`, `dnsLookupFailed`,
        /// `httpError`, `sslError`, `cancelled` or `custom`.
        public var failureType = "timeout"
        /// The statuses an `httpError` failure answers with, one picked at random each time.
        public var customStatusCodes = [400, 401, 403, 404, 500, 502, 503]
        public var urlPatterns: [String] = []
        public var httpMethods: [String] = []
        public var customDomain = "DebugSwift.CustomNetworkError"
        public var customCode = -1
        public var customDescription = "Injected custom network error."

        public init() {}
    }

    public struct Rule: Codable, Sendable, Equatable {
        public var id: String
        public var urlPattern: String
        public var responseBody: String
        public var responseStatusCode: Int?
        /// `nil` matches every method.
        public var httpMethod: String?
        public var isEnabled: Bool
        /// `wildcard` when the pattern holds `*` or `?`, otherwise `exact`.
        public var matchType: String

        public init(
            urlPattern: String,
            responseBody: String,
            responseStatusCode: Int? = nil,
            httpMethod: String? = nil,
            isEnabled: Bool = true
        ) {
            id = UUID().uuidString
            self.urlPattern = urlPattern
            self.responseBody = responseBody
            self.responseStatusCode = responseStatusCode
            self.httpMethod = httpMethod?.uppercased()
            self.isEnabled = isEnabled
            matchType = urlPattern.contains("*") || urlPattern.contains("?") ? "wildcard" : "exact"
        }
    }

    public struct Rewrite: Codable, Sendable, Equatable {
        public var isEnabled = false
        /// Checked in order; the first enabled rule that matches answers the request.
        public var rules: [Rule] = []
        public var autoEnableOnRun = false
        /// Answers without sending the request.
        public var shortCircuitEnabled = true
        public var multipleMatchEnabled = false

        public init() {}
    }

    public var delay = Delay()
    public var failure = Failure()
    public var rewrite = Rewrite()

    public init() {}
}

@MainActor
extension DebugSwiftRuntime {
    /// The Network Injection rules, the same ones the panel shows and edits, on iOS and Android.
    static var networkInjection: DebugSwiftNetworkInjection {
        get {
            guard let data = networkInjectionSettingsJSON().data(using: .utf8),
                  let settings = try? JSONDecoder().decode(DebugSwiftNetworkInjection.self, from: data) else {
                return DebugSwiftNetworkInjection()
            }
            return settings
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else { return }
            _ = applyNetworkInjectionSettingsJSON(json)
        }
    }
}
