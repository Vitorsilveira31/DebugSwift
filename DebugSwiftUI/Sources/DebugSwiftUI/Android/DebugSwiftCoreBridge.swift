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
/// - `sanitize.record`: `{url, requestHeaders, responseHeaders, requestBody, responseBody,
///   decryptedResponseBody}`, headers as `{name: [values]}`; answers the same fields masked.
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
        case "url.matches": ["matches": urlMatches(input)]
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

    private static func sanitizeRecord(_ input: [String: Any]) -> [String: Any] {
        let sanitizer = networkSanitizer
        let requestHeaders = input["requestHeaders"] as? [String: [String]] ?? [:]
        let responseHeaders = input["responseHeaders"] as? [String: [String]] ?? [:]
        func body(_ key: String, _ headers: [String: [String]]) -> String {
            let text = input[key] as? String ?? ""
            guard !text.isEmpty else { return text }
            let type = headers.first { $0.key.lowercased() == "content-type" }?.value.first
            let masked = sanitizer.sanitize(body: Data(text.utf8), contentType: type)
            // A custom redactor may return bytes that aren't UTF-8: never fall back to the original.
            return String(data: masked, encoding: .utf8) ?? NetworkSanitizer.redactedValue
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
