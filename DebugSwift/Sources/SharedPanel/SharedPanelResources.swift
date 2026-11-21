//
//  SharedPanelResources.swift
//  DebugSwift
//

import Foundation
import Security

/// The Resources area of the shared panel on iOS: the app's files, its UserDefaults and HTTP
/// cookies, in the shapes the Android runtime returns its files, SharedPreferences and cookies.
@MainActor
final class SharedPanelResources {
    static let shared = SharedPanelResources()

    private static let previewLimit = 1_000_000
    private static let previewCharacters = 200_000
    /// The panel's own keys (the simulated location) are not the app's preferences.
    private static let hiddenDefaults: Set<String> = [
        LocationToolkit.Constants.simulatedLatitude, LocationToolkit.Constants.simulatedLongitude
    ]
    private static let standardStore = "Standard"

    private let defaultsDiff = UserDefaultsDiffAdapter.shared
    private var snapshotAt: Date?
    /// The file the preview chose, for Share.
    private var selectedFile: String?

    private init() {}

    // MARK: - Operations

    func resource(_ operation: String, _ arguments: [String: String]) -> [String: Any]? {
        switch operation {
        case "files.list": return listFiles(arguments["path"] ?? "")
        case "files.read": return readFile(arguments["path"] ?? "")
        case "files.delete": return deleteFile(arguments["path"] ?? "")
        case "prefs.list": return preferences()
        case "prefs.diff": return preferenceChanges()
        case "cookies.list": return cookies()
        case "keystore.list": return keychainItems()
        case "db.list": return databases()
        case "db.tables": return tables(arguments["db"] ?? "")
        case "db.rows": return rows(arguments["db"] ?? "", table: arguments["table"] ?? "", offset: Int(arguments["offset"] ?? "") ?? 0)
        case "db.query": return query(arguments["db"] ?? "", sql: arguments["sql"] ?? "")
        default: return nil
        }
    }

    func perform(featureID: String, actionID: String, value: String) -> String? {
        switch (featureID, actionID) {
        case ("files", "browse_files"):
            selectedFile = value
            return "Selected \(value)."
        case ("files", "export"):
            guard let path = selectedFile, let url = resolve(path), FileManager.default.fileExists(atPath: url.path) else {
                return "Choose a file first."
            }
            FileSharingManager.share(url)
            return "Sharing \(url.lastPathComponent)."
        case ("preferences", "set_preference"), ("persistent_data", "set_preference"), ("user_defaults", "set_preference"):
            return setPreference(value)
        case ("preferences", "delete_preference"), ("persistent_data", "delete_preference"), ("user_defaults", "delete_preference"):
            return deletePreference(value)
        case ("keychain", "set_keychain_item"):
            return setKeychainItem(value)
        case ("keychain", "delete_keychain_item"):
            return deleteKeychainItem(value)
        case ("database", "export_database"):
            guard let path = databasePath(value) else { return "No database named \(value)." }
            FileSharingManager.share(URL(fileURLWithPath: path))
            return "Sharing \(value)."
        case ("preferences", "snapshot_preferences"):
            defaultsDiff.snapshotNow()
            snapshotAt = Date()
            return "Snapshot taken."
        case ("preferences", "undo_preference_change"):
            guard let change = defaultsDiff.changes().first(where: { $0.key == value }) else { return "No change to \(value)." }
            defaultsDiff.undo(change)
            return "Restored \(value)."
        default:
            return nil
        }
    }

    // MARK: - Files

    /// The sandbox folders the browser starts from.
    private static let roots = ["Documents", "Library", "tmp"]

    /// A path inside one of the roots, or nil for anything outside them.
    private func resolve(_ path: String) -> URL? {
        let parts = path.split(separator: "/").map(String.init)
        guard let root = parts.first, Self.roots.contains(root) else { return nil }
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(root).standardizedFileURL
        let target = parts.dropFirst().reduce(base) { $0.appendingPathComponent($1) }.standardizedFileURL
        guard target.path == base.path || target.path.hasPrefix(base.path + "/") else { return nil }
        return target
    }

    private func listFiles(_ path: String) -> [String: Any] {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if trimmed.isEmpty {
            return [
                "path": "",
                "entries": Self.roots.map { ["name": $0, "isDirectory": true, "size": 0, "modified": 0] }
            ]
        }
        guard let directory = resolve(trimmed) else {
            return ["error": "The file browser is limited to the app's Documents, Library and tmp folders."]
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            return ["error": "Not a directory: \(trimmed)"]
        }
        let entries: [[String: Any]] = items.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let isDirectory = values.isDirectory ?? false
            return [
                "name": url.lastPathComponent,
                "isDirectory": isDirectory,
                "size": isDirectory ? 0 : (values.fileSize ?? 0),
                "modified": Int((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
            ]
        }
        .sorted { lhs, rhs in
            let leftDirectory = lhs["isDirectory"] as? Bool ?? false
            let rightDirectory = rhs["isDirectory"] as? Bool ?? false
            if leftDirectory != rightDirectory { return leftDirectory }
            return (lhs["name"] as? String ?? "").lowercased() < (rhs["name"] as? String ?? "").lowercased()
        }
        return ["path": trimmed, "entries": Array(entries.prefix(500))]
    }

    private func readFile(_ path: String) -> [String: Any] {
        guard let url = resolve(path),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]))
                .flatMap({ $0.isRegularFile == true ? $0.fileSize : nil }) else {
            return ["error": "File not found: \(path)"]
        }
        var result: [String: Any] = ["path": path, "size": size]
        guard size <= Self.previewLimit else {
            result["isText"] = false
            result["note"] = "Preview is limited to 1 MB."
            return result
        }
        guard let data = try? Data(contentsOf: url) else { return ["error": "The file could not be read."] }
        if data.prefix(8_000).contains(0) {
            result["isText"] = false
            result["note"] = "Binary file, no text preview."
            return result
        }
        result["isText"] = true
        result["text"] = String(String(decoding: data, as: UTF8.self).prefix(Self.previewCharacters))
        return result
    }

    private func deleteFile(_ path: String) -> [String: Any] {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = resolve(trimmed) else { return ["error": "Path is outside the app's private storage."] }
        guard trimmed.contains("/") else { return ["error": "Cannot delete a storage root."] }
        guard FileManager.default.fileExists(atPath: url.path) else { return ["error": "Path not found: \(path)"] }
        do {
            try FileManager.default.removeItem(at: url)
            return ["ok": true, "message": "Deleted \(url.lastPathComponent)."]
        } catch {
            return ["ok": false, "message": "Could not delete \(url.lastPathComponent): \(error.localizedDescription)"]
        }
    }

    // MARK: - UserDefaults

    private static func typeName(_ value: Any) -> String {
        // A stored 0 or 1 bridges to Bool too: only a CFBoolean is a Boolean.
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return CFNumberIsFloatType(number) ? "Double" : "Int"
        }
        return switch value {
        case is Bool: "Boolean"
        case is Date: "Date"
        case is Data: "Data"
        case is [Any]: "Array"
        case is [String: Any]: "Dictionary"
        default: "String"
        }
    }

    private func preferences() -> [String: Any] {
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        let values: [[String: Any]] = defaults.keys.sorted().filter { !Self.hiddenDefaults.contains($0) }.map { key in
            let value = defaults[key] ?? ""
            return ["key": key, "type": Self.typeName(value), "value": "\(value)"]
        }
        return ["stores": [["name": Self.standardStore, "values": values]]]
    }

    /// "store|key=value". The value keeps the type the key already has (String for a new key).
    private func setPreference(_ value: String) -> String {
        let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "Enter store|key=value." }
        let pair = parts[1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard pair.count == 2, !pair[0].isEmpty else { return "Enter key=value." }
        let (key, text) = (pair[0], pair[1])
        let defaults = UserDefaults.standard
        switch defaults.object(forKey: key).map(Self.typeName) {
        case "Boolean":
            guard let flag = Bool(text.lowercased()) else { return "\(key) is a Boolean: enter true or false." }
            defaults.set(flag, forKey: key)
        case "Int":
            guard let number = Int(text) else { return "\(key) is a whole number." }
            defaults.set(number, forKey: key)
        case "Double":
            guard let number = Double(text) else { return "\(key) is a number." }
            defaults.set(number, forKey: key)
        case "Date", "Data", "Array", "Dictionary":
            return "\(key) holds a value this screen can't edit as text."
        default:
            defaults.set(text, forKey: key)
        }
        return "Saved \(key)."
    }

    /// "store|key".
    private func deletePreference(_ value: String) -> String {
        let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return "Enter store|key." }
        UserDefaults.standard.removeObject(forKey: parts[1])
        return "Deleted \(parts[1])."
    }

    private func preferenceChanges() -> [String: Any] {
        var result: [String: Any] = [
            "changes": defaultsDiff.changes().filter { !Self.hiddenDefaults.contains($0.key) }.map { change in
                [
                    "key": change.key,
                    "kind": "\(change.kind)",
                    "old": change.oldValue.map { "\($0)" } ?? "",
                    "new": change.newValue.map { "\($0)" } ?? ""
                ]
            }
        ]
        if let snapshotAt { result["snapshotAt"] = SharedPanelData.timeFormatter.string(from: snapshotAt) }
        return result
    }

    // MARK: - Keychain

    /// The app's generic-password items, each named service/key so two services can share a key.
    private func keychainItems() -> [String: Any] {
        let items = Keychain.allKeys(.genericPassword)
            .map { (service: $0.0, key: $0.1) }
            .filter { !Self.hiddenDefaults.contains($0.key) }
        return [
            "editable": true,
            "aliases": items.sorted { ($0.service, $0.key) < ($1.service, $1.key) }.map { item -> [String: Any] in
                [
                    "alias": item.key,
                    "service": item.service,
                    "value": Keychain(service: item.service)[string: item.key] ?? ""
                ]
            }
        ]
    }

    /// "service|key=value"; an empty service uses the app's default one.
    private func setKeychainItem(_ value: String) -> String {
        let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return "Enter service|key=value." }
        let pair = parts[1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard pair.count == 2, !pair[0].isEmpty else { return "Enter a key." }
        let keychain = parts[0].isEmpty ? Keychain() : Keychain(service: parts[0])
        do {
            try keychain.set(pair[1], key: pair[0])
            return "Saved \(pair[0])."
        } catch {
            return "Could not save \(pair[0]): \(error.localizedDescription)"
        }
    }

    /// "service|key".
    private func deleteKeychainItem(_ value: String) -> String {
        let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return "Enter service|key." }
        let keychain = parts[0].isEmpty ? Keychain() : Keychain(service: parts[0])
        do {
            try keychain.remove(parts[1])
            return "Deleted \(parts[1])."
        } catch {
            return "Could not delete \(parts[1]): \(error.localizedDescription)"
        }
    }

    // MARK: - Databases

    /// SQLite files in the sandbox, named by their path under the app's home folder. Includes
    /// Core Data stores and SwiftData's `.store` files, which are SQLite too.
    private func databaseFiles() -> [(name: String, path: String, size: Int)] {
        var files = DatabaseFileManager.shared.discoverDatabaseFiles()
            .map { ($0.path, Int($0.size)) }
        let support = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        if let stores = FileManager.default.enumerator(at: support, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in stores where url.pathExtension == "store" && Self.isSQLite(url) {
                files.append((url.path, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
            }
        }
        let home = NSHomeDirectory() + "/"
        var seen = Set<String>()
        return files.compactMap { path, size in
            guard seen.insert(path).inserted else { return nil }
            let name = path.hasPrefix(home) ? String(path.dropFirst(home.count)) : (path as NSString).lastPathComponent
            return (name, path, size)
        }.sorted { $0.name < $1.name }
    }

    private static func isSQLite(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 16)) == Data("SQLite format 3\0".utf8)
    }

    private func databasePath(_ name: String) -> String? {
        databaseFiles().first { $0.name == name }?.path
    }

    /// Realm files show their header as one informational table, as the iOS browser did.
    private static func isRealm(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".realm")
    }

    private func databases() -> [String: Any] {
        ["databases": databaseFiles().map { ["name": $0.name, "size": $0.size] }]
    }

    private func tables(_ name: String) -> [String: Any] {
        guard let path = databasePath(name) else { return ["error": "No database named \(name)."] }
        return [
            "db": name,
            "tables": (Self.isRealm(path) ? RealmManager.shared.getTables(from: path) : SQLiteManager.shared.getTables(from: path))
                .map { ["name": $0.name, "rows": $0.rowCount] }
        ]
    }

    private static let pageSize = 500

    private func rows(_ name: String, table: String, offset: Int) -> [String: Any] {
        guard let path = databasePath(name) else { return ["error": "No database named \(name)."] }
        if Self.isRealm(path) {
            let data = RealmManager.shared.getTableData(from: path, table: table)
            return ["columns": data.columns, "rows": data.rows.map(Self.texts), "offset": 0, "total": data.rows.count]
        }
        let total = SQLiteManager.shared.getTables(from: path).first { $0.name == table }?.rowCount
        let data = SQLiteManager.shared.getTableData(from: path, table: table, limit: Self.pageSize, offset: max(0, offset))
        var result: [String: Any] = ["columns": data.columns, "rows": data.rows.map(Self.texts), "offset": max(0, offset)]
        if let total { result["total"] = total }
        return result
    }

    private func query(_ name: String, sql: String) -> [String: Any] {
        guard let path = databasePath(name) else { return ["error": "No database named \(name)."] }
        guard !Self.isRealm(path) else { return ["error": "SQL runs on SQLite databases, not Realm files."] }
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ["error": "Enter a SQL statement."] }
        switch SQLiteManager.shared.executeQuery(path: path, query: sql) {
        case let .select(columns, rows):
            return ["columns": columns, "rows": rows.prefix(Self.pageSize).map(Self.texts), "total": rows.count]
        case let .update(affected):
            return ["columns": [String](), "rows": [[String]](), "message": affected == 1 ? "1 row changed." : "\(affected) rows changed."]
        case let .error(message):
            return ["error": message]
        }
    }

    /// A row's values as text; NULL stays null.
    private static func texts(_ row: [Any?]) -> [Any] {
        row.map { value -> Any in
            guard let value, !(value is NSNull) else { return NSNull() }
            if let data = value as? Data { return "<\(data.count) bytes>" }
            return "\(value)"
        }
    }

    // MARK: - Cookies

    private func cookies() -> [String: Any] {
        let all = HTTPCookieStorage.shared.cookies ?? []
        let hosts = Dictionary(grouping: all, by: \.domain).keys.sorted().map { host in
            [
                "host": host,
                "cookies": all.filter { $0.domain == host }.sorted { $0.name < $1.name }.map { ["name": $0.name, "value": $0.value] }
            ] as [String: Any]
        }
        return ["hosts": hosts]
    }
}
