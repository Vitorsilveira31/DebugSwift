//
//  GraphQLInspector.swift
//  DebugSwift
//
//  Created by Matheus Gois (GraphQL Inspector) on 16/07/26.
//

import Foundation

// MARK: - GraphQL Operation Inspector

/// The operation a captured GraphQL request represents. A single endpoint
/// serves many operations, so the name is the only way to distinguish
/// `GetUser` from `UpdateUser` once traffic is multiplexed over one URL.
public enum GraphQLOperation: Equatable {
    case query(name: String?)
    case mutation(name: String?)
    case subscription(name: String?)

    /// How the inspector lists it: "Query: GetUser", or "Query" without a name.
    public var label: String {
        switch self {
        case let .query(name): name.map { "Query: \($0)" } ?? "Query"
        case let .mutation(name): name.map { "Mutation: \($0)" } ?? "Mutation"
        case let .subscription(name): name.map { "Subscription: \($0)" } ?? "Subscription"
        }
    }
}

/// Pure, Foundation-only GraphQL parser. Staying off UIKit keeps it testable
/// and embeddable inside URL-session interceptors and unit tests without
/// dragging a UI layer into the parse path.
public enum GraphQLInspector {

    /// Surface the operation type and name so the debug UI can label a captured
    /// request without forcing the developer to read raw JSON.
    public static func extractOperation(from body: String) -> GraphQLOperation? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? String
        else { return nil }
        // In a document with several operations, `operationName` says which one runs.
        if let name = json["operationName"] as? String, !name.isEmpty,
           let chosen = parseOperationName(query, named: name) {
            return chosen
        }
        return parseOperationName(query)
    }

    /// The label for a request body, or "" when it isn't GraphQL. The query names the operation; a
    /// body without one (a persisted query, say) is labeled by its `operationName`.
    public static func operationLabel(from body: String) -> String {
        if let operation = extractOperation(from: body) { return operation.label }
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["operationName"] as? String, !name.isEmpty
        else { return "" }
        return "Operation: \(name)"
    }

    /// Pull `variables` out of the body so the actual arguments can be inspected
    /// separately from the query text they parameterize.
    public static func extractVariables(from body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["variables"] as? [String: Any]
    }

    /// Separate `data` from `errors` so success versus failure is obvious at a
    /// glance instead of buried inside an opaque response blob.
    public static func splitResponse(_ body: String) -> (data: Any?, errors: Any?)? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (json["data"], json["errors"])
    }

    // MARK: - Private

    /// Reads the operation with a regex instead of a full GraphQL parser: the
    /// query is a plain string inside JSON, so a lightweight match avoids pulling
    /// in an AST dependency just to read the leading keyword and name.
    static func parseOperationName(_ query: String, named name: String? = nil) -> GraphQLOperation? {
        let namePattern = name.map { NSRegularExpression.escapedPattern(for: $0) + "\\b" } ?? "\\w+"
        let pattern = "(query|mutation|subscription)\\s+(\(namePattern))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(query.startIndex..., in: query)
        guard let match = regex.firstMatch(in: query, options: [], range: range),
              match.numberOfRanges >= 3,
              let kindRange = Range(match.range(at: 1), in: query),
              let nameRange = Range(match.range(at: 2), in: query)
        else { return nil }
        let kind = String(query[kindRange])
        let name = String(query[nameRange])
        switch kind {
        case "query": return .query(name: name)
        case "mutation": return .mutation(name: name)
        case "subscription": return .subscription(name: name)
        default: return nil
        }
    }
}
