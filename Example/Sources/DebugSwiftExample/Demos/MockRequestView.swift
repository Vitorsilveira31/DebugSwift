//
//  MockRequestView.swift
//  Example
//
//  Created by Matheus Gois on 12/06/24.
//

import DebugSwiftUI
import Foundation
import SwiftUI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct APIEndpoint: Identifiable {
    let title: String
    let method: String
    let endpoint: String
    let body: [String: Any]?
    let description: String
    /// Sends through a session limited to TLS 1.2 and newer (iOS), to show that DebugSwift keeps
    /// the session's configuration while it captures the request.
    let usesTLSSession: Bool

    var id: String { method + " " + endpoint + " " + title }

    init(title: String, method: String, endpoint: String, body: [String: Any]? = nil, description: String, usesTLSSession: Bool = false) {
        self.title = title
        self.method = method
        self.endpoint = endpoint
        self.body = body
        self.description = description
        self.usesTLSSession = usesTLSSession
    }

    var methodColor: Color {
        switch method {
        case "GET": return .blue
        case "POST": return .green
        case "PUT": return .orange
        case "PATCH": return .purple
        case "DELETE": return .red
        default: return .gray
        }
    }
}

/// Every HTTP method against a fake REST API. The debug panel's HTTP Inspector lists each request.
struct MockRequestView: View {
    private let endpoints: [APIEndpoint] = [
        APIEndpoint(title: "Get Single Post", method: "GET",
                    endpoint: "https://jsonplaceholder.typicode.com/posts/1",
                    description: "Fetch post with ID 1"),
        APIEndpoint(title: "Get Post Comments", method: "GET",
                    endpoint: "https://jsonplaceholder.typicode.com/posts/1/comments",
                    description: "Fetch comments for post ID 1"),
        APIEndpoint(title: "Get Comments by Post ID", method: "GET",
                    endpoint: "https://jsonplaceholder.typicode.com/comments?postId=1",
                    description: "Fetch comments using a query parameter"),
        APIEndpoint(title: "Get All Users", method: "GET",
                    endpoint: "https://jsonplaceholder.typicode.com/users",
                    description: "Fetch all users (10 items)"),
        APIEndpoint(title: "Get All Albums", method: "GET",
                    endpoint: "https://jsonplaceholder.typicode.com/albums",
                    description: "Fetch all albums (100 items)"),
        APIEndpoint(title: "Get Photos", method: "GET",
                    endpoint: "https://jsonplaceholder.typicode.com/photos?_limit=5",
                    description: "Fetch the first 5 photos"),
        APIEndpoint(title: "Get Todos", method: "GET",
                    endpoint: "https://jsonplaceholder.typicode.com/todos?_limit=10",
                    description: "Fetch the first 10 todos"),
        APIEndpoint(title: "Create New Post", method: "POST",
                    endpoint: "https://jsonplaceholder.typicode.com/posts",
                    body: ["title": "My New Post", "body": "This is the content of my new post", "userId": 1],
                    description: "Create a new post with title and body"),
        APIEndpoint(title: "Update Post (PUT)", method: "PUT",
                    endpoint: "https://jsonplaceholder.typicode.com/posts/1",
                    body: ["id": 1, "title": "Updated Post Title", "body": "Updated post content", "userId": 1],
                    description: "Replace the entire post"),
        APIEndpoint(title: "Update Post (PATCH)", method: "PATCH",
                    endpoint: "https://jsonplaceholder.typicode.com/posts/1",
                    body: ["title": "Partially Updated Title"],
                    description: "Update only some fields of the post"),
        APIEndpoint(title: "Delete Post", method: "DELETE",
                    endpoint: "https://jsonplaceholder.typicode.com/posts/1",
                    description: "Delete post with ID 1"),
        APIEndpoint(title: "User Not Found (404)", method: "GET",
                    endpoint: "https://reqres.in/api/users/23",
                    description: "Request that returns a 404 error"),
        APIEndpoint(title: "Invalid Endpoint (404)", method: "GET",
                    endpoint: "https://jsonplaceholder.typicode.com/invalid-endpoint",
                    description: "Endpoint that doesn't exist"),
        APIEndpoint(title: "TLS v1.2+ Secure Request", method: "GET",
                    endpoint: "https://jsonplaceholder.typicode.com/posts/1",
                    description: "Secure request with TLS v1.2+ (intercepted by DebugSwift)",
                    usesTLSSession: true)
    ]

    var body: some View {
        List {
            Section {
                Text("Pick an endpoint and send it. Open the debug panel → Network → HTTP Inspector to see the request and response.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section {
                ForEach(endpoints) { endpoint in
                    NavigationLink {
                        RequestResponseView(endpoint: endpoint)
                    } label: {
                        EndpointRow(endpoint: endpoint)
                    }
                }
            } header: {
                Text("JSONPlaceholder API")
            }
        }
        .navigationTitle("REST API Demo")
    }
}

struct EndpointRow: View {
    let endpoint: APIEndpoint

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                MethodBadge(endpoint: endpoint)
                if endpoint.usesTLSSession {
                    Text("TLS v1.2+")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }
            Text(endpoint.title)
                .font(.body)
            Text(endpoint.description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct MethodBadge: View {
    let endpoint: APIEndpoint

    var body: some View {
        Text(endpoint.method)
            .font(.caption)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(endpoint.methodColor)
            .cornerRadius(4)
    }
}

struct RequestResponseView: View {
    let endpoint: APIEndpoint

    @State var responseText = ""
    @State var isLoading = false
    @State var statusCode: Int?

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Method")
                    Spacer()
                    MethodBadge(endpoint: endpoint)
                }
                DetailRow(label: "Endpoint", value: endpoint.endpoint)
                if let body = endpoint.body {
                    DetailRow(label: "Request Body", value: Self.formatJSON(body))
                }
                if endpoint.usesTLSSession {
                    Text("TLS minimum v1.2; DebugSwift keeps the session's configuration while it captures the request.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Request")
            }

            Section {
                Button(isLoading ? "Loading..." : "Make Request") {
                    Task { await makeRequest() }
                }
                .disabled(isLoading)
                if isLoading {
                    ProgressView()
                }
            }

            if !responseText.isEmpty {
                Section {
                    if let statusCode {
                        Text("Status: \(statusCode)")
                            .foregroundColor(statusCode < 400 ? .green : .red)
                    }
                    Text(responseText)
                        .font(.caption)
                } header: {
                    Text("Response")
                }
            }
        }
        .navigationTitle(endpoint.title)
    }

    @MainActor
    private func makeRequest() async {
        isLoading = true
        statusCode = nil
        defer { isLoading = false }

        guard let url = URL(string: endpoint.endpoint) else {
            responseText = "Invalid URL"
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            if let body = endpoint.body, ["POST", "PUT", "PATCH"].contains(endpoint.method) {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let session = endpoint.usesTLSSession ? Self.makeTLSSession() : URLSession.shared
            let (data, response) = try await session.data(for: request)
            statusCode = (response as? HTTPURLResponse)?.statusCode
            let prefix = endpoint.usesTLSSession ? "🔒 Used TLS v1.2+ secured URLSession\n\n" : ""
            responseText = prefix + GraphQLDemoView.prettyJSON(data)
        } catch {
            responseText = "Error: \(error.localizedDescription)"
        }
    }

    /// A TLS-restricted session that DebugSwift still intercepts.
    private static func makeTLSSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        #if os(iOS)
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.tlsMaximumSupportedProtocolVersion = .TLSv13
        #endif
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        // iOS captures every session; Android captures this one once it is configured.
        DebugSwiftRuntime.configure(configuration)
        return URLSession(configuration: configuration)
    }

    private static func formatJSON(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(object)"
        }
        return text
    }
}
