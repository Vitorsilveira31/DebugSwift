import SwiftUI

/// Lifecycle overrides that forget their super call: Android crashes with SuperNotCalledException,
/// and on iOS DebugSwift catches view controllers that skip it.
struct DebugSuperCallsView: View {
    @State var crashes: [String] = []
    @State var violations: [DebugStackEntry]? = nil
    @State var failure = ""

    var body: some View {
        List {
            Section {
                Text(verbatim: DebugPlatform.isAndroid
                    ? "Android reports a missing required super call as a SuperNotCalledException. The crashes below mention one."
                    : "DebugSwift watches view controller lifecycle methods and lists the overrides that skip their super call.")
                    .font(.caption)
                    .foregroundColor(Color.secondary)
            }
            if !failure.isEmpty {
                Text(verbatim: failure).foregroundColor(Color.red)
            }
            if let violations {
                Section("Missing super calls") {
                    if violations.isEmpty {
                        Text(verbatim: "None caught.")
                            .foregroundColor(Color.secondary)
                    }
                    ForEach(0..<violations.count, id: \.self) { index in
                        NavigationLink {
                            DebugTextDetailView(title: "Missing super call", text: violations[index].title + "\n\n" + violations[index].stack)
                        } label: {
                            Text(verbatim: violations[index].title).lineLimit(2)
                        }
                    }
                }
            }
            if DebugPlatform.isAndroid {
            Section("Crashes with a missing super call") {
                if crashes.isEmpty {
                    Text(verbatim: "None captured.")
                        .foregroundColor(Color.secondary)
                }
                ForEach(0..<crashes.count, id: \.self) { index in
                    NavigationLink {
                        DebugTextDetailView(title: "Crash report", text: crashes[index])
                    } label: {
                        Text(verbatim: String(crashes[index].split(separator: "\n").first ?? "Crash report"))
                            .lineLimit(2)
                    }
                }
            }
            }
            Section {
                Button("Refresh") { load() }
                if violations != nil {
                    Button("Clear", role: .destructive) {
                        _ = DebugSwiftRuntime.perform(featureID: "super_calls", actionID: "clear")
                        load()
                    }
                }
            }
        }
        .navigationTitle("Lifecycle Super Calls")
        .onAppear { load() }
    }

    func load() {
        switch DebugPerformanceDetail.fetch("supercalls", as: DebugSuperCallDetail.self) {
        case let .success(value):
            crashes = value.crashes
            violations = value.violations
            failure = ""
        case let .failure(error):
            failure = error.message
        }
    }
}
