import Foundation

extension DebugSwiftNetworkInjection {
    /// What one `DebugSwift.Network` injection call sets: the fields of each section (`delay`,
    /// `failure`, `rewrite`) it assigns, and the values it assigns them.
    ///
    /// The Android runtime writes exactly these fields into its current rules under its lock. A call
    /// therefore lands as if it ran after any other writer (an import, the panel): fields it doesn't
    /// set keep what that writer put there, and the fields it sets get the call's values, even
    /// where the value it read was already the same.
    struct Change {
        fileprivate(set) var fields: [String: [String]] = [:]
        fileprivate var apply: (inout DebugSwiftNetworkInjection) -> Void = { _ in }

        init() {}

        fileprivate init(_ section: String, _ fields: [String], _ apply: @escaping (inout DebugSwiftNetworkInjection) -> Void) {
            self.fields = [section: fields]
            self.apply = apply
        }

        /// Both changes, `other` last.
        func then(_ other: Change) -> Change {
            var combined = Change()
            combined.fields = fields.merging(other.fields) { first, second in first + second.filter { !first.contains($0) } }
            let apply = self.apply
            combined.apply = { settings in
                apply(&settings)
                other.apply(&settings)
            }
            return combined
        }

        /// The fields this change sets, as JSON values; a field it sets to `nil` is `NSNull`.
        /// `current` only fills in the parts of a section the change leaves alone.
        func sections(on current: DebugSwiftNetworkInjection) -> [String: [String: Any]] {
            var after = current
            apply(&after)
            var sections: [String: [String: Any]] = [:]
            for (name, keys) in fields {
                let values: [String: Any]?
                switch name {
                case "delay": values = DebugSwiftNetworkInjection.jsonFields(of: after.delay)
                case "failure": values = DebugSwiftNetworkInjection.jsonFields(of: after.failure)
                case "rewrite": values = DebugSwiftNetworkInjection.jsonFields(of: after.rewrite)
                default: values = nil
                }
                guard let values else { continue }
                sections[name] = Dictionary(uniqueKeysWithValues: keys.map { ($0, values[$0] ?? NSNull()) })
            }
            return sections
        }
    }

    fileprivate static func jsonFields<Section: Encodable>(of section: Section) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(section) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

extension DebugSwiftNetworkInjection.Change {
    /// Delays matching requests: by `fixedDelay`, or when it is `nil`, by a random time in
    /// `minDelay...maxDelay` (each left as it is when not given).
    static func delay(
        isEnabled: Bool = true,
        fixedDelay: Double?,
        minDelay: Double? = nil,
        maxDelay: Double? = nil,
        urlPatterns: [String],
        httpMethods: [String]
    ) -> Self {
        var fields = ["isEnabled", "fixedDelay", "urlPatterns", "httpMethods"]
        if minDelay != nil { fields.append("minDelay") }
        if maxDelay != nil { fields.append("maxDelay") }
        return Self("delay", fields) { settings in
            settings.delay.isEnabled = isEnabled
            settings.delay.fixedDelay = fixedDelay
            if let minDelay { settings.delay.minDelay = minDelay }
            if let maxDelay { settings.delay.maxDelay = maxDelay }
            settings.delay.urlPatterns = urlPatterns
            settings.delay.httpMethods = httpMethods
        }
    }

    static var disableDelay: Self { Self("delay", ["isEnabled"]) { $0.delay.isEnabled = false } }

    /// Fails a share of matching requests. `statusCodes` and `custom` are set only when given.
    static func failure(
        isEnabled: Bool = true,
        rate: Double,
        type: String,
        statusCodes: [Int]? = nil,
        custom: (domain: String, code: Int, description: String)? = nil,
        urlPatterns: [String],
        httpMethods: [String]
    ) -> Self {
        var fields = ["isEnabled", "failureRate", "failureType", "urlPatterns", "httpMethods"]
        if statusCodes != nil { fields.append("customStatusCodes") }
        if custom != nil { fields += ["customDomain", "customCode", "customDescription"] }
        return Self("failure", fields) { settings in
            settings.failure.isEnabled = isEnabled
            settings.failure.failureRate = rate
            settings.failure.failureType = type
            if let statusCodes { settings.failure.customStatusCodes = statusCodes }
            if let custom {
                settings.failure.customDomain = custom.domain
                settings.failure.customCode = custom.code
                settings.failure.customDescription = custom.description
            }
            settings.failure.urlPatterns = urlPatterns
            settings.failure.httpMethods = httpMethods
        }
    }

    static var disableFailure: Self { Self("failure", ["isEnabled"]) { $0.failure.isEnabled = false } }

    static func rewrite(isEnabled: Bool, rules: [DebugSwiftNetworkInjection.Rule]) -> Self {
        Self("rewrite", ["isEnabled", "rules"]) { settings in
            settings.rewrite.isEnabled = isEnabled
            settings.rewrite.rules = rules
        }
    }

    static var disableRewrite: Self { Self("rewrite", ["isEnabled"]) { $0.rewrite.isEnabled = false } }
}
