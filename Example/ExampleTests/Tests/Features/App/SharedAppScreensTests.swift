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

    @Test("Clearing the log hides what was logged before")
    func clearLog() async throws {
        DebugSwiftLogProbe.logError("logclear-before")
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try DebugResourceClient.fetch("app.logcat.clear", as: DebugActionReply.self).get()
        try await Task.sleep(nanoseconds: 50_000_000)
        DebugSwiftLogProbe.logError("logclear-after")
        let messages = try DebugResourceClient.fetch("app.logcat", ["filter": "logclear-", "level": "V"], as: DebugLogListing.self).get().entries.map(\.message)
        #expect(!messages.contains("logclear-before"))
        #expect(messages.contains("logclear-after"))
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

    @Test("Push state decodes, and options, templates and the switch round-trip")
    func push() throws {
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

        _ = DebugPush.act("toggle")
        #expect(try DebugResourceClient.fetch("app.push.state", as: DebugPushState.self).get().enabled != wasEnabled)
        #expect(DebugPush.act("clear_push_history", "nope").contains("Type CLEAR"))
    }
}

/// Writes an error-level entry to the unified log, so the log screen has something to filter.
enum DebugSwiftLogProbe {
    static func logError(_ message: String) {
        Logger(subsystem: "DebugSwift.Tests", category: "probe").error("\(message, privacy: .public)")
    }
}
