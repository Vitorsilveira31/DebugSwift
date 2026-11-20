//
//  OSLogTestView.swift
//  Example
//
//  Created by Matheus Gois on 12/05/26.
//

import DebugSwiftUI
import Foundation
import SkipFuse
import SwiftUI
#if canImport(OSLog)
import OSLog
#endif

/// Logs messages at each level. On iOS DebugSwift reads them from OSLog; on Android `Logger` goes to
/// Logcat and each message is also sent to the panel's Console.
struct OSLogTestView: View {
    @State var logCount = 0

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example", category: "TestCategory")

    var body: some View {
        List {
            Section {
                Text("Generate log messages, then open the debug panel → App → Console (OSLog Console on iOS, Logcat on Android).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Button("Log Info Message") {
                    logger.info("[OSLogTest] This is an info message #\(logCount)")
                    didLog("This is an info message #\(logCount)")
                }
                Button("Log Debug Message") {
                    logger.debug("[OSLogTest] This is a debug message #\(logCount)")
                    didLog("This is a debug message #\(logCount)")
                }
                Button("Log Warning Message") {
                    logger.warning("[OSLogTest] This is a warning message #\(logCount)")
                    didLog("This is a warning message #\(logCount)")
                }
                Button("Log Error Message") {
                    logger.error("[OSLogTest] This is an error message #\(logCount)")
                    didLog("This is an error message #\(logCount)")
                }
                Button("Log 10 Messages") {
                    for index in 1...10 {
                        logger.info("[OSLogTest] Bulk message \(index)/10 - Count #\(logCount)")
                        didLog("Bulk message \(index)/10 - Count #\(logCount)")
                    }
                }
                Button("Log Different Subsystems") { logDifferentSubsystems() }
            } header: {
                Text("Messages")
            }

            Section {
                Text("Total logs generated: \(logCount)")
                Button("Reset Counter") { logCount = 0 }
            }
        }
        .navigationTitle("OSLog Test")
    }

    /// Counts a message and, on Android, also shows it in the panel's Console.
    private func didLog(_ message: String) {
        #if os(Android)
        DebugSwiftRuntime.log("[OSLogTest] \(message)")
        #endif
        logCount += 1
    }

    private func logDifferentSubsystems() {
        Logger(subsystem: "com.example.network", category: "API").info("[Network] API request started")
        Logger(subsystem: "com.example.database", category: "Database").info("[Database] Fetching records")
        Logger(subsystem: "com.example.ui", category: "ViewLifecycle").info("[UI] View appeared")
        logger.info("[OSLogTest] Logged to 3 different subsystems")
        didLog("Logged to 3 different subsystems")
        logCount += 3
    }
}
