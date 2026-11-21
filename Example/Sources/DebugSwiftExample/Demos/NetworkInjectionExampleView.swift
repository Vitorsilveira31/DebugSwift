//
//  NetworkInjectionExampleView.swift
//  Example
//
//  Created by DebugSwift on 2026.
//

import DebugSwiftUI
import Foundation
import SwiftUI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Turns on delay, failure and response rewrite injection with `DebugSwift.Network`, the same on iOS
/// and Android, then sends a request so the result is visible here and in the HTTP Inspector.
struct NetworkInjectionExampleView: View {
    @State var responseText = "Tap a button to test network injection"
    @State var isLoading = false
    /// The request whose result the screen shows; an older one that finishes later is ignored.
    @State var currentRequest = 0
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
                // The switches change the rules only when tapped, so reflecting a preset never replaces it.
                Toggle("Enable Delay (2s)", isOn: Binding(get: { delayEnabled }, set: { enabled in
                    delayEnabled = enabled
                    if enabled {
                        DebugSwift.Network.shared.enableRequestDelay(2.0)
                    } else {
                        DebugSwift.Network.shared.disableRequestDelay()
                    }
                }))
                Button("Test with Fixed 3s Delay") {
                    DebugSwift.Network.shared.enableRequestDelay(3.0)
                    send()
                }
                Button("Test with Random Delay (1-5s)") {
                    DebugSwift.Network.shared.enableRequestDelay(min: 1.0, max: 5.0)
                    send()
                }
            } header: {
                Text("Delay Injection")
            }

            Section {
                Toggle("Enable Failure (50%)", isOn: Binding(get: { failureEnabled }, set: { enabled in
                    failureEnabled = enabled
                    if enabled {
                        DebugSwift.Network.shared.enableFailureInjection(failureRate: 0.5, failureType: .timeout)
                    } else {
                        DebugSwift.Network.shared.disableFailureInjection()
                    }
                }))
                Button("Test Timeout Error") {
                    DebugSwift.Network.shared.enableFailureInjection(failureRate: 1.0, failureType: .timeout)
                    send()
                }
                Button("Test Connection Lost") {
                    DebugSwift.Network.shared.enableFailureInjection(failureRate: 1.0, failureType: .connectionLost)
                    send()
                }
                Button("Test HTTP 404 Error") {
                    DebugSwift.Network.shared.enableHTTPErrorInjection(failureRate: 1.0, statusCodes: [404])
                    send()
                }
                Button("Test HTTP 500 Error") {
                    DebugSwift.Network.shared.enableHTTPErrorInjection(failureRate: 1.0, statusCodes: [500])
                    send()
                }
                Button("Test Random HTTP Errors") {
                    DebugSwift.Network.shared.enableHTTPErrorInjection(failureRate: 1.0, statusCodes: [400, 401, 403, 404, 500, 502, 503])
                    send()
                }
            } header: {
                Text("Failure Injection")
            }

            Section {
                Toggle("Enable Rewrite", isOn: Binding(get: { rewriteEnabled }, set: { enabled in
                    rewriteEnabled = enabled
                    if enabled {
                        applyRewriteRule()
                    } else {
                        DebugSwift.Network.shared.disableResponseBodyRewrite()
                    }
                }))
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
                    DebugSwift.Network.shared.enableRequestDelay(2.0)
                    DebugSwift.Network.shared.enableFailureInjection(failureRate: 1.0, failureType: .timeout)
                    send()
                }
                Button("Make Normal Request") {
                    DebugSwift.Network.shared.disableRequestDelay()
                    DebugSwift.Network.shared.disableFailureInjection()
                    DebugSwift.Network.shared.disableResponseBodyRewrite()
                    send()
                }
                .foregroundColor(.green)
            } header: {
                Text("Combined")
            }

            Section {
                Text("These rules are the panel's Network Injection rules: they show up there, and editing them there changes what these buttons set.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Network Injection")
        // The rules can also change in the debug panel, so the switches read them when the screen shows.
        .onAppear { syncSwitches() }
    }

    /// Shows in the switches whether each kind of injection is on, as the shared rules say.
    private func syncSwitches() {
        guard let data = DebugSwift.Network.shared.networkInjectionSettingsJSON().data(using: .utf8),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        func isOn(_ key: String) -> Bool {
            (settings[key] as? [String: Any])?["isEnabled"] as? Bool ?? false
        }
        delayEnabled = isOn("delay")
        failureEnabled = isOn("failure")
        rewriteEnabled = isOn("rewrite")
    }

    private func send() {
        syncSwitches()
        currentRequest += 1
        let request = currentRequest
        Task { @MainActor in await makeRequest(request) }
    }

    @MainActor
    private func makeRequest(_ request: Int) async {
        isLoading = true
        responseText = "Making request..."
        let startTime = Date()
        defer { if request == currentRequest { isLoading = false } }

        do {
            let url = URL(string: "https://jsonplaceholder.typicode.com/todos/1")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard request == currentRequest else { return }
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
            guard request == currentRequest else { return }
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
        DebugSwift.Network.shared.enableResponseBodyRewrite(rules: [ResponseBodyRewriteRule(urlPattern: pattern, responseBody: rewriteResponseBody)])
    }
}
