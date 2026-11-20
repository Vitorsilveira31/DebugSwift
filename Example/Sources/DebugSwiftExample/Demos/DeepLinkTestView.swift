//
//  DeepLinkTestView.swift
//  Example
//
//  Created by DebugSwift on 13/02/26.
//

import Foundation
import SwiftUI

/// Shows how a `debugswift://` link is parsed. The app opens it when such a link arrives, and the
/// debug panel's Deep Links tool can send one.
struct DeepLinkTestView: View {
    let url: URL?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let url {
                    Section {
                        DetailRow(label: "URL", value: url.absoluteString)
                        DetailRow(label: "Scheme", value: url.scheme ?? "N/A")
                        DetailRow(label: "Host", value: url.host ?? "N/A")
                        DetailRow(label: "Path", value: url.path.isEmpty ? "/" : url.path)
                        if let query = url.query, !query.isEmpty {
                            DetailRow(label: "Query", value: query)
                        }
                    } header: {
                        Text("URL Details")
                    }

                    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    if !items.isEmpty {
                        Section {
                            ForEach(items, id: \.name) { item in
                                HStack {
                                    Text(item.name)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(item.value ?? "")
                                }
                            }
                        } header: {
                            Text("Parameters")
                        }
                    }
                } else {
                    Text("No URL information available")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Deep Link Opened")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
        }
    }
}
