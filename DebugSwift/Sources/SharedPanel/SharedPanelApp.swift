//
//  SharedPanelApp.swift
//  DebugSwift
//

import CoreLocation
import OSLog
import UIKit

/// The App area of the shared panel on iOS: crash reports, the system log, deep links, location,
/// the event timeline and the agent debug log, in the shapes the Android runtime returns them.
@MainActor
final class SharedPanelApp {
    static let shared = SharedPanelApp()

    private static let logLimit = 500
    private let deepLinks = DeepLinkViewModel()

    private init() {}

    // MARK: - Operations

    func resource(_ operation: String, _ arguments: [String: String]) -> [String: Any]? {
        switch operation {
        case "app.crashes":
            return crashes()
        case "app.logcat":
            return log(filter: arguments["filter"] ?? "", minimumLevel: arguments["level"] ?? "V", includeApple: arguments["apple"] == "true")
        case "app.deeplink.open":
            return openDeepLink(arguments["uri"] ?? "")
        case "app.deeplink.history":
            return [
                "entries": deepLinks.history.map {
                    [
                        "url": $0.urlString,
                        "time": SharedPanelData.timeFormatter.string(from: $0.timestamp),
                        "status": $0.statusRawValue,
                        "error": $0.errorMessage ?? ""
                    ]
                }
            ]
        case "app.location.state":
            return ["mocking": LocationToolkit.shared.simulatedLocation != nil]
        case "app.location.mock":
            guard let latitude = Double(arguments["latitude"] ?? ""), let longitude = Double(arguments["longitude"] ?? ""),
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                return ["message": "Enter a latitude from -90 to 90 and a longitude from -180 to 180.", "mocking": LocationToolkit.shared.simulatedLocation != nil]
            }
            LocationToolkit.shared.simulatedLocation = CLLocation(latitude: latitude, longitude: longitude)
            return ["message": "The app now gets \(latitude), \(longitude).", "mocking": true]
        case "app.location.stop":
            LocationToolkit.shared.simulatedLocation = nil
            return ["message": "The app gets the real location again.", "mocking": false]
        case "app.agentlog.state":
            return agentLogState()
        case "app.agentlog.snapshot":
            do {
                let url = try AgentDebugLog.shared.writeSnapshot()
                return ["path": url.path, "message": "Snapshot written."]
            } catch {
                return ["error": "The snapshot could not be written: \(error.localizedDescription)"]
            }
        default:
            return nil
        }
    }

    func perform(featureID: String, actionID: String, value: String) -> String? {
        switch (featureID, actionID) {
        case ("crashes", "clear"):
            CrashManager.shared.deleteAll(ofType: .nsexception)
            CrashManager.shared.deleteAll(ofType: .signal)
            return "Crash reports cleared."
        case ("crashes", "export"):
            let text = crashReports().joined(separator: "\n\n---\n\n")
            return share(text, named: "debugswift-crashes.txt") ? "Sharing crash reports." : "No crash reports to export."
        case ("event_bus", "clear"):
            EventBusSubscriber.shared.bus.clear()
            return "Events cleared."
        case ("deep_links", "clear_history"):
            deepLinks.clearHistory()
            return "History cleared."
        case ("oslog_console", "clear"):
            OSLogMonitor.shared.clear()
            return "Log cleared."
        case ("agent_debug_log", "toggle"):
            let log = AgentDebugLog.shared
            if log.enabled { log.disable() } else { log.enable() }
            return log.enabled ? "Agent debug log on." : "Agent debug log off."
        case ("agent_debug_log", "clear"):
            AgentDebugLog.shared.clear()
            return "Agent debug log cleared."
        case ("agent_debug_log", "export"):
            let url = AgentDebugLog.shared.currentLogPath()
            guard FileManager.default.fileExists(atPath: url.path) else { return "The agent debug log is empty." }
            FileSharingManager.share(url)
            return "Sharing the agent debug log."
        default:
            return nil
        }
    }

    func snapshot(featureID: String) -> String? {
        switch featureID {
        case "event_bus":
            let time = SharedPanelData.timeFormatter
            let lines = EventBusSubscriber.shared.bus.events.reversed().map {
                "\(time.string(from: $0.timestamp)) [\($0.domain.rawValue)] \($0.summary)"
            }
            return lines.isEmpty ? "No diagnostic events published yet." : lines.joined(separator: "\n")
        case "location":
            if let location = LocationToolkit.shared.simulatedLocation {
                return "Simulated: \(location.coordinate.latitude), \(location.coordinate.longitude)"
            }
            return "The app gets the device's real location."
        case "deep_links":
            guard let last = deepLinks.history.first else { return "No link opened from DebugSwift yet." }
            return "\(last.urlString)\n\(last.statusRawValue) · \(last.formattedTimestamp)"
        default:
            return nil
        }
    }

    // MARK: - Crashes

    private func crashModels() -> [CrashModel] {
        (CrashManager.shared.recover(ofType: .nsexception) + CrashManager.shared.recover(ofType: .signal))
            .sorted { $0.details.date > $1.details.date }
    }

    private func crashReports() -> [String] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return crashModels().map { crash in
            var lines = [
                crash.details.name,
                formatter.string(from: crash.details.date),
                "App \(crash.details.appVersion ?? "?") (\(crash.details.appBuild ?? "?")) · iOS \(crash.details.iosVersion) · \(crash.details.deviceModel)",
                "Connection: \(crash.details.reachability)"
            ]
            for trace in crash.traces {
                lines.append("\n\(trace.title)\n\(trace.detail)")
            }
            if !crash.context.errorOutput.isEmpty {
                lines.append("\nError log\n\(crash.context.errorOutput)")
            }
            if !crash.context.consoleOutput.isEmpty {
                lines.append("\nConsole\n\(crash.context.consoleOutput)")
            }
            return lines.joined(separator: "\n")
        }
    }

    private func crashes() -> [String: Any] {
        let models = crashModels()
        return [
            "reports": crashReports(),
            // The screen at the moment of each crash, when it could be taken.
            "screenshots": models.map { $0.context.image?.base64EncodedString() ?? "" },
            "exits": [[String: Any]]()
        ]
    }

    // MARK: - System log

    private func log(filter: String, minimumLevel: String, includeApple: Bool) -> [String: Any] {
        let minimumRank = Self.rank(minimumLevel)
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let start = store.position(timeIntervalSinceLatestBoot: 0)
            let time = SharedPanelData.timeFormatter
            var entries: [[String: Any]] = []
            for case let entry as OSLogEntryLog in try store.getEntries(at: start) {
                if !includeApple, entry.subsystem.hasPrefix("com.apple") { continue }
                let level = Self.levelLetter(entry.level)
                if Self.rank(level) < minimumRank { continue }
                let tag = [entry.subsystem, entry.category].filter { !$0.isEmpty }.joined(separator: " · ")
                if !filter.isEmpty,
                   !entry.composedMessage.localizedCaseInsensitiveContains(filter),
                   !tag.localizedCaseInsensitiveContains(filter) {
                    continue
                }
                entries.append([
                    "time": time.string(from: entry.date),
                    "level": level,
                    "tag": tag,
                    "message": entry.composedMessage
                ])
            }
            return ["entries": Array(entries.suffix(Self.logLimit).reversed())]
        } catch {
            return ["error": "The system log could not be read: \(error.localizedDescription)"]
        }
    }

    /// The screen's levels (Logcat's V D I W E) and OSLog's notice and fault, in order.
    private static func rank(_ letter: String) -> Int {
        ["V": 0, "D": 1, "I": 2, "N": 3, "W": 3, "E": 4, "F": 5][letter] ?? 0
    }

    private static func levelLetter(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "D"
        case .info: "I"
        case .notice: "N"
        case .error: "E"
        case .fault: "F"
        default: "V"
        }
    }

    // MARK: - Deep links

    private func openDeepLink(_ uri: String) -> [String: Any] {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        let validation = deepLinks.validateURL(trimmed)
        guard validation.isValid else {
            return ["message": validation.error ?? "Enter a valid URL."]
        }
        deepLinks.openDeepLink(trimmed) { _, _ in }
        return ["message": "Opening \(trimmed)."]
    }

    // MARK: - Agent debug log

    private func agentLogState() -> [String: Any] {
        let log = AgentDebugLog.shared
        let url = log.currentLogPath()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let lines = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(100) ?? []
        let entries: [[String: Any]] = lines.reversed().compactMap { line in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return [
                "time": (json["timestamp"] as? Double) ?? 0,
                "kind": json["kind"] as? String ?? "",
                "location": json["location"] as? String ?? "",
                "message": json["message"] as? String ?? ""
            ]
        }
        return [
            "enabled": log.enabled,
            "session": ProcessInfo.processInfo.environment["AGENT_DEBUG_SESSION_ID"] ?? "",
            "path": url.path,
            "size": size,
            "entries": entries
        ]
    }

    // MARK: - Sharing

    private func share(_ text: String, named name: String) -> Bool {
        guard !text.isEmpty else { return false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return false }
        FileSharingManager.share(url)
        return true
    }
}
