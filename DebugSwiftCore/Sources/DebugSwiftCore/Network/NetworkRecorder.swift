import Foundation

/// Bounded, thread-safe store of recent HTTP exchanges.
///
/// Stack-agnostic on purpose: anything that can describe a finished request can feed it,
/// so the same inspector works on iOS and Android with `URLSession`, OkHttp, or a custom
/// transport. Records pass through a `NetworkSanitizer` on ingestion, so credentials in headers,
/// query strings and bodies never sit in memory or reach an export.
public actor NetworkRecorder {
    public static let shared = NetworkRecorder()

    public static let defaultCapacity = 500
    public static let defaultBodyLimit = 256 * 1024

    private let capacity: Int
    private let bodyLimit: Int
    private var sanitizer: NetworkSanitizer
    private var records: [NetworkRecord] = []
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// - Parameters:
    ///   - capacity: Most recent records kept; older ones are dropped first.
    ///   - bodyLimit: Bytes kept per request or response body; longer bodies are truncated.
    ///   - sanitizer: Masks headers, query parameters and body fields on ingestion.
    public init(
        capacity: Int = NetworkRecorder.defaultCapacity,
        bodyLimit: Int = NetworkRecorder.defaultBodyLimit,
        sanitizer: NetworkSanitizer = .default
    ) {
        self.capacity = max(1, capacity)
        self.bodyLimit = max(0, bodyLimit)
        self.sanitizer = sanitizer
    }

    /// Masks only the given header names; query strings and bodies use the default rules.
    public init(
        capacity: Int = NetworkRecorder.defaultCapacity,
        bodyLimit: Int = NetworkRecorder.defaultBodyLimit,
        redactedHeaders: Set<String>
    ) {
        var sanitizer = NetworkSanitizer.default
        sanitizer.headers = redactedHeaders
        self.init(capacity: capacity, bodyLimit: bodyLimit, sanitizer: sanitizer)
    }

    /// Replaces the rules for records captured from now on. Stored records keep the rules they
    /// were captured with.
    public func setSanitizer(_ sanitizer: NetworkSanitizer) {
        self.sanitizer = sanitizer
    }

    public var currentSanitizer: NetworkSanitizer {
        sanitizer
    }

    public func record(_ record: NetworkRecord) {
        records.append(sanitized(record))
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
        notifyObservers()
    }

    /// Records oldest first.
    public func snapshot() -> [NetworkRecord] {
        records
    }

    public func clear() {
        guard !records.isEmpty else { return }
        records.removeAll()
        notifyObservers()
    }

    public func harCaptures() -> [HARCapture] {
        records.map(\.harCapture)
    }

    public func harJSON(pretty: Bool = true) -> String? {
        HAREncoder.encodeJSON(harCaptures(), pretty: pretty)
    }

    /// Emits once per change, coalescing bursts. Re-read `snapshot()` after each value.
    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func notifyObservers() {
        for continuation in observers.values {
            continuation.yield()
        }
    }

    /// Masks before truncating: a cut JSON body no longer parses, so its fields could not be found.
    private func sanitized(_ record: NetworkRecord) -> NetworkRecord {
        let clean = sanitizer.sanitize(record)
        let outcome: NetworkRecord.Outcome
        switch clean.outcome {
        case let .response(statusCode, headers, body):
            outcome = .response(statusCode: statusCode, headers: headers, body: truncated(body))
        case .failure:
            outcome = clean.outcome
        }
        return NetworkRecord(
            id: clean.id,
            startedAt: clean.startedAt,
            duration: clean.duration,
            method: clean.method,
            url: clean.url,
            requestHeaders: clean.requestHeaders,
            requestBody: truncated(clean.requestBody),
            outcome: outcome
        )
    }

    private func truncated(_ body: Data?) -> Data? {
        guard let body, body.count > bodyLimit else { return body }
        return body.prefix(bodyLimit)
    }
}
