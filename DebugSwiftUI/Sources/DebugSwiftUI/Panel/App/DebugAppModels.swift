import Foundation

struct DebugCrashExit: Decodable, Identifiable {
    let time: Double
    let reason: String
    let status: Int
    let description: String
    let trace: String
    let hasBinaryTrace: Bool
    var id: String { "\(time)-\(reason)" }

    var date: Date { Date(timeIntervalSince1970: time / 1000) }
}

struct DebugCrashListing: Decodable {
    let reports: [String]
    let exits: [DebugCrashExit]
    /// iOS only: each report's screen at the moment of the crash, as base64 PNG ("" when none).
    let screenshots: [String]?
}

struct DebugLogEntry: Decodable {
    let time: String
    let level: String
    let tag: String
    let message: String
}

struct DebugLogListing: Decodable {
    let entries: [DebugLogEntry]
    /// iOS only: newer entries are still being read; ask again shortly.
    let pending: Bool?
}

/// The reply to an action: a message to show, and for mock location whether it is running.
struct DebugActionReply: Decodable {
    let message: String?
    let mocking: Bool?
}

func debugDateText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter.string(from: date)
}
