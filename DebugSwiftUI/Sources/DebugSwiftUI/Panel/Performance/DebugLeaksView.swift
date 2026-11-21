import SwiftUI

/// Screens that were closed but are still reachable a few seconds later, a sign of a leak: Activities
/// on Android, view controllers and views on iOS.
struct DebugLeaksView: View {
    @State var detail: DebugLeakDetail? = nil
    @State var failure = ""
    @State var status = ""

    var body: some View {
        List {
            if !failure.isEmpty {
                Text(verbatim: failure).foregroundColor(Color.red)
            }
            if let detail {
                Section("Summary") {
                    LabeledContent(DebugPlatform.isAndroid ? "Activities destroyed" : "Objects reported") { Text(verbatim: "\(detail.destroyed)") }
                    LabeledContent(DebugPlatform.isAndroid ? "Still held after 5 s" : "Still in memory") { Text(verbatim: "\(detail.candidates.count)") }
                }
                Section(DebugPlatform.isAndroid ? "Retained Activities" : "Still in memory") {
                    if detail.candidates.isEmpty {
                        Text(verbatim: DebugPlatform.isAndroid ? "No retained Activity candidates detected." : "No leaked view controllers or views detected.")
                            .foregroundColor(Color.secondary)
                    }
                    ForEach(0..<detail.candidates.count, id: \.self) { index in
                        if let report = detail.candidates[index].detail {
                            NavigationLink {
                                DebugTextDetailView(title: "Leak", text: report)
                            } label: {
                                Text(verbatim: detail.candidates[index].className)
                                    .font(.system(.footnote, design: .monospaced))
                                    .lineLimit(2)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: detail.candidates[index].className)
                                    .font(.system(.footnote, design: .monospaced))
                                Text(verbatim: "destroyed \(detail.candidates[index].ageSeconds) s ago")
                                    .font(.caption)
                                    .foregroundColor(Color.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                Button(DebugPlatform.isAndroid ? "Collect garbage and recheck" : "Recheck") {
                    status = DebugPerformanceDetail.act("app.perf.gc")
                    load()
                }
                Button("Refresh") { load() }
                if !status.isEmpty {
                    Text(verbatim: status).font(.caption)
                }
                Text(verbatim: DebugPlatform.isAndroid ? "This is a reachability check. Confirm a leak with the Android Studio Memory Profiler." : "This is a reachability check. Confirm a leak with the Xcode memory graph.")
                    .font(.caption)
                    .foregroundColor(Color.secondary)
            }
        }
        .navigationTitle("Leak Detection")
        .onAppear { load() }
    }

    func load() {
        switch DebugPerformanceDetail.fetch("leaks", as: DebugLeakDetail.self) {
        case let .success(value):
            detail = value
            failure = ""
        case let .failure(error):
            failure = error.message
        }
    }
}
