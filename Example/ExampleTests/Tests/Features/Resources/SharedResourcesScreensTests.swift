//
//  SharedResourcesScreensTests.swift
//  ExampleTests
//

@_spi(DebugSwiftUI) @testable import DebugSwift
@testable import DebugSwiftUI
import Foundation
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

        let deletion = try DebugResourceClient.fetch("files.delete", ["path": "tmp/\(name)"], as: DebugFileDeletion.self).get()
        #expect(deletion.ok)
        #expect(!FileManager.default.fileExists(atPath: url.path))
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
        _ = DebugSwiftRuntime.perform(featureID: "preferences", actionID: "set_preference", value: "Standard|\(number)=2")
        #expect(UserDefaults.standard.integer(forKey: number) == 2)
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
