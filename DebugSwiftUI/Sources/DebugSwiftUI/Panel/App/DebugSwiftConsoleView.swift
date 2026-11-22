import DebugSwiftCore
import Foundation

import SwiftUI

#if os(iOS)
@_spi(DebugSwiftUI) import DebugSwift
import UIKit
#endif

struct DebugSwiftConsoleEntry: Identifiable {
    let id: Int
    let message: String
}
struct DebugSwiftConsoleView: View {
    @State var entries: [DebugSwiftConsoleEntry] = []
    @State var searchText = ""
    @State var statusMessage = ""
    @State var confirmsClear = false

    private var filteredEntries: [DebugSwiftConsoleEntry] {
        guard !searchText.isEmpty else { return entries }
        let query = searchText.lowercased()
        return entries.filter { $0.message.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search console", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button("Refresh") { refresh() }
            }
            .padding()

            HStack {
                Button("Clear", role: ButtonRole.destructive) {
                    confirmsClear = true
                }
                .disabled(entries.isEmpty)

                Spacer()

                Button("Export Logs") {
                    perform("export")
                }
                .disabled(entries.isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            if filteredEntries.isEmpty {
                Spacer()
                Text(entries.isEmpty ? "No console messages captured." : "No messages match this search.")
                    .foregroundColor(Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            } else {
                List {
                    ForEach(filteredEntries) { entry in
                        HStack(alignment: VerticalAlignment.top, spacing: 12) {
                            Text(entry.message)
                                .font(Font.system(Font.TextStyle.footnote, design: Font.Design.monospaced))
                                .frame(maxWidth: CGFloat.infinity, alignment: Alignment.leading)

                            Button(role: ButtonRole.destructive) {
                                perform("delete_console_entry", value: "\(entry.id)")
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Delete console entry")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(Font.caption)
                    .foregroundColor(Color.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .navigationTitle("Console")
        .onAppear { refresh() }
        .alert("Clear all console messages?", isPresented: $confirmsClear) {
            Button("Cancel", role: ButtonRole.cancel) {}
            Button("Clear", role: ButtonRole.destructive) { perform("clear") }
        } message: {
            Text("This removes every captured print and NSLog entry.")
        }
    }

    private func refresh() {
        let snapshot = DebugSwiftRuntime.snapshot(featureID: "console")
        guard let data = snapshot.data(using: .utf8),
              let messages = try? JSONDecoder().decode([String].self, from: data) else {
            entries = []
            statusMessage = "Console data could not be loaded."
            return
        }
        entries = messages.indices.map { index in DebugSwiftConsoleEntry(id: index, message: messages[index]) }
        statusMessage = entries.count == 1 ? "1 message" : "\(entries.count) messages"
    }

    private func perform(_ actionID: String, value: String = "") {
        statusMessage = DebugSwiftRuntime.perform(
            featureID: "console",
            actionID: actionID,
            value: value
        )
        refresh()
    }
}
