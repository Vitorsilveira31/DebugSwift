import SwiftUI
#if os(iOS)
import DebugSwift
#endif

/// One button on the Custom Actions screen. The id says where the action lives, so two actions
/// with the same title in different groups stay apart.
struct DebugCustomActionEntry: Identifiable, Equatable {
    let id: String
    let section: String
    let title: String
}

extension DebugSwiftRuntime {
    /// The actions from `DebugSwift.App.shared.customAction`, then, on Android, the ones the host
    /// registered in Kotlin with `AndroidDebugTools.registerAction`.
    @MainActor
    static func customActionEntries() -> [DebugCustomActionEntry] {
        var entries: [DebugCustomActionEntry] = []
        for (groupIndex, group) in (DebugSwift.App.shared.customAction?() ?? []).enumerated() {
            for (actionIndex, action) in group.actions.enumerated() {
                entries.append(.init(id: "app:\(groupIndex):\(actionIndex)", section: group.title, title: action.title))
            }
        }
        #if os(Android)
        let registered = DebugSwiftNativeBridge.snapshot("custom_actions")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("No custom actions") }
        for title in registered {
            entries.append(.init(id: "android:\(title)", section: "Android", title: title))
        }
        #endif
        return entries
    }

    /// Runs the action an entry from `customActionEntries()` names.
    @MainActor
    static func runCustomAction(_ entry: DebugCustomActionEntry) -> String {
        let parts = entry.id.split(separator: ":", maxSplits: 2).map(String.init)
        if parts.first == "app", parts.count == 3, let groupIndex = Int(parts[1]), let actionIndex = Int(parts[2]) {
            let groups = DebugSwift.App.shared.customAction?() ?? []
            guard groups.indices.contains(groupIndex),
                  groups[groupIndex].actions.indices.contains(actionIndex),
                  groups[groupIndex].actions[actionIndex].title == entry.title,
                  let run = groups[groupIndex].actions[actionIndex].action else {
                return "The action '\(entry.title)' is no longer registered."
            }
            run()
            return "Action '\(entry.title)' completed."
        }
        #if os(Android)
        if parts.first == "android" {
            return DebugSwiftNativeBridge.perform("custom_actions", "run_custom", entry.title)
        }
        #endif
        return "The action '\(entry.title)' is no longer registered."
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
