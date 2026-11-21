import Foundation
import Testing
@testable import DebugSwiftCore

struct NetworkSanitizerTests {
    private let sanitizer = NetworkSanitizer.default

    @Test func masksHeadersIgnoringCaseAndSeparators() {
        let headers = sanitizer.sanitize(headers: [
            "authorization": "Bearer secret",
            "x_api_key": "k",
            "Accept": "application/json"
        ])
        #expect(headers["authorization"] == "<redacted>")
        #expect(headers["x_api_key"] == "<redacted>")
        #expect(headers["Accept"] == "application/json")
    }

    @Test func masksSensitiveQueryParametersAndKeepsOthersEncoded() {
        let url = sanitizer.sanitize(url: "https://api.test/v1/items?q=a%20b&access_token=abc&Page=2&apiKey=xyz")
        #expect(url == "https://api.test/v1/items?q=a%20b&access_token=%3Credacted%3E&Page=2&apiKey=%3Credacted%3E")
    }

    @Test func masksOAuthFragmentAndURLPassword() {
        let url = sanitizer.sanitize(url: "https://user:hunter2@auth.test/cb#access_token=abc&state=s1")
        #expect(url == "https://user:%3Credacted%3E@auth.test/cb#access_token=%3Credacted%3E&state=s1")
    }

    @Test func leavesCleanURLsUntouched() {
        let original = "https://api.test/search?q=swift&sort=desc"
        #expect(sanitizer.sanitize(url: original) == original)
    }

    @Test func masksNestedJSONFields() throws {
        let body = Data(#"{"user":{"email":"a@b.c","password":"p"},"items":[{"accessToken":"t","id":1}]}"#.utf8)
        let sanitized = sanitizer.sanitize(body: body, contentType: "application/json; charset=utf-8")
        let object = try #require(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        let user = try #require(object["user"] as? [String: Any])
        #expect(user["password"] as? String == "<redacted>")
        #expect(user["email"] as? String == "a@b.c")
        let items = try #require(object["items"] as? [[String: Any]])
        #expect(items[0]["accessToken"] as? String == "<redacted>")
        #expect(items[0]["id"] as? Int == 1)
    }

    @Test func keepsJSONWithoutSensitiveFieldsByteForByte() {
        let body = Data(#"{ "b": 1,   "a": [true] }"#.utf8)
        #expect(sanitizer.sanitize(body: body, contentType: "application/json") == body)
    }

    @Test func masksFormEncodedBodies() {
        let body = Data("username=ana&password=s%26cret&remember=1".utf8)
        let sanitized = sanitizer.sanitize(body: body, contentType: "application/x-www-form-urlencoded")
        #expect(String(data: sanitized, encoding: .utf8) == "username=ana&password=%3Credacted%3E&remember=1")
    }

    @Test func leavesNonTextBodiesAlone() {
        let body = Data([0xFF, 0x00, 0x10])
        #expect(sanitizer.sanitize(body: body, contentType: "application/octet-stream") == body)
        #expect(sanitizer.sanitize(body: body, contentType: nil) == body)
    }

    @Test func runsTheCustomRedactorLast() {
        var custom = NetworkSanitizer.default
        custom.customBodyRedactor = { body, _ in
            Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "4111", with: "####").utf8)
        }
        let sanitized = custom.sanitize(body: Data("card 4111".utf8), contentType: "text/plain")
        #expect(String(data: sanitized, encoding: .utf8) == "card ####")
    }

    @Test func customKeysReplaceTheDefaults() {
        var custom = NetworkSanitizer.default
        custom.queryParameters = ["session"]
        let url = custom.sanitize(url: "https://a.test/?session=1&token=2")
        #expect(url == "https://a.test/?session=%3Credacted%3E&token=2")
    }

    @Test func disabledSanitizerKeepsEverything() {
        let disabled = NetworkSanitizer.disabled
        #expect(disabled.sanitize(headers: ["Authorization": "x"])["Authorization"] == "x")
        let url = "https://a:b@c.test/?token=1"
        #expect(disabled.sanitize(url: url) == url)
    }

    @Test func sanitizesHARCaptures() {
        let capture = HARCapture(
            request: HARRequest(
                method: "POST",
                url: "https://a.test/login?token=1",
                headers: ["Content-Type": "application/json", "Cookie": "c"],
                body: #"{"password":"p"}"#
            ),
            response: HARResponse(
                status: 200,
                headers: ["content-type": "application/json"],
                body: #"{"refresh_token":"r"}"#
            )
        )
        let clean = sanitizer.sanitize(capture)
        #expect(clean.request.url == "https://a.test/login?token=%3Credacted%3E")
        #expect(clean.request.headers["Cookie"] == "<redacted>")
        #expect(clean.request.body == #"{"password":"<redacted>"}"#)
        #expect(clean.response.body == #"{"refresh_token":"<redacted>"}"#)
    }

    @Test func recorderSanitizesBeforeTruncating() async {
        let recorder = NetworkRecorder(bodyLimit: 1_000)
        await recorder.record(NetworkRecord(
            duration: 0.1,
            method: "POST",
            url: "https://a.test/login?access_token=1",
            requestHeaders: ["Content-Type": "application/json"],
            requestBody: Data(#"{"password":"p"}"#.utf8),
            outcome: .response(statusCode: 200, headers: [:], body: nil)
        ))
        let stored = await recorder.snapshot()[0]
        #expect(stored.url == "https://a.test/login?access_token=%3Credacted%3E")
        #expect(stored.requestBody == Data(#"{"password":"<redacted>"}"#.utf8))
    }

    @Test func recorderUsesReplacedSanitizerForNewRecords() async {
        let recorder = NetworkRecorder()
        await recorder.setSanitizer(.disabled)
        await recorder.record(NetworkRecord(
            duration: 0.1,
            method: "GET",
            url: "https://a.test/?token=1",
            outcome: .response(statusCode: 200, headers: [:], body: nil)
        ))
        #expect(await recorder.snapshot()[0].url == "https://a.test/?token=1")
    }

    @Test func masksKeyValuePairsInTextOfUnknownFormat() {
        let text = #"user=ana password=hunter2; token: "a\"b" note=keep pass%77ord=x"#
        let masked = sanitizer.sanitize(unformattedText: text)
        #expect(masked == #"user=ana password=<redacted>; token: "<redacted>" note=keep pass%77ord=<redacted>"#)
    }

    @Test func masksUnformattedTextAsJSONWhenItParses() {
        let masked = sanitizer.sanitize(unformattedText: #"{"token":"abc","name":"ana"}"#)
        #expect(masked.contains(#""token":"<redacted>""#))
        #expect(masked.contains(#""name":"ana""#))
        // JSON with nothing to mask is returned as it was, not re-scanned as key/value text.
        #expect(sanitizer.sanitize(unformattedText: #"{"name":"ana"}"#) == #"{"name":"ana"}"#)
    }

    @Test func masksADecryptedBodyThatIsNotJSON() {
        let record = NetworkRecord(
            id: UUID(), startedAt: Date(), duration: 0.1, method: "GET", url: "https://api.test",
            requestHeaders: [:], requestBody: nil,
            outcome: .response(statusCode: 200, headers: [:], body: nil),
            decryptedResponseBody: "access_token=abc&scope=read"
        )
        #expect(sanitizer.sanitize(record).decryptedResponseBody == "access_token=<redacted>&scope=read")
    }

    @Test func anEmptyValueDoesNotHideTheNextLinesSecret() {
        #expect(sanitizer.sanitize(unformattedText: "note:\npassword: hunter2") == "note:\npassword: <redacted>")
    }

    @Test func theCustomRedactorRunsOnUnformattedText() {
        var custom = NetworkSanitizer.default
        custom.customBodyRedactor = { body, _ in
            Data((String(data: body, encoding: .utf8) ?? "").replacingOccurrences(of: "4111", with: "####").utf8)
        }
        #expect(custom.sanitize(unformattedText: "card 4111") == "card ####")
        custom.customBodyRedactor = { _, _ in Data([0xff, 0xfe]) }
        #expect(custom.sanitize(unformattedText: "card 4111") == "<redacted>")
    }

    @Test func masksKeyValuePairsInTextBodies() {
        let masked = sanitizer.sanitize(body: Data("user=ana password=secret".utf8), contentType: "text/plain; charset=utf-8")
        #expect(String(data: masked, encoding: .utf8) == "user=ana password=<redacted>")
        let image = Data([0x89, 0x50, 0x4e, 0x47])
        #expect(sanitizer.sanitize(body: image, contentType: "image/png") == image)
    }

    @Test func masksPairsAfterPunctuationAndKeepsXMLWellFormed() {
        #expect(sanitizer.sanitize(unformattedText: "(password=hunter2)") == "(password=<redacted>)")
        let xml = sanitizer.sanitize(body: Data(#"<user name="ana" password="hunter2"/>"#.utf8), contentType: "application/xml")
        #expect(String(data: xml, encoding: .utf8) == #"<user name="ana" password="&lt;redacted&gt;"/>"#)
        // A backslash before a quote ends an XML value; it doesn't escape the quote.
        let path = sanitizer.sanitize(body: Data(#"<user note="C:\" password="hunter2"/>"#.utf8), contentType: "text/xml")
        #expect(String(data: path, encoding: .utf8) == #"<user note="C:\" password="&lt;redacted&gt;"/>"#)
        // Line breaks around `=` are allowed in XML.
        let broken = sanitizer.sanitize(body: Data("<user password\n=\n\"hunter2\"/>".utf8), contentType: "application/xml")
        #expect(String(data: broken, encoding: .utf8) == "<user password\n=\n\"&lt;redacted&gt;\"/>")
        // Text pairs inside XML stay on their line, as in plain text.
        let text = sanitizer.sanitize(body: Data("<root>note:\npassword: hunter2</root>".utf8), contentType: "application/xml")
        #expect(String(data: text, encoding: .utf8) == "<root>note:\npassword: &lt;redacted&gt;</root>")
        // A quoted text value after `:` stays on its line too; quoted text pairs on one line are masked.
        let quoted = sanitizer.sanitize(body: Data("<root>note:\n\"demo\" password: \"x\"</root>".utf8), contentType: "application/xml")
        #expect(String(data: quoted, encoding: .utf8) == "<root>note:\n\"demo\" password: \"&lt;redacted&gt;\"</root>")
        // An element named after a key has its text masked.
        let element = sanitizer.sanitize(body: Data("<login><user>ana</user><password>secret</password></login>".utf8), contentType: "text/xml")
        #expect(String(data: element, encoding: .utf8) == "<login><user>ana</user><password>&lt;redacted&gt;</password></login>")
    }

    @Test func aBodyWithoutAContentTypeIsMaskedAsJSONOrKeyValueText() {
        let form = sanitizer.sanitize(body: Data("user=ana&password=secret".utf8), contentType: nil)
        #expect(String(data: form, encoding: .utf8) == "user=ana&password=<redacted>")
        let json = sanitizer.sanitize(body: Data(#"{"password":"secret"}"#.utf8), contentType: nil)
        #expect(String(data: json, encoding: .utf8) == #"{"password":"<redacted>"}"#)
        let plain = Data(#"{"name":"ana"}"#.utf8)
        #expect(sanitizer.sanitize(body: plain, contentType: nil) == plain)
    }

    @Test func aMaskedKeyInsideAnotherKeysQuotedValueIsStillMasked() {
        let xml = sanitizer.sanitize(body: Data("<root>note:\n\"password: demo\"</root>".utf8), contentType: "application/xml")
        #expect(String(data: xml, encoding: .utf8) == "<root>note:\n\"password: &lt;redacted&gt;\"</root>")
        #expect(sanitizer.sanitize(unformattedText: #"note: "password: demo""#) == #"note: "password: <redacted>""#)
    }

    @Test func anUnquotedXMLValueMayHoldAQuote() {
        let xml = sanitizer.sanitize(body: Data("<root>password=a'long-secret-value</root>".utf8), contentType: "application/xml")
        #expect(String(data: xml, encoding: .utf8) == "<root>password=&lt;redacted&gt;</root>")
    }
}
