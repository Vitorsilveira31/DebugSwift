#if os(Android)
import DebugSwiftCore
import Foundation
import FoundationNetworking

public struct DebugSwiftThresholdEndpointSnapshot: Sendable {
    public let endpoint: String
    public let limit: Int
    public let timeWindow: TimeInterval

    public init(endpoint: String, limit: Int, timeWindow: TimeInterval) {
        self.endpoint = endpoint
        self.limit = limit
        self.timeWindow = timeWindow
    }
}

public struct DebugSwiftThresholdBreachSnapshot: Sendable {
    public let timestamp: Date
    public let message: String

    public init(timestamp: Date, message: String) {
        self.timestamp = timestamp
        self.message = message
    }
}

public struct DebugSwiftThresholdSnapshot: Sendable {
    public let isEnabled: Bool
    public let limit: Int
    public let timeWindow: TimeInterval
    public let shouldBlockRequests: Bool
    public let currentRequestCount: Int
    public let totalBreaches: Int
    public let endpointLimits: [DebugSwiftThresholdEndpointSnapshot]
    public let recentBreaches: [DebugSwiftThresholdBreachSnapshot]

    public init(
        isEnabled: Bool,
        limit: Int,
        timeWindow: TimeInterval,
        shouldBlockRequests: Bool,
        currentRequestCount: Int,
        totalBreaches: Int,
        endpointLimits: [DebugSwiftThresholdEndpointSnapshot],
        recentBreaches: [DebugSwiftThresholdBreachSnapshot]
    ) {
        self.isEnabled = isEnabled
        self.limit = limit
        self.timeWindow = timeWindow
        self.shouldBlockRequests = shouldBlockRequests
        self.currentRequestCount = currentRequestCount
        self.totalBreaches = totalBreaches
        self.endpointLimits = endpointLimits
        self.recentBreaches = recentBreaches
    }
}

public final class NetworkThresholdTracker {
    public struct ThresholdBreach: Sendable {
        public let timestamp: Date
        public let requestCount: Int
        public let threshold: Int
        public let endpoint: String?
        public let message: String
    }
}

public enum CustomHTTPProtocolURLScheme: String, CaseIterable {
    case http
    case https
    case ftp
    case mailto
    case file
    case data
    case tel
    case sms
    case ws
    case wss
}

/// Receives the events of each request DebugSwift captures, as on iOS.
public protocol CustomHTTPProtocolDelegate: AnyObject {
    func urlSession(_ protocol: URLProtocol, didReceive response: URLResponse)
    func urlSession(_ protocol: URLProtocol, didReceive data: Data)
    func didFinishLoading(_ protocol: URLProtocol)
    func urlSession(_ protocol: URLProtocol, didFailWithError error: Error)
    func urlSession(
        _ protocol: URLProtocol,
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    )
}

public protocol EncryptionServiceProtocol {
    func decrypt(_ data: Data, using key: Data?) -> Data?
    func isEncrypted(_ data: Data) -> Bool
    func getDecryptionKey(for url: URL?) -> Data?
    func registerCustomDecryptor(for urlPattern: String, decryptor: @escaping (Data) -> Data?)
    func customDecrypt(_ data: Data, for url: URL?) -> Data?
}

/// Decrypts captured response bodies. AES-GCM keys registered with
/// `DebugSwift.Network.registerDecryptionKey(for:key:)` are applied by the Android runtime; custom
/// decryptors run here, in Swift, for the requests DebugSwift captures from `URLSession`.
public final class EncryptionService: EncryptionServiceProtocol, @unchecked Sendable {
    public static let shared = EncryptionService()

    private let lock = NSLock()
    private var keys: [String: Data] = [:]
    private var decryptors: [String: (Data) -> Data?] = [:]

    public init() {}

    public func decrypt(_ data: Data, using key: Data?) -> Data? {
        nil
    }

    public func isEncrypted(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        if (try? JSONSerialization.jsonObject(with: data)) != nil { return false }
        return String(data: data, encoding: .utf8) == nil || Data(base64Encoded: data) != nil
    }

    public func getDecryptionKey(for url: URL?) -> Data? {
        guard let url = url?.absoluteString else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return keys.first { url.matches(wildcardPattern: $0.key) }?.value
    }

    public func registerCustomDecryptor(for urlPattern: String, decryptor: @escaping (Data) -> Data?) {
        lock.lock()
        decryptors[urlPattern] = decryptor
        lock.unlock()
    }

    public func customDecrypt(_ data: Data, for url: URL?) -> Data? {
        guard let url = url?.absoluteString else { return nil }
        lock.lock()
        let decryptor = decryptors.first { url.matches(wildcardPattern: $0.key) }?.value
        lock.unlock()
        return decryptor?(data)
    }

    func registerKey(_ key: Data, for urlPattern: String) {
        lock.lock()
        keys[urlPattern] = key
        lock.unlock()
    }

    func clearKeys() {
        lock.lock()
        keys.removeAll()
        lock.unlock()
    }

    var keyPatterns: [String] {
        lock.lock()
        defer { lock.unlock() }
        return keys.keys.sorted()
    }
}

extension DebugSwift {
    public class Network: @unchecked Sendable {
        public static let shared = Network()
        private init() {}

        /// Requests whose URL contains any of these strings are not captured.
        public var ignoredURLs = [String]() {
            didSet { sendFilters() }
        }

        /// When not empty, only requests whose URL contains one of these strings are captured.
        public var onlyURLs = [String]() {
            didSet { sendFilters() }
        }

        /// The URL schemes DebugSwift captures from `URLSession`.
        public var onlySchemes = CustomHTTPProtocolURLScheme.allCases.filter { $0 != .ws && $0 != .wss }

        /// Told about each request DebugSwift captures from `URLSession`.
        public var delegate: CustomHTTPProtocolDelegate?

        public var encryptionService: EncryptionServiceProtocol = EncryptionService.shared

        /// Decrypts captured response bodies with the registered keys and decryptors.
        public var isDecryptionEnabled = false {
            didSet { _ = DebugSwiftNativeBridge.performNetworkDecryptionAction("set_enabled", isDecryptionEnabled ? "true" : "false") }
        }

        /// Keeps credentials out of exported cURL commands. Android always masks them through the
        /// sanitizer; the value is kept for the same code to compile.
        public var redactCurlCredentials = true

        /// Masks credentials and personal data in captured traffic.
        public var sanitizer = NetworkSanitizer.default {
            didSet {
                let sanitizer = sanitizer
                Task { await DebugSwiftRuntime.configureNetworkSanitizer(sanitizer) }
            }
        }

        // MARK: - Threshold Limiter API

        public var threshold: Int {
            get { DebugSwiftHost.int(DebugSwiftHost.object("network.threshold.get")["limit"]) ?? 1000 }
            set { setThreshold(newValue, timeWindow: thresholdWindow) }
        }

        private var thresholdWindow: TimeInterval {
            DebugSwiftHost.double(DebugSwiftHost.object("network.threshold.get")["timeWindow"]) ?? 60
        }

        public func enableRequestTracking() {
            DebugSwiftHost.call("network.threshold.tracking", ["enabled": true])
        }

        public func disableRequestTracking() {
            DebugSwiftHost.call("network.threshold.tracking", ["enabled": false])
        }

        public func setThreshold(_ limit: Int, timeWindow: TimeInterval = 60.0) {
            DebugSwiftHost.call("network.threshold.set", ["limit": limit, "timeWindow": timeWindow])
        }

        public func setThresholdAlert(emoji: String, message: String) {
            DebugSwiftHost.call("network.threshold.alert", ["emoji": emoji, "message": message])
        }

        public func setRequestBlocking(_ enabled: Bool) {
            DebugSwiftHost.call("network.threshold.blocking", ["enabled": enabled])
        }

        public func setEndpointThreshold(_ endpoint: String, limit: Int, timeWindow: TimeInterval = 60.0) {
            DebugSwiftHost.call("network.threshold.endpoint", ["endpoint": endpoint, "limit": limit, "timeWindow": timeWindow])
        }

        public func getCurrentRequestCount(endpoint: String? = nil) -> Int {
            DebugSwiftHost.int(DebugSwiftHost.object("network.threshold.count", ["endpoint": endpoint ?? ""])["count"]) ?? 0
        }

        public func getThresholdSnapshot() -> DebugSwiftThresholdSnapshot {
            let state = DebugSwiftHost.object("network.threshold.get")
            let endpoints = (state["endpointLimits"] as? [[String: Any]] ?? []).map {
                DebugSwiftThresholdEndpointSnapshot(
                    endpoint: $0["endpoint"] as? String ?? "",
                    limit: DebugSwiftHost.int($0["limit"]) ?? 0,
                    timeWindow: DebugSwiftHost.double($0["timeWindow"]) ?? 60
                )
            }
            let breaches = Self.breaches(from: state)
            return DebugSwiftThresholdSnapshot(
                isEnabled: state["isEnabled"] as? Bool ?? false,
                limit: DebugSwiftHost.int(state["limit"]) ?? 1000,
                timeWindow: DebugSwiftHost.double(state["timeWindow"]) ?? 60,
                shouldBlockRequests: state["shouldBlockRequests"] as? Bool ?? false,
                currentRequestCount: DebugSwiftHost.int(state["currentRequestCount"]) ?? 0,
                totalBreaches: breaches.count,
                endpointLimits: endpoints,
                recentBreaches: breaches.suffix(5).reversed().map {
                    DebugSwiftThresholdBreachSnapshot(timestamp: $0.timestamp, message: $0.message)
                }
            )
        }

        public func getBreachHistory() -> [NetworkThresholdTracker.ThresholdBreach] {
            Self.breaches(from: DebugSwiftHost.object("network.threshold.get"))
        }

        public func clearThresholdHistory() {
            DebugSwiftHost.call("network.threshold.clear")
        }

        public func getThresholdLogs() -> String {
            DebugSwiftHost.object("network.threshold.logs")["logs"] as? String ?? ""
        }

        @MainActor
        public func exportThresholdLogs() {
            DebugSwiftHost.call("network.threshold.export")
        }

        private static func breaches(from state: [String: Any]) -> [NetworkThresholdTracker.ThresholdBreach] {
            (state["breaches"] as? [[String: Any]] ?? []).map {
                NetworkThresholdTracker.ThresholdBreach(
                    timestamp: Date(timeIntervalSince1970: (DebugSwiftHost.double($0["timestamp"]) ?? 0) / 1000),
                    requestCount: DebugSwiftHost.int($0["requestCount"]) ?? 0,
                    threshold: DebugSwiftHost.int($0["threshold"]) ?? 0,
                    endpoint: $0["endpoint"] as? String,
                    message: $0["message"] as? String ?? ""
                )
            }
        }

        // MARK: - Network Injection

        public func enableRequestDelay(_ delay: TimeInterval, urlPatterns: [String] = [], httpMethods: [String] = []) {
            Self.updateInjection { settings in
                settings.delay.isEnabled = true
                settings.delay.fixedDelay = delay
                settings.delay.urlPatterns = urlPatterns
                settings.delay.httpMethods = httpMethods
            }
        }

        public func enableRequestDelay(
            min minDelay: TimeInterval,
            max maxDelay: TimeInterval,
            urlPatterns: [String] = [],
            httpMethods: [String] = []
        ) {
            Self.updateInjection { settings in
                settings.delay.isEnabled = true
                settings.delay.fixedDelay = nil
                settings.delay.minDelay = minDelay
                settings.delay.maxDelay = Swift.max(minDelay, maxDelay)
                settings.delay.urlPatterns = urlPatterns
                settings.delay.httpMethods = httpMethods
            }
        }

        public func disableRequestDelay() {
            Self.updateInjection { $0.delay.isEnabled = false }
        }

        public func enableFailureInjection(
            failureRate: Double = 0.5,
            failureType: NetworkFailureConfig.FailureType = .timeout,
            urlPatterns: [String] = [],
            httpMethods: [String] = []
        ) {
            Self.updateInjection { settings in
                settings.failure.isEnabled = true
                settings.failure.failureRate = Swift.min(Swift.max(failureRate, 0), 1)
                settings.failure.urlPatterns = urlPatterns
                settings.failure.httpMethods = httpMethods
                Self.apply(failureType, to: &settings.failure)
            }
        }

        public func enableHTTPErrorInjection(
            failureRate: Double = 0.5,
            statusCodes: [Int] = [400, 401, 403, 404, 500, 502, 503],
            urlPatterns: [String] = [],
            httpMethods: [String] = []
        ) {
            Self.updateInjection { settings in
                settings.failure.isEnabled = true
                settings.failure.failureRate = Swift.min(Swift.max(failureRate, 0), 1)
                settings.failure.failureType = "httpError"
                settings.failure.customStatusCodes = statusCodes
                settings.failure.urlPatterns = urlPatterns
                settings.failure.httpMethods = httpMethods
            }
        }

        public func disableFailureInjection() {
            Self.updateInjection { $0.failure.isEnabled = false }
        }

        public func configureNetworkInjection(
            delayConfig: RequestDelayConfig? = nil,
            failureConfig: NetworkFailureConfig? = nil,
            rewriteConfig: ResponseBodyRewriteConfig? = nil
        ) {
            Self.updateInjection { settings in
                if let delayConfig {
                    settings.delay.isEnabled = delayConfig.isEnabled
                    settings.delay.fixedDelay = delayConfig.fixedDelay
                    settings.delay.minDelay = delayConfig.minDelay
                    settings.delay.maxDelay = delayConfig.maxDelay
                    settings.delay.urlPatterns = delayConfig.urlPatterns
                    settings.delay.httpMethods = delayConfig.httpMethods
                }
                if let failureConfig {
                    settings.failure.isEnabled = failureConfig.isEnabled
                    settings.failure.failureRate = failureConfig.failureRate
                    settings.failure.urlPatterns = failureConfig.urlPatterns
                    settings.failure.httpMethods = failureConfig.httpMethods
                    settings.failure.customStatusCodes = failureConfig.customStatusCodes
                    Self.apply(failureConfig.failureType, to: &settings.failure)
                }
                if let rewriteConfig {
                    settings.rewrite.isEnabled = rewriteConfig.isEnabled
                    settings.rewrite.rules = rewriteConfig.rules.map(Self.rule)
                }
            }
        }

        public func enableResponseBodyRewrite(rules: [ResponseBodyRewriteRule]) {
            Self.updateInjection { settings in
                settings.rewrite.isEnabled = true
                settings.rewrite.rules = rules.map(Self.rule)
            }
        }

        public func disableResponseBodyRewrite() {
            Self.updateInjection { $0.rewrite.isEnabled = false }
        }

        private static func rule(_ rule: ResponseBodyRewriteRule) -> DebugSwiftNetworkInjection.Rule {
            var converted = DebugSwiftNetworkInjection.Rule(
                urlPattern: rule.urlPattern,
                responseBody: rule.responseBody,
                responseStatusCode: rule.responseStatusCode,
                httpMethod: rule.httpMethod?.rawValue,
                isEnabled: rule.isEnabled
            )
            converted.matchType = rule.matchType.rawValue
            return converted
        }

        private static func apply(_ type: NetworkFailureConfig.FailureType, to failure: inout DebugSwiftNetworkInjection.Failure) {
            switch type {
            case .timeout: failure.failureType = "timeout"
            case .connectionLost: failure.failureType = "connectionLost"
            case .notConnectedToInternet: failure.failureType = "notConnectedToInternet"
            case .cannotFindHost: failure.failureType = "cannotFindHost"
            case .dnsLookupFailed: failure.failureType = "dnsLookupFailed"
            case .sslError: failure.failureType = "sslError"
            case .cancelled: failure.failureType = "cancelled"
            case let .httpError(statusCode):
                failure.failureType = "httpError"
                if let statusCode { failure.customStatusCodes = [statusCode] }
            case let .custom(domain, code, description):
                failure.failureType = "custom"
                failure.customDomain = domain
                failure.customCode = code
                failure.customDescription = description
            }
        }

        private static let injectionLock = NSLock()

        /// Reads the rules, changes them and applies them before returning, so a request started
        /// right after the call already sees them. The runtime applies the change only if the rules
        /// are still the version that was read; if something else changed them in between (an
        /// import, the panel), the change is made again on top of theirs.
        private static func updateInjection(_ change: (inout DebugSwiftNetworkInjection) -> Void) {
            injectionLock.lock()
            defer { injectionLock.unlock() }
            for _ in 0..<5 {
                let reply = DebugSwiftHost.object("network.injection.get")
                guard let version = DebugSwiftHost.int(reply["version"]),
                      let raw = reply["settings"],
                      let data = try? JSONSerialization.data(withJSONObject: raw),
                      var settings = try? JSONDecoder().decode(DebugSwiftNetworkInjection.self, from: data) else { return }
                change(&settings)
                guard let encoded = try? JSONEncoder().encode(settings),
                      let object = try? JSONSerialization.jsonObject(with: encoded) else { return }
                let result = DebugSwiftHost.object("network.injection.set", ["version": version, "settings": object])
                if result["ok"] as? Bool == true || result["message"] as? String != "conflict" { return }
            }
        }

        // MARK: - Injection settings

        /// The delay, failure and rewrite settings as JSON, the format the panel's form edits.
        public func networkInjectionSettingsJSON() -> String {
            DebugSwiftNativeBridge.networkInjectionSettingsJSON()
        }

        /// Applies settings produced by the shared SwiftUI form.
        @discardableResult
        public func applyNetworkInjectionSettingsJSON(_ json: String) -> Bool {
            Self.injectionLock.lock()
            defer { Self.injectionLock.unlock() }
            return DebugSwiftNativeBridge.applyNetworkInjectionSettingsJSON(json) == "Network injection settings applied."
        }

        /// Exports response modifier rules in the CSV format the iOS settings screen uses.
        public func responseRewriteRulesCSV() -> String {
            DebugSwiftHost.object("network.injection.csv")["csv"] as? String ?? ""
        }

        /// Imports response modifier rules from CSV, updating existing URL and method pairs.
        public func importResponseRewriteRulesCSV(_ csv: String) -> String {
            Self.injectionLock.lock()
            defer { Self.injectionLock.unlock() }
            return DebugSwiftNativeBridge.importNetworkInjectionRulesCSV(csv)
        }

        /// Opens the share sheet for the exported response modifier CSV.
        @MainActor
        public func shareResponseRewriteRulesCSV() {
            _ = DebugSwiftNativeBridge.exportNetworkInjectionRulesCSV()
        }

        // MARK: - History

        public func clearNetworkHistory() {
            DebugSwiftHost.call("network.clearHistory")
            Task { await NetworkRecorder.shared.clear() }
        }

        @MainActor
        public func clearWebSocketHistory() {
            DebugSwiftHost.call("network.clearWebSockets")
        }

        @MainActor
        public func clearAllNetworkData() {
            DebugSwiftHost.call("network.clearAll")
            Task { await NetworkRecorder.shared.clear() }
        }

        /// Records a request sent by a transport DebugSwift does not capture, so it shows in the
        /// HTTP Inspector like the others.
        @discardableResult
        public func logRequest(
            url: URL,
            method: String = "GET",
            requestHeaders: [String: String]? = nil,
            requestBody: Data? = nil,
            responseStatusCode: Int? = nil,
            responseHeaders: [String: String]? = nil,
            responseBody: Data? = nil,
            error: Error? = nil,
            startTime: Date? = nil,
            endTime: Date = Date()
        ) -> Bool {
            guard Self.accepts(url) else { return false }
            let startedAt = startTime ?? endTime
            let outcome: NetworkRecord.Outcome = if let error {
                .failure(description: error.localizedDescription)
            } else {
                .response(statusCode: responseStatusCode ?? 200, headers: responseHeaders ?? [:], body: responseBody)
            }
            let record = NetworkRecord(
                startedAt: startedAt,
                duration: Swift.max(0, endTime.timeIntervalSince(startedAt)),
                method: method,
                url: url.absoluteString,
                requestHeaders: requestHeaders ?? [:],
                requestBody: requestBody,
                outcome: outcome
            )
            Task { await NetworkRecorder.shared.record(record) }
            return true
        }

        /// Keeps the requests of the last `retentionDays` days in the Session History screen.
        public static func configureSessionHistory(retentionDays: Int, batchSize: Int) {
            DebugSwiftHost.call("network.sessionHistory", ["retentionDays": retentionDays, "batchSize": batchSize])
        }

        // MARK: - Decryption

        public func setDecryptionEnabled(_ enabled: Bool) {
            isDecryptionEnabled = enabled
        }

        /// Registers an AES-GCM key for responses whose URL matches `urlPattern`.
        public func registerDecryptionKey(for urlPattern: String, key: Data) {
            EncryptionService.shared.registerKey(key, for: urlPattern)
            _ = DebugSwiftNativeBridge.performNetworkDecryptionAction(
                "register_key",
                "\(Self.regex(fromWildcard: urlPattern)):\(key.base64EncodedString())"
            )
        }

        public var registeredDecryptionKeyPatterns: [String] {
            EncryptionService.shared.keyPatterns
        }

        public func clearDecryptionKeys() {
            EncryptionService.shared.clearKeys()
            _ = DebugSwiftNativeBridge.performNetworkDecryptionAction("clear_keys", "")
        }

        public func registerCustomDecryptor(for urlPattern: String, decryptor: @escaping (Data) -> Data?) {
            encryptionService.registerCustomDecryptor(for: urlPattern, decryptor: decryptor)
        }

        public func setEncryptionService(_ service: EncryptionServiceProtocol) {
            encryptionService = service
        }

        // MARK: - URLSession configuration

        /// Makes the sessions created from `configuration` captured.
        public func injectIntoConfiguration(_ configuration: URLSessionConfiguration) {
            DebugSwiftRuntime.configure(configuration)
        }

        public func defaultConfiguration() -> URLSessionConfiguration {
            let configuration = URLSessionConfiguration.default
            injectIntoConfiguration(configuration)
            return configuration
        }

        public func ephemeralConfiguration() -> URLSessionConfiguration {
            let configuration = URLSessionConfiguration.ephemeral
            injectIntoConfiguration(configuration)
            return configuration
        }

        // MARK: - Capture filters

        /// Whether DebugSwift captures a request to `url`.
        static func accepts(_ url: URL) -> Bool {
            let network = Network.shared
            guard let scheme = url.scheme?.lowercased(),
                  network.onlySchemes.contains(where: { $0.rawValue == scheme }) else { return false }
            let text = url.absoluteString
            if network.ignoredURLs.contains(where: { !$0.isEmpty && text.contains($0) }) { return false }
            let only = network.onlyURLs.filter { !$0.isEmpty }
            return only.isEmpty || only.contains { text.contains($0) }
        }

        /// The response body a decryptor reads, if decryption is on and one applies to `url`.
        func decryptedBody(_ data: Data, for url: URL) -> String? {
            guard isDecryptionEnabled,
                  let decrypted = encryptionService.customDecrypt(data, for: url),
                  let text = String(data: decrypted, encoding: .utf8) else { return nil }
            return text
        }

        private func sendFilters() {
            DebugSwiftHost.call("network.filters", ["ignored": ignoredURLs, "only": onlyURLs])
        }

        private static func regex(fromWildcard pattern: String) -> String {
            NSRegularExpression.escapedPattern(for: pattern)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".")
        }
    }

    /// The app's stored data. Android finds the app's databases, preferences and files on its own;
    /// register the ones it cannot list.
    public class Resources: @unchecked Sendable {
        public static let shared = Resources()
        private init() {}

        /// iOS App Group containers. Android apps have no shared containers, so the list stays empty
        /// of accessible locations.
        public var appGroupIdentifiers: [String] = []

        public func configureAppGroups(_ identifiers: [String]) {
            appGroupIdentifiers = identifiers
        }

        public func addAppGroup(_ identifier: String) {
            guard !appGroupIdentifiers.contains(identifier) else { return }
            appGroupIdentifiers.append(identifier)
        }

        public func removeAppGroup(_ identifier: String) {
            appGroupIdentifiers.removeAll { $0 == identifier }
        }

        public func getAccessibleAppGroups() -> [(identifier: String, url: URL)] {
            []
        }

        /// Lists a Room database in the database browser, the counterpart of `configureCoreData`.
        public func registerDatabase(named name: String) {
            DebugSwiftHost.call("resources.registerDatabase", ["name": name])
        }

        /// Lists a SharedPreferences file in the Preferences screen.
        public func registerPreferences(named name: String) {
            DebugSwiftHost.call("resources.registerPreferences", ["name": name])
        }
    }
}
#endif
