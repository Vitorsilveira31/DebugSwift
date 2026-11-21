//
//  SharedAppScreensTests.swift
//  ExampleTests
//

import CoreLocation
@_spi(DebugSwiftUI) @testable import DebugSwift
@testable import DebugSwiftUI
import Foundation
import OSLog
import Testing

/// The shared SwiftUI App screens read the same operations on iOS as on Android. These check that
/// DebugSwift's iOS answers decode into the models the screens use.
/// Serialized: the log tests share the provider's log cache and its Clear time.
@MainActor
@Suite(.serialized)
struct SharedAppScreensTests {
    @Test("Crash reports decode, with one screenshot slot per report")
    func crashes() throws {
        let listing = try DebugResourceClient.fetch("app.crashes", as: DebugCrashListing.self).get()
        #expect(listing.exits.isEmpty)
        #expect(listing.screenshots?.count == listing.reports.count)
    }

    @Test("The system log keeps entries at or above the minimum level")
    func systemLog() async throws {
        let marker = UUID().uuidString.prefix(8)
        DebugSwiftLogProbe.logNotice("level-notice-\(marker)")
        DebugSwiftLogProbe.logError("level-error-\(marker)")
        func messages(_ level: String) throws -> [String] {
            try DebugResourceClient.fetch("app.logcat", ["filter": "level-", "level": level], as: DebugLogListing.self).get().entries.map(\.message)
        }
        var all: [String] = []
        // The first read covers the last five minutes of a busy test process, which takes a while.
        for _ in 0..<300 where !(all.contains("level-notice-\(marker)") && all.contains("level-error-\(marker)")) {
            try await Task.sleep(nanoseconds: 200_000_000)
            all = try messages("V")
        }
        #expect(all.contains("level-notice-\(marker)"))
        #expect(all.contains("level-error-\(marker)"))
        let errors = try messages("E")
        #expect(errors.contains("level-error-\(marker)"))
        #expect(!errors.contains("level-notice-\(marker)"))
    }

    @Test("Clearing the log hides what was logged before, and new entries appear")
    func clearLog() async throws {
        let before = "logclear-before-\(UUID().uuidString.prefix(8))"
        let after = "logclear-after-\(UUID().uuidString.prefix(8))"
        func messages() throws -> [String] {
            try DebugResourceClient.fetch("app.logcat", ["filter": "logclear-", "level": "V"], as: DebugLogListing.self).get().entries.map(\.message)
        }
        DebugSwiftLogProbe.logError(before)
        var seen: [String] = []
        for _ in 0..<300 where !seen.contains(before) {
            try await Task.sleep(nanoseconds: 200_000_000)
            seen = try messages()
        }
        #expect(seen.contains(before))

        _ = try DebugResourceClient.fetch("app.logcat.clear", as: DebugActionReply.self).get()
        try await Task.sleep(nanoseconds: 50_000_000)
        DebugSwiftLogProbe.logError(after)
        seen = []
        for _ in 0..<300 where !seen.contains(after) {
            try await Task.sleep(nanoseconds: 200_000_000)
            seen = try messages()
        }
        #expect(seen.contains(after))
        #expect(!seen.contains(before))
    }

    @Test("Switching the Apple subsystems filter right after a read still reads the log")
    func logFilterSwitch() async throws {
        func listing(apple: Bool) throws -> DebugLogListing {
            try DebugResourceClient.fetch("app.logcat", ["filter": "", "level": "V", "apple": apple ? "true" : "false"], as: DebugLogListing.self).get()
        }
        DebugSwiftLogProbe.logError("filter-switch-probe")
        var current = try listing(apple: false)
        for _ in 0..<50 where current.pending == true {
            try await Task.sleep(nanoseconds: 100_000_000)
            current = try listing(apple: false)
        }
        // Right after that read ends, inside the read throttle: the screen only asks again while
        // a read is pending, so the answer must start one (or already have entries).
        current = try listing(apple: true)
        #expect(current.pending == true || !current.entries.isEmpty)
        // Back to the app's own entries before the next test.
        current = try listing(apple: false)
        for _ in 0..<100 where current.pending == true {
            try await Task.sleep(nanoseconds: 100_000_000)
            current = try listing(apple: false)
        }
    }

    @Test("A link no app handles ends up failed in the history")
    func deepLinkFailure() async throws {
        let link = "debugswift-no-handler-\(UUID().uuidString.prefix(6).lowercased())://x"
        _ = try DebugResourceClient.fetch("app.deeplink.open", ["uri": link], as: DebugActionReply.self).get()
        var history = try DebugResourceClient.fetch("app.deeplink.history", as: DebugDeepLinkHistory.self).get()
        for _ in 0..<50 where history.pending == true || !history.entries.contains(where: { $0.url == link }) {
            try await Task.sleep(nanoseconds: 100_000_000)
            history = try DebugResourceClient.fetch("app.deeplink.history", as: DebugDeepLinkHistory.self).get()
        }
        let entry = try #require(history.entries.first { $0.url == link })
        #expect(entry.status != "Success")
    }

    @Test("The agent log state lists the newest lines of a large log")
    func agentLogTail() throws {
        let url = AgentDebugLog.shared.currentLogPath()
        let original = try? Data(contentsOf: url)
        defer {
            if let original { try? original.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = (0..<3000).map { #"{"timestamp":\#($0),"kind":"app","location":"test","message":"line-\#($0)"}"# }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let state = try DebugResourceClient.fetch("app.agentlog.state", as: DebugAgentLogState.self).get()
        #expect(state.entries.count == 100)
        #expect(state.entries.first?.message == "line-2999")
        #expect(state.entries.last?.message == "line-2900")
    }

    @Test("A tail window that starts on a line boundary keeps its first line")
    func agentLogTailBoundary() throws {
        let url = AgentDebugLog.shared.currentLogPath()
        let original = try? Data(contentsOf: url)
        defer {
            if let original { try? original.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 1024-byte lines: the 64 KB window holds exactly 64 whole lines, starting right after a newline.
        let lines = (0..<200).map { index -> String in
            let head = #"{"timestamp":\#(index),"kind":"app","location":"test","message":"line-\#(index)","pad":""#
            return head + String(repeating: "x", count: 1023 - head.utf8.count - 2) + #""}"#
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let state = try DebugResourceClient.fetch("app.agentlog.state", as: DebugAgentLogState.self).get()
        #expect(state.entries.count == 64)
        #expect(state.entries.last?.message == "line-136")
    }

    @Test("A log tail that starts inside a character still lists its whole lines")
    func agentLogTailUnicode() throws {
        let url = AgentDebugLog.shared.currentLogPath()
        let original = try? Data(contentsOf: url)
        defer {
            if let original { try? original.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Each line is 3-byte characters only, so the 64 KB window starts inside one of them.
        let lines = (0..<2000).map { #"{"timestamp":\#($0),"kind":"app","location":"中中中","message":"中-\#($0)"}"# }
        var data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let window = 64 * 1024
        // Each newline added at the end moves the window's first byte one byte on; stop at the
        // second byte of a "中" (E4 B8 AD), leaving two continuation bytes before the next one.
        while data[data.count - window] != 0xB8 { data.append(UInt8(ascii: "\n")) }
        try data.write(to: url)
        let state = try DebugResourceClient.fetch("app.agentlog.state", as: DebugAgentLogState.self).get()
        #expect(state.entries.count == 100)
        #expect(state.entries.first?.message == "中-1999")
    }

    @Test("Mocking a location reports it and stopping clears it")
    func location() throws {
        let previous = LocationToolkit.shared.simulatedLocation
        defer { LocationToolkit.shared.simulatedLocation = previous }
        let set = try DebugResourceClient.fetch("app.location.mock", ["latitude": "35.702069", "longitude": "139.775327"], as: DebugActionReply.self).get()
        #expect(set.mocking == true)
        #expect(DebugSwiftRuntime.snapshot(featureID: "location").contains("35.702069"))
        #expect(try DebugResourceClient.fetch("app.location.state", as: DebugActionReply.self).get().mocking == true)

        let bad = try DebugResourceClient.fetch("app.location.mock", ["latitude": "95", "longitude": "0"], as: DebugActionReply.self).get()
        #expect(bad.message?.contains("-90 to 90") == true)

        let stop = try DebugResourceClient.fetch("app.location.stop", as: DebugActionReply.self).get()
        #expect(stop.mocking == false)
        #expect(LocationToolkit.shared.simulatedLocation == nil)
    }

    @Test("Deep link history decodes, and an invalid link is rejected")
    func deepLinks() throws {
        _ = try DebugResourceClient.fetch("app.deeplink.history", as: DebugDeepLinkHistory.self).get()
        let reply = try DebugResourceClient.fetch("app.deeplink.open", ["uri": "   "], as: DebugActionReply.self).get()
        #expect(reply.message?.isEmpty == false)
        #expect(reply.message?.hasPrefix("Opening") == false)
    }

    @Test("The event timeline lists published events, newest first, and clears")
    func eventTimeline() {
        let bus = EventBusSubscriber.shared.bus
        bus.publish(DebugEvent(timestamp: Date(), domain: .app, summary: "shared-timeline-first"))
        bus.publish(DebugEvent(timestamp: Date(), domain: .app, summary: "shared-timeline-second"))
        let lines = DebugSwiftRuntime.snapshot(featureID: "event_bus").split(separator: "\n").map(String.init)
        let first = lines.firstIndex { $0.contains("shared-timeline-first") }
        let second = lines.firstIndex { $0.contains("shared-timeline-second") }
        #expect(first != nil && second != nil)
        if let first, let second { #expect(second < first) }

        _ = DebugSwiftRuntime.perform(featureID: "event_bus", actionID: "clear")
        #expect(DebugSwiftRuntime.snapshot(featureID: "event_bus") == "No diagnostic events published yet.")
    }

    @Test("The agent debug log state decodes and toggles")
    func agentLog() throws {
        let log = AgentDebugLog.shared
        let wasEnabled = log.enabled
        defer { if wasEnabled != log.enabled { _ = DebugSwiftRuntime.perform(featureID: "agent_debug_log", actionID: "toggle") } }
        let before = try DebugResourceClient.fetch("app.agentlog.state", as: DebugAgentLogState.self).get()
        _ = DebugSwiftRuntime.perform(featureID: "agent_debug_log", actionID: "toggle")
        let after = try DebugResourceClient.fetch("app.agentlog.state", as: DebugAgentLogState.self).get()
        #expect(after.enabled != before.enabled)
        #expect(!after.path.isEmpty)
    }
}

/// Writes an error-level entry to the unified log, so the log screen has something to filter.
enum DebugSwiftLogProbe {
    static func logNotice(_ message: String) {
        Logger(subsystem: "DebugSwift.Tests", category: "probe").notice("\(message, privacy: .public)")
    }

    static func logError(_ message: String) {
        Logger(subsystem: "DebugSwift.Tests", category: "probe").error("\(message, privacy: .public)")
    }
}
