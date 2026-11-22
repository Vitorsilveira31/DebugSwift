#if os(Android)
import DebugSwiftCore
import Foundation
import SkipFuse

/// Kotlin's way into DebugSwiftCore, so the Android runtime uses the same logic as iOS instead of a
/// Kotlin copy. Kotlin calls `DebugSwiftCoreBridge.call(operation, json)` (Skip/DebugSwiftCoreBridge.kt),
/// which lands in the exported function below and answers JSON.
///
/// - `sanitizer.configure`: `{headers?, queryParameters?, bodyKeys?, redactsURLPassword?}`; a list
///   left out keeps its current value.
/// - `sanitizer.defaults`: the default `headers`, `queryParameters` and `bodyKeys`.
/// - `url.matches`: `{url, patterns, full, queryExact}`; whether the URL matches any of the wildcard
///   patterns, as iOS matches injection and rewrite rules: `full` for the whole URL rather than a part,
///   `queryExact` for exactly the pattern's query items rather than at least them.
/// - `graphql.label`: `{body}`; the operation label the inspector lists ("Query: GetUser"), or "".
/// - `har.encode`: `{records: [{method, url, startedAt (ms), durationMs, status, requestHeaders,
///   responseHeaders, requestBody, responseBody}]}`; answers `{json}`, a HAR 1.2 log.
/// - `curl.command`: `{method, url, headers, body}`; a cURL command, credentials masked.
/// - `agent.snapshot`: `{app, device, metrics, network: [{method, url, status, durationMs, error?}],
///   agentLog: {path, enabled, sessionId}}`; answers `{json}`, the `agent-snapshot.json` iOS writes.
/// - `sanitize.record`: `{url, requestHeaders, responseHeaders, requestBody, responseBody,
///   decryptedResponseBody}`, headers as `{name: [values]}`; answers the same fields masked.
/// - `body.text`: `{bytes (Base64), contentType}`; answers `{text}`, the body read as
///   `NetworkSanitizer.decodedText` reads it (the placeholder when it can't be).
/// - `network.rows`: `{records: [{id, url, method, statusCode, startedAt (ms), durationMs,
///   requestHeaders, responseHeaders, requestBody, responseBody, decryptedResponseBody, error,
///   source, graphqlOperation?, requestBytes?, responseBytes?}]}`; answers `{json}`, the network
///   inspector's `{"requests": [...]}`.
/// - `network.log`: `{record}`, one record as for `network.rows`; answers `{text}`, the request log
///   the inspector copies.
enum DebugSwiftCoreBridge {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sanitizer = NetworkSanitizer.default

    /// The rules every captured request is masked with; also set from Swift through
    /// `DebugSwift.Network.shared.sanitizer`, custom body redactor included.
    static var networkSanitizer: NetworkSanitizer {
        get { lock.withLock { sanitizer } }
        set { lock.withLock { sanitizer = newValue } }
    }

    /// Changes the rules under one lock, so two updates of different fields both stay.
    private static func updateSanitizer(_ change: (inout NetworkSanitizer) -> Void) {
        lock.withLock { change(&sanitizer) }
    }

    static func handle(_ operation: String, _ arguments: String) -> String {
        let input = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        let output: [String: Any] = switch operation {
        case "sanitizer.configure": configure(input)
        case "sanitizer.defaults": [
            "headers": NetworkSanitizer.defaultHeaders.sorted(),
            "queryParameters": NetworkSanitizer.defaultQueryParameters.sorted(),
            "bodyKeys": NetworkSanitizer.defaultBodyKeys.sorted()
        ]
        case "sanitize.record": sanitizeRecord(input)
        case "body.text": bodyText(input)
        case "url.matches": ["matches": urlMatches(input)]
        case "graphql.label": ["label": GraphQLInspector.operationLabel(from: input["body"] as? String ?? "")]
        case "har.encode": ["json": HAREncoder.encodeJSON(harCaptures(input)) ?? ""]
        case "curl.command": ["command": curlCommand(input)]
        case "agent.snapshot": ["json": agentSnapshot(input)]
        case "network.rows": ["json": NetworkInspectorRequest.snapshotJSON((input["records"] as? [[String: Any]] ?? []).map(inspectorRequest))]
        case "network.log": ["text": inspectorRequest(input["record"] as? [String: Any] ?? [:]).log]
        default: ["error": "Unknown DebugSwiftCore operation: \(operation)."]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: output),
              let text = String(data: data, encoding: .utf8) else { return #"{"error":"The reply could not be encoded."}"# }
        return text
    }

    private static func configure(_ input: [String: Any]) -> [String: Any] {
        let headers = input["headers"] as? [String]
        let query = input["queryParameters"] as? [String]
        let keys = input["bodyKeys"] as? [String]
        let password = input["redactsURLPassword"] as? Bool
        updateSanitizer { sanitizer in
            if let headers { sanitizer.headers = Set(headers) }
            if let query { sanitizer.queryParameters = Set(query) }
            if let keys { sanitizer.bodyKeys = Set(keys) }
            if let password { sanitizer.redactsURLPassword = password }
        }
        return [:]
    }

    /// Headers as Core keeps them: one value per name, several joined as HTTP does.
    private static func joined(_ value: Any?) -> [String: String] {
        (value as? [String: [String]] ?? [:]).mapValues { $0.joined(separator: ", ") }
    }

    private static func harCaptures(_ input: [String: Any]) -> [HARCapture] {
        (input["records"] as? [[String: Any]] ?? []).map { record in
            let requestBody = record["requestBody"] as? String ?? ""
            let responseBody = record["responseBody"] as? String ?? ""
            let started = (record["startedAt"] as? NSNumber)?.doubleValue ?? 0
            return HARCapture(
                request: HARRequest(
                    method: record["method"] as? String ?? "GET",
                    url: record["url"] as? String ?? "",
                    headers: joined(record["requestHeaders"]),
                    body: requestBody.isEmpty ? nil : requestBody
                ),
                response: HARResponse(
                    status: record["status"] as? Int ?? 0,
                    headers: joined(record["responseHeaders"]),
                    body: responseBody.isEmpty ? nil : responseBody
                ),
                startedDateTime: Date(timeIntervalSince1970: started / 1000),
                time: (record["durationMs"] as? NSNumber)?.doubleValue ?? 0
            )
        }
    }

    private static func inspectorRequest(_ record: [String: Any]) -> NetworkInspectorRequest {
        NetworkInspectorRequest(
            id: record["id"] as? String ?? "",
            url: record["url"] as? String ?? "",
            method: record["method"] as? String ?? "GET",
            statusCode: record["statusCode"] as? String ?? "0",
            startedAtMilliseconds: (record["startedAt"] as? NSNumber)?.int64Value ?? 0,
            durationMilliseconds: (record["durationMs"] as? NSNumber)?.intValue ?? 0,
            requestHeaders: joined(record["requestHeaders"]),
            responseHeaders: joined(record["responseHeaders"]),
            requestBody: Data((record["requestBody"] as? String ?? "").utf8),
            responseBody: Data((record["responseBody"] as? String ?? "").utf8),
            decryptedResponseBody: Data((record["decryptedResponseBody"] as? String ?? "").utf8),
            error: record["error"] as? String ?? "",
            source: record["source"] as? String ?? "http",
            // Kotlin keeps a truncated copy of large bodies: the label and the sizes it captured
            // from the whole body win over what the copy would give.
            graphqlOperation: record["graphqlOperation"] as? String,
            requestBytes: (record["requestBytes"] as? NSNumber)?.intValue,
            responseBytes: (record["responseBytes"] as? NSNumber)?.intValue
        )
    }

    private static func curlCommand(_ input: [String: Any]) -> String {
        let body = input["body"] as? String ?? ""
        let request = HARRequest(
            method: input["method"] as? String ?? "GET",
            url: input["url"] as? String ?? "",
            headers: HAREncoder.redactHeaders(joined(input["headers"])),
            body: body.isEmpty ? nil : body
        )
        return HAREncoder.curlCommand(for: HARCapture(request: request, response: HARResponse(status: 0, headers: [:])))
    }

    private static func agentSnapshot(_ input: [String: Any]) -> String {
        let requests = (input["network"] as? [[String: Any]] ?? []).suffix(AgentSnapshot.defaultRequestLimit).map { request in
            AgentSnapshot.Request(
                method: request["method"] as? String ?? "",
                url: request["url"] as? String ?? "",
                status: (request["status"] as? NSNumber)?.intValue ?? 0,
                durationMs: (request["durationMs"] as? NSNumber)?.intValue ?? 0,
                error: (request["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        let log = input["agentLog"] as? [String: Any]
        let snapshot = AgentSnapshot(
            platform: "android",
            app: input["app"] as? [String: String] ?? [:],
            device: input["device"] as? [String: String] ?? [:],
            metrics: (input["metrics"] as? [String: NSNumber] ?? [:]).mapValues(\.doubleValue),
            network: Array(requests),
            agentLog: log.map {
                AgentSnapshot.AgentLog(
                    path: $0["path"] as? String ?? "",
                    enabled: $0["enabled"] as? Bool ?? false,
                    sessionId: $0["sessionId"] as? String ?? ""
                )
            }
        )
        return (try? snapshot.jsonData()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func urlMatches(_ input: [String: Any]) -> Bool {
        let text = input["url"] as? String ?? ""
        let patterns = input["patterns"] as? [String] ?? []
        let strategy: URLPatternMatchStrategy = (input["full"] as? Bool ?? false) ? .full : .contains
        let query: URLQueryPatternMatchStrategy = (input["queryExact"] as? Bool ?? false) ? .exact : .subset
        guard let url = URL(string: text) else {
            return text.matchesAny(wildcardPatterns: patterns, strategy: strategy)
        }
        return url.matchesAny(wildcardPatterns: patterns, strategy: strategy, queryStrategy: query)
    }

    /// A captured body's text as Core reads raw bodies; the placeholder when its declared encoding
    /// can't be read.
    private static func bodyText(_ input: [String: Any]) -> [String: Any] {
        let body = Data(base64Encoded: input["bytes"] as? String ?? "") ?? Data()
        let text = NetworkSanitizer.decodedText(of: body, contentType: input["contentType"] as? String)
        return ["text": text ?? NetworkSanitizer.redactedValue]
    }

    private static func sanitizeRecord(_ input: [String: Any]) -> [String: Any] {
        let sanitizer = networkSanitizer
        let requestHeaders = input["requestHeaders"] as? [String: [String]] ?? [:]
        let responseHeaders = input["responseHeaders"] as? [String: [String]] ?? [:]
        func body(_ key: String, _ headers: [String: [String]]) -> String {
            let text = input[key] as? String ?? ""
            guard !text.isEmpty else { return text }
            let type = headers.first { $0.key.lowercased() == "content-type" }?.value.first
            // Kotlin already decoded the body: the header's charset must not be applied again.
            return sanitizer.sanitize(text: text, contentType: type)
        }
        return [
            "url": sanitizer.sanitize(url: input["url"] as? String ?? ""),
            "requestHeaders": sanitize(requestHeaders, with: sanitizer),
            "responseHeaders": sanitize(responseHeaders, with: sanitizer),
            "requestBody": body("requestBody", requestHeaders),
            "responseBody": body("responseBody", responseHeaders),
            "decryptedResponseBody": sanitizer.sanitize(unformattedText: input["decryptedResponseBody"] as? String ?? "")
        ]
    }

    /// Headers keep all their values; a masked name has its values replaced by one placeholder.
    private static func sanitize(_ headers: [String: [String]], with sanitizer: NetworkSanitizer) -> [String: [String]] {
        let masked = sanitizer.sanitize(headers: headers.mapValues { $0.joined(separator: ",") })
        return headers.reduce(into: [:]) { result, pair in
            let value = masked[pair.key] ?? ""
            result[pair.key] = value == NetworkSanitizer.redactedValue ? [value] : pair.value
        }
    }
}

/// `DebugSwiftCoreBridge.call(operation: String, arguments: String): String` in Kotlin.
@_cdecl("Java_debug_swift_android_DebugSwiftCoreBridge_call")
public func DebugSwiftCoreBridge_call(
    _ env: JNIEnvPointer,
    _ target: JavaObjectPointer?,
    _ operation: JavaString?,
    _ arguments: JavaString?
) -> JavaString? {
    let operation = String?.fromJavaObject(operation, options: []) ?? ""
    let arguments = String?.fromJavaObject(arguments, options: []) ?? "{}"
    return DebugSwiftCoreBridge.handle(operation, arguments).toJavaObject(options: [])
}
#endif
