import SwiftUI

/// This process's log (Logcat on Android, OSLog on iOS), filterable by minimum level and by text in
/// the tag or message.
struct DebugLogcatView: View {
    @State var entries: [DebugLogEntry] = []
    @State var filter = ""
    @State var level = "V"
    @State var includeApple = false
    @State var failure = ""

    let levels = ["V", "D", "I", "W", "E"]

    var body: some View {
        List {
            Section {
                TextField("Filter tag or message", text: $filter)
                HStack(spacing: 8) {
                    ForEach(levels, id: \.self) { candidate in
                        Button(candidate) {
                            level = candidate
                            load()
                        }
                        .foregroundColor(level == candidate ? Color.accentColor : Color.secondary)
                    }
                    Spacer()
                    Button("Refresh") { load() }
                    Button("Clear") {
                        _ = DebugResourceClient.fetch("app.logcat.clear", as: DebugActionReply.self)
                        load()
                    }
                }
                if !DebugPlatform.isAndroid {
                    Toggle("Include Apple subsystems", isOn: Binding(
                        get: { includeApple },
                        set: { include in
                            includeApple = include
                            load()
                        },
                    ))
                }
            }
            if !failure.isEmpty {
                Text(verbatim: failure).foregroundColor(Color.red)
            }
            ForEach(0..<entries.count, id: \.self) { index in
                DebugLogRow(entry: entries[index])
            }
        }
        .navigationTitle("System Log")
        .onAppear { load() }
    }

    func load() {
        let result = DebugResourceClient.fetch(
            "app.logcat",
            ["filter": filter, "level": level, "apple": includeApple ? "true" : "false"],
            as: DebugLogListing.self,
        )
        switch result {
        case let .success(value):
            entries = value.entries
            if value.pending == true {
                Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    load()
                }
            }
            failure = value.entries.isEmpty ? (DebugPlatform.isAndroid ? "No matching Logcat records." : "No matching log entries.") : ""
        case let .failure(error):
            failure = error.message
        }
    }
}

struct DebugLogRow: View {
    let entry: DebugLogEntry

    var color: Color {
        switch entry.level {
        case "E", "F": Color.red
        case "W": Color.orange
        case "V", "D": Color.secondary
        default: Color.primary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: "\(entry.time)  \(entry.level)  \(entry.tag)")
                .font(.caption)
                .foregroundColor(Color.secondary)
            Text(verbatim: entry.message)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(color)
        }
    }
}
