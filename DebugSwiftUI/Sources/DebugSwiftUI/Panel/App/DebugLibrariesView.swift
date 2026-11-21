import SwiftUI

struct DebugLibrary: Decodable, Identifiable {
    let path: String
    let name: String
    let size: Int
    let origin: String
    /// iOS only: where the image is loaded in memory.
    let address: String?

    /// Prefixed so a path that is both a split and a mapped file stays unique in one list.
    var id: String { "library-" + path }
}

struct DebugCodePath: Identifiable {
    let path: String
    var id: String { "split-" + path }
}

struct DebugAppLibrary: Decodable, Identifiable {
    let name: String
    let size: Int
    var id: String { "packed-" + name }
}

struct DebugLibrariesInfo: Decodable {
    let appLibraries: [DebugAppLibrary]
    let packageName: String
    let libraries: [DebugLibrary]
    // Android only: the APK's code and native setup.
    let abis: String?
    let nativeDirectory: String?
    let sourceDirectory: String?
    let splits: [String]?
    let classLoader: String?
    let nativeHeap: Int?
    /// iOS only: each library's Objective-C classes can be listed and inspected.
    let classesAvailable: Bool?
}

/// The app and its libraries as the process has them loaded now: what is loaded, from where, and
/// how large each is. On iOS each library's classes can be browsed.
struct DebugLibrariesView: View {
    @State var info: DebugLibrariesInfo? = nil
    @State var filter = ""
    @State var origin = "All"
    @State var failure = ""

    let origins = ["All", "App", "System"]

    var visible: [DebugLibrary] {
        guard let info else { return [] }
        return info.libraries.filter { library in
            (origin == "All" || library.origin == origin)
                && (filter.isEmpty || library.name.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        List {
            if !failure.isEmpty {
                Text(verbatim: failure).foregroundColor(Color.red)
            }
            if let info {
                Section("App") {
                    LabeledContent(DebugPlatform.isAndroid ? "Package" : "Bundle identifier") { Text(verbatim: info.packageName) }
                    if let abis = info.abis {
                        LabeledContent("Supported ABIs") { Text(verbatim: abis).multilineTextAlignment(.trailing) }
                    }
                    if let nativeHeap = info.nativeHeap {
                        LabeledContent("Native heap") { Text(verbatim: debugByteCount(nativeHeap)) }
                    }
                    if let classLoader = info.classLoader {
                        LabeledContent("Class loader") { Text(verbatim: classLoader).multilineTextAlignment(.trailing) }
                    }
                }
                if let sourceDirectory = info.sourceDirectory, let nativeDirectory = info.nativeDirectory {
                Section("Code") {
                    Text(verbatim: sourceDirectory)
                        .font(.system(.footnote, design: .monospaced))
                    ForEach((info.splits ?? []).map { DebugCodePath(path: $0) }) { split in
                        Text(verbatim: split.path)
                            .font(.system(.footnote, design: .monospaced))
                    }
                    Text(verbatim: "Native: " + nativeDirectory)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(Color.secondary)
                }
                }
                Section(DebugPlatform.isAndroid ? "Native libraries in the app (\(info.appLibraries.count))" : "Frameworks in the app (\(info.appLibraries.count))") {
                    ForEach(info.appLibraries) { library in
                        HStack {
                            Text(verbatim: library.name)
                            Spacer()
                            Text(verbatim: debugByteCount(library.size))
                                .font(.caption)
                                .foregroundColor(Color.secondary)
                        }
                    }
                }
                Section {
                    TextField("Filter by name", text: $filter)
                    HStack(spacing: 14) {
                        ForEach(origins, id: \.self) { candidate in
                            Button(candidate) { origin = candidate }
                                .foregroundColor(origin == candidate ? Color.accentColor : Color.secondary)
                        }
                        Spacer()
                        Text(verbatim: "\(visible.count) of \(info.libraries.count)")
                            .font(.caption)
                            .foregroundColor(Color.secondary)
                    }
                }
                Section(DebugPlatform.isAndroid ? "Mapped libraries and code files" : "Loaded images") {
                    ForEach(visible) { library in
                        if info.classesAvailable == true {
                            NavigationLink {
                                DebugLibraryClassesView(library: library)
                            } label: {
                                DebugLibraryRow(library: library)
                            }
                        } else {
                            DebugLibraryRow(library: library)
                        }
                    }
                }
            }
            Section {
                Button("Refresh") { load() }
            }
        }
        .navigationTitle("Installed Libraries")
        .onAppear { load() }
    }

    func load() {
        switch DebugResourceClient.fetch("app.libraries", as: DebugLibrariesInfo.self) {
        case let .success(value):
            info = value
            failure = ""
        case let .failure(error):
            failure = error.message
        }
    }
}

struct DebugLibraryRow: View {
    let library: DebugLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: library.name)
                Spacer()
                Text(verbatim: debugByteCount(library.size))
                    .font(.caption)
                    .foregroundColor(Color.secondary)
            }
            Text(verbatim: library.origin + " · " + (library.address.map { $0 + " · " } ?? "") + library.path)
                .font(.caption2)
                .foregroundColor(Color.secondary)
                .lineLimit(2)
        }
    }
}

/// The Objective-C classes one library defines, each opening its superclasses, properties and methods.
struct DebugLibraryClassesView: View {
    let library: DebugLibrary
    @State var classes: [String] = []
    @State var filter = ""
    @State var failure = ""

    var visible: [String] {
        filter.isEmpty ? classes : classes.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        List {
            Section {
                TextField("Filter classes", text: $filter)
                Text(verbatim: "\(visible.count) of \(classes.count) classes")
                    .font(.caption)
                    .foregroundColor(Color.secondary)
            }
            if !failure.isEmpty {
                Text(verbatim: failure).foregroundColor(Color.red)
            }
            ForEach(visible, id: \.self) { name in
                NavigationLink {
                    DebugClassDetailView(name: name)
                } label: {
                    Text(verbatim: name).font(.system(.footnote, design: .monospaced))
                }
            }
        }
        .navigationTitle(Text(verbatim: library.name))
        .onAppear {
            switch DebugResourceClient.fetch("app.libraries.classes", ["path": library.path], as: DebugClassList.self) {
            case let .success(value): classes = value.classes
            case let .failure(error): failure = error.message
            }
        }
    }
}

struct DebugClassList: Decodable {
    let classes: [String]
}

struct DebugClassDescription: Decodable {
    let text: String
}

struct DebugClassDetailView: View {
    let name: String
    @State var text = ""

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(Text(verbatim: name))
        .onAppear {
            switch DebugResourceClient.fetch("app.libraries.class", ["name": name], as: DebugClassDescription.self) {
            case let .success(value): text = value.text
            case let .failure(error): text = error.message
            }
        }
    }
}
