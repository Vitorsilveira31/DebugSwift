import SwiftUI
#if os(iOS)
import DebugSwift
#endif

/// One button on the Custom Actions screen. It keeps the action it was built from, so the button
/// runs that action even if the host reorders or renames its actions before the tap.
struct DebugCustomActionEntry: Identifiable {
    let id: String
    let section: String
    let title: String
    let run: (() -> Void)?
}

extension DebugSwiftRuntime {
    /// The actions from `DebugSwift.App.shared.customAction`, then, on Android, the ones the host
    /// registered in Kotlin with `AndroidDebugTools.registerAction`.
    @MainActor
    static func customActionEntries() -> [DebugCustomActionEntry] {
        var entries: [DebugCustomActionEntry] = []
        for (groupIndex, group) in (DebugSwift.App.shared.customAction?() ?? []).enumerated() {
            for (actionIndex, action) in group.actions.enumerated() {
                entries.append(.init(id: "app:\(groupIndex):\(actionIndex)", section: group.title, title: action.title, run: action.action))
            }
        }
        #if os(Android)
        let registered = DebugSwiftNativeBridge.snapshot("custom_actions")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("No custom actions") }
        for title in registered {
            // Kotlin keeps its actions by title, which is unique there.
            entries.append(.init(id: "android:\(title)", section: "Android", title: title, run: nil))
        }
        #endif
        return entries
    }

    /// Runs the action an entry from `customActionEntries()` holds.
    @MainActor
    static func runCustomAction(_ entry: DebugCustomActionEntry) -> String {
        if let run = entry.run {
            run()
            return "Action '\(entry.title)' completed."
        }
        #if os(Android)
        if entry.id.hasPrefix("android:") {
            return DebugSwiftNativeBridge.perform("custom_actions", "run_custom", entry.title)
        }
        #endif
        return "The action '\(entry.title)' has nothing to run."
    }
}

/// The host app's actions, grouped as the host registered them, each with a button to run it.
struct DebugCustomActionsView: View {
    @State var entries: [DebugCustomActionEntry] = []
    @State var status = ""

    var sections: [String] {
        var seen: [String] = []
        for entry in entries where !seen.contains(entry.section) { seen.append(entry.section) }
        return seen
    }

    var body: some View {
        List {
            if entries.isEmpty {
                Text(verbatim: "No custom actions registered by the host app.")
                    .foregroundColor(Color.secondary)
            }
            ForEach(sections, id: \.self) { section in
                Section(section) {
                    ForEach(entries.filter { $0.section == section }) { entry in
                        Button(entry.title) {
                            status = DebugSwiftRuntime.runCustomAction(entry)
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
        .navigationTitle("Custom Actions")
        .onAppear { entries = DebugSwiftRuntime.customActionEntries() }
    }
}
