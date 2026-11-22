import DebugSwiftCore
import Foundation

import SwiftUI

#if os(iOS)
@_spi(DebugSwiftUI) import DebugSwift
import UIKit
#endif

struct DebugSwiftNetworkThresholdView: View {
    @State var trackingEnabled = false
    @State var thresholdLimit = 1000
    @State var windowSeconds = 60
    @State var blockingEnabled = false
    @State var currentRequestCount = 0
    @State var totalBreaches = 0
    @State var endpointDetails = "No endpoint limits configured."
    @State var breachDetails = "No threshold breaches."
    @State var statusMessage = ""
    @State var confirmsHistoryClear = false
    @State var refreshTimer: Timer?

    var body: some View {
        Form {
            Section("Current Status") {
                Toggle("Enable Tracking", isOn: Binding(
                    get: { trackingEnabled },
                    set: { enabled in
                        trackingEnabled = enabled
                        apply("set_threshold_tracking", value: enabled ? "true" : "false")
                    }
                ))

                HStack {
                    Text("Current Requests")
                    Spacer()
                    if trackingEnabled {
                        let percentage = thresholdLimit > 0 ? Int((Double(currentRequestCount) / Double(thresholdLimit)) * 100.0) : 0
                        Text("\(currentRequestCount) / \(thresholdLimit) (\(percentage)%)")
                            .foregroundColor(percentage >= 90 ? Color.red : percentage >= 70 ? Color.orange : Color.green)
                    } else {
                        Text("Disabled per \(windowSeconds)s")
                            .foregroundColor(Color.secondary)
                    }
                }

                HStack {
                    Text("Total Breaches")
                    Spacer()
                    Text("\(totalBreaches)")
                        .foregroundColor(Color.secondary)
                }
            }

            Section("Configuration") {
                Stepper(label: {
                    Text("Threshold Limit: \(thresholdLimit) requests")
                }, onIncrement: {
                    updateThresholdLimit(thresholdLimit + 10)
                }, onDecrement: {
                    updateThresholdLimit(thresholdLimit - 10)
                })

                Stepper(label: {
                    Text("Time Window: \(windowSeconds) seconds")
                }, onIncrement: {
                    updateWindow(windowSeconds + 10)
                }, onDecrement: {
                    updateWindow(windowSeconds - 10)
                })

                Toggle("Block Exceeding Requests", isOn: Binding(
                    get: { blockingEnabled },
                    set: { enabled in
                        blockingEnabled = enabled
                        apply("set_threshold_blocking", value: enabled ? "true" : "false")
                    }
                ))
            }

            Section("Endpoint Limits") {
                Text(endpointDetails)
                    .font(Font.system(Font.TextStyle.footnote, design: Font.Design.monospaced))
                    .frame(maxWidth: CGFloat.infinity, alignment: Alignment.leading)
            }

            Section("Recent Breaches") {
                Text(breachDetails)
                    .font(Font.system(Font.TextStyle.footnote, design: Font.Design.monospaced))
                    .frame(maxWidth: CGFloat.infinity, alignment: Alignment.leading)
            }

            Section("Actions") {
                Button("Refresh") { refresh() }
                Button("Clear History", role: ButtonRole.destructive) { confirmsHistoryClear = true }
                Button("Export Logs") {
                    statusMessage = DebugSwiftRuntime.perform(featureID: "network_thresholds", actionID: "export")
                }
            }

            if !statusMessage.isEmpty {
                Section("Status") {
                    Text(statusMessage)
                        .font(Font.caption)
                }
            }
        }
        .navigationTitle("Request Threshold")
        .onAppear {
            refresh()
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in refresh() }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .alert("Clear request history?", isPresented: $confirmsHistoryClear) {
            Button("Cancel", role: ButtonRole.cancel) {}
            Button("Clear History", role: ButtonRole.destructive) {
                apply("clear_threshold_history")
            }
        } message: {
            Text("This removes the request history and recorded threshold breaches.")
        }
    }

    private func apply(_ actionID: String, value: String = "") {
        statusMessage = DebugSwiftRuntime.perform(
            featureID: "network_thresholds",
            actionID: actionID,
            value: value
        )
        refresh()
    }

    private func updateThresholdLimit(_ value: Int) {
        let updatedValue = min(1000, max(1, value))
        guard updatedValue != thresholdLimit else { return }
        thresholdLimit = updatedValue
        apply("set_threshold", value: "\(updatedValue),\(windowSeconds)")
    }

    private func updateWindow(_ value: Int) {
        let updatedValue = min(300, max(10, value))
        guard updatedValue != windowSeconds else { return }
        windowSeconds = updatedValue
        apply("set_threshold", value: "\(thresholdLimit),\(updatedValue)")
    }

    private func refresh() {
        let rows = DebugSwiftRuntime.snapshot(featureID: "network_thresholds").components(separatedBy: "\n")
        let settings = rows.first?.components(separatedBy: "|") ?? []
        if settings.count >= 7, settings[0] == "threshold" {
            trackingEnabled = settings[1] == "true"
            thresholdLimit = Int(settings[2]) ?? 1000
            windowSeconds = Int(settings[3]) ?? 60
            blockingEnabled = settings[4] == "true"
            currentRequestCount = Int(settings[5]) ?? 0
            totalBreaches = Int(settings[6]) ?? 0
        }

        let details = rows.dropFirst().joined(separator: "\n")
        let sections = details.components(separatedBy: "\n\nRECENT BREACHES\n")
        let endpointText = sections.first?
            .replacingOccurrences(of: "ENDPOINT LIMITS\n", with: "")
        if let endpointText, !endpointText.isEmpty {
            endpointDetails = endpointText
        } else {
            endpointDetails = "No endpoint limits configured."
        }
        breachDetails = sections.count > 1 ? sections[1] : "No threshold breaches."
    }
}
