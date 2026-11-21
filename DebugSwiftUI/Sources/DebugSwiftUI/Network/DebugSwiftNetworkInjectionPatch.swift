import Foundation

extension DebugSwiftNetworkInjection {
    /// The fields of each section (`delay`, `failure`, `rewrite`) whose value differs from `old`,
    /// as JSON values; a removed optional is `NSNull`. Sections with no change are left out.
    ///
    /// The Android runtime writes exactly these fields into its current rules, so a change made
    /// here never puts back fields another writer changed meanwhile (an import's rewrite rules).
    func changedSections(from old: DebugSwiftNetworkInjection) -> [String: [String: Any]] {
        var sections: [String: [String: Any]] = [:]
        func add<Section: Encodable & Equatable>(_ name: String, _ before: Section, _ after: Section) {
            guard before != after,
                  let oldFields = Self.fields(of: before),
                  let newFields = Self.fields(of: after) else { return }
            var changed: [String: Any] = [:]
            for key in Set(oldFields.keys).union(newFields.keys)
            where Self.encoded(oldFields[key]) != Self.encoded(newFields[key]) {
                changed[key] = newFields[key] ?? NSNull()
            }
            if !changed.isEmpty { sections[name] = changed }
        }
        add("delay", old.delay, delay)
        add("failure", old.failure, failure)
        add("rewrite", old.rewrite, rewrite)
        return sections
    }

    private static func fields<Section: Encodable>(of section: Section) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(section) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// A JSON value in a comparable form; wrapped in an array so scalars serialize too.
    private static func encoded(_ value: Any?) -> Data? {
        guard let value else { return nil }
        return try? JSONSerialization.data(withJSONObject: [value], options: .sortedKeys)
    }
}
