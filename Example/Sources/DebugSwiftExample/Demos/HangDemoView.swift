//
//  HangDemoView.swift
//  Example
//
//  Created by Matheus Gois (Hang Demo) on 17/07/26.
//

import Foundation
import SwiftUI

/// Blocks the main thread for a configurable duration to trigger the Hang (iOS) or ANR (Android)
/// detector. On iOS, Hang Detection must be enabled for more than 10s (the grace period) in the
/// debug panel → Performance so the watchdog is active.
struct HangDemoView: View {
    @State var duration: Double = 1.0
    @State var isBlocking = false
    @State var lastResult: String?

    var body: some View {
        List {
            Section {
                Text("Blocks the main thread for the chosen duration so the hang detector fires. Enable Hangs and ANRs in the debug panel → Performance, wait about 10s, then tap Block.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Text("Block duration: \(String(format: "%.2f", duration))s")
                Slider(value: $duration, in: 0.25...5.0, step: 0.25)
                Button("Block main thread") { blockMainThread() }
                    .foregroundColor(.red)
                    .disabled(isBlocking)
                if isBlocking {
                    ProgressView("Blocking… the UI will freeze.")
                }
                if let lastResult {
                    Text(lastResult)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                Text("Then open the debug panel → Performance → Hangs and ANRs to see the recorded event with its stack trace pointing at the blocking call.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Hang Demo")
    }

    private func blockMainThread() {
        isBlocking = true
        lastResult = nil
        let target = duration
        Task { @MainActor in
            // Give the button a frame to show the progress row before the main thread freezes.
            try? await Task.sleep(nanoseconds: 100_000_000)
            let start = Date()
            // Busy-wait on the main thread: exactly what the hang detector is built to catch.
            while Date().timeIntervalSince(start) < target {}
            isBlocking = false
            lastResult = "Blocked the main thread for \(String(format: "%.2f", target))s. Check the hang list."
        }
    }
}
