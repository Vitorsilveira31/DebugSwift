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

    private func xml(_ text: String, type: String = "application/xml") -> String? {
        String(data: sanitizer.sanitize(body: Data(text.utf8), contentType: type), encoding: .utf8)
    }

    @Test func masksKeyValuePairsInTextBodies() {
        let masked = sanitizer.sanitize(body: Data("user=ana password=secret".utf8), contentType: "text/plain; charset=utf-8")
        #expect(String(data: masked, encoding: .utf8) == "user=ana password=<redacted>")
        let plain = Data("nothing to hide".utf8)
        #expect(sanitizer.sanitize(body: plain, contentType: "text/plain") == plain)
        let image = Data([0x89, 0x50, 0x4e, 0x47])
        #expect(sanitizer.sanitize(body: image, contentType: "image/png") == image)
    }

    @Test func masksXMLElementsAndAttributesNamedAfterAKey() {
        #expect(xml("<login><user>ana</user><password>secret</password></login>")
            == "<login><user>ana</user><password>&lt;redacted&gt;</password></login>")
        #expect(xml(#"<user name="ana" password="hunter2"/>"#, type: "text/xml")
            == #"<user name="ana" password="&lt;redacted&gt;"/>"#)
        #expect(xml("<user token = 'abc'/>") == "<user token = '&lt;redacted&gt;'/>")
        #expect(xml("<s:Envelope><ns:password>x</ns:password></s:Envelope>", type: "application/soap+xml")
            == "<s:Envelope><ns:password>&lt;redacted&gt;</ns:password></s:Envelope>")
    }

    @Test func anXMLElementIsMaskedWholeWhateverItHolds() {
        // A `>` in a quoted attribute doesn't end the start tag.
        #expect(xml(#"<password hint=">">hunter2</password>"#) == #"<password hint=">">&lt;redacted&gt;</password>"#)
        #expect(xml("<password><![CDATA[a<b]]></password>") == "<password>&lt;redacted&gt;</password>")
        #expect(xml("<password><part>a</part>\n<part>b</part></password><user>ana</user>")
            == "<password>&lt;redacted&gt;</password><user>ana</user>")
        // A nested element of the same name doesn't end the outer one.
        #expect(xml("<password><password>a</password>b</password>") == "<password>&lt;redacted&gt;</password>")
        // A longer name that starts like a key isn't that key.
        #expect(xml("<passwordHint>dog</passwordHint>") == "<passwordHint>dog</passwordHint>")
        #expect(xml("<password/><user>ana</user>") == "<password/><user>ana</user>")
    }

    @Test func aCutOffXMLDocumentIsMaskedToItsEnd() {
        #expect(xml("<login><password>hunter2") == "<login><password>&lt;redacted&gt;")
        #expect(xml(#"<user password="hunt"#) == #"<user password="&lt;redacted&gt;"#)
    }

    @Test func anXMLDocumentWithNothingToMaskIsReturnedByteForByte() {
        let body = Data(#"<user name="ana"><city>Rio</city></user>"#.utf8)
        #expect(sanitizer.sanitize(body: body, contentType: "application/xml") == body)
    }

    @Test func aClosingTagInsideCDATAOrACommentDoesNotEndTheElement() {
        #expect(xml("<password><![CDATA[</password>hunter2]]></password>") == "<password>&lt;redacted&gt;</password>")
        #expect(xml("<password><!-- </password> -->hunter2</password><user>ana</user>")
            == "<password>&lt;redacted&gt;</password><user>ana</user>")
        #expect(xml("<password><![CDATA[hunter2") == "<password>&lt;redacted&gt;")
    }

    @Test func attributesAreOnlyLookedForInsideTags() {
        #expect(xml(#"<root>note="<user password="hunter2"/></root>"#)
            == #"<root>note="<user password="&lt;redacted&gt;"/></root>"#)
        #expect(xml(#"<root>password="text"</root>"#) == #"<root>password="text"</root>"#)
    }

    @Test func anUnclosedAttributeValueDoesNotHideTheTagsAfterIt() {
        #expect(xml(#"<a hint="oops><user password="hunter2"/>"#) == #"<a hint="oops><user password="&lt;redacted&gt;"/>"#)
        #expect(xml(#"<user password="hunt<b/>"#) == #"<user password="&lt;redacted&gt;<b/>"#)
    }

    @Test func manyMaskedSiblingsAreMaskedInOnePass() {
        let body = String(repeating: "<password>x</password>", count: 2_000)
        #expect(xml(body) == String(repeating: "<password>&lt;redacted&gt;</password>", count: 2_000))
        // Time grows with the size: 20,000 elements with attributes take well under a second.
        let start = Date()
        let large = String(repeating: #"<x a="1"><password>x</password></x>"#, count: 20_000)
        #expect(xml(large)?.contains("<password>x</password>") == false)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func processingInstructionsCommentsAndCDATAHoldNoTags() {
        #expect(xml("<password><?pi </password> ?>hunter2</password>") == "<password>&lt;redacted&gt;</password>")
        let comment = "<root><!-- <password> --><user>ana</user></root>"
        #expect(xml(comment) == comment)
        let cdata = "<root><![CDATA[<password>]]>ana</root>"
        #expect(xml(cdata) == cdata)
    }

    @Test func attributesInsideCDATAOrCommentsAreLeftAlone() {
        #expect(xml(#"<root><![CDATA[<a password="]]><password>hunter2</password></root>"#)
            == #"<root><![CDATA[<a password="]]><password>&lt;redacted&gt;</password></root>"#)
    }

    @Test func namesInAnyScriptAreRecognized() {
        #expect(xml("<données><ü:password>x</ü:password></données>") == "<données><ü:password>&lt;redacted&gt;</ü:password></données>")
        #expect(xml(#"<usuário password="x"/>"#) == #"<usuário password="&lt;redacted&gt;"/>"#)
    }

    @Test func contentTypeParametersDoNotPickTheMasker() {
        let text = sanitizer.sanitize(body: Data("password=hunter2".utf8), contentType: #"text/plain; name="payload.xml""#)
        #expect(String(data: text, encoding: .utf8) == "password=<redacted>")
        #expect(xml("<password>x</password>", type: #"application/soap+xml; action="urn:json""#) == "<password>&lt;redacted&gt;</password>")
    }

    @Test func textBodiesAreMaskedInTheirDeclaredEncoding() {
        let utf16 = Data([0xFF, 0xFE]) + "<password>hunter2</password>".data(using: .utf16LittleEndian)!
        let masked16 = sanitizer.sanitize(body: utf16, contentType: "application/xml; charset=utf-16")
        #expect(masked16.starts(with: [0xFF, 0xFE]))
        #expect(String(data: masked16.dropFirst(2), encoding: .utf16LittleEndian) == "<password>&lt;redacted&gt;</password>")
        let latin1 = "café password=hunter2".data(using: .isoLatin1)!
        let maskedLatin1 = sanitizer.sanitize(body: latin1, contentType: "text/plain; charset=iso-8859-1")
        #expect(String(data: maskedLatin1, encoding: .isoLatin1) == "café password=<redacted>")
        let declared = #"<?xml version="1.0" encoding="ISO-8859-1"?><password>é</password>"#.data(using: .isoLatin1)!
        #expect(String(data: sanitizer.sanitize(body: declared, contentType: "text/xml"), encoding: .isoLatin1)
            == #"<?xml version="1.0" encoding="ISO-8859-1"?><password>&lt;redacted&gt;</password>"#)
        // Without a declared encoding, a body that isn't UTF-8 is read byte for byte.
        let undeclared = "café password=hunter2".data(using: .windowsCP1252)!
        #expect(sanitizer.sanitize(body: undeclared, contentType: "text/plain")
            == "café password=<redacted>".data(using: .windowsCP1252)!)
        // Bytes the declared encoding can't read are replaced, not passed through.
        let invalid = Data([0x70, 0x3D, 0xFF, 0xFE, 0xFD])
        #expect(sanitizer.sanitize(body: invalid, contentType: "text/plain; charset=utf-8") == Data("<redacted>".utf8))
    }

    @Test func aDOCTYPEIsSkippedWithItsLiterals() {
        #expect(xml(#"<!DOCTYPE r [<!-- a "quote --><?pi x?>]><r><password>hunter2</password></r>"#)
            == #"<!DOCTYPE r [<!-- a "quote --><?pi x?>]><r><password>&lt;redacted&gt;</password></r>"#)
        let doctype = #"<!DOCTYPE r SYSTEM "r.dtd"><r>ana</r>"#
        #expect(xml(doctype) == doctype)
    }

    @Test func aBodyThatDeclaresEntitiesIsReplacedWhole() {
        #expect(xml(#"<!DOCTYPE r [<!ENTITY credential "hunter2">]><r><password>&credential;</password></r>"#) == "<redacted>")
        #expect(xml(#"<!DOCTYPE r [<!ENTITY e "<!--">]><r><password>hunter2</password></r>"#) == "<redacted>")
    }

    @Test func decodedTextIsNotReadAgainInTheHeadersCharset() {
        #expect(sanitizer.sanitize(text: "password=hunter2", contentType: "text/plain; charset=utf-16le") == "password=<redacted>")
        let capture = HARCapture(
            request: HARRequest(method: "POST", url: "https://example.com", headers: ["Content-Type": "text/plain; charset=utf-16le"], body: "password=hunter2"),
            response: HARResponse(status: 200, headers: [:])
        )
        #expect(sanitizer.sanitize(capture).request.body == "password=<redacted>")
    }

    @Test func utf16XMLWithoutAByteOrderMarkIsRecognized() {
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
            let body = "<password>hunter2</password>".data(using: encoding)!
            #expect(String(data: sanitizer.sanitize(body: body, contentType: "application/xml"), encoding: encoding)
                == "<password>&lt;redacted&gt;</password>")
        }
    }

    @Test func utf32BodiesAreNotTakenForUTF16() {
        let body = Data([0xFF, 0xFE, 0x00, 0x00]) + "<password>hunter2</password>".data(using: .utf32LittleEndian)!
        let masked = sanitizer.sanitize(body: body, contentType: "application/xml")
        #expect(String(data: masked.dropFirst(4), encoding: .utf32LittleEndian) == "<password>&lt;redacted&gt;</password>")
    }

    @Test func aQuotedParameterHoldsNoCharset() {
        let masked = sanitizer.sanitize(body: Data("password=hunter2".utf8), contentType: #"text/plain; name="report;charset=utf-16""#)
        #expect(String(data: masked, encoding: .utf8) == "password=<redacted>")
        let utf16 = "password=hunter2".data(using: .utf16BigEndian)!
        #expect(String(data: sanitizer.sanitize(body: utf16, contentType: #"text/plain; charset="utf-16""#), encoding: .utf16BigEndian)
            == "password=<redacted>")
    }

    @Test func aCutOffDOCTYPESubsetFailsFast() {
        let start = Date()
        let body = "<!DOCTYPE r [" + String(repeating: "<!-- c -->", count: 40)
        _ = xml(body)
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func aDeclaredEncodingThatCantBeReadIsReplaced() {
        let utf7 = Data("+ADw-password+AD4-hunter2+ADw-/password+AD4-".utf8)
        #expect(sanitizer.sanitize(body: utf7, contentType: "application/xml; charset=utf-7") == Data("<redacted>".utf8))
        let plain = Data("password=hunter2".utf8)
        #expect(String(data: sanitizer.sanitize(body: plain, contentType: "text/plain; charset=UTF-8"), encoding: .utf8) == "password=<redacted>")
    }

    @Test func theSubtypeAndItsSuffixPickTheMasker() {
        #expect(xml("<password>x</password>", type: "application/vnd.json+xml") == "<password>&lt;redacted&gt;</password>")
        let report = Data("<password>x</password>".utf8)
        #expect(sanitizer.sanitize(body: report, contentType: "application/vnd.example.xml-report") == report)
        let json = sanitizer.sanitize(body: Data(#"{"password":"x"}"#.utf8), contentType: "application/problem+json")
        #expect(String(data: json, encoding: .utf8) == #"{"password":"<redacted>"}"#)
    }

    @Test func aQuotedCharsetIsUnescapedAndOnlyAnXMLDeclarationNamesAnEncoding() {
        let utf16 = "password=demo".data(using: .utf16LittleEndian)!
        #expect(String(data: sanitizer.sanitize(body: utf16, contentType: #"text/plain; charset="utf\-16le""#), encoding: .utf16LittleEndian)
            == "password=<redacted>")
        #expect(xml(#"<?xml-example encoding="utf-16"?><password>demo</password>"#)
            == #"<?xml-example encoding="utf-16"?><password>&lt;redacted&gt;</password>"#)
    }

    @Test func processingInstructionsInsideADOCTYPESubsetAreSkipped() {
        let body = #"<!DOCTYPE r [<?pi <password> ]> ?>]><r>ana</r>"#
        #expect(xml(body) == body)
    }

    @Test func aLongXMLDeclarationIsReadWhole() {
        let padding = String(repeating: " ", count: 300)
        let body = Data("<?xml version=\"1.0\"\(padding)encoding=\"utf-7\"?>+ADw-password+AD4-hunter2+ADw-/password+AD4-".utf8)
        #expect(sanitizer.sanitize(body: body, contentType: "application/xml") == Data("<redacted>".utf8))
    }

    @Test func decodedTextReadsRawBodiesAsTheSanitizerDoes() {
        let bare = "<password>x</password>".data(using: .utf16LittleEndian)!
        #expect(NetworkSanitizer.decodedText(of: bare, contentType: "application/xml") == "<password>x</password>")
        let bom = Data([0xFE, 0xFF]) + "a=b".data(using: .utf16BigEndian)!
        #expect(NetworkSanitizer.decodedText(of: bom, contentType: "text/plain") == "a=b")
        let utf7 = Data(#"<?xml version="1.0" encoding="UTF-7"?>+ADw-password+AD4-x"#.utf8)
        #expect(NetworkSanitizer.decodedText(of: utf7, contentType: "application/xml") == nil)
        #expect(NetworkSanitizer.decodedText(of: Data("{}".utf8), contentType: nil) == "{}")
    }
}
