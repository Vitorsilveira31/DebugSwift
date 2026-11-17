import Foundation

/// One JSON file that tells a coding agent the app's state at a moment: which app and device,
/// current resource use, and the latest network calls. It complements the NDJSON agent debug log,
/// which is a timeline: the log says what happened, the snapshot says where things stand now.
///
/// iOS and Android write the same schema, documented in `Documentation/AGENT-SNAPSHOT.md`, as
/// `agent-snapshot.json` next to `agent-debug.ndjson`. URLs pass through a `NetworkSanitizer`.
public struct AgentSnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let fileName = "agent-snapshot.json"
    public static let defaultRequestLimit = 50

    public struct Request: Codable, Sendable, Equatable {
        public var method: String
        public var url: String
        /// 0 when the request failed before a response arrived.
        public var status: Int
        public var durationMs: Int
        public var error: String?

        public init(method: String, url: String, status: Int, durationMs: Int, error: String? = nil) {
            self.method = method
            self.url = url
            self.status = status
            self.durationMs = durationMs
            self.error = error
        }
    }

    public struct AgentLog: Codable, Sendable, Equatable {
        public var path: String
        public var enabled: Bool
        public var sessionId: String

        public init(path: String, enabled: Bool, sessionId: String) {
            self.path = path
            self.enabled = enabled
            self.sessionId = sessionId
        }
    }

    public var schemaVersion: Int
    /// Milliseconds since 1970, like the `timestamp` field of the NDJSON log.
    public var generatedAt: Int
    /// `ios` or `android`.
    public var platform: String
    /// `bundleId`, `version`, `build`.
    public var app: [String: String]
    /// `model`, `osVersion`.
    public var device: [String: String]
    /// Known keys: `cpuPercent`, `memoryBytes`, `fps`, `activeLeaks`. A platform omits what it cannot measure.
    public var metrics: [String: Double]
    /// Newest last, at most `defaultRequestLimit`.
    public var network: [Request]
    public var agentLog: AgentLog?

    public init(
        generatedAt: Date = Date(),
        platform: String,
        app: [String: String] = [:],
        device: [String: String] = [:],
        metrics: [String: Double] = [:],
        network: [Request] = [],
        agentLog: AgentLog? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.generatedAt = Int(generatedAt.timeIntervalSince1970 * 1000)
        self.platform = platform
        self.app = app
        self.device = device
        self.metrics = metrics
        self.network = network
        self.agentLog = agentLog
    }

    /// The newest `limit` records as snapshot requests, with URLs sanitized.
    public static func requests(
        from records: [NetworkRecord],
        limit: Int = AgentSnapshot.defaultRequestLimit,
        sanitizer: NetworkSanitizer = .default
    ) -> [Request] {
        records.suffix(max(0, limit)).map { record in
            let error: String? = if case let .failure(description) = record.outcome { description } else { nil }
            return Request(
                method: record.method,
                url: sanitizer.sanitize(url: record.url),
                status: record.statusCode ?? 0,
                durationMs: Int((record.duration * 1000).rounded()),
                error: error
            )
        }
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Writes `agent-snapshot.json` into `directory`, replacing an older one, and returns its URL.
    @discardableResult
    public func write(toDirectory directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.fileName)
        try jsonData().write(to: url, options: .atomic)
        return url
    }
}
