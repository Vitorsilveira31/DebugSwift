//
//  FeatureHandling.swift
//  DebugSwift
//
//  Created by Mochamad Rakha Luthfi Fahsya on 24/01/24.
//

import CoreLocation
import UIKit

@MainActor
enum FeatureHandling {
    /// Whether the host (or the shared panel) ran a setup, so later code doesn't redo it and
    /// replace the host's hidden features and disabled methods.
    nonisolated(unsafe) static var isSetUp = false

    static var enabledBetaFeatures: [DebugSwiftBetaFeature] = []
    static var hiddenFeatures: [DebugSwiftFeature] = []

    static func setup(
        only featuresToShow: [DebugSwiftFeature] = DebugSwiftFeature.allCases
    ) {
        isSetUp = true
        hiddenFeatures = DebugSwiftFeature.allCases.filter { !featuresToShow.contains($0) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                DebugSwift.App.shared.defaultControllers.removeAll(where: { !featuresToShow.contains($0.controllerType) })
                installPanel()
            }
        }
    }

    static func setup(
        hide features: [DebugSwiftFeature],
        disable methods: [DebugSwiftSwizzleFeature],
        enableBeta betaFeatures: [DebugSwiftBetaFeature] = []
    ) {
        isSetUp = true
        setupBetaFeatures(betaFeatures)
        setupMethods(methods)
        hiddenFeatures = features

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                DebugSwift.App.shared.defaultControllers.removeAll(where: { features.contains($0.controllerType) })
                installPanel()
            }
        }
    }

    private static var isPanelInstalled = false

    /// Hands the floating ball the screen it opens: the host's `panelProvider`, or the UIKit tab bar.
    static func installPanel() {
        FloatViewManager.setup(DebugSwift.App.shared.panelProvider?() ?? TabBarController())
        isPanelInstalled = true
    }

    /// Rebuilds the panel after `panelProvider` changes. Before setup has run there is nothing to
    /// rebuild, and setup will read the provider itself; while the debugger is open the swap waits.
    static func reloadPanelIfInstalled() {
        guard isPanelInstalled else { return }
        guard !FloatViewManager.isShowingDebuggerView else {
            pendingPanelReload = true
            return
        }
        installPanel()
    }

    private static var pendingPanelReload = false

    /// Called before the debugger opens, to apply a provider set while it was last open.
    static func applyPendingPanelReload() {
        guard pendingPanelReload else { return }
        pendingPanelReload = false
        installPanel()
    }

    static func setupMethods(_ methodsToDisable: [DebugSwiftSwizzleFeature]) {
        DebugSwift.App.shared.disableMethods = methodsToDisable

        if !methodsToDisable.contains(.network) {
            enableNetwork()
        }

        if !methodsToDisable.contains(.webSocket) {
            enableWebSocket()
        }
        
        if !methodsToDisable.contains(.wkWebView) {
            enableWKWebView()
        }

        if !methodsToDisable.contains(.location) {
            enableLocation()
        }

        if !methodsToDisable.contains(.views) {
            enableUIView()
        }

        if !methodsToDisable.contains(.crashManager) {
            enableCrashManager()
        }

        if !methodsToDisable.contains(.leaksDetector) {
            enableLeaksDetector()
        }

        if !methodsToDisable.contains(.console) {
            enableConsole()
        }
        
        if !methodsToDisable.contains(.swiftUIRender) {
            enableSwiftUIRender()
        }

        if !methodsToDisable.contains(.orientationForwarding) {
            enableOrientationForwarding()
        }

        if !methodsToDisable.contains(.superCallDetector) {
            enableSuperCallDetector()
        }
    }

    private static func enableNetwork() {
        URLSessionConfiguration.swizzleMethods()
        NetworkHelper.shared.enable()
    }

    private static func enableWebSocket() {
        WebSocketMonitor.shared.enable()
    }
    
    private static func enableWKWebView() {
        Task { @MainActor in
            WKWebViewNetworkMonitor.shared.install()
        }
    }

    private static func enableCrashManager() {
        StderrCapture.shared.startCapturing()
        StderrCapture.shared.syncData()

        CrashManager.shared.register()
    }

    private static func enableUIView() {
        Task {
            UIView.swizzleMethods()
            UIWindow.db_swizzleMethods()
        }
    }

    private static func enableLocation() {
        CLLocationManager.swizzleMethods()
    }

    private static func enableLeaksDetector() {
        Task {
            UIViewController.lvcdSwizzleLifecycleMethods()
        }
    }

    private static func enableConsole() {
        StdoutCapture.shared.startCapturing()
    }
    
    private static func enableOrientationForwarding() {
        if #available(iOS 16.0, *) {
            UIWindowScene.db_swizzleRequestGeometryUpdate()
        }
        UIViewController.db_swizzleViewDidAppear()
    }

    private static func enableSuperCallDetector() {
        UIViewController.db_swizzleLifecycleForSuperCallDetection()
    }

    private static func enableSwiftUIRender() {
        // Only enable if beta features include SwiftUI render tracking
        guard enabledBetaFeatures.contains(.swiftUIRenderTracking) else { return }
        
        Task {
            UIView.enableSwiftUIRenderTracking()
        }
    }
    
    private static func setupBetaFeatures(_ betaFeatures: [DebugSwiftBetaFeature]) {
        enabledBetaFeatures = betaFeatures

        if betaFeatures.contains(.agentDebugLog) {
            AgentDebugLog.shared.enable()
        } else {
            AgentDebugLog.shared.disable()
        }

#if canImport(SwiftData)
        if #available(iOS 17.0, *) {
            Task { @MainActor in
                await NetworkSessionPersistenceManager.shared.applyFeatureEnabled(
                    betaFeatures.contains(.networkSessionPersistence)
                )
            }
        }
#endif
    }
}
