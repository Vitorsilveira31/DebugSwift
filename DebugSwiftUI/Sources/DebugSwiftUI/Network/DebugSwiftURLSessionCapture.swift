import DebugSwiftCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension DebugSwiftRuntime {
    /// Makes DebugSwift capture the sessions created from `configuration`: call it before
    /// `URLSession(configuration:)`. `URLSession.shared` needs nothing.
    ///
    /// iOS captures every session already, so this does nothing there. On Android it adds the
    /// protocol that records each request in the HTTP Inspector and applies Network Injection rules.
    static func configure(_ configuration: URLSessionConfiguration) {
        #if os(Android)
        DebugSwiftURLSessionCapture.add(to: configuration)
        #endif
    }
}

#if os(Android)
/// Captures Swift `URLSession` traffic on Android, where Foundation is swift-corelibs-foundation.
///
/// A task there asks its configuration's `protocolClasses` first, and the default configuration
/// already lists Foundation's own HTTP protocol, so `URLProtocol.registerClass` never sees http(s)
/// requests. The protocol is put first in the configuration instead: in `URLSession.shared`'s at
/// install, and in other configurations through `DebugSwiftRuntime.configure(_:)`.
enum DebugSwiftURLSessionCapture {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        // swift-corelibs-foundation returns the session's live configuration, and each new task
        // reads its protocolClasses, so this reaches every task URLSession.shared starts from now on.
        add(to: URLSession.shared.configuration)
    }

    static func add(to configuration: URLSessionConfiguration) {
        var classes = configuration.protocolClasses ?? []
        let capture = ObjectIdentifier(DebugSwiftURLProtocol.self)
        guard !classes.contains(where: { ObjectIdentifier($0) == capture }) else { return }
        classes.insert(DebugSwiftURLProtocol.self, at: 0)
        configuration.protocolClasses = classes
    }
}

/// Sends each http(s) request through a session of its own, applying the Network Injection rules,
/// and records the exchange in `NetworkRecorder.shared`, which the HTTP Inspector lists.
final class DebugSwiftURLProtocol: URLProtocol, @unchecked Sendable {
    /// The session that really sends the requests. Its configuration does not list this protocol.
    private static let transport = URLSession(configuration: .default)

    private let lock = NSLock()
    private var loading: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// What the loading task needs. Foundation calls a protocol from its own queue and keeps it alive
    /// until loading ends, so handing both across is safe.
    private struct Loading: @unchecked Sendable {
        let request: URLRequest
        weak var owner: DebugSwiftURLProtocol?
    }

    override func startLoading() {
        let loading = Loading(request: request, owner: self)
        let task = Task { await Self.load(loading) }
        lock.lock()
        self.loading = task
        lock.unlock()
    }

    private static func load(_ loading: Loading) async {
        let request = loading.request
        let startedAt = Date()
        do {
            let (data, response) = try await NetworkInjection.apply(to: request) { request in
                try await DebugSwiftURLProtocol.transport.data(for: request)
            }
            try Task.checkCancellation()
            let http = response as? HTTPURLResponse
            await record(request, startedAt: startedAt, outcome: .response(
                statusCode: http?.statusCode ?? 0,
                headers: headers(of: http),
                body: data
            ))
            guard let owner = loading.owner else { return }
            owner.client?.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
            owner.client?.urlProtocol(owner, didLoad: data)
            owner.client?.urlProtocolDidFinishLoading(owner)
        } catch {
            if !(error is CancellationError) {
                await record(request, startedAt: startedAt, outcome: .failure(description: error.localizedDescription))
            }
            guard let owner = loading.owner else { return }
            owner.client?.urlProtocol(owner, didFailWithError: error)
        }
    }

    override func stopLoading() {
        lock.lock()
        let task = loading
        loading = nil
        lock.unlock()
        task?.cancel()
    }

    private static func record(_ request: URLRequest, startedAt: Date, outcome: NetworkRecord.Outcome) async {
        await NetworkRecorder.shared.record(NetworkRecord(
            startedAt: startedAt,
            duration: Date().timeIntervalSince(startedAt),
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "",
            requestHeaders: request.allHTTPHeaderFields ?? [:],
            requestBody: request.httpBody,
            outcome: outcome
        ))
    }

    private static func headers(of response: HTTPURLResponse?) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response?.allHeaderFields ?? [:] {
            if let key = key as? String { headers[key] = "\(value)" }
        }
        return headers
    }
}
#endif
