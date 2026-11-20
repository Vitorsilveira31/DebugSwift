//
//  GraphQLDemoView.swift
//  Example
//
//  Created by Matheus Gois (GraphQL Demo) on 17/07/26.
//

import Foundation
import SwiftUI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends real GraphQL POSTs to a public endpoint so the GraphQL Inspector has operations to show.
struct GraphQLDemoView: View {
    @State var responseText = ""
    @State var isLoading = false
    @State var statusCode: Int?
    @State var errorMessage: String?

    private let endpoint = URL(string: "https://countries.trevorblades.com/")!

    var body: some View {
        List {
            Section {
                Text("Sends GraphQL POST requests to countries.trevorblades.com. Open the debug panel → Network → GraphQL Inspector to see each operation's name, type and variables.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Button("Run query (GetCountries)") {
                    let query = """
                    query GetCountries($code: ID!) {
                      country(code: $code) {
                        name
                        native
                        capital
                        emoji
                      }
                    }
                    """
                    send(query: query, variables: ["code": "BR"])
                }
                // Looks like a mutation by its keyword: the inspector classifies it as one.
                Button("Run mutation-shaped query") {
                    send(query: "mutation SetFlag {\n  __typename\n}", variables: nil)
                }
                // No operation name: the inspector shows none.
                Button("Run anonymous query") {
                    send(query: "{ __typename }", variables: nil)
                }
            } header: {
                Text("Operations")
            }
            .disabled(isLoading)

            if isLoading || statusCode != nil || errorMessage != nil || !responseText.isEmpty {
                Section {
                    if isLoading {
                        ProgressView("Sending…")
                    }
                    if let statusCode {
                        Text("Status: \(statusCode)")
                            .foregroundColor(statusCode == 200 ? .green : .red)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                    if !responseText.isEmpty {
                        Text(responseText)
                            .font(.caption)
                    }
                } header: {
                    Text("Response")
                }
            }
        }
        .navigationTitle("GraphQL Demo")
    }

    private func send(query: String, variables: [String: String]?) {
        isLoading = true
        errorMessage = nil
        responseText = ""
        statusCode = nil

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var body: [String: Any] = ["query": query]
        if let variables { body["variables"] = variables }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        Task { @MainActor in
            defer { isLoading = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                statusCode = (response as? HTTPURLResponse)?.statusCode
                responseText = Self.prettyJSON(data)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    static func prettyJSON(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .utf8) ?? "Unable to decode response"
    }
}
