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
            // As the UIKit browser did: the manager reads the registered context from the main actor.
            let tables = CoreDataManager.shared.getEntities(for: context).map { ["name": $0.name, "rows": $0.objectCount] as [String: Any] }
            return ["db": name, "tables": tables]
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
                let total = (try? context.count(for: request)) ?? 0
                request.fetchOffset = offset
                request.fetchLimit = pageSize
                let objects = (try? context.fetch(request)) ?? []
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
            let models = (try? manager.fetchModels(entityName: entity, in: registration)) ?? []
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
