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
@MainActor
struct SharedAppScreensTests {
    @Test("Crash reports decode, with one screenshot slot per report")
    func crashes() throws {
        let listing = try DebugResourceClient.fetch("app.crashes", as: DebugCrashListing.self).get()
        #expect(listing.exits.isEmpty)
        #expect(listing.screenshots?.count == listing.reports.count)
    }

    @Test("The system log decodes and honors the minimum level")
    func systemLog() throws {
        DebugSwiftLogProbe.logError("shared-screens-probe")
        let all = try DebugResourceClient.fetch("app.logcat", ["filter": "", "level": "V"], as: DebugLogListing.self).get()
        let errors = try DebugResourceClient.fetch("app.logcat", ["filter": "", "level": "E"], as: DebugLogListing.self).get()
        #expect(errors.entries.count <= all.entries.count)
        #expect(errors.entries.allSatisfy { ["E", "F"].contains($0.level) })
    }

    @Test("Clearing the log hides what was logged before, and new entries appear")
    func clearLog() async throws {
        func messages() async throws -> [String] {
            var listing = try DebugResourceClient.fetch("app.logcat", ["filter": "logclear-", "level": "V"], as: DebugLogListing.self).get()
            for _ in 0..<40 where listing.pending == true {
                try await Task.sleep(nanoseconds: 100_000_000)
                listing = try DebugResourceClient.fetch("app.logcat", ["filter": "logclear-", "level": "V"], as: DebugLogListing.self).get()
            }
            return listing.entries.map(\.message)
        }
        DebugSwiftLogProbe.logError("logclear-before")
        var seen: [String] = []
        for _ in 0..<20 where !seen.contains("logclear-before") {
            try await Task.sleep(nanoseconds: 300_000_000)
            seen = try await messages()
        }
        #expect(seen.contains("logclear-before"))

        _ = try DebugResourceClient.fetch("app.logcat.clear", as: DebugActionReply.self).get()
        try await Task.sleep(nanoseconds: 50_000_000)
        DebugSwiftLogProbe.logError("logclear-after")
        for _ in 0..<20 where !seen.contains("logclear-after") {
            try await Task.sleep(nanoseconds: 300_000_000)
            seen = try await messages()
        }
        #expect(seen.contains("logclear-after"))
        #expect(!seen.contains("logclear-before"))
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

    @Test("A link no app can open reports the failure")
    func deepLinkFailure() throws {
        let reply = try DebugResourceClient.fetch("app.deeplink.open", ["uri": "debugswift-no-handler-scheme://x"], as: DebugActionReply.self).get()
        #expect(reply.message?.hasPrefix("Opening") == false)
        #expect(reply.message?.hasPrefix("Opened") == false)
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

    @Test("Loaded images decode, and a library's classes and a class's methods can be read")
    func libraries() throws {
        let info = try DebugResourceClient.fetch("app.libraries", as: DebugLibrariesInfo.self).get()
        #expect(info.classesAvailable == true)
        #expect(info.abis == nil)
        #expect(!info.packageName.isEmpty)
        #expect(info.libraries.contains { $0.origin == "App" })
        #expect(info.libraries.contains { $0.address?.hasPrefix("0x") == true })

        var found: String?
        for library in info.libraries where library.origin == "App" {
            let classes = try DebugResourceClient.fetch("app.libraries.classes", ["path": library.path], as: DebugClassList.self).get().classes
            if let name = classes.first(where: { $0.hasSuffix("SharedPanelPerformance") }) {
                found = name
                break
            }
        }
        let name = try #require(found)
        let text = try DebugResourceClient.fetch("app.libraries.class", ["name": name], as: DebugClassDescription.self).get().text
        #expect(text.contains("Inherits from NSObject"))
        #expect(text.contains("Instance methods"))
    }

    @Test("Push state decodes, and options, templates, the switch and resending round-trip")
    func push() async throws {
        let push = DebugSwift.PushNotification.self
        let wasEnabled = push.isEnabled
        let config = push.configuration
        defer {
            push.updateConfiguration(config)
            if push.isEnabled != wasEnabled { _ = DebugPush.act("toggle") }
            _ = DebugPush.act("remove_template", "contract-template")
        }
        _ = try DebugResourceClient.fetch("app.push.state", as: DebugPushState.self).get()

        _ = DebugPush.setOption("interactionDelay", "7")
        #expect(try DebugResourceClient.fetch("app.push.state", as: DebugPushState.self).get().interactionDelay == 7)
        #expect(DebugPush.setOption("maxHistoryCount", "0").contains("above 0"))

        _ = DebugPush.act("add_template", "contract-template|Hello|World")
        #expect(try DebugResourceClient.fetch("app.push.state", as: DebugPushState.self).get().templates.contains { $0.name == "contract-template" })
        _ = DebugPush.act("remove_template", "contract-template")
        #expect(try DebugResourceClient.fetch("app.push.state", as: DebugPushState.self).get().templates.contains { $0.name == "contract-template" } == false)

        // A custom template named like a built-in one removes only itself.
        let builtIn = try #require(push.templates.first { $0.isDefault })
        _ = DebugPush.act("add_template", "\(builtIn.name)|Same|Name")
        let custom = try #require(try DebugResourceClient.fetch("app.push.state", as: DebugPushState.self).get().templates.first { $0.name == builtIn.name && !$0.isDefault })
        _ = DebugPush.act("remove_template", custom.reference)
        let remaining = try DebugResourceClient.fetch("app.push.state", as: DebugPushState.self).get().templates
        #expect(remaining.contains { $0.templateID == builtIn.id })
        #expect(!remaining.contains { $0.templateID == custom.templateID })

        _ = DebugPush.act("toggle")
        #expect(try DebugResourceClient.fetch("app.push.state", as: DebugPushState.self).get().enabled != wasEnabled)
        if !push.isEnabled { _ = DebugPush.act("toggle") }

        // The composer's optional fields and payload reach the notification.
        _ = DebugPush.act("notify", "Composed|With payload|0|Sub|5|default|orders|order=42, kind=test")
        var composed: SimulatedNotification?
        for _ in 0..<50 where composed == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
            composed = push.history.first { $0.title == "Composed" }
        }
        #expect(composed?.userInfo == ["order": "42", "kind": "test"])
        #expect(composed?.subtitle == "Sub")
        #expect(composed?.badge == 5)
        #expect(composed?.category == "orders")
        #expect(DebugPush.act("notify", "Bad|Payload|0||||| novalue").contains("key=value"))

        // Sending a notification again keeps its subtitle, badge and payload.
        let original = SimulatedNotification(
            title: "Resend", body: "Payload", subtitle: "Sub", badge: 3, sound: "default",
            category: "contract", userInfo: ["order": "42"]
        )
        await PushNotificationSimulator.shared.simulateNotification(original)
        _ = DebugPush.act("resend_notification", original.id)
        var copy: SimulatedNotification?
        for _ in 0..<50 where copy == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
            copy = push.history.first { $0.id != original.id && $0.title == "Resend" }
        }
        #expect(copy?.userInfo["order"] == "42")
        #expect(copy?.subtitle == "Sub")
        #expect(copy?.badge == 3)
        #expect(copy?.category == "contract")
        #expect(DebugPush.act("clear_push_history", "nope").contains("Type CLEAR"))
    }
}

/// Writes an error-level entry to the unified log, so the log screen has something to filter.
enum DebugSwiftLogProbe {
    static func logError(_ message: String) {
        Logger(subsystem: "DebugSwift.Tests", category: "probe").error("\(message, privacy: .public)")
    }
}
