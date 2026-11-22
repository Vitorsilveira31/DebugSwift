import Foundation
import Testing
@testable import DebugSwiftCore

struct HARAndGraphQLTests {
    @Test func labelsAGraphQLOperationByTypeAndName() {
        #expect(GraphQLInspector.operationLabel(from: #"{"query":"query GetUser { user { id } }"}"#) == "Query: GetUser")
        #expect(GraphQLInspector.operationLabel(from: #"{"query":"mutation Save($id: ID) { save }"}"#) == "Mutation: Save")
        // A persisted query has no text, only its name.
        #expect(GraphQLInspector.operationLabel(from: #"{"operationName":"Feed","extensions":{}}"#) == "Operation: Feed")
        #expect(GraphQLInspector.operationLabel(from: #"{"name":"not graphql"}"#) == "")
        #expect(GraphQLInspector.operationLabel(from: "plain text") == "")
    }

    @Test func aHAREntryCarriesBothBodiesAndTheirTypes() throws {
        let capture = HARCapture(
            request: HARRequest(method: "POST", url: "https://api.test/items", headers: ["content-type": "application/json"], body: #"{"name":"café"}"#),
            response: HARResponse(status: 201, headers: ["Content-Type": "application/json"], body: #"{"id":1}"#)
        )
        let log = try #require(HAREncoder.encode([capture])["log"] as? [String: Any])
        let entry = try #require((log["entries"] as? [[String: Any]])?.first)
        let request = try #require(entry["request"] as? [String: Any])
        let postData = try #require(request["postData"] as? [String: Any])
        #expect(postData["text"] as? String == #"{"name":"café"}"#)
        #expect(postData["mimeType"] as? String == "application/json")
        // Sizes count bytes: "é" is two.
        #expect(request["bodySize"] as? Int == 16)
        let content = try #require((entry["response"] as? [String: Any])?["content"] as? [String: Any])
        #expect(content["text"] as? String == #"{"id":1}"#)
        #expect(content["mimeType"] as? String == "application/json")
    }

    @Test func aHAREntryWithoutBodiesHasNoBodyFields() throws {
        let capture = HARCapture(
            request: HARRequest(method: "GET", url: "https://api.test", headers: [:]),
            response: HARResponse(status: 204, headers: [:])
        )
        let log = try #require(HAREncoder.encode([capture])["log"] as? [String: Any])
        let entry = try #require((log["entries"] as? [[String: Any]])?.first)
        #expect((entry["request"] as? [String: Any])?["postData"] == nil)
        #expect(((entry["response"] as? [String: Any])?["content"] as? [String: Any])?["text"] == nil)
    }

    @Test func operationNameChoosesTheOperationInAMultiOperationDocument() {
        let body = #"{"operationName":"Save","query":"query Read { viewer { id } } mutation Save { save }"}"#
        #expect(GraphQLInspector.operationLabel(from: body) == "Mutation: Save")
        // A name that isn't declared falls back to the first operation.
        #expect(GraphQLInspector.operationLabel(from: #"{"operationName":"Other","query":"query Read { a }"}"#) == "Query: Read")
    }

    @Test func credentialHeadersAreMaskedWhateverTheirCase() {
        let headers = HAREncoder.redactHeaders(["authorization": "Bearer t", "COOKIE": "a=1", "Accept": "x"])
        #expect(headers == ["authorization": "<redacted>", "COOKIE": "<redacted>", "Accept": "x"])
    }
}
