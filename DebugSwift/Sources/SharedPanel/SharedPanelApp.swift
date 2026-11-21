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
        case "app.logcat.clear":
            logClearedAt = Date()
            return ["message": "Log cleared."]
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

    /// Whether the bundled symbol map is loaded, trying once.
    private lazy var symbolsLoaded: Bool = {
        if !SymbolicatorAdapter.shared.isSymbolTableLoaded,
           let map = Bundle.main.url(forResource: "symbol_map", withExtension: "json") {
            _ = SymbolicatorAdapter.shared.load(from: map.path)
        }
        return SymbolicatorAdapter.shared.isSymbolTableLoaded
    }()

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
            // With the app's symbol_map.json, traces show function names and source locations.
            let titles = symbolsLoaded ? SymbolicatorAdapter.shared.symbolicate(traces: crash.traces) : crash.traces.map(\.title)
            for (title, trace) in zip(titles, crash.traces) {
                lines.append("\n\(title)\n\(trace.detail)")
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

    /// One system log entry, kept between reads.
    private struct LogItem: Sendable {
        let date: Date
        let level: String
        let tag: String
        let message: String
    }

    /// The newest entries, oldest first, read off the main actor: the first read covers the last
    /// five minutes, each later one only what was logged after the last entry kept, and the cache
    /// holds at most this many.
    nonisolated private static let logCapacity = 2000
    private var logItems: [LogItem] = []
    private var logIncludesApple = false
    private var logReading = false
    private var logReadAt = Date.distantPast
    /// The system log can't be erased; Clear hides what was logged before it.
    private var logClearedAt: Date?

    private func log(filter: String, minimumLevel: String, includeApple: Bool) -> [String: Any] {
        if includeApple != logIncludesApple {
            logIncludesApple = includeApple
            logItems = []
        }
        readNewLogEntries()
        let minimumRank = Self.rank(minimumLevel)
        let time = SharedPanelData.timeFormatter
        let entries: [[String: Any]] = logItems.filter { item in
            (logClearedAt.map { item.date >= $0 } ?? true)
                && Self.rank(item.level) >= minimumRank
                && (filter.isEmpty || item.message.localizedCaseInsensitiveContains(filter) || item.tag.localizedCaseInsensitiveContains(filter))
        }.suffix(Self.logLimit).map {
            ["time": time.string(from: $0.date), "level": $0.level, "tag": $0.tag, "message": $0.message]
        }
        // While a read is running the screen asks again shortly, so new entries appear.
        return ["entries": entries, "pending": logReading]
    }

    private func readNewLogEntries() {
        guard !logReading, Date().timeIntervalSince(logReadAt) >= 0.5 else { return }
        logReading = true
        let since = logItems.last?.date
        let includeApple = logIncludesApple
        Task.detached(priority: .utility) {
            let items = Self.readLog(since: since, includeApple: includeApple, limit: Self.logCapacity)
            await MainActor.run {
                let app = SharedPanelApp.shared
                if includeApple == app.logIncludesApple {
                    app.logItems.append(contentsOf: items)
                    if app.logItems.count > Self.logCapacity {
                        app.logItems.removeFirst(app.logItems.count - Self.logCapacity)
                    }
                }
                app.logReading = false
                app.logReadAt = Date()
            }
        }
    }

    /// Entries logged after `since`, oldest first; the first read covers the last five minutes.
    /// Only the newest `limit` are kept.
    nonisolated private static func readLog(since: Date?, includeApple: Bool, limit: Int) -> [LogItem] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let start = since ?? Date().addingTimeInterval(-300)
        guard let entries = try? store.getEntries(at: store.position(date: start)) else { return [] }
        var items: [LogItem] = []
        for case let entry as OSLogEntryLog in entries {
            // The position for a date is approximate: check each entry's own date.
            if let since, entry.date <= since { continue }
            if !includeApple, entry.subsystem.hasPrefix("com.apple") { continue }
            let tag = [entry.subsystem, entry.category].filter { !$0.isEmpty }.joined(separator: " · ")
            items.append(LogItem(date: entry.date, level: levelLetter(entry.level), tag: tag, message: entry.composedMessage))
            if items.count > limit * 2 { items.removeFirst(items.count - limit) }
        }
        return Array(items.suffix(limit))
    }

    /// The screen's levels (Logcat's V D I W E) and OSLog's notice and fault, in order.
    private static func rank(_ letter: String) -> Int {
        ["V": 0, "D": 1, "I": 2, "N": 3, "W": 3, "E": 4, "F": 5][letter] ?? 0
    }

    nonisolated private static func levelLetter(_ level: OSLogEntryLog.Level) -> String {
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
        // A link no app handles fails at once; opening one that can be opened finishes later and
        // shows in the history.
        var immediate: (opened: Bool, error: String?)?
        deepLinks.openDeepLink(trimmed) { opened, error in immediate = (opened, error) }
        if let immediate {
            return ["message": immediate.opened ? "Opened \(trimmed)." : (immediate.error ?? "Could not open \(trimmed).")]
        }
        return ["message": "Opening \(trimmed)."]
    }

    // MARK: - Agent debug log

    private func agentLogState() -> [String: Any] {
        let log = AgentDebugLog.shared
        let url = log.currentLogPath()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let lines = Self.tail(of: url, size: size).suffix(100)
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

    /// The last lines of a file, read from its final 64 KB: the log grows without a limit.
    private static func tail(of url: URL, size: Int) -> [Substring] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let window = 64 * 1024
        let offset = max(0, size - window)
        try? handle.seek(toOffset: UInt64(offset))
        guard var data = try? handle.readToEnd() else { return [] }
        // Starting mid-file, the first line is cut, maybe inside a character: drop its bytes up to
        // the first newline before decoding.
        if offset > 0 {
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return [] }
            data = data[data.index(after: newline)...]
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
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
