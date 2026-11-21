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

/// A host protocol that, like Foundation, decides from the request: it accepts `request-only.test`
/// requests and rejects the task overload, which Foundation never asks.
final class RequestOnlyProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "request-only.test" }
    override class func canInit(with task: URLSessionTask) -> Bool { false }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("request-only".utf8))
        client?.urlProtocolDidFinishLoading(self)
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

/// The newest record for a URL ending in `suffix`. Recording runs in its own task, so it is polled
/// for up to five seconds rather than read once after a fixed sleep.
func latestRecord(endingWith suffix: String) async -> NetworkRecord? {
    for _ in 0..<100 {
        if let record = await NetworkRecorder.shared.snapshot().last(where: { $0.url.hasSuffix(suffix) }) {
            return record
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return nil
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

// 1b. URLSession.shared, which lists no protocol of its own: with the capture installed its
//     requests still reach Foundation's built-in HTTP protocol, and are recorded.
DebugSwiftURLSessionCapture.install()
let shared = await fetch(URLSession.shared, "https://jsonplaceholder.typicode.com/todos/2")
let sharedRecord = await latestRecord(endingWith: "/todos/2")
check("URLSession.shared request", shared.status == 200 && shared.body.contains("\"id\": 2"),
      "status \(shared.status), error \(shared.error.map { "\($0)" } ?? "none")")
check("URLSession.shared request recorded", sharedRecord?.statusCode == 200, "recorded \(sharedRecord?.statusCode.map(String.init) ?? "nothing")")

// 1c. A session whose only protocol handles another scheme, as Skip's AssetURLProtocol does in
//     an Android app's URLSession.shared: an https request still reaches Foundation's built-in
//     protocol, as it does without DebugSwift.
final class AssetOnlyProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "asset" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
    override func stopLoading() {}
}
let assetConfiguration = URLSessionConfiguration.ephemeral
assetConfiguration.protocolClasses = [AssetOnlyProtocol.self]
DebugSwiftURLSessionCapture.add(to: assetConfiguration)
let assetSession = await fetch(URLSession(configuration: assetConfiguration), "https://jsonplaceholder.typicode.com/todos/3")
check("session listing only another scheme's protocol", assetSession.status == 200,
      "status \(assetSession.status), error \(assetSession.error.map { "\($0)" } ?? "none")")

// 1d. A protocol is picked as Foundation picks it, by `canInit(with: URLRequest)`.
let requestOnly = await fetch(capturedSession { $0.protocolClasses = [RequestOnlyProtocol.self] }, "https://request-only.test/check")
check("protocol picked by its request check", requestOnly.status == 200 && requestOnly.body == "request-only",
      "status \(requestOnly.status), body \(requestOnly.body), error \(requestOnly.error.map { "\($0)" } ?? "none")")

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

// 8. A presenter hand-off keeps the panel open on the same feature, as SwiftUI drives it: the
//    newer presenter attaches, the older sheet's binding reports false, then its onDismiss runs.
let presentation = DebugSwiftPresentation()
let first = UUID()
let second = UUID()
presentation.attach(first)
presentation.present(route: "measurement")
let firstShowed = presentation.isShowing(for: first)
presentation.attach(second)
presentation.setShowing(false, for: first)
presentation.sheetDidDismiss(for: first)
check("presenter hand-off keeps the measurement tool",
      firstShowed && presentation.isShowing(for: second) && presentation.isPresented && presentation.route == "measurement",
      "presented \(presentation.isPresented), route \(presentation.route ?? "nil"), second showing \(presentation.isShowing(for: second))")
presentation.setShowing(false, for: second)
presentation.sheetDidDismiss(for: second)
check("closing the panel clears the route", !presentation.isPresented && presentation.route == nil,
      "presented \(presentation.isPresented), route \(presentation.route ?? "nil")")

// The last presenter leaving closes the panel, so a later presenter does not reopen an old route.
let lonely = DebugSwiftPresentation()
let only = UUID()
lonely.attach(only)
lonely.present(route: "measurement")
lonely.detach(only)
lonely.attach(UUID())
check("the last presenter leaving closes the panel", !lonely.isPresented && lonely.route == nil,
      "presented \(lonely.isPresented), route \(lonely.route ?? "nil")")

// 9. An injection call sends the fields it sets, with its own values, and the runtime writes them
//    into its current rules (as `network.injection.patch` does): a write made between the call's
//    read and its patch keeps every field the call doesn't set.
func patched(_ settings: DebugSwiftNetworkInjection, with sections: [String: [String: Any]]) -> DebugSwiftNetworkInjection {
    let data = try! JSONEncoder().encode(settings)
    var json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    for (name, fields) in sections {
        var section = json[name] as? [String: Any] ?? [:]
        for (key, value) in fields { section[key] = value is NSNull ? nil : value }
        json[name] = section
    }
    return try! JSONDecoder().decode(DebugSwiftNetworkInjection.self, from: JSONSerialization.data(withJSONObject: json))
}
var rulesA = DebugSwiftNetworkInjection()
rulesA.rewrite.isEnabled = true
rulesA.rewrite.rules = [.init(urlPattern: "https://a.test/*", responseBody: "A")]
let disabling = DebugSwiftNetworkInjection.Change.disableRewrite.sections(on: rulesA)
check("disabling a rewrite sends only isEnabled",
      Set(disabling.keys) == ["rewrite"] && Set(disabling["rewrite"]?.keys ?? [:].keys) == ["isEnabled"] && disabling["rewrite"]?["isEnabled"] as? Bool == false,
      "\(disabling)")
var rulesB = rulesA
rulesB.rewrite.rules = [.init(urlPattern: "https://b.test/*", responseBody: "B")]
let afterImport = patched(rulesB, with: disabling)
check("disabling a rewrite keeps rules imported meanwhile",
      !afterImport.rewrite.isEnabled && afterImport.rewrite.rules.map(\.urlPattern) == ["https://b.test/*"],
      "\(afterImport.rewrite)")

// enableRequestDelay(3) reads an enabled 1 s delay; a native writer then disables it at 2 s.
var oneSecond = DebugSwiftNetworkInjection()
oneSecond.delay.isEnabled = true
oneSecond.delay.fixedDelay = 1
let delaying = DebugSwiftNetworkInjection.Change.delay(fixedDelay: 3, urlPatterns: [], httpMethods: []).sections(on: oneSecond)
check("enabling a delay sends every field it sets, even unchanged ones",
      Set(delaying.keys) == ["delay"] && Set(delaying["delay"]?.keys ?? [:].keys) == ["isEnabled", "fixedDelay", "urlPatterns", "httpMethods"],
      "\(delaying)")
var nativeWrite = oneSecond
nativeWrite.delay.isEnabled = false
nativeWrite.delay.fixedDelay = 2
let delayed = patched(nativeWrite, with: delaying)
check("a delay enabled after a native write is on at its own value",
      delayed.delay.isEnabled && delayed.delay.fixedDelay == 3, "\(delayed.delay)")

// A range delay clears the fixed delay; a timeout failure leaves the status codes alone.
let ranging = DebugSwiftNetworkInjection.Change.delay(fixedDelay: nil, minDelay: 1, maxDelay: 4, urlPatterns: [], httpMethods: []).sections(on: oneSecond)
check("a range delay clears the fixed delay", ranging["delay"]?["fixedDelay"] is NSNull && patched(oneSecond, with: ranging).delay.fixedDelay == nil,
      "\(ranging)")
let timeout = DebugSwiftNetworkInjection.Change.failure(rate: 0.5, type: "timeout", urlPatterns: [], httpMethods: []).sections(on: oneSecond)
check("a timeout failure leaves the status codes alone", timeout["failure"]?["customStatusCodes"] == nil && timeout["failure"]?["isEnabled"] as? Bool == true,
      "\(timeout)")
let both = DebugSwiftNetworkInjection.Change.disableDelay.then(.disableFailure).sections(on: oneSecond)
check("combined changes send each section's fields", Set(both.keys) == ["delay", "failure"], "\(both)")

print(failures.isEmpty ? "ALL PASSED" : "FAILED: \(failures.joined(separator: ", "))")
exit(failures.isEmpty ? 0 : 1)
