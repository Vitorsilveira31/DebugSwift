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

    /// Masks matching keys in JSON (at any depth), `application/x-www-form-urlencoded`, XML and
    /// `text/*` bodies. XML masks the content of an element named after a key and the value of an
    /// attribute named after one; other text masks `key=value` and `key: value` pairs, as
    /// `sanitize(unformattedText:)` does. A body without a type is masked only as JSON. A body with
    /// nothing to mask is returned byte for byte.
    public func sanitize(body: Data, contentType: String?) -> Data {
        sanitize(body: body, contentType: contentType, decodedText: false)
    }

    /// Masks a body that is already text, as `sanitize(body:contentType:)` does, without reading it
    /// again in the `charset` the header names: that charset was the wire's, and the text is decoded.
    /// Output of a custom redactor that isn't UTF-8 becomes the placeholder.
    public func sanitize(text: String, contentType: String?) -> String {
        let sanitized = sanitize(body: Data(text.utf8), contentType: contentType, decodedText: true)
        return String(data: sanitized, encoding: .utf8) ?? Self.redactedValue
    }

    /// `decodedText`: the bytes are UTF-8 text already, whatever the header's `charset` says.
    private func sanitize(body: Data, contentType: String?, decodedText: Bool) -> Data {
        var result = body
        if !normalizedBodyKeys.isEmpty, !body.isEmpty {
            // The media type alone: a parameter such as `name="payload.xml"` must not pick the masker.
            let type = (contentType?.split(separator: ";", maxSplits: 1).first.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            if type.contains("x-www-form-urlencoded") {
                if let text = String(data: body, encoding: .utf8) {
                    let sanitized = sanitizeFormEncoded(text, keys: normalizedBodyKeys)
                    if sanitized != text { result = Data(sanitized.utf8) }
                }
            } else if type.isEmpty || type.contains("json") {
                result = sanitizeJSON(body) ?? body
            } else if type.contains("xml") {
                result = maskingText(body, contentType: decodedText ? nil : contentType, xml: !decodedText) { maskingXML($0) }
            } else if type.hasPrefix("text/") {
                result = maskingText(body, contentType: decodedText ? nil : contentType, xml: false) { maskingKeys(inUnformattedText: $0) }
            }
        }
        if let customBodyRedactor {
            result = customBodyRedactor(result, contentType)
        }
        return result
    }

    /// Masks text whose format is unknown, such as a decrypted body: as JSON when it parses, and
    /// otherwise every `key=value` or `key: value` pair whose key is a masked one. Quoted values may
    /// hold escaped quotes, so the whole quoted value is masked.
    public func sanitize(unformattedText text: String) -> String {
        guard !text.isEmpty else { return text }
        return applyingCustomRedactor(to: maskingKeys(inUnformattedText: text))
    }

    private func maskingKeys(inUnformattedText text: String) -> String {
        guard !normalizedBodyKeys.isEmpty else { return text }
        if let json = sanitizeJSON(Data(text.utf8)), let result = String(data: json, encoding: .utf8) {
            return result
        }
        if (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil {
            return text
        }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in Self.keyValuePattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 2))
            // Keys can be percent-encoded, as in form bodies (`pass%77ord`): compare them decoded.
            let decoded = name.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? name
            guard normalizedBodyKeys.contains(Self.normalize(decoded)) else { continue }
            let valueRange = match.range(at: 4)
            result += source.substring(with: NSRange(location: cursor, length: valueRange.location - cursor))
            result += Self.redactedValue
            cursor = valueRange.location + valueRange.length
        }
        guard cursor > 0 else { return text }
        return result + source.substring(from: cursor)
    }

    /// Decodes a text body in its declared encoding, masks it and writes it back in that encoding.
    /// The encoding comes from a byte order mark, the `charset` parameter or, for XML, the
    /// declaration's `encoding`, else UTF-8, or Latin-1 when nothing declared one and the body
    /// isn't UTF-8. A body that its declared encoding can't decode is replaced by the placeholder:
    /// unread text could hold anything.
    private func maskingText(_ body: Data, contentType: String?, xml: Bool, mask: (String) -> String) -> Data {
        var (encoding, bom, declared) = Self.textEncoding(of: body, contentType: contentType, xml: xml)
        var decoded = String(data: body.dropFirst(bom.count), encoding: encoding)
        if decoded == nil, !declared {
            // Nothing said it's UTF-8: read it as Latin-1, which takes any byte and writes it back
            // unchanged, so the ASCII keys are still found.
            encoding = .isoLatin1
            decoded = String(data: body, encoding: encoding)
        }
        guard let text = decoded else { return Data(Self.redactedValue.utf8) }
        let masked = mask(text)
        guard masked != text else { return body }
        guard let data = masked.data(using: encoding, allowLossyConversion: false) else {
            return Data(Self.redactedValue.utf8)
        }
        return bom + data
    }

    /// The encoding of a text body, the byte order mark it starts with, if any, and whether the
    /// encoding was declared (a mark, a `charset` or an XML `encoding`).
    private static func textEncoding(of body: Data, contentType: String?, xml: Bool) -> (String.Encoding, Data, Bool) {
        // UTF-32's marks first: UTF-32LE's starts with UTF-16LE's.
        let marks: [([UInt8], String.Encoding)] = [
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian), ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xEF, 0xBB, 0xBF], .utf8), ([0xFF, 0xFE], .utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian)
        ]
        for (mark, encoding) in marks where body.starts(with: mark) {
            return (encoding, Data(mark), true)
        }
        // XML in UTF-16 without a byte order mark starts with `<` and a NUL (XML 1.0, appendix F).
        if xml, body.count >= 2 {
            if body.starts(with: [0x3C, 0x00]) { return (.utf16LittleEndian, Data(), true) }
            if body.starts(with: [0x00, 0x3C]) { return (.utf16BigEndian, Data(), true) }
        }
        var name = contentType.flatMap(charsetParameter)
        if name == nil, xml, let head = String(data: body.prefix(200), encoding: .isoLatin1),
           let match = xmlEncodingPattern.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) {
            name = (head as NSString).substring(with: match.range(at: 1))
        }
        switch name?.lowercased() {
        case "utf-16", "utf-16be": return (.utf16BigEndian, Data(), true)
        case "utf-16le": return (.utf16LittleEndian, Data(), true)
        case "utf-32", "utf-32be": return (.utf32BigEndian, Data(), true)
        case "utf-32le": return (.utf32LittleEndian, Data(), true)
        case "iso-8859-1", "latin1", "latin-1": return (.isoLatin1, Data(), true)
        case "windows-1252", "cp1252": return (.windowsCP1252, Data(), true)
        case "us-ascii", "ascii": return (.ascii, Data(), true)
        default: return (.utf8, Data(), name != nil)
        }
    }

    /// The `charset` parameter of a Content-Type. Parameters are split on `;` outside quoted
    /// values, so `name="a;charset=utf-16"` holds no charset.
    private static func charsetParameter(_ contentType: String) -> String? {
        var parameters: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in contentType {
            if escaped {
                escaped = false
            } else if quoted, character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ";", !quoted {
                parameters.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        parameters.append(current)
        for parameter in parameters.dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair[0].lowercased() == "charset" else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    /// The `encoding` of an XML declaration (group 1).
    private static let xmlEncodingPattern = try! NSRegularExpression(
        pattern: #"^\s*<\?xml[^>]*\bencoding\s*=\s*["']([A-Za-z0-9._-]+)["']"#
    )

    /// The placeholder as XML text, so a masked document stays well-formed.
    private static let xmlRedactedValue = "&lt;redacted&gt;"

    /// Masks the value of every attribute named after a key, keeping its quotes, then the whole
    /// content of every element named after a key, nested markup and CDATA included; a closing tag
    /// written inside CDATA or a comment doesn't end the element. Names may carry
    /// a namespace prefix (`ns:password`); the local name is compared.
    private func maskingXML(_ text: String) -> String {
        guard !normalizedBodyKeys.isEmpty else { return text }
        func masked(_ name: String) -> Bool {
            normalizedBodyKeys.contains(Self.normalize(String(name.split(separator: ":").last ?? Substring(name))))
        }
        var source = text as NSString
        var result = ""
        var cursor = 0
        // Attributes are looked for inside tags only: `note="` in element text must not hide the
        // tag that follows it.
        let attributes = Self.xmlTagPattern.matches(in: text, range: NSRange(location: 0, length: source.length))
            .filter { !Self.isNonMarkup($0, in: source) }
            .flatMap { Self.xmlAttributePattern.matches(in: text, range: $0.range) }
        for match in attributes where masked(source.substring(with: match.range(at: 1))) {
            let value = match.range(at: 3)
            // Keep the quotes: the value is everything between them, or up to the end of a document
            // cut off inside it.
            let closed = value.length >= 2 && source.character(at: value.location + value.length - 1) == source.character(at: value.location)
            let inner = NSRange(location: value.location + 1, length: value.length - (closed ? 2 : 1))
            result += source.substring(with: NSRange(location: cursor, length: inner.location - cursor))
            result += Self.xmlRedactedValue
            cursor = inner.location + inner.length
        }
        let attributesMasked = cursor > 0 ? result + source.substring(from: cursor) : text

        source = attributesMasked as NSString
        result = ""
        cursor = 0
        var position = 0
        while position < source.length,
              let start = Self.xmlStartTagPattern.firstMatch(
                  in: attributesMasked, range: NSRange(location: position, length: source.length - position)
              ) {
            let contentStart = start.range.location + start.range.length
            position = contentStart
            // A tag written inside a CDATA section, comment or processing instruction isn't one.
            guard !Self.isNonMarkup(start, in: source) else { continue }
            let name = source.substring(with: start.range(at: 1))
            guard masked(name) else { continue }
            result += source.substring(with: NSRange(location: cursor, length: contentStart - cursor))
            result += Self.xmlRedactedValue
            // A document cut off inside the element (a truncated capture) is masked to its end.
            guard let end = Self.closingTag(named: name, in: source, from: contentStart) else { return result }
            cursor = end.location
            position = end.location + end.length
        }
        guard cursor > 0 else { return attributesMasked }
        return result + source.substring(from: cursor)
    }

    /// The `</name>` that closes the element whose content starts at `location`, counting nested
    /// elements of the same name, or `nil` when the document ends before it.
    private static func closingTag(named name: String, in source: NSString, from location: Int) -> NSRange? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        // CDATA sections, comments and processing instructions come first, so a tag written inside
        // one isn't counted; one left open runs to the end, and so does the element.
        let pattern = Self.xmlNonMarkup + #"|<(/)?"# + escaped
            + #"(?:\s(?:[^<>"'/]|"[^"<]*"|'[^'<]*'|/(?!>))*)?(/)?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        var depth = 1
        var closing: NSRange?
        // Enumerated, not collected: the scan stops at the closing tag instead of reading every
        // later sibling.
        regex.enumerateMatches(in: source as String, range: NSRange(location: location, length: source.length - location)) { match, _, stop in
            guard let match, !Self.isNonMarkup(match, in: source) else { return }
            if match.range(at: 1).location != NSNotFound {
                depth -= 1
                if depth == 0 {
                    closing = match.range
                    stop.pointee = true
                }
            } else if match.range(at: 2).location == NSNotFound {
                depth += 1
            }
        }
        return closing
    }

    /// An attribute: its name (group 1), `=` and a quoted value (group 3). XML attribute values
    /// don't escape quotes with a backslash and can't hold `<`, so a value ends at its first
    /// matching quote; one left open ends before the next `<` or at the end of a cut-off document.
    private static let xmlAttributePattern = try! NSRegularExpression(
        pattern: #"(?<=[\s<])("# + xmlName + #")(\s*=\s*)("[^"<]*(?:"|(?=<)|\z)|'[^'<]*(?:'|(?=<)|\z))"#
    )

    /// Any start tag, self-closing or cut off, as the range its attributes are looked for in. It
    /// ends at `>`, or, when malformed, before the next `<` or at the end of the document.
    private static let xmlTagPattern = try! NSRegularExpression(
        pattern: xmlNonMarkup + "|<" + xmlName + #"(?:\s(?:[^<>"']|"[^"<]*"|'[^'<]*')*(?:"[^"<]*|'[^'<]*)?)?(?:>|(?=<)|\z)"#,
        options: [.dotMatchesLineSeparators]
    )

    /// An XML name, prefix included: letters of any script, digits, `_`, `.`, `-` and `:`.
    private static let xmlName = #"[\p{L}_][\p{L}\p{M}\p{N}_.:-]*"#

    /// A DOCTYPE (its quoted literals and internal subset included), CDATA section, comment or
    /// processing instruction, matched before tags so their text is skipped; a CDATA section,
    /// comment or processing instruction left open runs to the end of the document.
    private static let xmlNonMarkup = #"<!DOCTYPE(?:[^\[>"']|"[^"]*"|'[^']*')*(?:\[(?:<!--.*?-->|[^\]"']|"[^"]*"|'[^']*')*\])?\s*>"#
        + #"|<!\[CDATA\[.*?(?:\]\]>|\z)|<!--.*?(?:-->|\z)|<\?.*?(?:\?>|\z)"#

    /// Whether a match of a pattern that starts with `xmlNonMarkup` is one of those, not a tag.
    private static func isNonMarkup(_ match: NSTextCheckingResult, in source: NSString) -> Bool {
        guard match.range.length > 1 else { return false }
        let next = source.character(at: match.range.location + 1)
        return next == 0x21 || next == 0x3F // `<!` or `<?`
    }

    /// A start tag that isn't self-closing: its name (group 1), after the non-markup it skips.
    /// Quoted attribute values may hold `>`.
    private static let xmlStartTagPattern = try! NSRegularExpression(
        pattern: xmlNonMarkup + "|<(" + xmlName + #")(?:\s(?:[^<>"'/]|"[^"<]*"|'[^'<]*'|/(?!>))*)?>"#,
        options: [.dotMatchesLineSeparators]
    )

    /// The host's redactor over text whose type is unknown; output that isn't UTF-8 becomes the
    /// placeholder rather than the unmasked text.
    private func applyingCustomRedactor(to text: String) -> String {
        guard let customBodyRedactor else { return text }
        return String(data: customBodyRedactor(Data(text.utf8), nil), encoding: .utf8) ?? Self.redactedValue
    }

    private static let keyValuePattern = try! NSRegularExpression(
        // Spaces and tabs only around `:` or `=`: an empty value at a line's end must not take the
        // next line's key as its value and leave that key's value unmasked.
        pattern: #"(^|[\s&;,{"'])([A-Za-z0-9_.%+-]+)(["']?[ \t]*[:=][ \t]*)("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s&;,}]+)"#
    )

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
            // Plaintext a decryptor produced: its format is unknown, so JSON or key/value pairs.
            decryptedResponseBody: record.decryptedResponseBody.map { sanitize(unformattedText: $0) }
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
