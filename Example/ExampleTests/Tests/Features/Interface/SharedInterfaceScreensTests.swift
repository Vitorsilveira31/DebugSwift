//
//  SharedInterfaceScreensTests.swift
//  ExampleTests
//

@_spi(DebugSwiftUI) @testable import DebugSwift
@testable import DebugSwiftUI
import Foundation
import Testing
import UIKit

/// The shared SwiftUI Interface screens read the same operations on iOS as on Android. These check
/// that DebugSwift's iOS answers decode into the models the screens use.
@MainActor
@Suite(.serialized)
struct SharedInterfaceScreensTests {
    @Test("SwiftUI render tracking turns on, counts renders by view type, and clears")
    func renderTracking() async throws {
        SharedPanelData.prepare()
        let tracker = SwiftUIRenderTracker.shared
        let wasEnabled = tracker.isEnabled
        let previousStyle = tracker.overlayStyle
        defer {
            UserInterfaceToolkit.shared.swiftUIRenderTrackingEnabled = wasEnabled
            tracker.overlayStyle = previousStyle
            tracker.clearStats()
        }
        _ = DebugSwiftRuntime.perform(featureID: "swiftui_render", actionID: "tracking", value: "true")
        _ = DebugSwiftRuntime.perform(featureID: "swiftui_render", actionID: "style", value: "none")
        _ = DebugSwiftRuntime.perform(featureID: "swiftui_render", actionID: "clear")
        #expect(DebugSwiftRuntime.perform(featureID: "swiftui_render", actionID: "style", value: "sparkles").contains("Unknown"))

        let first = UIView()
        let second = UIView()
        tracker.trackRender(for: first, viewType: "CardView")
        tracker.trackRender(for: first, viewType: "CardView")
        tracker.trackRender(for: second, viewType: "CardView")
        tracker.trackRender(for: second, viewType: "RowView")

        var state = try DebugResourceClient.fetch("app.compose.state", as: DebugComposeState.self).get()
        #expect(state.tracking == true)
        #expect(state.style == "none")
        #expect(state.total == 4)
        #expect(state.recomposers == 3)
        #expect(state.views?.first?.name == "CardView")
        #expect(state.views?.first?.count == 3)
        #expect(state.views?.last?.name == "RowView")

        // Only renders counted by `.trackRenders()` are probe renders, not every hosting view.
        let probesBefore = state.probeRenders
        NotificationCenter.default.post(name: .swiftUIViewDidRender, object: ["viewName": "Probe", "renderCount": 1])
        try await Task.sleep(nanoseconds: 100_000_000)
        state = try DebugResourceClient.fetch("app.compose.state", as: DebugComposeState.self).get()
        #expect(state.probeRenders == probesBefore + 1)

        _ = DebugSwiftRuntime.perform(featureID: "swiftui_render", actionID: "clear")
        state = try DebugResourceClient.fetch("app.compose.state", as: DebugComposeState.self).get()
        #expect(state.total == 0)
        #expect(state.views?.isEmpty == true)

        _ = DebugSwiftRuntime.perform(featureID: "swiftui_render", actionID: "tracking", value: "false")
        tracker.trackRender(for: first, viewType: "CardView")
        state = try DebugResourceClient.fetch("app.compose.state", as: DebugComposeState.self).get()
        #expect(state.tracking == false)
        #expect(state.total == 0)
    }

    @Test("Render tracking leaves out the shared panel's own views")
    func renderTrackingSkipsThePanel() throws {
        let window = try #require(SharedPanelInterface.appWindow())
        let tracker = SwiftUIRenderTracker.shared
        let wasEnabled = tracker.isEnabled
        let previousStyle = tracker.overlayStyle
        tracker.isEnabled = true
        tracker.overlayStyle = .none
        tracker.clearStats()
        let container = UIView(frame: window.bounds)
        container.addSubview(SharedPanelData.makePanelMarker())
        let panelView = UIView()
        container.addSubview(panelView)
        window.addSubview(container)
        let appView = UIView()
        window.rootViewController?.view.addSubview(appView)
        defer {
            container.removeFromSuperview()
            appView.removeFromSuperview()
            tracker.clearStats()
            tracker.isEnabled = wasEnabled
            tracker.overlayStyle = previousStyle
        }
        tracker.trackRender(for: panelView, viewType: "PanelView")
        tracker.trackRender(for: appView, viewType: "AppView")
        let counts = tracker.getRenderStats()["renderCounts"] as? [String: Int] ?? [:]
        #expect(counts.keys.contains { $0.hasPrefix("AppView_") })
        #expect(!counts.keys.contains { $0.hasPrefix("PanelView_") })
    }

    @Test("A late render sample spreads its renders over the seconds it covers")
    func renderSampling() {
        let interface = SharedPanelInterface.shared
        _ = DebugSwiftRuntime.perform(featureID: "swiftui_render", actionID: "clear")
        defer { _ = DebugSwiftRuntime.perform(featureID: "swiftui_render", actionID: "clear") }
        let start = Date()
        interface.record(total: 0, at: start)
        interface.record(total: 10, at: start.addingTimeInterval(1))
        // Three seconds without a firing, as while a drag held the run loop.
        interface.record(total: 40, at: start.addingTimeInterval(4))
        #expect(Array(interface.renderHistory.suffix(4)) == [10, 10, 10, 10])
        interface.record(total: 45, at: start.addingTimeInterval(6))
        #expect(Array(interface.renderHistory.suffix(2)) == [3, 2])
    }

    @Test("The documentation recorder keeps taps and scrolls only while on, and saves an annotated screenshot")
    func documentationRecorder() async throws {
        let recorder = SharedPanelInterface.shared
        _ = DebugPerformanceDetail.act("app.doc.clear")
        defer {
            _ = DebugPerformanceDetail.act("app.doc.record", ["on": "false"])
            _ = DebugPerformanceDetail.act("app.doc.clear")
        }
        recorder.recordTouch(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 10))
        _ = DebugPerformanceDetail.act("app.doc.record", ["on": "true"])
        recorder.recordTouch(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 103, y: 202))
        recorder.recordTouch(from: CGPoint(x: 150, y: 500), to: CGPoint(x: 150, y: 300))

        var state = try DebugResourceClient.fetch("app.doc.state", as: DebugDocState.self).get()
        #expect(state.recording)
        #expect(state.density == 1)
        #expect(state.gestures.map(\.kind) == ["tap", "scroll"])
        #expect(state.gestures.last?.startY == 500)
        #expect(state.gestures.last?.endY == 300)
        #expect(DebugDocRecorderView().describe(state.gestures[0], density: state.density) == "Tap at (103, 202) pt")

        let message = DebugPerformanceDetail.act("app.doc.capture")
        #expect(message.contains("Screenshot saved"))
        state = try DebugResourceClient.fetch("app.doc.state", as: DebugDocState.self).get()
        let image = try #require(UIImage(contentsOfFile: state.screenshot)?.cgImage)
        let window = try #require(SharedPanelInterface.appWindow())
        #expect(CGFloat(image.width) == window.bounds.width * window.screen.scale)

        let saved = state.screenshot
        _ = DebugPerformanceDetail.act("app.doc.clear")
        #expect(!FileManager.default.fileExists(atPath: saved))
        state = try DebugResourceClient.fetch("app.doc.state", as: DebugDocState.self).get()
        #expect(state.gestures.isEmpty)
        #expect(state.screenshot.isEmpty)
        #expect(DebugSwiftRuntime.perform(featureID: "doc_recorder", actionID: "export") == "Capture a screenshot first.")
    }

    @Test("A capture numbers the last 24 gestures as the recorder's list does")
    func gestureNumbers() {
        let recorder = SharedPanelInterface.shared
        _ = DebugPerformanceDetail.act("app.doc.clear")
        _ = DebugPerformanceDetail.act("app.doc.record", ["on": "true"])
        defer {
            _ = DebugPerformanceDetail.act("app.doc.record", ["on": "false"])
            _ = DebugPerformanceDetail.act("app.doc.clear")
        }
        for index in 0..<30 {
            recorder.recordTouch(from: CGPoint(x: index, y: 0), to: CGPoint(x: index, y: 0))
        }
        let marks = recorder.annotatedGestures(in: nil)
        #expect(marks.count == 24)
        #expect(marks.first?.number == 7)
        #expect(marks.first?.gesture.end.x == 6)
    }

    @Test("A capture of a window draws only the gestures made in it, with their list numbers")
    func gesturesPerWindow() {
        let recorder = SharedPanelInterface.shared
        _ = DebugPerformanceDetail.act("app.doc.clear")
        _ = DebugPerformanceDetail.act("app.doc.record", ["on": "true"])
        defer {
            _ = DebugPerformanceDetail.act("app.doc.record", ["on": "false"])
            _ = DebugPerformanceDetail.act("app.doc.clear")
        }
        let (first, second) = (UIWindow(), UIWindow())
        recorder.recordTouch(from: .zero, to: .zero, in: ObjectIdentifier(first))
        recorder.recordTouch(from: .zero, to: .zero, in: ObjectIdentifier(second))
        recorder.recordTouch(from: .zero, to: .zero, in: ObjectIdentifier(first))
        #expect(recorder.annotatedGestures(in: ObjectIdentifier(first)).map(\.number) == [1, 3])
        #expect(recorder.annotatedGestures(in: ObjectIdentifier(second)).map(\.number) == [2])
    }

    @Test("A window class of the app named like DebugSwift's is still the app's")
    func hostWindowNamedCustomWindow() {
        #expect(SharedPanelInterface.isAppWindow(HostApp.CustomWindow()))
        #expect(!SharedPanelInterface.isAppWindow(CustomWindow()))
    }

    @Test("Turning tracking off in the panel stops it when the host turned it on through the API")
    func trackingSwitchAfterHostAPI() {
        let tracker = SwiftUIRenderTracker.shared
        let wasEnabled = tracker.isEnabled
        let toolkitWasEnabled = UserInterfaceToolkit.shared.swiftUIRenderTrackingEnabled
        defer {
            UserInterfaceToolkit.shared.swiftUIRenderTrackingEnabled = toolkitWasEnabled
            tracker.isEnabled = wasEnabled
        }
        UserInterfaceToolkit.shared.swiftUIRenderTrackingEnabled = false
        DebugSwift.SwiftUIRender.shared.isEnabled = true
        _ = DebugSwiftRuntime.perform(featureID: "swiftui_render", actionID: "tracking", value: "false")
        #expect(!tracker.isEnabled)
    }

    @Test("A reset made outside the panel restarts the render count")
    func renderResetFromOutside() {
        let interface = SharedPanelInterface.shared
        let tracker = SwiftUIRenderTracker.shared
        let wasEnabled = tracker.isEnabled
        let previousStyle = tracker.overlayStyle
        tracker.isEnabled = true
        tracker.overlayStyle = .none
        _ = DebugSwiftRuntime.perform(featureID: "swiftui_render", actionID: "clear")
        defer {
            _ = DebugSwiftRuntime.perform(featureID: "swiftui_render", actionID: "clear")
            tracker.isEnabled = wasEnabled
            tracker.overlayStyle = previousStyle
        }
        let start = Date()
        interface.sample(now: start)
        let views = (0..<3).map { _ in UIView() }
        views.forEach { tracker.trackRender(for: $0, viewType: "Counted") }
        interface.sample(now: start.addingTimeInterval(1))
        #expect(interface.renderHistory.last == 3)
        tracker.clearStats()
        views.prefix(2).forEach { tracker.trackRender(for: $0, viewType: "Counted") }
        interface.sample(now: start.addingTimeInterval(2))
        #expect(interface.renderHistory.last == 2)
    }

    @Test("Every marker on a capture is red, not only the first")
    func markerColors() throws {
        let marks = [
            SharedPanelInterface.Gesture(kind: "tap", start: CGPoint(x: 20, y: 20), end: CGPoint(x: 20, y: 20)),
            SharedPanelInterface.Gesture(kind: "tap", start: CGPoint(x: 70, y: 70), end: CGPoint(x: 70, y: 70))
        ]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            SharedPanelInterface.annotate(context.cgContext, marks.enumerated().map { (gesture: $0.element, number: $0.offset + 1) })
        }
        let cgImage = try #require(image.cgImage)
        // The context draws into the buffer only inside this closure, where the pointer is valid.
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let bitmap = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // A point inside the second dot, clear of its label.
            bitmap.draw(cgImage, in: CGRect(x: -70, y: -(100 - 79), width: 100, height: 100))
            return true
        }
        #expect(drawn)
        #expect(pixel[0] > 200)
        #expect(pixel[1] < 120)
        #expect(pixel[2] < 120)
    }

    @Test("Captures leave out the shared panel when it is presented in the app's window")
    func capturesSkipThePanel() throws {
        let window = try #require(SharedPanelInterface.appWindow())
        // A sheet puts the panel in a container of its own, a direct subview of the app's window.
        let container = UIView(frame: window.bounds)
        container.backgroundColor = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        container.addSubview(SharedPanelData.makePanelMarker())
        window.addSubview(container)
        defer { container.removeFromSuperview() }

        #expect(SharedPanelInterface.panelContainers(in: window) == [container])
        // Touches on the panel are not the app's.
        let button = UIView()
        container.addSubview(button)
        let panels = SharedPanelInterface.panelContainers(in: window)
        #expect(!SharedPanelInterface.isAppTouch(on: button, panels: panels))
        #expect(SharedPanelInterface.isAppTouch(on: window.rootViewController?.view, panels: panels))
        let result = try DebugResourceClient.fetch("app.ui.palette", as: DebugPaletteResult.self).get()
        let red = result.colors.first { $0.hex == "#FF0000" }?.percent ?? 0
        #expect(red < 50)
        #expect(!container.isHidden)
    }

    @Test("The palette ranks colors by share, merges close shades into them, and skips see-through pixels")
    func paletteRanking() {
        func pixels(_ color: (UInt8, UInt8, UInt8, UInt8), _ count: Int) -> [UInt8] {
            Array(repeating: [color.0, color.1, color.2, color.3], count: count).flatMap { $0 }
        }
        // (235, 10, 10) falls in another bucket but is too close to red to be listed.
        let rgba = pixels((255, 0, 0, 255), 60) + pixels((235, 10, 10, 255), 15)
            + pixels((0, 0, 255, 255), 25) + pixels((0, 255, 0, 10), 50)
        let colors = SharedPanelInterface.dominantColors(rgba)
        #expect(colors.count == 2)
        #expect(colors.first?["hex"] as? String == "#FF0000")
        // The close shade counts toward red.
        #expect(colors.first?["percent"] as? Double == 75)
        #expect(colors.last?["hex"] as? String == "#0000FF")
        #expect(colors.last?["percent"] as? Double == 25)

        // Two blue shades together cover more than red, so blue comes first.
        let shades = pixels((255, 0, 0, 255), 40) + pixels((0, 0, 255, 255), 35) + pixels((10, 10, 235, 255), 25)
        let ranked = SharedPanelInterface.dominantColors(shades)
        #expect(ranked.first?["hex"] as? String == "#0000FF")
        #expect(ranked.first?["percent"] as? Double == 60)
    }

    @Test("The palette reads the app's window")
    func paletteFromScreen() throws {
        let result = try DebugResourceClient.fetch("app.ui.palette", as: DebugPaletteResult.self).get()
        #expect(result.source == "screen")
        #expect(!result.colors.isEmpty)
        #expect(result.colors.allSatisfy { $0.hex.count == 7 && $0.hex.hasPrefix("#") })
    }

    @Test("The view hierarchy lists the app's views with their frames and text, without the panel")
    func viewHierarchy() throws {
        let window = try #require(SharedPanelInterface.appWindow())
        let root = try #require(window.rootViewController?.view)
        let label = UILabel(frame: CGRect(x: 10, y: 20, width: 120, height: 30))
        label.text = "tree-probe-text"
        label.accessibilityIdentifier = "tree-probe"
        root.addSubview(label)
        let panel = UIView(frame: window.bounds)
        panel.addSubview(SharedPanelData.makePanelMarker())
        let hidden = UILabel()
        hidden.text = "panel-only-text"
        panel.addSubview(hidden)
        window.addSubview(panel)
        defer {
            label.removeFromSuperview()
            panel.removeFromSuperview()
        }

        let tree = try DebugResourceClient.fetch("app.ui.tree", as: DebugViewTree.self).get()
        #expect(tree.windowWidth == Int(window.bounds.width))
        #expect(tree.dp(12) == "12 pt")
        func all(_ node: DebugViewNode) -> [DebugViewNode] { [node] + node.children.flatMap(all) }
        let nodes = all(tree.root)
        let probe = try #require(nodes.first { $0.resourceId == "tree-probe" })
        #expect(probe.text == "tree-probe-text")
        #expect(probe.kind == "uikit")
        let origin = root.convert(CGPoint(x: 10, y: 20), to: window)
        #expect(probe.left == Int(origin.x.rounded()) && probe.top == Int(origin.y.rounded()))
        #expect(probe.width == 120 && probe.height == 30)
        #expect(!nodes.contains { $0.text == "panel-only-text" })

        // A highlight is drawn over the app and goes when cleared.
        let reply = try DebugResourceClient.fetch("app.ui.highlight", ["rects": "10,20,130,50"], as: DebugActionReply.self).get()
        #expect(reply.message == nil)
        #expect(window.subviews.contains { $0.accessibilityIdentifier == "DebugSwiftHighlight" })
        #expect(!all(try DebugResourceClient.fetch("app.ui.tree", as: DebugViewTree.self).get().root).contains { $0.className == "UIView" && $0.resourceId == "DebugSwiftHighlight" })
        _ = try DebugResourceClient.fetch("app.ui.clearHighlight", as: DebugActionReply.self).get()
        #expect(!window.subviews.contains { $0.accessibilityIdentifier == "DebugSwiftHighlight" })
    }

    @Test("The three tools are listed for the shared panel, and the UIKit entry point points there")
    func listing() {
        let ids = DebugSwift.availableInterfaceFeatureIDs()
        #expect(ids.first == "view_hierarchy")
        #expect(ids.contains("doc_recorder"))
        #expect(ids.contains("color_palette"))
        for id in ["swiftui_render", "doc_recorder", "color_palette"] {
            let navigation = DebugSwift.debugInterfaceViewController(for: id) as? UINavigationController
            #expect(navigation?.viewControllers.first is SharedPanelOnlyViewController)
        }
        #expect(DebugSwift.debugInterfaceViewController(for: "grid") == nil)
    }
}

/// A host app's own window class that shares a name with DebugSwift's.
enum HostApp {
    final class CustomWindow: UIWindow {}
}
