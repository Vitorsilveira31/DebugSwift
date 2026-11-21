//
//  SharedResourcesScreensTests.swift
//  ExampleTests
//

@_spi(DebugSwiftUI) @testable import DebugSwift
@testable import DebugSwiftUI
import Foundation
import SQLite3
import Testing

/// The shared SwiftUI Resources screens read the same operations on iOS as on Android. These check
/// that DebugSwift's iOS answers decode into the models the screens use.
@MainActor
@Suite(.serialized)
struct SharedResourcesScreensTests {
    @Test("Files list the sandbox roots, and a file can be read and deleted, never outside them")
    func files() throws {
        let roots = try DebugResourceClient.fetch("files.list", ["path": ""], as: DebugFileListing.self).get()
        #expect(roots.entries.map(\.name) == ["Documents", "Library", "tmp"])

        let name = "shared-files-\(UUID().uuidString.prefix(8)).txt"
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("tmp").appendingPathComponent(name)
        try "hello from the test".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let listing = try DebugResourceClient.fetch("files.list", ["path": "tmp"], as: DebugFileListing.self).get()
        #expect(listing.entries.contains { $0.name == name && !$0.isDirectory })
        let content = try DebugResourceClient.fetch("files.read", ["path": "tmp/\(name)"], as: DebugFileContent.self).get()
        #expect(content.isText)
        #expect(content.text == "hello from the test")

        #expect((try? DebugResourceClient.fetch("files.list", ["path": "Documents/../../"], as: DebugFileListing.self).get()) == nil)
        #expect((try? DebugResourceClient.fetch("files.delete", ["path": "tmp"], as: DebugFileDeletion.self).get()) == nil)
        for root in ["tmp/.", "Documents/child/..", "tmp/"] {
            #expect((try? DebugResourceClient.fetch("files.delete", ["path": root], as: DebugFileDeletion.self).get()) == nil)
        }
        #expect(FileManager.default.fileExists(atPath: url.path))

        // A name ending in a space is its own file: deleting it leaves the one without the space.
        let spaced = url.appendingPathExtension("bak")
        try "plain".write(to: spaced, atomically: true, encoding: .utf8)
        try "spaced".write(to: URL(fileURLWithPath: spaced.path + " "), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: spaced) }
        let spacedDeletion = try DebugResourceClient.fetch("files.delete", ["path": "tmp/\(name).bak "], as: DebugFileDeletion.self).get()
        #expect(spacedDeletion.ok)
        #expect(FileManager.default.fileExists(atPath: spaced.path))
        #expect(!FileManager.default.fileExists(atPath: spaced.path + " "))

        let deletion = try DebugResourceClient.fetch("files.delete", ["path": "tmp/\(name)"], as: DebugFileDeletion.self).get()
        #expect(deletion.ok)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A configured App Group is a root of the file browser")
    func appGroups() throws {
        let identifier = "group.debugswift.tests"
        // The test app has no App Group entitlement, so a folder stands in for the container.
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("group-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let lookup = DebugSwift.Resources.appGroupContainer
        DebugSwift.Resources.appGroupContainer = { $0 == identifier ? container : nil }
        DebugSwift.Resources.shared.addAppGroup(identifier)
        defer {
            DebugSwift.Resources.shared.removeAppGroup(identifier)
            DebugSwift.Resources.appGroupContainer = lookup
            try? FileManager.default.removeItem(at: container)
        }
        let name = "shared-group-\(UUID().uuidString.prefix(8)).txt"
        try "from the group".write(to: container.appendingPathComponent(name), atomically: true, encoding: .utf8)

        let roots = try DebugResourceClient.fetch("files.list", ["path": ""], as: DebugFileListing.self).get()
        #expect(roots.entries.map(\.name) == ["Documents", "Library", "tmp", identifier])
        let listing = try DebugResourceClient.fetch("files.list", ["path": identifier], as: DebugFileListing.self).get()
        #expect(listing.entries.contains { $0.name == name })
        let content = try DebugResourceClient.fetch("files.read", ["path": "\(identifier)/\(name)"], as: DebugFileContent.self).get()
        #expect(content.text == "from the group")
        #expect((try? DebugResourceClient.fetch("files.delete", ["path": identifier], as: DebugFileDeletion.self).get()) == nil)
    }

    @Test("A symbolic link can't lead the file browser out of its folder, and deleting a link keeps its target")
    func symbolicLinks() throws {
        let documents = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let tag = UUID().uuidString.prefix(8)
        let outside = documents.appendingPathComponent("outside-\(tag)")
        let folder = documents.appendingPathComponent("folder-\(tag)")
        let inside = documents.appendingPathComponent("inside-\(tag)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "kept".write(to: folder.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: outside, withDestinationURL: Bundle.main.bundleURL)
        try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: folder)
        defer { [outside, inside, folder].forEach { try? FileManager.default.removeItem(at: $0) } }

        let plist = Bundle.main.bundleURL.appendingPathComponent("Info.plist")
        #expect((try? DebugResourceClient.fetch("files.list", ["path": "Documents/outside-\(tag)"], as: DebugFileListing.self).get()) == nil)
        #expect((try? DebugResourceClient.fetch("files.read", ["path": "Documents/outside-\(tag)/Info.plist"], as: DebugFileContent.self).get()) == nil)
        #expect((try? DebugResourceClient.fetch("files.delete", ["path": "Documents/outside-\(tag)/Info.plist"], as: DebugFileDeletion.self).get()) == nil)
        #expect(FileManager.default.fileExists(atPath: plist.path))

        let content = try DebugResourceClient.fetch("files.read", ["path": "Documents/inside-\(tag)/note.txt"], as: DebugFileContent.self).get()
        #expect(content.text == "kept")
        let deletion = try DebugResourceClient.fetch("files.delete", ["path": "Documents/inside-\(tag)"], as: DebugFileDeletion.self).get()
        #expect(deletion.ok)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: inside.path)) == nil)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("note.txt").path))
    }

    @Test("Preferences list, save with the key's type, delete, and show changes since a snapshot")
    func preferences() throws {
        let key = "shared-prefs-\(UUID().uuidString.prefix(8))"
        UserDefaults.standard.set(3, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        _ = DebugSwiftRuntime.perform(featureID: "preferences", actionID: "snapshot_preferences")
        let listing = try DebugResourceClient.fetch("prefs.list", as: DebugPreferenceListing.self).get()
        let value = try #require(listing.stores.first?.values.first { $0.key == key })
        #expect(value.type == "Int")
        #expect(value.value == "3")

        #expect(DebugSwiftRuntime.perform(featureID: "preferences", actionID: "set_preference", value: "Standard|\(key)=seven").contains("whole number"))
        _ = DebugSwiftRuntime.perform(featureID: "preferences", actionID: "set_preference", value: "Standard|\(key)=7")
        #expect(UserDefaults.standard.integer(forKey: key) == 7)

        let changes = try DebugResourceClient.fetch("prefs.diff", as: DebugPreferenceChanges.self).get()
        #expect(changes.snapshotAt != nil)
        #expect(changes.changes.contains { $0.key == key && $0.old == "3" && $0.new == "7" })
        _ = DebugSwiftRuntime.perform(featureID: "preferences", actionID: "undo_preference_change", value: key)
        #expect(UserDefaults.standard.integer(forKey: key) == 3)

        _ = DebugSwiftRuntime.perform(featureID: "preferences", actionID: "delete_preference", value: "Standard|\(key)")
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }

    @Test("A number stored as 0 or 1 stays a number, and a Boolean stays a Boolean")
    func preferenceNumberTypes() throws {
        let number = "shared-prefs-number-\(UUID().uuidString.prefix(8))"
        let flag = "shared-prefs-flag-\(UUID().uuidString.prefix(8))"
        UserDefaults.standard.set(1, forKey: number)
        UserDefaults.standard.set(1.0, forKey: number + "-double")
        UserDefaults.standard.set(true, forKey: flag)
        defer { [number, number + "-double", flag].forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        let values = try #require(try DebugResourceClient.fetch("prefs.list", as: DebugPreferenceListing.self).get().stores.first?.values)
        #expect(values.first { $0.key == number }?.type == "Int")
        #expect(values.first { $0.key == number + "-double" }?.type == "Double")
        #expect(values.first { $0.key == flag }?.type == "Boolean")
        #expect(values.first { $0.key == flag }?.value == "true")
        // The value shown saves back unchanged.
        #expect(DebugSwiftRuntime.perform(featureID: "preferences", actionID: "set_preference", value: "Standard|\(flag)=false") == "Saved \(flag).")
        #expect(UserDefaults.standard.object(forKey: flag) as? Bool == false)
        _ = DebugSwiftRuntime.perform(featureID: "preferences", actionID: "set_preference", value: "Standard|\(number)=2")
        #expect(UserDefaults.standard.integer(forKey: number) == 2)
    }

    @Test("Keychain items list with their values, and can be added, edited and deleted")
    func keychain() throws {
        let key = "shared-keychain-\(UUID().uuidString.prefix(8))"
        defer { _ = DebugSwiftRuntime.perform(featureID: "keychain", actionID: "delete_keychain_item", value: "|\(key)") }
        #expect(DebugSwiftRuntime.perform(featureID: "keychain", actionID: "set_keychain_item", value: "|\(key)=first") == "Saved \(key).")
        var listing = try DebugResourceClient.fetch("keystore.list", as: DebugKeystoreListing.self).get()
        #expect(listing.editable == true)
        let item = try #require(listing.aliases.first { $0.alias == key })
        #expect(item.value == "first")

        _ = DebugSwiftRuntime.perform(featureID: "keychain", actionID: "set_keychain_item", value: "\(item.service ?? "")|\(key)=second")
        listing = try DebugResourceClient.fetch("keystore.list", as: DebugKeystoreListing.self).get()
        #expect(listing.aliases.first { $0.alias == key }?.value == "second")

        _ = DebugSwiftRuntime.perform(featureID: "keychain", actionID: "delete_keychain_item", value: "\(item.service ?? "")|\(key)")
        listing = try DebugResourceClient.fetch("keystore.list", as: DebugKeystoreListing.self).get()
        #expect(!listing.aliases.contains { $0.alias == key })
    }

    @Test("A SQLite database lists its tables and rows, pages, and runs SQL")
    func database() throws {
        let name = "shared-db-\(UUID().uuidString.prefix(8)).sqlite"
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes (body) VALUES ('one'), ('two'), (NULL);", nil, nil, nil)
        sqlite3_close(db)

        let listing = try DebugResourceClient.fetch("db.list", as: DebugDatabaseListing.self).get()
        let database = try #require(listing.databases.first { $0.name == "Documents/\(name)" })
        let tables = try DebugResourceClient.fetch("db.tables", ["db": database.name], as: DebugTableListing.self).get()
        #expect(tables.tables.first { $0.name == "notes" }?.rows == 3)

        let rows = try DebugResourceClient.fetch("db.rows", ["db": database.name, "table": "notes", "offset": "0"], as: DebugTableData.self).get()
        #expect(rows.columns == ["id", "body"])
        #expect(rows.rows.count == 3)
        #expect(rows.rows.last?.last == .some(nil))
        #expect(rows.total == 3)

        let update = try DebugResourceClient.fetch("db.query", ["db": database.name, "sql": "UPDATE notes SET body = 'three' WHERE body IS NULL"], as: DebugTableData.self).get()
        #expect(update.message == "1 row changed.")
        let select = try DebugResourceClient.fetch("db.query", ["db": database.name, "sql": "SELECT body FROM notes ORDER BY id"], as: DebugTableData.self).get()
        #expect(select.rows.map { $0.first ?? nil } == ["one", "two", "three"])
        #expect((try? DebugResourceClient.fetch("db.query", ["db": database.name, "sql": "SELECT * FROM missing"], as: DebugTableData.self).get()) == nil)
    }

    @Test("Cookies are grouped by host")
    func cookies() throws {
        let domain = "shared-cookies-\(UUID().uuidString.prefix(6).lowercased()).test"
        let cookie = try #require(HTTPCookie(properties: [.domain: domain, .path: "/", .name: "session", .value: "abc"]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        let listing = try DebugResourceClient.fetch("cookies.list", as: DebugCookieListing.self).get()
        let host = try #require(listing.hosts.first { $0.host == domain })
        #expect(host.cookies.map(\.name) == ["session"])
    }
}
