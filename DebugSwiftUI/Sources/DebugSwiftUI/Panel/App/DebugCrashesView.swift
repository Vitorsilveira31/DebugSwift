import SwiftUI

/// Uncaught exceptions DebugSwift saved, with the screen at the time on iOS, and the reasons Android
/// reports for recent process exits.
struct DebugCrashesView: View {
    @State var listing: DebugCrashListing? = nil
    @State var failure = ""
    @State var status = ""

    var body: some View {
        List {
            if !failure.isEmpty {
                Text(verbatim: failure).foregroundColor(Color.red)
            }
            Section {
                Button("Export") { status = DebugSwiftRuntime.perform(featureID: "crashes", actionID: "export") }
                Button("Clear saved reports", role: .destructive) {
                    status = DebugSwiftRuntime.perform(featureID: "crashes", actionID: "clear")
                    load()
                }
                if !status.isEmpty {
                    Text(verbatim: status).font(.caption)
                }
            }
            if let listing {
                Section("Saved crash reports") {
                    if listing.reports.isEmpty {
                        Text(verbatim: "No uncaught crash reports saved by DebugSwift.")
                            .foregroundColor(Color.secondary)
                    }
                    ForEach(0..<listing.reports.count, id: \.self) { index in
                        NavigationLink {
                            DebugCrashReportView(report: listing.reports[index], screenshot: listing.screenshots?[safe: index])
                        } label: {
                            Text(verbatim: String(listing.reports[index].split(separator: "\n").first ?? "Crash report"))
                                .lineLimit(2)
                        }
                    }
                }
                if DebugPlatform.isAndroid {
                Section("Recent process exits") {
                    if listing.exits.isEmpty {
                        Text(verbatim: "Android reported no recent process exits.")
                            .foregroundColor(Color.secondary)
                    }
                    ForEach(listing.exits) { exit in
                        NavigationLink {
                            DebugTextDetailView(title: exit.reason, text: detail(of: exit))
                        } label: {
                            DebugCrashExitRow(exit: exit)
                        }
                    }
                }
                }
            }
        }
        .navigationTitle("Crash Reports")
        .onAppear { load() }
    }

    func detail(of exit: DebugCrashExit) -> String {
        var lines = [debugDateText(exit.date), exit.reason, "Status \(exit.status)"]
        if !exit.description.isEmpty { lines.append(exit.description) }
        if !exit.trace.isEmpty { lines.append("\n" + exit.trace) }
        if exit.hasBinaryTrace { lines.append("\nThe native tombstone is binary and is not shown. Read it with adb logcat or a bug report.") }
        return lines.joined(separator: "\n")
    }

    func load() {
        switch DebugResourceClient.fetch("app.crashes", as: DebugCrashListing.self) {
        case let .success(value):
            listing = value
            failure = ""
        case let .failure(error):
            failure = error.message
        }
    }
}

struct DebugCrashExitRow: View {
    let exit: DebugCrashExit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: exit.reason)
            Text(verbatim: debugDateText(exit.date))
                .font(.caption)
                .foregroundColor(Color.secondary)
            if !exit.description.isEmpty {
                Text(verbatim: exit.description)
                    .font(.caption)
                    .foregroundColor(Color.secondary)
                    .lineLimit(2)
            }
        }
    }
}

/// A scrolling monospaced text, for one crash report or exit.
struct DebugTextDetailView: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .navigationTitle(Text(verbatim: title))
    }
}

/// One saved crash: its text, and on iOS the screen as it was when the app crashed.
struct DebugCrashReportView: View {
    let report: String
    let screenshot: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                #if os(iOS)
                if let screenshot, let data = Data(base64Encoded: screenshot), let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 360)
                }
                #endif
                Text(verbatim: report)
                    .font(.system(.footnote, design: .monospaced))
            }
            .padding()
        }
        .navigationTitle("Crash report")
    }
}

extension Array {
    /// The element at `index`, or nil past the end.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
