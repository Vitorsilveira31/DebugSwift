import Foundation
import Testing
@testable import DebugSwiftCore

struct NetworkInspectorRequestTests {
    private func request(
        statusCode: String = "200",
        error: String = "",
        responseHeaders: [String: String] = ["content-type": "application/json"],
        requestBody: Data = Data(#"{"query":"query GetUser { user { id } }","operationName":"GetUser"}"#.utf8),
        responseBody: Data = Data(#"{"data":{}}"#.utf8),
        mimeType: String? = nil
    ) -> NetworkInspectorRequest {
        NetworkInspectorRequest(
            id: "1",
            url: "https://api.example.com/graphql",
            method: "POST",
            statusCode: statusCode,
            startedAtMilliseconds: 1_700_000_000_000,
            durationMilliseconds: 120,
            requestHeaders: ["Accept": "application/json"],
            responseHeaders: responseHeaders,
            requestBody: requestBody,
            responseBody: responseBody,
            mimeType: mimeType,
            error: error
        )
    }

    @Test func derivesSizesBodiesMIMETypeAndGraphQLLabel() {
        let row = request()
        #expect(row.requestBytes == row.requestBody.utf8.count)
        #expect(row.responseBody == #"{"data":{}}"#)
        #expect(row.responseBodyBase64 == Data(#"{"data":{}}"#.utf8).base64EncodedString())
        #expect(row.mimeType == "application/json")
        #expect(row.graphqlOperation == "Query: GetUser")
        #expect(row.timestampMilliseconds == 1_700_000_000_000)
        #expect(!row.timestamp.isEmpty)
        #expect(request(mimeType: "text/plain").mimeType == "text/plain")
    }

    @Test func onlyA2xxWithoutAnErrorIsASuccess() {
        #expect(request(statusCode: "204").isSuccess)
        #expect(!request(statusCode: "304").isSuccess)
        #expect(!request(statusCode: "404").isSuccess)
        #expect(!request(statusCode: "200", error: "The request timed out.").isSuccess)
        #expect(!request(statusCode: "0").isSuccess)
    }

    @Test func binaryBodiesKeepTheirSizeAndBase64() {
        let bytes = Data([0xff, 0xd8, 0xff])
        let row = request(responseHeaders: [:], responseBody: bytes)
        #expect(row.responseBody.isEmpty)
        #expect(row.responseBytes == 3)
        #expect(row.responseBodyBase64 == bytes.base64EncodedString())
        #expect(row.log.contains("<binary data: 3 bytes>"))
        #expect(row.log.contains("------- MIME TYPE -------\nNo data"))
    }

    @Test func theLogListsEverySection() {
        let log = request().log
        #expect(log.hasPrefix("[POST] "))
        #expect(log.contains("(200)"))
        #expect(log.contains("------- URL -------\nhttps://api.example.com/graphql"))
        #expect(log.contains("------- REQUEST HEADER -------\nAccept: application/json"))
        #expect(log.contains("------- TOTAL TIME -------\n120 ms"))
    }

    @Test func theSnapshotRoundTripsThroughJSON() throws {
        struct Snapshot: Decodable { let requests: [NetworkInspectorRequest] }
        let json = NetworkInspectorRequest.snapshotJSON([request(), request(statusCode: "500")])
        let decoded = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        #expect(decoded.requests == [request(), request(statusCode: "500")])
    }
}
