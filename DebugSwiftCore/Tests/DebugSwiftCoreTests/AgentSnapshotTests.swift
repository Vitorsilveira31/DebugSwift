import Foundation
import Testing
@testable import DebugSwiftCore

struct AgentSnapshotTests {
    private func record(_ url: String, status: Int? = 200, duration: TimeInterval = 0.1234) -> NetworkRecord {
        NetworkRecord(
            duration: duration,
            method: "GET",
            url: url,
            outcome: status.map { .response(statusCode: $0, headers: [:], body: nil) } ?? .failure(description: "offline")
        )
    }

    @Test func keepsTheNewestRequestsAndSanitizesTheirURLs() {
        let records = (0..<5).map { record("https://a.test/\($0)?token=s\($0)") }
        let requests = AgentSnapshot.requests(from: records, limit: 2)
        #expect(requests.map(\.url) == [
            "https://a.test/3?token=%3Credacted%3E",
            "https://a.test/4?token=%3Credacted%3E"
        ])
        #expect(requests[0].durationMs == 123)
    }

    @Test func reportsFailuresAsStatusZeroWithTheError() {
        let requests = AgentSnapshot.requests(from: [record("https://a.test", status: nil)])
        #expect(requests[0].status == 0)
        #expect(requests[0].error == "offline")
    }

    @Test func encodesTheDocumentedSchema() throws {
        let snapshot = AgentSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1.5),
            platform: "ios",
            app: ["bundleId": "com.example"],
            metrics: ["cpuPercent": 12.5],
            network: [AgentSnapshot.Request(method: "GET", url: "https://a.test/x", status: 200, durationMs: 5)],
            agentLog: AgentSnapshot.AgentLog(path: "/tmp/agent-debug.ndjson", enabled: true, sessionId: "s1")
        )
        let object = try #require(JSONSerialization.jsonObject(with: snapshot.jsonData()) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["generatedAt"] as? Int == 1500)
        #expect(object["platform"] as? String == "ios")
        #expect((object["metrics"] as? [String: Any])?["cpuPercent"] as? Double == 12.5)
        let network = try #require(object["network"] as? [[String: Any]])
        #expect(network[0]["url"] as? String == "https://a.test/x")
        #expect((object["agentLog"] as? [String: Any])?["sessionId"] as? String == "s1")
        #expect(String(decoding: try snapshot.jsonData(), as: UTF8.self).contains("https://a.test/x"))
    }

    @Test func writesAndReadsBackTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = AgentSnapshot(platform: "android", device: ["model": "Pixel"])
        let url = try snapshot.write(toDirectory: directory)
        #expect(url.lastPathComponent == "agent-snapshot.json")
        let decoded = try JSONDecoder().decode(AgentSnapshot.self, from: Data(contentsOf: url))
        #expect(decoded == snapshot)
    }
}
