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
        #expect(masked == #"user=ana password=<redacted>; token: <redacted> note=keep pass%77ord=<redacted>"#)
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
}
