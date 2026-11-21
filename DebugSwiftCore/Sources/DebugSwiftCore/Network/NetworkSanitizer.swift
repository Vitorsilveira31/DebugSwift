import Foundation

/// Masks credentials and personal data in captured HTTP traffic before it is stored or exported.
///
/// Headers are only one place a secret can travel. Tokens also ride in query strings
/// (`?access_token=`), in the URL's user info, in OAuth fragments, and in JSON or form bodies, so
/// the sanitizer covers each of them. Names are compared case-insensitively and ignoring `_` and
/// `-`, so `access_token`, `Access-Token` and `accessToken` all match the same entry.
public struct NetworkSanitizer: Sendable {
    /// Replaces a masked value in headers and JSON bodies.
    public static let redactedValue = "<redacted>"

    public static let defaultHeaders: Set<String> = HAREncoder.defaultRedactedKeys.union([
        "Proxy-Authorization", "X-API-Key", "X-Auth-Token", "X-Access-Token", "X-CSRF-Token"
    ])

    public static let defaultQueryParameters: Set<String> = [
        "access_token", "refresh_token", "id_token", "token", "api_key", "apikey",
        "password", "secret", "client_secret", "signature", "sig",
        "X-Amz-Signature", "X-Amz-Credential", "X-Amz-Security-Token"
    ]

    public static let defaultBodyKeys: Set<String> = [
        "password", "passwd", "new_password", "old_password",
        "access_token", "refresh_token", "id_token", "token", "client_secret", "secret",
        "api_key", "apikey", "card_number", "cvv", "cvc", "ssn"
    ]

    /// Masks the default headers, query parameters and body keys.
    public static let `default` = NetworkSanitizer()

    /// Leaves traffic untouched. Meant for local debugging sessions that need the raw values.
    public static let disabled = NetworkSanitizer(
        headers: [],
        queryParameters: [],
        bodyKeys: [],
        redactsURLPassword: false
    )

    public var headers: Set<String> { didSet { normalizedHeaders = Self.normalize(headers) } }
    public var queryParameters: Set<String> { didSet { normalizedQuery = Self.normalize(queryParameters) } }
    public var bodyKeys: Set<String> { didSet { normalizedBodyKeys = Self.normalize(bodyKeys) } }
    /// Masks the password in `https://user:password@host` URLs.
    public var redactsURLPassword: Bool
    /// Runs after the built-in body rules, for formats or fields they do not know about.
    public var customBodyRedactor: (@Sendable (_ body: Data, _ contentType: String?) -> Data)?

    private var normalizedHeaders: Set<String>
    private var normalizedQuery: Set<String>
    private var normalizedBodyKeys: Set<String>

    public init(
        headers: Set<String> = NetworkSanitizer.defaultHeaders,
        queryParameters: Set<String> = NetworkSanitizer.defaultQueryParameters,
        bodyKeys: Set<String> = NetworkSanitizer.defaultBodyKeys,
        redactsURLPassword: Bool = true,
        customBodyRedactor: (@Sendable (_ body: Data, _ contentType: String?) -> Data)? = nil
    ) {
        self.headers = headers
        self.queryParameters = queryParameters
        self.bodyKeys = bodyKeys
        self.redactsURLPassword = redactsURLPassword
        self.customBodyRedactor = customBodyRedactor
        normalizedHeaders = Self.normalize(headers)
        normalizedQuery = Self.normalize(queryParameters)
        normalizedBodyKeys = Self.normalize(bodyKeys)
    }

    // MARK: - Headers

    public func sanitize(headers: [String: String]) -> [String: String] {
        guard !normalizedHeaders.isEmpty else { return headers }
        return headers.reduce(into: [:]) { result, pair in
            result[pair.key] = normalizedHeaders.contains(Self.normalize(pair.key)) ? Self.redactedValue : pair.value
        }
    }

    // MARK: - URL

    /// Masks matching query parameters, matching parameters in a form-style fragment, and the
    /// user-info password. Other parameters keep their original encoding.
    public func sanitize(url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        var changed = false
        if redactsURLPassword, components.password != nil {
            components.percentEncodedPassword = Self.encodedRedactedValue
            changed = true
        }
        if !normalizedQuery.isEmpty {
            if let query = components.percentEncodedQuery {
                let sanitized = sanitizeFormEncoded(query, keys: normalizedQuery)
                if sanitized != query {
                    components.percentEncodedQuery = sanitized
                    changed = true
                }
            }
            if let fragment = components.percentEncodedFragment, fragment.contains("=") {
                let sanitized = sanitizeFormEncoded(fragment, keys: normalizedQuery)
                if sanitized != fragment {
                    components.percentEncodedFragment = sanitized
                    changed = true
                }
            }
        }
        guard changed else { return url }
        return components.string ?? url
    }

    // MARK: - Body

    /// Masks matching keys in JSON (at any depth) and `application/x-www-form-urlencoded` bodies.
    /// A body with nothing to mask is returned byte for byte.
    public func sanitize(body: Data, contentType: String?) -> Data {
        var result = body
        if !normalizedBodyKeys.isEmpty, !body.isEmpty {
            let type = contentType?.lowercased() ?? ""
            if type.contains("x-www-form-urlencoded") {
                if let text = String(data: body, encoding: .utf8) {
                    let sanitized = sanitizeFormEncoded(text, keys: normalizedBodyKeys)
                    if sanitized != text { result = Data(sanitized.utf8) }
                }
            } else if type.isEmpty || type.contains("json") {
                result = sanitizeJSON(body) ?? body
            }
        }
        if let customBodyRedactor {
            result = customBodyRedactor(result, contentType)
        }
        return result
    }

    // MARK: - Records

    public func sanitize(_ record: NetworkRecord) -> NetworkRecord {
        let requestType = Self.contentType(in: record.requestHeaders)
        let outcome: NetworkRecord.Outcome
        switch record.outcome {
        case let .response(statusCode, responseHeaders, body):
            let responseType = Self.contentType(in: responseHeaders)
            outcome = .response(
                statusCode: statusCode,
                headers: sanitize(headers: responseHeaders),
                body: body.map { sanitize(body: $0, contentType: responseType) }
            )
        case .failure:
            outcome = record.outcome
        }
        return NetworkRecord(
            id: record.id,
            startedAt: record.startedAt,
            duration: record.duration,
            method: record.method,
            url: sanitize(url: record.url),
            requestHeaders: sanitize(headers: record.requestHeaders),
            requestBody: record.requestBody.map { sanitize(body: $0, contentType: requestType) },
            outcome: outcome,
            // Plaintext a decryptor produced, masked like a JSON body; its real type is unknown.
            decryptedResponseBody: record.decryptedResponseBody.map {
                sanitize(text: $0, contentType: "application/json")
            }
        )
    }

    public func sanitize(_ capture: HARCapture) -> HARCapture {
        let request = HARRequest(
            method: capture.request.method,
            url: sanitize(url: capture.request.url),
            headers: sanitize(headers: capture.request.headers),
            body: capture.request.body.map {
                sanitize(text: $0, contentType: Self.contentType(in: capture.request.headers))
            }
        )
        let response = HARResponse(
            status: capture.response.status,
            headers: sanitize(headers: capture.response.headers),
            body: capture.response.body.map {
                sanitize(text: $0, contentType: Self.contentType(in: capture.response.headers))
            }
        )
        return HARCapture(
            request: request,
            response: response,
            startedDateTime: capture.startedDateTime,
            time: capture.time
        )
    }

    // MARK: - Helpers

    static let encodedRedactedValue = "%3Credacted%3E"

    private func sanitize(text: String, contentType: String?) -> String {
        let sanitized = sanitize(body: Data(text.utf8), contentType: contentType)
        return String(data: sanitized, encoding: .utf8) ?? text
    }

    private static func contentType(in headers: [String: String]) -> String? {
        headers.first { $0.key.lowercased() == "content-type" }?.value
    }

    static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0 != "_" && $0 != "-" }
    }

    private static func normalize(_ names: Set<String>) -> Set<String> {
        Set(names.map(normalize))
    }

    private func sanitizeFormEncoded(_ text: String, keys: Set<String>) -> String {
        text.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            guard let separator = pair.firstIndex(of: "=") else { return String(pair) }
            let rawName = pair[..<separator]
            let name = String(rawName).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(rawName)
            guard keys.contains(Self.normalize(name)) else { return String(pair) }
            return "\(rawName)=\(Self.encodedRedactedValue)"
        }.joined(separator: "&")
    }

    private func sanitizeJSON(_ body: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            return nil
        }
        var changed = false
        let sanitized = redactJSON(object, changed: &changed)
        guard changed, JSONSerialization.isValidJSONObject(sanitized) else { return nil }
        return try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys])
    }

    private func redactJSON(_ value: Any, changed: inout Bool) -> Any {
        if let dictionary = value as? [String: Any] {
            var result = [String: Any]()
            for (key, item) in dictionary {
                if normalizedBodyKeys.contains(Self.normalize(key)) {
                    result[key] = Self.redactedValue
                    changed = true
                } else {
                    result[key] = redactJSON(item, changed: &changed)
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { redactJSON($0, changed: &changed) }
        }
        return value
    }
}
