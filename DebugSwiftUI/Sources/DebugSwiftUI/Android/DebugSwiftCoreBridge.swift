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
        default: ["error": "Unknown DebugSwiftCore operation: \(operation)."]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: output),
              let text = String(data: data, encoding: .utf8) else { return #"{"error":"The reply could not be encoded."}"# }
        return text
    }

    private static func configure(_ input: [String: Any]) -> [String: Any] {
        var updated = networkSanitizer
        if let headers = input["headers"] as? [String] { updated.headers = Set(headers) }
        if let query = input["queryParameters"] as? [String] { updated.queryParameters = Set(query) }
        if let keys = input["bodyKeys"] as? [String] { updated.bodyKeys = Set(keys) }
        if let password = input["redactsURLPassword"] as? Bool { updated.redactsURLPassword = password }
        networkSanitizer = updated
        return [:]
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
            return String(data: masked, encoding: .utf8) ?? text
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
