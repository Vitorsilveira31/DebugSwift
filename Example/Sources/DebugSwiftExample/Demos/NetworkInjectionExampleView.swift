//
//  NetworkInjectionExampleView.swift
//  Example
//
//  Created by DebugSwift on 2026.
//

import Foundation
import SwiftUI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Turns on delay, failure and response rewrite injection from code, then sends a request so the
/// result is visible here and in the debug panel's HTTP Inspector.
struct NetworkInjectionExampleView: View {
    @State var responseText = "Tap a button to test network injection"
    @State var isLoading = false
    @State var delayEnabled = false
    @State var failureEnabled = false
    @State var rewriteEnabled = false
    @State var rewriteURLPattern = "https://jsonplaceholder.typicode.com/todos/1"
    @State var rewriteResponseBody = """
    {
      "id": 1,
      "title": "rewritten from UI",
      "completed": true
    }
    """

    var body: some View {
        List {
            Section {
                Text(responseText)
                    .font(.caption)
                if isLoading {
                    ProgressView()
                }
            } header: {
                Text("Response")
            }

            Section {
                Toggle("Enable Delay (2s)", isOn: $delayEnabled)
                    .onChange(of: delayEnabled) { _, enabled in
                        if enabled {
                            ExampleNetworkRules.setDelay(2.0)
                        } else {
                            ExampleNetworkRules.clearDelay()
                        }
                    }
                Button("Test with Fixed 3s Delay") {
                    ExampleNetworkRules.setDelay(3.0)
                    send()
                }
                Button("Test with Random Delay (1-5s)") {
                    ExampleNetworkRules.setDelay(min: 1.0, max: 5.0)
                    send()
                }
            } header: {
                Text("Delay Injection")
            }

            Section {
                Toggle("Enable Failure (50%)", isOn: $failureEnabled)
                    .onChange(of: failureEnabled) { _, enabled in
                        if enabled {
                            ExampleNetworkRules.setFailure(.timeout, rate: 0.5)
                        } else {
                            ExampleNetworkRules.clearFailure()
                        }
                    }
                Button("Test Timeout Error") {
                    ExampleNetworkRules.setFailure(.timeout, rate: 1.0)
                    send()
                }
                Button("Test Connection Lost") {
                    ExampleNetworkRules.setFailure(.connectionLost, rate: 1.0)
                    send()
                }
                Button("Test HTTP 404 Error") {
                    ExampleNetworkRules.setHTTPError(statusCodes: [404], rate: 1.0)
                    send()
                }
                Button("Test HTTP 500 Error") {
                    ExampleNetworkRules.setHTTPError(statusCodes: [500], rate: 1.0)
                    send()
                }
                Button("Test Random HTTP Errors") {
                    ExampleNetworkRules.setHTTPError(statusCodes: [400, 401, 403, 404, 500, 502, 503], rate: 1.0)
                    send()
                }
            } header: {
                Text("Failure Injection")
            }

            Section {
                Toggle("Enable Rewrite", isOn: $rewriteEnabled)
                    .onChange(of: rewriteEnabled) { _, enabled in
                        if enabled {
                            applyRewriteRule()
                        } else {
                            ExampleNetworkRules.clearRewrite()
                        }
                    }
                Text("URL Wildcard Pattern")
                    .font(.subheadline)
                TextField("https://api.example.com/path/*", text: $rewriteURLPattern)
                    .onChange(of: rewriteURLPattern) { _, _ in
                        if rewriteEnabled { applyRewriteRule() }
                    }
                Text("Response Body")
                    .font(.subheadline)
                TextEditor(text: $rewriteResponseBody)
                    .frame(minHeight: 120)
                    .onChange(of: rewriteResponseBody) { _, _ in
                        if rewriteEnabled { applyRewriteRule() }
                    }
                Button("Test Request With Current Rule") { send() }
            } header: {
                Text("Response Body Rewrite")
            }

            Section {
                Button("Test Delay + Failure") {
                    ExampleNetworkRules.setDelay(2.0)
                    ExampleNetworkRules.setFailure(.timeout, rate: 1.0)
                    send()
                }
                Button("Make Normal Request") {
                    ExampleNetworkRules.reset()
                    delayEnabled = false
                    failureEnabled = false
                    rewriteEnabled = false
                    send()
                }
                .foregroundColor(.green)
            } header: {
                Text("Combined")
            }

            #if os(Android)
            Section {
                Text("On Android these rules apply to the Swift requests this app sends. Rules set in the debug panel → Network Injection apply to OkHttp traffic, and come back for Swift requests after Make Normal Request.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            #endif
        }
        .navigationTitle("Network Injection")
    }

    private func send() {
        Task { @MainActor in await makeRequest() }
    }

    @MainActor
    private func makeRequest() async {
        isLoading = true
        responseText = "Making request..."
        let startTime = Date()
        defer { isLoading = false }

        do {
            let url = URL(string: "https://jsonplaceholder.typicode.com/todos/1")!
            let (data, response) = try await URLSession.shared.data(from: url)
            let duration = Date().timeIntervalSince(startTime)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            responseText = """
            ✅ Success
            Duration: \(String(format: "%.2f", duration))s
            Status: \(status)

            Response:
            \(String(data: data, encoding: .utf8) ?? "Unable to decode")
            """
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            responseText = """
            ❌ Error
            Duration: \(String(format: "%.2f", duration))s

            Error: \(error.localizedDescription)
            """
        }
    }

    private func applyRewriteRule() {
        let pattern = rewriteURLPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }
        ExampleNetworkRules.setRewrite(urlPattern: pattern, body: rewriteResponseBody)
    }
}
