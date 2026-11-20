#if os(Android)
import Foundation

public struct SimulatedNotification: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let subtitle: String?
    public let badge: Int?
    public let sound: String?
    public let category: String?
    public let userInfo: [String: String]
    public let scheduledDate: Date
    public let deliveryDate: Date?
    public let status: NotificationStatus
    public let trigger: NotificationTrigger
    public let interactionType: InteractionType?

    public enum NotificationStatus: String, Codable, CaseIterable, Sendable {
        case scheduled = "Scheduled"
        case delivered = "Delivered"
        case interacted = "Interacted"
        case dismissed = "Dismissed"
        case failed = "Failed"

        public var emoji: String {
            switch self {
            case .scheduled: return "⏰"
            case .delivered: return "✅"
            case .interacted: return "👆"
            case .dismissed: return "❌"
            case .failed: return "🚫"
            }
        }

        public var colorHex: String {
            switch self {
            case .scheduled: return "#FF8C00"
            case .delivered: return "#32CD32"
            case .interacted: return "#1E90FF"
            case .dismissed: return "#808080"
            case .failed: return "#FF4500"
            }
        }
    }

    public enum NotificationTrigger: Codable, Sendable {
        case immediate
        case timeInterval(TimeInterval)
        case date(Date)
        case location(String)

        public var description: String {
            switch self {
            case .immediate:
                return "Immediate"
            case .timeInterval(let interval):
                return "In \(Int(interval))s"
            case .date(let date):
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                formatter.dateStyle = .short
                return formatter.string(from: date)
            case .location(let location):
                return "At \(location)"
            }
        }

        var delay: TimeInterval {
            switch self {
            case .immediate, .location: return 0
            case .timeInterval(let interval): return max(0, interval)
            case .date(let date): return max(0, date.timeIntervalSinceNow)
            }
        }
    }

    public enum InteractionType: String, Codable, CaseIterable, Sendable {
        case tap = "Tap"
        case action = "Action"
        case dismiss = "Dismiss"
        case none = "None"
    }

    public init(
        id: String = UUID().uuidString,
        title: String,
        body: String,
        subtitle: String? = nil,
        badge: Int? = nil,
        sound: String? = nil,
        category: String? = nil,
        userInfo: [String: String] = [:],
        trigger: NotificationTrigger = .immediate,
        status: NotificationStatus = .scheduled
    ) {
        self.init(
            id: id, title: title, body: body, subtitle: subtitle, badge: badge, sound: sound,
            category: category, userInfo: userInfo, scheduledDate: Date(), deliveryDate: nil,
            status: status, trigger: trigger, interactionType: nil
        )
    }

    init(
        id: String, title: String, body: String, subtitle: String?, badge: Int?, sound: String?,
        category: String?, userInfo: [String: String], scheduledDate: Date, deliveryDate: Date?,
        status: NotificationStatus, trigger: NotificationTrigger, interactionType: InteractionType?
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.subtitle = subtitle
        self.badge = badge
        self.sound = sound
        self.category = category
        self.userInfo = userInfo
        self.scheduledDate = scheduledDate
        self.deliveryDate = deliveryDate
        self.status = status
        self.trigger = trigger
        self.interactionType = interactionType
    }
}

public struct NotificationTemplate: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let title: String
    public let body: String
    public let subtitle: String?
    public let badge: Int?
    public let sound: String?
    public let category: String?
    public let userInfo: [String: String]
    public let isDefault: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        title: String,
        body: String,
        subtitle: String? = nil,
        badge: Int? = nil,
        sound: String? = nil,
        category: String? = nil,
        userInfo: [String: String] = [:],
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.body = body
        self.subtitle = subtitle
        self.badge = badge
        self.sound = sound
        self.category = category
        self.userInfo = userInfo
        self.isDefault = isDefault
    }

    public func toSimulatedNotification(trigger: SimulatedNotification.NotificationTrigger = .immediate) -> SimulatedNotification {
        SimulatedNotification(
            title: title,
            body: body,
            subtitle: subtitle,
            badge: badge,
            sound: sound,
            category: category,
            userInfo: userInfo,
            trigger: trigger
        )
    }
}

extension NotificationTemplate {
    public static let defaultTemplates: [NotificationTemplate] = [
        NotificationTemplate(
            name: "Message",
            title: "New Message",
            body: "You have a new message from {{sender}}",
            userInfo: ["type": "message", "sender": "John Doe"],
            isDefault: true
        ),
        NotificationTemplate(
            name: "News Update",
            title: "Breaking News",
            body: "{{headline}}",
            subtitle: "{{category}}",
            userInfo: ["type": "news", "category": "Technology"],
            isDefault: true
        ),
        NotificationTemplate(
            name: "Reminder",
            title: "Reminder",
            body: "Don't forget: {{task}}",
            badge: 1,
            userInfo: ["type": "reminder"],
            isDefault: true
        ),
        NotificationTemplate(
            name: "Marketing",
            title: "Special Offer! 🎉",
            body: "Get {{discount}}% off your next purchase",
            subtitle: "Limited time offer",
            userInfo: ["type": "marketing", "discount": "50"],
            isDefault: true
        ),
        NotificationTemplate(
            name: "System Alert",
            title: "System Notification",
            body: "{{message}}",
            sound: "system",
            userInfo: ["type": "system"],
            isDefault: true
        )
    ]
}

public struct NotificationConfiguration: Codable, Sendable {
    public var isEnabled: Bool
    public var showInForeground: Bool
    public var playSound: Bool
    public var showBadge: Bool
    public var autoInteraction: Bool
    public var interactionDelay: TimeInterval
    public var simulateRealPush: Bool
    public var defaultSound: String
    public var maxHistoryCount: Int

    public static let `default` = NotificationConfiguration()

    public init(
        isEnabled: Bool = true,
        showInForeground: Bool = true,
        playSound: Bool = true,
        showBadge: Bool = true,
        autoInteraction: Bool = false,
        interactionDelay: TimeInterval = 3.0,
        simulateRealPush: Bool = false,
        defaultSound: String = "default",
        maxHistoryCount: Int = 100
    ) {
        self.isEnabled = isEnabled
        self.showInForeground = showInForeground
        self.playSound = playSound
        self.showBadge = showBadge
        self.autoInteraction = autoInteraction
        self.interactionDelay = interactionDelay
        self.simulateRealPush = simulateRealPush
        self.defaultSound = defaultSound
        self.maxHistoryCount = maxHistoryCount
    }
}

/// The registration state behind `DebugSwift.APNSToken`. On Android the token is the Firebase
/// Cloud Messaging registration token.
public final class APNSTokenManager: @unchecked Sendable {
    public enum RegistrationState: String, CaseIterable {
        case notRequested = "not_requested"
        case pending = "pending"
        case registered = "registered"
        case failed = "failed"
        case denied = "denied"
    }

    public enum APNSEnvironment: String, CaseIterable {
        case development = "development"
        case production = "production"
        case unknown = "unknown"
    }

    static let shared = APNSTokenManager()

    var registrationState: RegistrationState = .notRequested
    var deviceToken: String?
}

extension DebugSwift {
    public enum PushNotification {
        public static func enableSimulation() {
            DebugSwiftHost.call("push.enabled", ["enabled": true])
        }

        public static func disableSimulation() {
            DebugSwiftHost.call("push.enabled", ["enabled": false])
        }

        @MainActor public static var isEnabled: Bool {
            state["enabled"] as? Bool ?? false
        }

        public static func simulate(title: String, body: String, delay: TimeInterval = 0) {
            simulate(title: title, body: body, subtitle: nil, delay: delay)
        }

        public static func simulate(
            title: String,
            body: String,
            subtitle: String? = nil,
            badge: Int? = nil,
            sound: String? = nil,
            userInfo: [String: String] = [:],
            delay: TimeInterval = 0
        ) {
            post(SimulatedNotification(
                title: title, body: body, subtitle: subtitle, badge: badge, sound: sound, userInfo: userInfo,
                trigger: delay > 0 ? .timeInterval(delay) : .immediate
            ))
        }

        public static func simulateFromTemplate(_ templateName: String, delay: TimeInterval = 0) {
            DebugSwiftHost.call("push.template", ["name": templateName, "delay": delay])
        }

        public static func simulateInteraction(identifier: String) {
            DebugSwiftHost.call("push.interact", ["id": identifier])
        }

        public static func simulateForegroundNotification(identifier: String) {
            DebugSwiftHost.call("push.foreground", ["id": identifier])
        }

        public static func simulateBackgroundNotification(identifier: String) {
            DebugSwiftHost.call("push.background", ["id": identifier])
        }

        public static func addTemplate(_ template: NotificationTemplate) {
            var arguments: [String: Any] = [
                "id": template.id,
                "name": template.name, "title": template.title, "body": template.body,
                "subtitle": template.subtitle ?? "", "sound": template.sound ?? "",
                "category": template.category ?? "", "userInfo": template.userInfo
            ]
            if let badge = template.badge { arguments["badge"] = badge }
            DebugSwiftHost.call("push.addTemplate", arguments)
        }

        public static func removeTemplate(id templateId: String) {
            DebugSwiftHost.call("push.removeTemplate", ["id": templateId])
        }

        @MainActor public static var templates: [NotificationTemplate] {
            (state["templates"] as? [[String: Any]] ?? []).map { row in
                NotificationTemplate(
                    id: row["id"] as? String ?? UUID().uuidString,
                    name: row["name"] as? String ?? "",
                    title: row["title"] as? String ?? "",
                    body: row["body"] as? String ?? "",
                    subtitle: row["subtitle"] as? String,
                    badge: DebugSwiftHost.int(row["badge"]),
                    sound: row["sound"] as? String,
                    category: row["category"] as? String,
                    userInfo: row["userInfo"] as? [String: String] ?? [:],
                    isDefault: row["isDefault"] as? Bool ?? false
                )
            }
        }

        @MainActor public static var history: [SimulatedNotification] {
            (state["history"] as? [[String: Any]] ?? []).map { row in
                let scheduled = DebugSwiftHost.double(row["scheduledMs"]).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
                let delivered = DebugSwiftHost.double(row["deliveredMs"]).map { Date(timeIntervalSince1970: $0 / 1000) }
                let trigger = row["trigger"] as? String ?? "Immediate"
                let seconds = Double(trigger.filter(\.isNumber)) ?? 0
                return SimulatedNotification(
                    id: row["id"] as? String ?? UUID().uuidString,
                    title: row["title"] as? String ?? "",
                    body: row["body"] as? String ?? "",
                    subtitle: row["subtitle"] as? String,
                    badge: DebugSwiftHost.int(row["badge"]),
                    sound: row["sound"] as? String,
                    category: row["category"] as? String,
                    userInfo: row["userInfo"] as? [String: String] ?? [:],
                    scheduledDate: scheduled,
                    deliveryDate: delivered,
                    status: SimulatedNotification.NotificationStatus(rawValue: row["status"] as? String ?? "") ?? .scheduled,
                    trigger: seconds > 0 ? .timeInterval(seconds) : .immediate,
                    interactionType: (row["interaction"] as? String).flatMap(SimulatedNotification.InteractionType.init(rawValue:))
                )
            }
        }

        public static func clearHistory() {
            DebugSwiftHost.call("push.clearHistory")
        }

        public static func removeNotification(id notificationId: String) {
            DebugSwiftHost.call("push.remove", ["id": notificationId])
        }

        /// Applies every option and the simulation switch together, or none of them if one is rejected.
        public static func updateConfiguration(_ config: NotificationConfiguration) {
            DebugSwiftHost.call("push.config", [
                "isEnabled": config.isEnabled,
                "showInForeground": config.showInForeground,
                "playSound": config.playSound,
                "showBadge": config.showBadge,
                "autoInteraction": config.autoInteraction,
                "interactionDelay": config.interactionDelay,
                "simulateRealPush": config.simulateRealPush,
                "defaultSound": config.defaultSound,
                "maxHistoryCount": config.maxHistoryCount
            ])
        }

        @MainActor public static var configuration: NotificationConfiguration {
            let state = state
            return NotificationConfiguration(
                isEnabled: state["enabled"] as? Bool ?? false,
                showInForeground: state["showInForeground"] as? Bool ?? true,
                playSound: state["playSound"] as? Bool ?? true,
                showBadge: state["showBadge"] as? Bool ?? true,
                autoInteraction: state["autoInteraction"] as? Bool ?? false,
                interactionDelay: DebugSwiftHost.double(state["interactionDelay"]) ?? 3,
                simulateRealPush: state["simulateRealPush"] as? Bool ?? false,
                defaultSound: state["defaultSound"] as? String ?? "default",
                maxHistoryCount: DebugSwiftHost.int(state["maxHistory"]) ?? 100
            )
        }

        public static func runTestScenario(_ scenario: TestScenario) {
            Task { @MainActor in
                switch scenario {
                case .messageFlow: DebugSwiftHost.call("push.scenario", ["name": "messageFlow"])
                case .newsUpdates: DebugSwiftHost.call("push.scenario", ["name": "newsUpdates"])
                case .marketingCampaign: DebugSwiftHost.call("push.scenario", ["name": "marketingCampaign"])
                case .systemAlerts: DebugSwiftHost.call("push.scenario", ["name": "systemAlerts"])
                case .customFlow(let notifications):
                    for notification in notifications {
                        post(notification)
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            }
        }

        @MainActor public enum TestScenario {
            case messageFlow
            case newsUpdates
            case marketingCampaign
            case systemAlerts
            case customFlow([SimulatedNotification])
        }

        private static var state: [String: Any] {
            DebugSwiftHost.object("push.state")
        }

        private static func post(_ notification: SimulatedNotification) {
            var arguments: [String: Any] = [
                "title": notification.title, "body": notification.body,
                "subtitle": notification.subtitle ?? "", "sound": notification.sound ?? "",
                "category": notification.category ?? "", "userInfo": notification.userInfo,
                "delay": notification.trigger.delay
            ]
            if let badge = notification.badge { arguments["badge"] = badge }
            DebugSwiftHost.call("push.simulate", arguments)
        }
    }

    public enum APNSToken {
        /// Reports the push registration token: on Android, the FCM token's bytes.
        @MainActor
        public static func didRegister(deviceToken: Data) {
            let token = String(data: deviceToken, encoding: .utf8) ?? deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
            didRegister(token: token)
        }

        /// Reports the Firebase Cloud Messaging registration token.
        @MainActor
        public static func didRegister(token: String) {
            APNSTokenManager.shared.deviceToken = token
            APNSTokenManager.shared.registrationState = .registered
            DebugSwiftHost.call("push.token", ["token": token])
        }

        @MainActor
        public static func didFailToRegister(error: Error) {
            APNSTokenManager.shared.registrationState = .failed
            DebugSwiftRuntime.log("Push registration failed: \(error.localizedDescription)")
        }

        @MainActor
        public static func willRequestPermissions() {
            APNSTokenManager.shared.registrationState = .pending
        }

        @MainActor
        public static func didDenyPermissions() {
            APNSTokenManager.shared.registrationState = .denied
        }

        @MainActor
        public static var deviceToken: String? {
            APNSTokenManager.shared.deviceToken
        }

        @MainActor
        public static var registrationState: APNSTokenManager.RegistrationState {
            APNSTokenManager.shared.registrationState
        }

        /// FCM tokens have no development or production environment.
        @MainActor
        public static var environment: APNSTokenManager.APNSEnvironment {
            .unknown
        }

        @MainActor
        @discardableResult
        public static func copyToClipboard() -> Bool {
            guard deviceToken != nil else { return false }
            _ = DebugSwiftRuntime.perform(featureID: "push_token", actionID: "copy_token")
            return true
        }

        /// Reads the notification permission again and updates the registration state.
        @MainActor
        public static func refreshStatus() async {
            let permission = DebugSwiftHost.object("push.state")["permission"] as? String ?? ""
            if permission.hasPrefix("Not granted") || permission.hasPrefix("Disabled") {
                APNSTokenManager.shared.registrationState = .denied
            } else if APNSTokenManager.shared.deviceToken != nil {
                APNSTokenManager.shared.registrationState = .registered
            }
        }
    }
}

extension DebugSwift.PushNotification {
    public static func simulateMessage(from sender: String, message: String) {
        simulate(
            title: "New Message",
            body: message,
            subtitle: "From \(sender)",
            userInfo: ["type": "message", "sender": sender]
        )
    }

    public static func simulateReminder(_ task: String, in delay: TimeInterval = 0) {
        simulate(
            title: "Reminder",
            body: "Don't forget: \(task)",
            badge: 1,
            userInfo: ["type": "reminder", "task": task],
            delay: delay
        )
    }

    public static func simulateNews(headline: String, category: String = "General") {
        simulate(
            title: "Breaking News",
            body: headline,
            subtitle: category,
            userInfo: ["type": "news", "category": category]
        )
    }

    public static func simulateMarketing(title: String, offer: String, discount: String? = nil) {
        var userInfo = ["type": "marketing", "offer": offer]
        if let discount {
            userInfo["discount"] = discount
        }
        simulate(
            title: title,
            body: offer,
            subtitle: discount.map { "\($0)% off" },
            badge: 1,
            userInfo: userInfo
        )
    }
}
#endif
