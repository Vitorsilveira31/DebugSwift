import SwiftUI

/// Shows the last link, opens any URI as a link to test link handling, and on iOS lists the links
/// opened from here.
struct DebugDeepLinksView: View {
    @State var uri = ""
    @State var lastLink = ""
    @State var status = ""
    @State var history: [DebugDeepLinkEntry]? = nil

    /// Links to try without typing.
    let quickLinks = ["debugswift://profile/123", "https://github.com/DebugSwift/DebugSwift"]

    var body: some View {
        Form {
            Section("Last link received") {
                Text(verbatim: lastLink)
                    .font(.system(.footnote, design: .monospaced))
            }
            Section("Open a link") {
                TextField("https://example.com/path", text: $uri)
                Button("Open") { open() }
            }
            Section("Quick tests") {
                ForEach(quickLinks, id: \.self) { link in
                    Button(link) {
                        uri = link
                        open()
                    }
                }
            }
            if let history {
                Section("Recent history") {
                    if history.isEmpty {
                        Text(verbatim: "No links opened from here yet.")
                            .foregroundColor(Color.secondary)
                    }
                    ForEach(0..<history.count, id: \.self) { index in
                        Button {
                            uri = history[index].url
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: history[index].url)
                                    .font(.system(.footnote, design: .monospaced))
                                Text(verbatim: "\(history[index].status) · \(history[index].time)" + (history[index].error.isEmpty ? "" : " · \(history[index].error)"))
                                    .font(.caption)
                                    .foregroundColor(Color.secondary)
                            }
                        }
                    }
                    if !history.isEmpty {
                        Button("Clear history", role: .destructive) {
                            _ = DebugSwiftRuntime.perform(featureID: "deep_links", actionID: "clear_history")
                            load()
                        }
                    }
                }
            }
            if !status.isEmpty {
                Section("Status") {
                    Text(verbatim: status).font(.caption)
                }
            }
        }
        .navigationTitle("Deep Links")
        .onAppear { load() }
    }

    func open() {
        switch DebugResourceClient.fetch("app.deeplink.open", ["uri": uri], as: DebugActionReply.self) {
        case let .success(reply):
            status = reply.message ?? "Opened."
        case let .failure(error):
            status = error.message
        }
        load()
    }

    func load() {
        lastLink = DebugSwiftRuntime.snapshot(featureID: "deep_links")
        // Android keeps no history of its own: the section shows only where the platform has one.
        if case let .success(listing) = DebugResourceClient.fetch("app.deeplink.history", as: DebugDeepLinkHistory.self) {
            history = listing.entries
        }
    }
}

struct DebugDeepLinkEntry: Decodable {
    let url: String
    let time: String
    let status: String
    let error: String
}

struct DebugDeepLinkHistory: Decodable {
    let entries: [DebugDeepLinkEntry]
}
