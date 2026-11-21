import DebugSwiftUI
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Uses every public member of DebugSwift's iOS API. It is never called: it exists so that the
/// Android build fails when the Android API in DebugSwiftUI lacks a member or gives one another
/// signature. Members built on UIKit, Core Data or SwiftData types are checked on iOS only, next to
/// their Android counterpart.
@MainActor
enum APIParityCheck {
    static func check() async throws {
        // DebugSwift
        let debugSwift = DebugSwift()
        debugSwift.setup(hideFeatures: [.interface], disable: [.leaksDetector], enableBetaFeatures: [.agentDebugLog])
        debugSwift.show()
        debugSwift.hide()
        debugSwift.toggle()
        DebugSwift.debugViewControllerWillPresent()
        DebugSwift.debugViewControllerDidDismiss()
        let _: [DebugSwiftFeature] = DebugSwift.availableDebugFeatures()
        let _: [DebugSwiftSwizzleFeature] = DebugSwiftSwizzleFeature.allCases
        let _: [DebugSwiftBetaFeature] = DebugSwiftBetaFeature.allCases

        // App
        DebugSwift.App.shared.customInfo = { [CustomData(title: "t", infos: [.init(title: "a", subtitle: "b")])] }
        DebugSwift.App.shared.customAction = { [CustomAction(title: "t", actions: [.init(title: "a") {}])] }
        DebugSwift.App.presentDebugger()
        DebugSwift.App.removeDebugger()
        let _: URL = try DebugSwift.App.writeAgentSnapshot()

        // Console (`DebugSwift.Debugger` has no public initializer on iOS, so hosts cannot reach it)
        DebugSwift.Console.shared.ignoredLogs = ["a"]
        DebugSwift.Console.shared.onlyLogs = []
        let _: [String] = DebugSwift.Console.shared.messages()
        DebugSwift.Console.shared.removeMessage(at: 0)
        DebugSwift.Console.shared.clear()
        DebugSwift.Console.shared.shareMessages()

        // Measurement
        DebugSwift.Measurement.activate()
        DebugSwift.Measurement.deactivate()
        DebugSwift.Measurement.toggle()
        let _: Bool = DebugSwift.Measurement.isActive

        // Network
        let network = DebugSwift.Network.shared
        network.ignoredURLs = ["a"]
        network.onlyURLs = []
        network.onlySchemes = [.http, .https]
        network.delegate = nil
        let _: EncryptionServiceProtocol = network.encryptionService
        network.isDecryptionEnabled = false
        network.redactCurlCredentials = true
        network.sanitizer = .default
        network.threshold = 100
        network.enableRequestTracking()
        network.disableRequestTracking()
        network.setThreshold(10, timeWindow: 60)
        network.setThresholdAlert(emoji: "⚠️", message: "m")
        network.setRequestBlocking(false)
        network.setEndpointThreshold("e", limit: 1, timeWindow: 1)
        let _: Int = network.getCurrentRequestCount(endpoint: nil)
        let snapshot: DebugSwiftThresholdSnapshot = network.getThresholdSnapshot()
        let _: [DebugSwiftThresholdEndpointSnapshot] = snapshot.endpointLimits
        let _: [DebugSwiftThresholdBreachSnapshot] = snapshot.recentBreaches
        let breaches: [NetworkThresholdTracker.ThresholdBreach] = network.getBreachHistory()
        _ = breaches.first?.message
        network.clearThresholdHistory()
        let _: String = network.getThresholdLogs()
        network.exportThresholdLogs()
        network.enableRequestDelay(1, urlPatterns: [], httpMethods: [])
        network.enableRequestDelay(min: 1, max: 2, urlPatterns: [], httpMethods: [])
        network.disableRequestDelay()
        network.enableFailureInjection(failureRate: 0.5, failureType: .timeout, urlPatterns: [], httpMethods: [])
        network.enableHTTPErrorInjection(failureRate: 0.5, statusCodes: [500], urlPatterns: [], httpMethods: [])
        network.disableFailureInjection()
        network.configureNetworkInjection(delayConfig: nil, failureConfig: nil, rewriteConfig: nil)
        network.enableResponseBodyRewrite(rules: [ResponseBodyRewriteRule(urlPattern: "a", responseBody: "b")])
        network.disableResponseBodyRewrite()
        let _: String = network.networkInjectionSettingsJSON()
        let _: Bool = network.applyNetworkInjectionSettingsJSON("{}")
        let _: String = network.responseRewriteRulesCSV()
        let _: String = network.importResponseRewriteRulesCSV("")
        network.shareResponseRewriteRulesCSV()
        network.clearNetworkHistory()
        network.clearWebSocketHistory()
        network.clearAllNetworkData()
        let _: Bool = network.logRequest(url: URL(string: "https://example.com")!, method: "GET")
        DebugSwift.Network.configureSessionHistory(retentionDays: 7, batchSize: 1)
        network.setDecryptionEnabled(false)
        network.registerDecryptionKey(for: "a", key: Data())
        let _: [String] = network.registeredDecryptionKeyPatterns
        network.clearDecryptionKeys()
        network.registerCustomDecryptor(for: "a") { $0 }
        network.setEncryptionService(network.encryptionService)
        let configuration = URLSessionConfiguration.default
        network.injectIntoConfiguration(configuration)
        let _: URLSessionConfiguration = network.defaultConfiguration()
        let _: URLSessionConfiguration = network.ephemeralConfiguration()

        // Resources
        let resources = DebugSwift.Resources.shared
        resources.appGroupIdentifiers = []
        resources.configureAppGroups(["a"])
        resources.addAppGroup("b")
        resources.removeAppGroup("b")
        let _: [(identifier: String, url: URL)] = resources.getAccessibleAppGroups()

        // Performance
        DebugSwift.Performance.Chart.setTimeWindow(seconds: 60)
        DebugSwift.Performance.Chart.setTimeWindow(minutes: 1)
        let leakDetector = DebugSwift.Performance.shared.leakDetector
        leakDetector.onDetect(detectionDelay: 1) { leak in _ = leak.message }
        leakDetector.ignoredWindowClassNames = []
        leakDetector.ignoredViewControllerClassNames = []
        leakDetector.ignoredViewClassNames = []
        DebugSwift.Performance.ThreadChecker.enable()
        DebugSwift.Performance.ThreadChecker.disable()
        DebugSwift.Performance.ThreadChecker.enableAutoFix()
        DebugSwift.Performance.ThreadChecker.setShowVisualAlerts(false)
        DebugSwift.Performance.ThreadChecker.setLogToConsole(false)
        DebugSwift.Performance.ThreadChecker.ignoreClass("a")
        DebugSwift.Performance.ThreadChecker.unignoreClass("a")
        DebugSwift.Performance.ThreadChecker.setIgnoredClasses([])
        DebugSwift.Performance.ThreadChecker.clearViolations()
        DebugSwift.Performance.SuperCallChecker.onDetect { violation in _ = violation.message }
        let _: [SuperCallViolation] = DebugSwift.Performance.SuperCallChecker.violations
        DebugSwift.Performance.SuperCallChecker.ignoreClass("a")
        DebugSwift.Performance.SuperCallChecker.setIgnoredClasses([])
        DebugSwift.Performance.SuperCallChecker.clearViolations()
        let capture: CapturedBacktrace = DebugSwift.Performance.Backtrace.capture(label: "a")
        let _: [BacktraceFrame] = capture.frames
        let _: [CapturedBacktrace] = DebugSwift.Performance.Backtrace.captured
        DebugSwift.Performance.Backtrace.onCapture { _ in }
        DebugSwift.Performance.Backtrace.clear()
        DebugSwift.Performance.shared.isBatteryMonitoringEnabled = true
        DebugSwift.Performance.shared.onLeakDetected { data in _ = data.message }
        let _: [DebugSwift.Performance.AutoFixMode] = DebugSwift.Performance.AutoFixMode.allCases
        let _: [DebugSwift.Performance.ThreadViolation.Severity] = DebugSwift.Performance.ThreadViolation.Severity.allCases

        // Push notifications and the push token
        DebugSwift.PushNotification.enableSimulation()
        DebugSwift.PushNotification.disableSimulation()
        let _: Bool = DebugSwift.PushNotification.isEnabled
        DebugSwift.PushNotification.simulate(title: "t", body: "b", delay: 0)
        DebugSwift.PushNotification.simulate(title: "t", body: "b", subtitle: nil, badge: nil, sound: nil, userInfo: [:], delay: 0)
        DebugSwift.PushNotification.simulateFromTemplate("Message", delay: 0)
        DebugSwift.PushNotification.simulateInteraction(identifier: "a")
        DebugSwift.PushNotification.simulateForegroundNotification(identifier: "a")
        DebugSwift.PushNotification.simulateBackgroundNotification(identifier: "a")
        DebugSwift.PushNotification.addTemplate(NotificationTemplate(name: "n", title: "t", body: "b"))
        DebugSwift.PushNotification.removeTemplate(id: "a")
        let _: [NotificationTemplate] = DebugSwift.PushNotification.templates
        let _: [SimulatedNotification] = DebugSwift.PushNotification.history
        DebugSwift.PushNotification.clearHistory()
        DebugSwift.PushNotification.removeNotification(id: "a")
        DebugSwift.PushNotification.updateConfiguration(NotificationConfiguration.default)
        let _: NotificationConfiguration = DebugSwift.PushNotification.configuration
        DebugSwift.PushNotification.runTestScenario(.messageFlow)
        DebugSwift.PushNotification.runTestScenario(.customFlow([SimulatedNotification(title: "t", body: "b")]))
        DebugSwift.PushNotification.simulateMessage(from: "a", message: "b")
        DebugSwift.PushNotification.simulateReminder("a", in: 0)
        DebugSwift.PushNotification.simulateNews(headline: "a", category: "b")
        DebugSwift.PushNotification.simulateMarketing(title: "a", offer: "b", discount: nil)
        DebugSwift.APNSToken.didRegister(deviceToken: Data())
        DebugSwift.APNSToken.didFailToRegister(error: URLError(.badURL))
        DebugSwift.APNSToken.willRequestPermissions()
        DebugSwift.APNSToken.didDenyPermissions()
        let _: String? = DebugSwift.APNSToken.deviceToken
        let _: APNSTokenManager.RegistrationState = DebugSwift.APNSToken.registrationState
        let _: APNSTokenManager.APNSEnvironment = DebugSwift.APNSToken.environment
        let _: Bool = DebugSwift.APNSToken.copyToClipboard()
        await DebugSwift.APNSToken.refreshStatus()

        // WebSocket, web views and render tracking
        DebugSwift.WebSocket.enableMonitoring()
        DebugSwift.WebSocket.disableMonitoring()
        let _: Bool = DebugSwift.WebSocket.isMonitoringEnabled
        let _: Int = DebugSwift.WebSocket.activeConnectionCount
        let _: Int = DebugSwift.WebSocket.totalUnreadFrames
        DebugSwift.WebSocket.clearAllData()
        DebugSwift.WebSocket.clearFrames(for: URL(string: "wss://example.com")!)
        let webView = DebugSwift.WKWebView.shared
        webView.isEnabled = true
        webView.captureRequestBodies = true
        webView.captureResponseHeaders = true
        webView.maxStoredRequests = 100
        webView.enable()
        webView.disable()
        webView.install()
        let _: [String: Any] = webView.getConfiguration()
        webView.resetToDefaults()
        let render = DebugSwift.SwiftUIRender.shared
        render.isEnabled = true
        render.overlayStyle = .border
        render.overlayDuration = 1
        render.loggingEnabled = false
        render.persistentOverlays = false
        render.clearPersistentOverlays()
        render.cleanupOrphanedOverlays()
        let _: [String: Any] = render.getRenderStats()
        render.clearStats()

        #if os(iOS)
        // UIKit, Core Data and SwiftData types: iOS only.
        let _ = DebugSwift.debugViewController()
        let _ = DebugSwift.debugFeatureViewController(for: .network)
        DebugSwift.App.shared.customControllers = { [] }
        resources.coreDataReadOnly = true
        #else
        // Their Android counterparts.
        DebugSwift.App.shared.customTools = { [] }
        resources.registerDatabase(named: "app_database")
        resources.registerPreferences(named: "user_preferences")
        DebugSwift.APNSToken.didRegister(token: "fcm-token")
        #endif
    }
}
