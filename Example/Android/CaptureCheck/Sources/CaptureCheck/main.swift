import DebugSwiftCore
import Foundation
import FoundationNetworking

// Checks DebugSwift's Android URLSession capture against swift-corelibs-foundation, on a device or
// emulator. run.sh builds it for Android and runs it there; it exits non-zero if a check fails.

nonisolated(unsafe) var failures: [String] = []

func check(_ name: String, _ passed: Bool, _ detail: String) {
    print("\(passed ? "PASS" : "FAIL") \(name): \(detail)")
    if !passed { failures.append(name) }
}

func wait(_ semaphore: DispatchSemaphore, seconds: Double) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            _ = semaphore.wait(timeout: .now() + seconds)
            continuation.resume()
        }
    }
}

/// A host protocol that answers every request with a fixed body, in two chunks (none if empty).
final class HostProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data("from-host".utf8)
    /// When set, the chunks and the finish come this long after the response.
    nonisolated(unsafe) static var chunkDelay: Double = 0

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = Self.body
        nonisolated(unsafe) let host = self
        let rest: @Sendable () -> Void = {
            if !body.isEmpty {
                let half = body.count / 2
                host.client?.urlProtocol(host, didLoad: body.prefix(half))
                host.client?.urlProtocol(host, didLoad: body.suffix(from: half))
            }
            host.client?.urlProtocolDidFinishLoading(host)
        }
        if Self.chunkDelay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.chunkDelay, execute: rest)
        } else {
            rest()
        }
    }

    override func stopLoading() {}
}

func capturedSession(_ configure: (URLSessionConfiguration) -> Void = { _ in }) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HostProtocol.self]
    configure(configuration)
    DebugSwiftURLSessionCapture.add(to: configuration)
    return URLSession(configuration: configuration)
}

func fetch(_ session: URLSession, _ url: String) async -> (status: Int, body: String, error: Error?) {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: (Int, String, Error?) = (-1, "", nil)
    session.dataTask(with: URL(string: url)!) { data, response, error in
        result = ((response as? HTTPURLResponse)?.statusCode ?? -1, data.map { String(decoding: $0, as: UTF8.self) } ?? "", error)
        done.signal()
    }.resume()
    await wait(done, seconds: 20)
    return result
}

func latestRecord(endingWith suffix: String) async -> NetworkRecord? {
    try? await Task.sleep(nanoseconds: 300_000_000)
    return await NetworkRecorder.shared.snapshot().last { $0.url.hasSuffix(suffix) }
}

/// Records what the capture reports to `DebugSwift.Network.shared.delegate`.
final class DelegateLog: CustomHTTPProtocolDelegate, @unchecked Sendable {
    var events: [String] = []
    /// Keeps the capture alive past the task, as a host delegate holding on to it would, so a late
    /// callback is stopped by the capture's own state, not because it was already freed.
    var protocols: [URLProtocol] = []
    func urlSession(_ protocol: URLProtocol, didReceive response: URLResponse) {
        events.append("response")
        protocols.append(`protocol`)
    }
    func urlSession(_ protocol: URLProtocol, didReceive data: Data) { events.append("data") }
    func didFinishLoading(_ protocol: URLProtocol) { events.append("finish") }
    func urlSession(_ protocol: URLProtocol, didFailWithError error: Error) { events.append("fail") }
}

/// A protocol client that stops the load from inside its first callback.
final class StoppingClient: NSObject, URLProtocolClient, @unchecked Sendable {
    weak var capture: URLProtocol?
    var events: [String] = []
    func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) {}
    func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) {}
    func urlProtocol(_ protocol: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) {
        events.append("response")
        capture?.stopLoading()
    }
    func urlProtocol(_ protocol: URLProtocol, didLoad data: Data) { events.append("data") }
    func urlProtocolDidFinishLoading(_ protocol: URLProtocol) { events.append("finish") }
    func urlProtocol(_ protocol: URLProtocol, didFailWithError error: Error) { events.append("fail") }
    func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge) {}
    func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge) {}
}

/// Starts the capture directly for `url`, with a client that stops it inside the first callback.
func stopInsideFirstCallback(_ url: String, session: URLSession) -> (client: [String], delegate: [String]) {
    let log = DelegateLog()
    DebugSwift.Network.shared.delegate = log
    defer { DebugSwift.Network.shared.delegate = nil }
    let client = StoppingClient()
    let task = session.dataTask(with: URL(string: url)!) // created, never resumed
    let capture = DebugSwiftURLProtocol(task: task, cachedResponse: nil, client: client)
    client.capture = capture
    capture.startLoading()
    return (client.events, log.events)
}

// 1. A host protocol in the session still answers exactly as without DebugSwift, and the
//    request is recorded. (corelibs keeps only the last chunk for a completion handler, with or
//    without DebugSwift, so the reference is the same session without the capture.)
HostProtocol.status = 299
HostProtocol.body = Data("from-host".utf8)
let plainConfiguration = URLSessionConfiguration.ephemeral
plainConfiguration.protocolClasses = [HostProtocol.self]
let reference = await fetch(URLSession(configuration: plainConfiguration), "https://host.test/reference")
let hosted = await fetch(capturedSession(), "https://host.test/answer")
let hostedRecord = await latestRecord(endingWith: "/answer")
check("host protocol answers as without DebugSwift", hosted.status == reference.status && hosted.body == reference.body,
      "with capture \(hosted.status) \"\(hosted.body)\", without \(reference.status) \"\(reference.body)\"")
check("host protocol request recorded", hostedRecord?.statusCode == 299, "recorded \(hostedRecord?.statusCode.map(String.init) ?? "nothing")")
HostProtocol.status = 200

// 2. Downloads, with a completion handler and with a delegate, through the real network.
let downloadURL = URL(string: "https://jsonplaceholder.typicode.com/todos/1")!
let downloadConfiguration = URLSessionConfiguration.default
DebugSwiftURLSessionCapture.add(to: downloadConfiguration)
let handlerDone = DispatchSemaphore(value: 0)
nonisolated(unsafe) var handlerContents = ""
URLSession(configuration: downloadConfiguration).downloadTask(with: downloadURL) { location, _, _ in
    handlerContents = location.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    handlerDone.signal()
}.resume()
await wait(handlerDone, seconds: 20)
check("download with a completion handler", handlerContents.contains("\"userId\""), "file holds \(handlerContents.count) characters")

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var contents = ""
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        contents = (try? String(contentsOf: location, encoding: .utf8)) ?? ""
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { done.signal() }
}
let downloadDelegate = DownloadDelegate()
URLSession(configuration: downloadConfiguration, delegate: downloadDelegate, delegateQueue: nil).downloadTask(with: downloadURL).resume()
await wait(downloadDelegate.done, seconds: 20)
check("download with a delegate", downloadDelegate.contents.contains("\"userId\""), "file holds \(downloadDelegate.contents.count) characters")

// 3. The session's own timeout still applies.
let slowConfiguration = URLSessionConfiguration.default
slowConfiguration.timeoutIntervalForRequest = 2
DebugSwiftURLSessionCapture.add(to: slowConfiguration)
let started = Date()
let slow = await fetch(URLSession(configuration: slowConfiguration), "https://httpbin.org/delay/10")
let elapsed = Date().timeIntervalSince(started)
check("session timeout", (slow.error as? URLError)?.code == .timedOut && elapsed < 6, String(format: "error %@ after %.1fs", "\(slow.error.map { "\($0)" } ?? "none")", elapsed))

// 4. A JSON response over 1 MB with a password at the start is stored without it.
HostProtocol.body = Data((#"{"password":"sensitive-secret","filler":""# + String(repeating: "x", count: 1_200_000) + #""}"#).utf8)
_ = await fetch(capturedSession(), "https://host.test/large")
let largeBody = await latestRecord(endingWith: "/large")?.responseBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
check("large body masked before trimming", !largeBody.isEmpty && !largeBody.contains("sensitive-secret"), "stored \(largeBody.utf8.count) bytes")

// 5. A pass-through rewrite is delivered once, over a chunked body and over an empty one.
NetworkInjection.install { url, _ in
    url.hasSuffix("/rewrite") ? NetworkInjectionDecision(rewrite: .init(body: #"{"ok":true}"#, shortCircuit: false)) : nil
}
HostProtocol.body = Data(#"{"original":"aaaaaaaaaaaaaaaaaaaa"}"#.utf8)
let chunked = await fetch(capturedSession(), "https://host.test/rewrite")
check("rewrite over a chunked body", chunked.body == #"{"ok":true}"#, chunked.body)
HostProtocol.body = Data()
let empty = await fetch(capturedSession(), "https://host.test/rewrite")
check("rewrite over an empty body", empty.body == #"{"ok":true}"#, empty.body)
NetworkInjection.install(nil)

// 6. A stop from inside the first callback ends the load, on both paths.
NetworkInjection.install { url, _ in url.hasSuffix("/blocked") ? NetworkInjectionDecision(isBlocked: true) : nil }
let injected = stopInsideFirstCallback("https://host.test/blocked", session: capturedSession())
check("stop during an injected answer", injected.client == ["response"] && injected.delegate.isEmpty,
      "client \(injected.client), delegate \(injected.delegate)")
NetworkInjection.install(nil)

// 7. A forwarded load the app cancels when its response arrives reports nothing more, even when
//    the protocol below keeps sending (this one ignores stopLoading and sends the rest later).
final class CancellingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var events: [String] = []
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        events.append("response")
        dataTask.cancel()
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { events.append("data") }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        events.append((error as? URLError)?.code == .cancelled ? "cancelled" : "completed")
        done.signal()
    }
}
HostProtocol.body = Data("from-host".utf8)
HostProtocol.chunkDelay = 0.5
let forwardedLog = DelegateLog()
DebugSwift.Network.shared.delegate = forwardedLog
let cancelling = CancellingDelegate()
let cancellingConfiguration = URLSessionConfiguration.ephemeral
cancellingConfiguration.protocolClasses = [HostProtocol.self]
DebugSwiftURLSessionCapture.add(to: cancellingConfiguration)
URLSession(configuration: cancellingConfiguration, delegate: cancelling, delegateQueue: nil)
    .dataTask(with: URL(string: "https://host.test/forwarded")!).resume()
await wait(cancelling.done, seconds: 10)
try? await Task.sleep(nanoseconds: 1_000_000_000) // past the late chunks
DebugSwift.Network.shared.delegate = nil
HostProtocol.chunkDelay = 0
check("cancel during a forwarded load", cancelling.events == ["response", "cancelled"] && !forwardedLog.events.contains("data") && !forwardedLog.events.contains("finish"),
      "app delegate \(cancelling.events), DebugSwift delegate \(forwardedLog.events)")

print(failures.isEmpty ? "ALL PASSED" : "FAILED: \(failures.joined(separator: ", "))")
exit(failures.isEmpty ? 0 : 1)
