//
//  SharedPanelRegisteredStores.swift
//  DebugSwift
//

import CoreData
import Foundation
#if canImport(SwiftData)
import SwiftData
#endif

/// The Core Data contexts and SwiftData containers the host registered with
/// `DebugSwift.Resources`, shown in the database browser beside the SQLite files. They are read
/// through their contexts, so in-memory stores show up too. Each is named "Core Data/<name>" or
/// "SwiftData/<name>", which no file path can be.
@MainActor
enum SharedPanelRegisteredStores {
    private static let coreDataPrefix = "Core Data/"
    private static let swiftDataPrefix = "SwiftData/"

    static func names() -> [String] {
        var names = CoreDataManager.shared.getAvailableContexts().map { coreDataPrefix + $0.name }
        #if canImport(SwiftData)
        if #available(iOS 17.0, *) {
            names += SwiftDataManager.shared.getAvailableContexts().map { swiftDataPrefix + $0.name }
        }
        #endif
        return names
    }

    static func isRegistered(_ name: String) -> Bool {
        name.hasPrefix(coreDataPrefix) || name.hasPrefix(swiftDataPrefix)
    }

    /// Entities with their object counts, or an error for a store that is no longer registered.
    static func tables(_ name: String) -> [String: Any] {
        if let context = coreDataContext(name) {
            // On the context's own queue, so a private-queue context is read safely too.
            var result: [String: Any] = [:]
            context.performAndWait {
                do {
                    let entities = (context.persistentStoreCoordinator?.managedObjectModel.entities ?? []).compactMap(\.name).sorted()
                    let tables = try entities.map { entity -> [String: Any] in
                        ["name": entity, "rows": try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entity))]
                    }
                    result = ["db": name, "tables": tables]
                } catch {
                    result = ["error": "The store could not be read: \(error.localizedDescription)"]
                }
            }
            return result
        }
        #if canImport(SwiftData)
        if #available(iOS 17.0, *), let registration = swiftDataRegistration(name) {
            let tables = SwiftDataManager.shared.getEntities(for: registration)
                .filter(\.isBrowsable)
                .map { ["name": $0.name, "rows": $0.objectCount] as [String: Any] }
            return ["db": name, "tables": tables]
        }
        #endif
        return ["error": "No database named \(name)."]
    }

    /// One page of an entity's objects, one column per attribute.
    static func rows(_ name: String, entity: String, offset: Int, pageSize: Int) -> [String: Any] {
        let offset = max(0, offset)
        if let context = coreDataContext(name) {
            var result: [String: Any] = ["error": "No entity named \(entity)."]
            context.performAndWait {
                guard let description = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName[entity] else { return }
                let columns = description.attributesByName.keys.sorted()
                let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                let total: Int
                let objects: [NSManagedObject]
                do {
                    total = try context.count(for: request)
                    request.fetchOffset = offset
                    request.fetchLimit = pageSize
                    objects = try context.fetch(request)
                } catch {
                    result = ["error": "\(entity) could not be read: \(error.localizedDescription)"]
                    return
                }
                result = [
                    "columns": columns,
                    "rows": objects.map { object in columns.map { text(object.value(forKey: $0)) } },
                    "offset": offset,
                    "total": total
                ]
            }
            return result
        }
        #if canImport(SwiftData)
        if #available(iOS 17.0, *), let registration = swiftDataRegistration(name) {
            let manager = SwiftDataManager.shared
            let models: [any PersistentModel]
            do {
                models = try manager.fetchModels(entityName: entity, in: registration)
            } catch {
                return ["error": "\(entity) could not be read: \(error.localizedDescription)"]
            }
            let page = Array(models.dropFirst(offset).prefix(pageSize))
            let columns = page.first.map { manager.getProperties(for: $0, entityName: entity, in: registration).map(\.name) } ?? []
            let rows: [[Any]] = page.map { model in
                let values = Dictionary(
                    manager.getProperties(for: model, entityName: entity, in: registration).map { ($0.name, $0.valueDescription) },
                    uniquingKeysWith: { first, _ in first }
                )
                return columns.map { values[$0].map { $0 as Any } ?? NSNull() }
            }
            return ["columns": columns, "rows": rows, "offset": offset, "total": models.count]
        }
        #endif
        return ["error": "No database named \(name)."]
    }

    /// Whether a SQLite file backs a registered store whose read-only option is on:
    /// `coreDataReadOnly` for Core Data, `swiftDataReadOnly` for SwiftData.
    static func isReadOnlyStoreFile(_ path: String) -> Bool {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        func same(_ url: URL?) -> Bool { url.map { $0.resolvingSymlinksInPath().path == target } ?? false }
        if DebugSwift.Resources.shared.coreDataReadOnly,
           CoreDataManager.shared.getAvailableContexts().contains(where: { entry in
               (entry.context.persistentStoreCoordinator?.persistentStores ?? []).contains { same($0.url) }
           }) {
            return true
        }
        #if canImport(SwiftData)
        if #available(iOS 17.0, *), DebugSwift.Resources.shared.swiftDataReadOnly,
           SwiftDataManager.shared.getAvailableContexts().contains(where: { registration in
               registration.container.configurations.contains { same($0.url) }
           }) {
            return true
        }
        #endif
        return false
    }

    private static func coreDataContext(_ name: String) -> NSManagedObjectContext? {
        guard name.hasPrefix(coreDataPrefix) else { return nil }
        let contextName = String(name.dropFirst(coreDataPrefix.count))
        return CoreDataManager.shared.getAvailableContexts().first { $0.name == contextName }?.context
    }

    #if canImport(SwiftData)
    @available(iOS 17.0, *)
    private static func swiftDataRegistration(_ name: String) -> SwiftDataContextRegistration? {
        guard name.hasPrefix(swiftDataPrefix) else { return nil }
        let registrationName = String(name.dropFirst(swiftDataPrefix.count))
        return SwiftDataManager.shared.getAvailableContexts().first { $0.name == registrationName }
    }
    #endif

    /// An attribute's value as text; nil stays null.
    nonisolated private static func text(_ value: Any?) -> Any {
        guard let value, !(value is NSNull) else { return NSNull() }
        if let data = value as? Data { return "<\(data.count) bytes>" }
        if let object = value as? NSManagedObject { return object.objectID.uriRepresentation().lastPathComponent }
        return "\(value)"
    }
}
