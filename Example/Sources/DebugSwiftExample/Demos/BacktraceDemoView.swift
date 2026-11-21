//
//  BacktraceDemoView.swift
//  Example
//
//  Demonstrates DebugSwift.Performance.Backtrace.capture(), the same on iOS and Android.
//

import DebugSwiftUI
import Foundation
import SwiftUI

/// Captures the current call stack on demand (not a crash). The captures show in the debug panel →
/// Performance → Backtraces.
struct BacktraceDemoView: View {
    @State var captures: [CapturedBacktrace] = []
    @State var label = ""

    var body: some View {
        List {
            Section {
                Text("Captures the current call stack with DebugSwift.Performance.Backtrace.capture(). See them in the debug panel → Performance → Backtraces.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Label (optional), e.g. checkout-button-tap", text: $label)
            }

            Section {
                Button("Capture Backtrace") { captureNow() }
                Button("Capture from nested call") { captureFromNestedCall() }
                Button("Clear all captures") { clearAll() }
                    .foregroundColor(.red)
            }

            Section {
                if captures.isEmpty {
                    Text("No captures yet. Tap a button above.")
                        .foregroundColor(.secondary)
                }
                ForEach(captures, id: \.id) { capture in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(labelText(capture))
                            .font(.caption)
                            .fontWeight(.bold)
                        if let firstFrame = capture.frames.first {
                            Text("Frame 0: \(firstFrame.symbol)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        Text("\(capture.frames.count) frame\(capture.frames.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Captures in this session: \(captures.count)")
            }
        }
        .navigationTitle("Backtrace Demo")
        .onAppear { refresh() }
    }

    private func captureNow() {
        DebugSwift.Performance.Backtrace.capture(label: label.isEmpty ? nil : label)
        refresh()
    }

    private func captureFromNestedCall() {
        deeplyNestedCapture(depth: 3, label: label.isEmpty ? "nested-3" : label)
        refresh()
    }

    private func deeplyNestedCapture(depth: Int, label: String) {
        if depth > 0 {
            deeplyNestedCapture(depth: depth - 1, label: label)
        } else {
            DebugSwift.Performance.Backtrace.capture(label: label)
        }
    }

    private func clearAll() {
        DebugSwift.Performance.Backtrace.clear()
        refresh()
    }

    private func refresh() {
        captures = DebugSwift.Performance.Backtrace.captured
    }

    private func labelText(_ capture: CapturedBacktrace) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        let prefix = capture.label.map { "\($0) · " } ?? ""
        return "\(prefix)\(formatter.string(from: capture.timestamp))"
    }
}
