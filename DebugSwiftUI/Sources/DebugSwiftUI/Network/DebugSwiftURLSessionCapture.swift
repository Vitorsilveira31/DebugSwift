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

/// Lets Foundation's own HTTP protocol send each request, and watches it go by.
///
/// The request goes out through the protocol Foundation would have used, created for the same
/// task. So the task's session configuration (cookies, credentials, timeouts, cache), its
/// delegate's redirect and challenge decisions, data streamed to a data delegate and the file of
/// a download task behave exactly as without DebugSwift. A client in between records the exchange
/// for the HTTP Inspector.
///
/// Network Injection acts before the request is sent: a delay holds it back, and a block, an
/// injected failure or a short-circuit rewrite answers it without sending it. A rewrite that lets
/// the request through replaces the response the task's completion handler or `async` call gets;
/// a data delegate still receives the real body, which Foundation streams to it directly. Download
/// tasks honor delays and network failures, not rules that answer with an HTTP response.
final class DebugSwiftURLProtocol: URLProtocol {
    private enum State {
        case idle
        /// Waiting out an injected delay; the number tells this wait from a later one.
        case waiting(Int)
        /// Foundation's protocol is sending the request.
        case forwarding(URLProtocol)
        /// Answering from the injection rules without sending the request.
        case answering
        case finished
        case stopped
    }

    private let lock = NSLock()
    private var state = State.idle
    private var waits = 0

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return DebugSwift.Network.accepts(url)
    }

    override class func canInit(with task: URLSessionTask) -> Bool {
        if task is URLSessionWebSocketTask { return false }
        guard let request = task.currentRequest else { return false }
        return canInit(with: request)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        lock.lock()
        let current = state
        lock.unlock()
        if case let .forwarding(foundation) = current {
            // The task resumed after a suspension: Foundation's protocol picks up where it was.
            foundation.startLoading()
            return
        }
        guard let task else {
            fail(URLError(.unsupportedURL), startedAt: Date())
            return
        }
        let decision = NetworkInjection.decision(for: request)
        let startedAt = Date()
        guard let decision, decision.delaySeconds > 0 else {
            begin(task: task, decision: decision, startedAt: startedAt)
            return
        }
        lock.lock()
        waits += 1
        let wait = waits
        state = .waiting(wait)
        lock.unlock()
        // Foundation calls a protocol on the task's work queue; the request starts there after the
        // delay, as it would have without one.
        let queue = Self.workQueue(of: task) ?? DispatchQueue.global()
        // Foundation keeps a protocol alive while its task loads and calls it from the task's work
        // queue, where the delayed start runs too; the lock guards the state it reads.
        nonisolated(unsafe) let capture = self
        queue.asyncAfter(deadline: .now() + min(decision.delaySeconds, 60)) {
            capture.resumeAfterDelay(wait, task: task, decision: decision, startedAt: startedAt)
        }
    }

    private func resumeAfterDelay(_ wait: Int, task: URLSessionTask, decision: NetworkInjectionDecision, startedAt: Date) {
        begin(task: task, decision: decision, startedAt: startedAt, afterWait: wait)
    }

    override func stopLoading() {
        lock.lock()
        let current = state
        let suspending = task?.state == .suspended
        switch current {
        case .forwarding:
            break
        case .waiting where suspending:
            // Resuming starts the request over, delay included.
            state = .idle
        default:
            state = .stopped
        }
        lock.unlock()
        if case let .forwarding(foundation) = current {
            foundation.stopLoading()
        }
    }

    /// Starts the request or answers it. `afterWait` is the delay that just ended, if any: only that
    /// delay may still start the request, not an older one a suspension replaced.
    private func begin(task: URLSessionTask, decision: NetworkInjectionDecision?, startedAt: Date, afterWait: Int? = nil) {
        let isDownload = task is URLSessionDownloadTask
        if let decision, let url = request.url,
           let outcome = NetworkInjection.immediateOutcome(of: decision, for: url) {
            switch outcome {
            case let .success((data, response)) where !isDownload:
                guard move(to: .answering, afterWait: afterWait) else { return }
                answer(data: data, response: response, startedAt: startedAt)
                return
            case let .failure(error):
                guard move(to: .answering, afterWait: afterWait) else { return }
                fail(error, startedAt: startedAt)
                return
            case .success where decision.isBlocked:
                // A download's file cannot come from an injected response, but a blocked one still
                // must not reach the network: it fails instead.
                guard move(to: .answering, afterWait: afterWait) else { return }
                fail(URLError(.resourceUnavailable, userInfo: [
                    NSLocalizedDescriptionKey: "Blocked by DebugSwift network rules."
                ]), startedAt: startedAt)
                return
            case .success:
                // An injected HTTP error or rewrite cannot become a download file; it goes out as is.
                break
            }
        }
        guard let foundationProtocol = Self.foundationProtocol(for: task) else {
            guard move(to: .answering, afterWait: afterWait) else { return }
            fail(URLError(.unsupportedURL), startedAt: startedAt)
            return
        }
        let rewrite = isDownload ? nil : decision.flatMap { $0.rewrite == nil ? nil : $0 }
        let observer = DebugSwiftProtocolObserver(
            capture: self,
            client: client,
            request: request,
            startedAt: startedAt,
            rewrite: rewrite
        )
        let foundation = foundationProtocol.init(task: task, cachedResponse: cachedResponse, client: observer)
        guard move(to: .forwarding(foundation), afterWait: afterWait) else { return }
        foundation.startLoading()
    }

    /// Moves on, checked and changed in one step under the lock. Without `afterWait` it moves from
    /// idle; with it, only from that same wait. False once the request was stopped, answered, or
    /// its delay was replaced.
    private func move(to next: State, afterWait: Int? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch (state, afterWait) {
        case (.idle, nil):
            state = next
            return true
        case let (.waiting(current), wait?) where current == wait:
            state = next
            return true
        default:
            return false
        }
    }

    /// True while this protocol may still report the answer it is giving.
    private var isAnswering: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .answering = state { return true }
        return false
    }

    private func finish() {
        lock.lock()
        if case .answering = state { state = .finished }
        lock.unlock()
    }

    private func answer(data: Data, response: URLResponse, startedAt: Date) {
        let http = response as? HTTPURLResponse
        Self.record(request, startedAt: startedAt, outcome: .response(
            statusCode: http?.statusCode ?? 0,
            headers: Self.headers(of: http),
            body: data
        ))
        guard isAnswering else { return }
        let delegate = DebugSwift.Network.shared.delegate
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        delegate?.urlSession(self, didReceive: response)
        client?.urlProtocol(self, didLoad: data)
        delegate?.urlSession(self, didReceive: data)
        client?.urlProtocolDidFinishLoading(self)
        delegate?.didFinishLoading(self)
        finish()
    }

    private func fail(_ error: Error, startedAt: Date) {
        Self.record(request, startedAt: startedAt, outcome: .failure(description: error.localizedDescription))
        guard isAnswering || task == nil else { return }
        client?.urlProtocol(self, didFailWithError: error)
        DebugSwift.Network.shared.delegate?.urlSession(self, didFailWithError: error)
        finish()
    }

    /// The protocol Foundation would have picked for `task` had DebugSwift not been first: the
    /// first one after DebugSwift's in the task's own session configuration, so a protocol the
    /// host added (a mock, a custom transport) still answers. Foundation's defaults are the
    /// fallback when the session cannot be read.
    private static func foundationProtocol(for task: URLSessionTask) -> URLProtocol.Type? {
        let capture = ObjectIdentifier(DebugSwiftURLProtocol.self)
        let classes = session(of: task)?.configuration.protocolClasses
            ?? URLSessionConfiguration.default.protocolClasses
            ?? []
        return classes
            .compactMap { $0 as? URLProtocol.Type }
            .first { ObjectIdentifier($0) != capture && $0.canInit(with: task) }
    }

    /// The session a task belongs to. Foundation keeps it internal, so it is read through reflection.
    private static func session(of task: URLSessionTask) -> URLSession? {
        var mirror: Mirror? = Mirror(reflecting: task)
        while let current = mirror {
            if let value = current.children.first(where: { $0.label == "session" })?.value {
                // Stored as an implicitly unwrapped optional: unwrap it before casting.
                let wrapped = Mirror(reflecting: value)
                if wrapped.displayStyle == .optional {
                    return wrapped.children.first?.value as? URLSession
                }
                return value as? URLSession
            }
            mirror = current.superclassMirror
        }
        return nil
    }

    /// The task's work queue, where Foundation calls its protocols. It is internal to Foundation,
    /// so it is read through reflection; without it a delayed request starts on a global queue.
    private static func workQueue(of task: URLSessionTask) -> DispatchQueue? {
        var mirror: Mirror? = Mirror(reflecting: task)
        while let current = mirror {
            if let queue = current.children.first(where: { $0.label == "workQueue" })?.value as? DispatchQueue {
                return queue
            }
            mirror = current.superclassMirror
        }
        return nil
    }

    static func record(_ request: URLRequest, startedAt: Date, outcome: NetworkRecord.Outcome, decryptedBody: String? = nil) {
        let record = NetworkRecord(
            startedAt: startedAt,
            duration: Date().timeIntervalSince(startedAt),
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "",
            requestHeaders: request.allHTTPHeaderFields ?? [:],
            requestBody: request.httpBody,
            outcome: outcome,
            decryptedResponseBody: decryptedBody
        )
        Task { await NetworkRecorder.shared.record(record) }
    }

    static func headers(of response: HTTPURLResponse?) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response?.allHeaderFields ?? [:] {
            if let key = key as? String { headers[key] = "\(value)" }
        }
        return headers
    }
}

/// The client Foundation's protocol reports to: it passes every call on to the task's own client
/// unchanged, records the exchange, applies a pass-through rewrite and tells
/// `DebugSwift.Network.shared.delegate`.
private final class DebugSwiftProtocolObserver: NSObject, URLProtocolClient, @unchecked Sendable {
    /// What the inspector keeps of a body; the Android runtime trims it further.
    private static let inspectedBodyLimit = 1_048_576
    /// The largest body handed to a decryptor. A decryptor needs the whole body (an authentication
    /// tag is often at its end), so a longer one is not decrypted rather than decrypted in part.
    private static let decryptedBodyLimit = 8 * 1_048_576

    private weak var capture: DebugSwiftURLProtocol?
    private let client: URLProtocolClient?
    private let request: URLRequest
    private let startedAt: Date
    private let rewrite: NetworkInjectionDecision?

    private let lock = NSLock()
    private var response: URLResponse?
    /// True once the response came through `didReceive`, which Foundation calls only for tasks
    /// with a delegate; `async` and completion-handler tasks get it from `task.response`.
    private var responseReported = false
    private var body = Data()
    /// The whole body for a decryptor, up to `decryptedBodyLimit`; nil once it grew past that.
    private var fullBody: Data? = Data()
    private var recorded = false

    init(
        capture: DebugSwiftURLProtocol,
        client: URLProtocolClient?,
        request: URLRequest,
        startedAt: Date,
        rewrite: NetworkInjectionDecision?
    ) {
        self.capture = capture
        self.client = client
        self.request = request
        self.startedAt = startedAt
        self.rewrite = rewrite
    }

    private func rewritten(_ response: URLResponse) -> (Data, URLResponse)? {
        guard let rewrite, let url = request.url else { return nil }
        return NetworkInjection.rewritten(response, by: rewrite, for: url)
    }

    func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) {
        client?.urlProtocol(`protocol`, wasRedirectedTo: request, redirectResponse: redirectResponse)
    }

    func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) {
        client?.urlProtocol(`protocol`, cachedResponseIsValid: cachedResponse)
    }

    func urlProtocol(_ protocol: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) {
        let delivered = rewritten(response)?.1 ?? response
        lock.lock()
        self.response = delivered
        responseReported = true
        lock.unlock()
        client?.urlProtocol(`protocol`, didReceive: delivered, cacheStoragePolicy: policy)
        if let capture { DebugSwift.Network.shared.delegate?.urlSession(capture, didReceive: delivered) }
    }

    func urlProtocol(_ protocol: URLProtocol, didLoad data: Data) {
        lock.lock()
        let received = response ?? `protocol`.task?.response
        lock.unlock()
        let delivered = received.flatMap(rewritten)?.0 ?? data
        lock.lock()
        if body.count < Self.inspectedBodyLimit {
            body.append(delivered.prefix(Self.inspectedBodyLimit - body.count))
        }
        if let current = fullBody {
            fullBody = current.count + delivered.count <= Self.decryptedBodyLimit ? current + delivered : nil
        }
        lock.unlock()
        client?.urlProtocol(`protocol`, didLoad: delivered)
        if let capture { DebugSwift.Network.shared.delegate?.urlSession(capture, didReceive: delivered) }
    }

    func urlProtocolDidFinishLoading(_ protocol: URLProtocol) {
        lock.lock()
        let reported = responseReported
        lock.unlock()
        if !reported, let response = `protocol`.task?.response {
            if let rewrittenResponse = rewritten(response)?.1 {
                // Telling the client sets `task.response`, which the completion handler receives.
                client?.urlProtocol(`protocol`, didReceive: rewrittenResponse, cacheStoragePolicy: .notAllowed)
                lock.lock()
                self.response = rewrittenResponse
                lock.unlock()
            } else {
                lock.lock()
                self.response = response
                lock.unlock()
            }
        }
        recordResponse()
        client?.urlProtocolDidFinishLoading(`protocol`)
        if let capture { DebugSwift.Network.shared.delegate?.didFinishLoading(capture) }
    }

    func urlProtocol(_ protocol: URLProtocol, didFailWithError error: Error) {
        if (error as? URLError)?.code != .cancelled, markRecorded() {
            DebugSwiftURLProtocol.record(request, startedAt: startedAt, outcome: .failure(description: error.localizedDescription))
        }
        client?.urlProtocol(`protocol`, didFailWithError: error)
        if let capture { DebugSwift.Network.shared.delegate?.urlSession(capture, didFailWithError: error) }
    }

    func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge) {
        client?.urlProtocol(`protocol`, didReceive: challenge)
    }

    func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge) {
        client?.urlProtocol(`protocol`, didCancel: challenge)
    }

    private func markRecorded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !recorded else { return false }
        recorded = true
        return true
    }

    private func recordResponse() {
        guard markRecorded() else { return }
        lock.lock()
        let response = self.response
        let body = self.body
        let fullBody = self.fullBody
        lock.unlock()
        let http = response as? HTTPURLResponse
        let decrypted: String? = if let fullBody, !fullBody.isEmpty {
            request.url.flatMap { DebugSwift.Network.shared.decryptedBody(fullBody, for: $0) }
        } else if fullBody == nil {
            "Not decrypted: the response is larger than \(Self.decryptedBodyLimit / 1_048_576) MB."
        } else {
            nil
        }
        DebugSwiftURLProtocol.record(request, startedAt: startedAt, outcome: .response(
            statusCode: http?.statusCode ?? 0,
            headers: DebugSwiftURLProtocol.headers(of: http),
            body: body.isEmpty ? nil : body
        ), decryptedBody: decrypted)
    }
}
#endif
