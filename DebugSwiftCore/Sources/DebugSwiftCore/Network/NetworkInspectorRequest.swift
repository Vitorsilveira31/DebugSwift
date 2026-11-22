import Foundation

/// One request as the shared network inspector lists it. iOS and Android both build their rows here,
/// so the derived fields (sizes, Base64 bodies, MIME type, GraphQL label, success, the copied log)
/// follow one set of rules. The JSON keys are the ones the inspector screens decode.
public struct NetworkInspectorRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let url: String
    public let method: String
    public let statusCode: String
    public let timestamp: String
    public let timestampMilliseconds: Int64
    public let durationMilliseconds: Int
    public let requestBytes: Int
    public let responseBytes: Int
    public let requestHeaders: [String: String]
    public let responseHeaders: [String: String]
    public let requestBody: String
    public let responseBody: String
    public let decryptedResponseBody: String
    public let requestBodyBase64: String?
    public let responseBodyBase64: String?
    public let decryptedResponseBodyBase64: String?
    public let mimeType: String
    public let error: String
    public let graphqlOperation: String
    public let source: String
    public let isSuccess: Bool

    /// Builds a row from a captured exchange.
    /// - Parameters:
    ///   - statusCode: The HTTP status, `"0"` when the request got no response.
    ///   - startedAtMilliseconds: When the request started, in milliseconds since 1970.
    ///   - timestamp: The start time as the platform shows it; `yyyy-MM-dd HH:mm:ss` from
    ///     `startedAtMilliseconds` when left out.
    ///   - mimeType: The response MIME type; the response `Content-Type` header when left out.
    ///   - graphqlOperation: The GraphQL operation label; read from the request body when left out.
    public init(
        id: String,
        url: String,
        method: String,
        statusCode: String,
        startedAtMilliseconds: Int64,
        timestamp: String? = nil,
        durationMilliseconds: Int,
        requestHeaders: [String: String],
        responseHeaders: [String: String],
        requestBody: Data,
        responseBody: Data,
        decryptedResponseBody: Data = Data(),
        mimeType: String? = nil,
        error: String = "",
        source: String = "http",
        graphqlOperation: String? = nil
    ) {
        let requestText = String(data: requestBody, encoding: .utf8) ?? ""
        self.id = id
        self.url = url
        self.method = method
        self.statusCode = statusCode
        self.timestamp = timestamp ?? Self.timestamp(milliseconds: startedAtMilliseconds)
        self.timestampMilliseconds = startedAtMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.requestBytes = requestBody.count
        self.responseBytes = responseBody.count
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.requestBody = requestText
        self.responseBody = String(data: responseBody, encoding: .utf8) ?? ""
        self.decryptedResponseBody = String(data: decryptedResponseBody, encoding: .utf8) ?? ""
        self.requestBodyBase64 = requestBody.base64EncodedString()
        self.responseBodyBase64 = responseBody.base64EncodedString()
        self.decryptedResponseBodyBase64 = decryptedResponseBody.base64EncodedString()
        self.mimeType = mimeType ?? Self.header("Content-Type", in: responseHeaders) ?? ""
        self.error = error
        self.graphqlOperation = graphqlOperation ?? GraphQLInspector.operationLabel(from: requestText)
        self.source = source
        self.isSuccess = Self.isSuccess(statusCode: statusCode, error: error)
    }

    /// A request succeeded when it got a 2xx response and no transport error.
    public static func isSuccess(statusCode: String, error: String) -> Bool {
        guard error.isEmpty, let status = Int(statusCode) else { return false }
        return (200 ..< 300).contains(status)
    }

    /// The text the inspector copies or shares for this request.
    public var log: String {
        func headers(_ headers: [String: String]) -> String {
            headers.isEmpty ? "No data" : headers.keys.sorted().map { "\($0): \(headers[$0] ?? "")" }.joined(separator: "\n")
        }
        func body(_ text: String, bytes: Int) -> String {
            if !text.isEmpty { return text }
            return bytes == 0 ? "No data" : "<binary data: \(bytes) bytes>"
        }
        let response = decryptedResponseBody.isEmpty ? body(responseBody, bytes: responseBytes) : decryptedResponseBody
        return """
        [\(method)] \(timestamp) (\(statusCode))

        ------- URL -------
        \(url.isEmpty ? "No data" : url)

        ------- REQUEST HEADER -------
        \(headers(requestHeaders))

        ------- REQUEST -------
        \(body(requestBody, bytes: requestBytes))

        ------- RESPONSE HEADER -------
        \(headers(responseHeaders))

        ------- RESPONSE -------
        \(response)

        ------- RESPONSE SIZE -------
        \(responseBytes) bytes

        ------- TOTAL TIME -------
        \(durationMilliseconds) ms

        ------- MIME TYPE -------
        \(mimeType.isEmpty ? "No data" : mimeType)
        """
    }

    /// The inspector's JSON for these rows: `{"requests": [...]}`.
    public static func snapshotJSON(_ requests: [NetworkInspectorRequest]) -> String {
        struct Snapshot: Encodable { let requests: [NetworkInspectorRequest] }
        guard let data = try? JSONEncoder().encode(Snapshot(requests: requests)),
              let json = String(data: data, encoding: .utf8) else { return #"{"requests":[]}"# }
        return json
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func timestamp(milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }
}
