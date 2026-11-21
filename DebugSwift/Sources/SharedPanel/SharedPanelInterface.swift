//
//  SharedPanelInterface.swift
//  DebugSwift
//

import UIKit

/// iOS answers for the shared Interface screens: SwiftUI render tracking (`app.compose.state`, the
/// operation Android's Compose screen reads), the documentation recorder (`app.doc.*`) and the
/// color palette (`app.ui.palette`).
@MainActor
final class SharedPanelInterface {
    static let shared = SharedPanelInterface()

    private init() {}

    /// Starts counting renders of views marked with `.trackRenders()`, so the count covers the
    /// whole session rather than only the time the screen is open.
    func prepare() {
        guard probeObserver == nil else { return }
        probeObserver = NotificationCenter.default.addObserver(forName: .swiftUIViewDidRender, object: nil, queue: .main) { note in
            // The tracker posts this for every hosting view it counts; only the modifier sends a view name.
            guard (note.object as? [String: Any])?["viewName"] != nil else { return }
            MainActor.assumeIsolated { SharedPanelInterface.shared.probeRenders += 1 }
        }
    }

    func resource(_ operation: String, _ arguments: [String: String]) -> [String: Any]? {
        switch operation {
        case "app.compose.state":
            return renderState()
        case "app.doc.state":
            return documentationState()
        case "app.doc.record":
            setRecording(arguments["on"] == "true")
            return [:]
        case "app.doc.capture":
            return ["message": captureDocumentation()]
        case "app.doc.clear":
            gestures.removeAll()
            // The screenshot is ours: remove it, or Clear would leave it in tmp for good.
            if !screenshotPath.isEmpty { try? FileManager.default.removeItem(atPath: screenshotPath) }
            screenshotPath = ""
            captureMessage = ""
            return [:]
        case "app.ui.palette":
            return palette()
        case "app.ui.tree":
            return viewTree()
        case "app.ui.highlight":
            return ["count": highlight(arguments["rects"] ?? "")]
        case "app.ui.clearHighlight":
            clearHighlight()
            return [:]
        default:
            return nil
        }
    }

    func perform(featureID: String, actionID: String, value: String) -> String? {
        let tracker = SwiftUIRenderTracker.shared
        switch (featureID, actionID) {
        case ("swiftui_render", "tracking"):
            // Both: the host may have switched the tracker through `DebugSwift.SwiftUIRender`,
            // which leaves the toolkit's flag as it was.
            UserInterfaceToolkit.shared.swiftUIRenderTrackingEnabled = value == "true"
            tracker.isEnabled = value == "true"
            return value == "true" ? "Render tracking on." : "Render tracking off."
        case ("swiftui_render", "persistent"):
            tracker.persistentOverlays = value == "true"
            return value == "true" ? "Borders stay on screen." : "Borders fade out."
        case ("swiftui_render", "logging"):
            tracker.loggingEnabled = value == "true"
            return value == "true" ? "Renders are logged to the console." : "Console logging off."
        case ("swiftui_render", "style"):
            guard let style = Self.styles.first(where: { $0.name == value })?.style else { return "Unknown style: \(value)." }
            tracker.overlayStyle = style
            return "Style set."
        case ("swiftui_render", "clear"):
            tracker.clearStats()
            probeRenders = 0
            history.removeAll()
            lastTotal = 0
            lastSampleAt = Date()
            return "Render counts cleared."
        case ("doc_recorder", "export"):
            guard !screenshotPath.isEmpty, FileManager.default.fileExists(atPath: screenshotPath) else {
                return "Capture a screenshot first."
            }
            FileSharingManager.share(URL(fileURLWithPath: screenshotPath))
            return "Sharing the screenshot."
        default:
            return nil
        }
    }

    // MARK: - SwiftUI render tracking

    private static let styles: [(name: String, style: SwiftUIRenderTracker.RenderOverlayStyle)] = [
        ("border", .border), ("count", .borderWithCount), ("none", .none)
    ]
    private static let historyLength = 60

    private var probeObserver: NSObjectProtocol?
    private var probeRenders = 0
    private var history: [Int] = []
    private var lastTotal = 0
    private var lastSampleAt = Date()
    private var lastGeneration = 0
    private var sampler: Timer?

    private func renderState() -> [String: Any] {
        startSampling()
        let tracker = SwiftUIRenderTracker.shared
        let counts = tracker.getRenderStats()["renderCounts"] as? [String: Int] ?? [:]
        // The tracker keys each view as "Type_ObjectIdentifier"; group the counts by type.
        var byType: [String: Int] = [:]
        for (identifier, count) in counts {
            let type = identifier.range(of: "_", options: .backwards).map { String(identifier[..<$0.lowerBound]) } ?? identifier
            byType[type, default: 0] += count
        }
        let views = byType.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(20)
            .map { ["name": $0.key, "count": $0.value] }
        return [
            "total": counts.values.reduce(0, +),
            "recomposers": counts.count,
            "perSecond": history,
            "probeRenders": probeRenders,
            "frames": SharedPanelPerformance.shared.framesDrawn,
            "tracking": tracker.isEnabled,
            "persistent": tracker.persistentOverlays,
            "logging": tracker.loggingEnabled,
            "style": Self.styles.first { $0.style == tracker.overlayStyle }?.name ?? "count",
            "views": Array(views)
        ]
    }

    /// Samples the render total once a second, so the screen can draw renders per second.
    private func startSampling() {
        guard sampler == nil else { return }
        lastTotal = Self.totalRenders()
        lastSampleAt = Date()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { SharedPanelInterface.shared.sample() }
        }
        // Common modes keep it firing while a scroll or drag is tracked.
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }

    func sample(now: Date = Date()) {
        // A reset from outside the panel (`clearStats()`) restarts the count: the new total is
        // what was rendered since.
        let generation = SwiftUIRenderTracker.shared.resetGeneration
        if generation != lastGeneration {
            lastGeneration = generation
            lastTotal = 0
        }
        record(total: Self.totalRenders(), at: now)
    }

    /// Adds one entry per second since the last sample: a late or skipped firing spreads its
    /// renders over the seconds it covers instead of counting them as one second.
    func record(total: Int, at now: Date) {
        let seconds = min(max(Int(now.timeIntervalSince(lastSampleAt).rounded()), 1), Self.historyLength)
        let delta = max(total - lastTotal, 0)
        for index in 0..<seconds {
            // Whole renders per second, the remainder going to the first seconds.
            history.append(delta / seconds + (index < delta % seconds ? 1 : 0))
        }
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        lastTotal = total
        lastSampleAt = now
    }

    /// The render history, for tests.
    var renderHistory: [Int] { history }

    private static func totalRenders() -> Int {
        (SwiftUIRenderTracker.shared.getRenderStats()["totalRenders"] as? Int) ?? 0
    }

    // MARK: - Documentation recorder

    struct Gesture {
        let kind: String
        let start: CGPoint
        let end: CGPoint
        /// The window the touch was in; its coordinates belong to that window only.
        var window: ObjectIdentifier? = nil
    }

    private static let gestureLimit = 200
    private static let annotatedLimit = 24
    /// A touch that moves less than this is a tap, as on Android (24 dp there).
    private static let scrollDistance: CGFloat = 24

    private(set) var isRecording = false
    private(set) var gestures: [Gesture] = []
    private var touchStarts: [ObjectIdentifier: CGPoint] = [:]
    private var screenshotPath = ""
    private var captureMessage = ""
    private static var swizzled = false

    func setRecording(_ on: Bool) {
        if on, !Self.swizzled, let original = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
           let replacement = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sharedPanel_sendEvent(_:))) {
            method_exchangeImplementations(original, replacement)
            Self.swizzled = true
        }
        isRecording = on
        touchStarts.removeAll()
    }

    /// Keeps the app's taps and scrolls; touches on DebugSwift's own windows are left out.
    func record(_ event: UIEvent, in window: UIWindow) {
        // Only this window's touches: an event can carry touches from other windows, in their coordinates.
        guard isRecording, event.type == .touches, Self.isAppWindow(window), let touches = event.touches(for: window) else { return }
        // Looked up only when a touch starts, so moves and ends cost nothing extra.
        let panels = touches.contains { $0.phase == .began } ? Self.panelContainers(in: window) : []
        for touch in touches {
            let key = ObjectIdentifier(touch)
            let point = touch.location(in: window)
            switch touch.phase {
            case .began:
                guard Self.isAppTouch(on: touch.view, panels: panels) else { continue }
                touchStarts[key] = point
            case .ended:
                guard let start = touchStarts.removeValue(forKey: key) else { continue }
                recordTouch(from: start, to: point, in: ObjectIdentifier(window))
            case .cancelled:
                touchStarts.removeValue(forKey: key)
            default:
                break
            }
        }
    }

    /// Whether a touch on this view belongs to the app: not to the shared panel, which a `.sheet`
    /// shows in the app's own window.
    static func isAppTouch(on view: UIView?, panels: [UIView]) -> Bool {
        guard let view else { return true }
        return !panels.contains { view.isDescendant(of: $0) }
    }

    /// Keeps one finished touch: a tap when it barely moved, a scroll otherwise.
    func recordTouch(from start: CGPoint, to end: CGPoint, in window: ObjectIdentifier? = nil) {
        guard isRecording else { return }
        let kind = hypot(end.x - start.x, end.y - start.y) >= Self.scrollDistance ? "scroll" : "tap"
        gestures.append(Gesture(kind: kind, start: start, end: end, window: window))
        if gestures.count > Self.gestureLimit { gestures.removeFirst(gestures.count - Self.gestureLimit) }
    }

    private func documentationState() -> [String: Any] {
        [
            "recording": isRecording,
            // Points on iOS: the screen describes them as they are.
            "density": 1.0,
            "gestures": gestures.map { gesture in
                [
                    "kind": gesture.kind,
                    "startX": Double(gesture.start.x), "startY": Double(gesture.start.y),
                    "endX": Double(gesture.end.x), "endY": Double(gesture.end.y)
                ]
            },
            "screenshot": screenshotPath,
            "message": captureMessage
        ]
    }

    /// Draws the app's window with the last gestures numbered on it and saves it as a PNG.
    private func captureDocumentation() -> String {
        // A failure is the result shown for this attempt; the last good screenshot stays available.
        guard let window = Self.appWindow() else {
            captureMessage = "No app window is available."
            return captureMessage
        }
        let marks = annotatedGestures(in: ObjectIdentifier(window))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            Self.drawApp(window, in: context.cgContext)
            Self.annotate(context.cgContext, marks)
        }
        guard let data = image.pngData() else {
            captureMessage = "The screenshot could not be encoded."
            return captureMessage
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("debugswift-screen-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        do {
            try data.write(to: url)
        } catch {
            captureMessage = "The screenshot could not be saved: \(error.localizedDescription)"
            return captureMessage
        }
        if !screenshotPath.isEmpty { try? FileManager.default.removeItem(atPath: screenshotPath) }
        screenshotPath = url.path
        captureMessage = "Screenshot saved to \(url.path)"
        return captureMessage
    }

    /// The gestures drawn on a capture of a window: the last 24 made in it, each with the number
    /// it has in the recorder's list.
    func annotatedGestures(in window: ObjectIdentifier?) -> [(gesture: Gesture, number: Int)] {
        let numbered = gestures.enumerated()
            .filter { $0.element.window == nil || $0.element.window == window }
            .map { (gesture: $0.element, number: $0.offset + 1) }
        return Array(numbered.suffix(Self.annotatedLimit))
    }

    /// Numbered dots for taps; a numbered dot and an arrow for scrolls, as on Android.
    static func annotate(_ context: CGContext, _ marks: [(gesture: Gesture, number: Int)]) {
        let radius: CGFloat = 11
        context.setStrokeColor(UIColor.systemRed.cgColor)
        context.setFillColor(UIColor.systemRed.cgColor)
        context.setLineWidth(2.5)
        context.setLineCap(.round)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 11),
            .foregroundColor: UIColor.white
        ]
        for (mark, number) in marks {
            let dot = mark.kind == "scroll" ? mark.start : mark.end
            if mark.kind == "scroll" {
                context.setStrokeColor(UIColor.systemRed.cgColor)
                let angle = atan2(mark.end.y - mark.start.y, mark.end.x - mark.start.x)
                let head: CGFloat = 12
                let spread = CGFloat.pi / 6
                context.move(to: mark.start)
                context.addLine(to: mark.end)
                context.move(to: mark.end)
                context.addLine(to: CGPoint(x: mark.end.x - head * cos(angle - spread), y: mark.end.y - head * sin(angle - spread)))
                context.move(to: mark.end)
                context.addLine(to: CGPoint(x: mark.end.x - head * cos(angle + spread), y: mark.end.y - head * sin(angle + spread)))
                context.strokePath()
            }
            // Drawing a label leaves the context's fill white, so set red again for each dot.
            context.setFillColor(UIColor.systemRed.cgColor)
            context.fillEllipse(in: CGRect(x: dot.x - radius, y: dot.y - radius, width: radius * 2, height: radius * 2))
            let label = NSAttributedString(string: "\(number)", attributes: attributes)
            let size = label.size()
            label.draw(at: CGPoint(x: dot.x - size.width / 2, y: dot.y - size.height / 2))
        }
    }

    // MARK: - Color palette

    private static let sampleWidth: CGFloat = 180
    private static let maxColors = 14

    /// The colors of the app's window by share of the screen, grouped and ranked as on Android.
    private func palette() -> [String: Any] {
        guard let window = Self.appWindow(), window.bounds.width > 0, window.bounds.height > 0 else {
            return ["error": "No app window is available."]
        }
        let scale = Self.sampleWidth / window.bounds.width
        let width = Int(Self.sampleWidth)
        let height = max(Int(window.bounds.height * scale), 1)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Flip to UIKit's top-left origin, then draw the window scaled down.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            UIGraphicsPushContext(context)
            Self.drawApp(window, in: context)
            UIGraphicsPopContext()
            return true
        }
        guard drawn else { return ["error": "The screen could not be read."] }
        return ["colors": Self.dominantColors(pixels), "source": "screen"]
    }

    /// Groups pixels by their top five bits per channel, averages each group and ranks by share.
    static func dominantColors(_ rgba: [UInt8]) -> [[String: Any]] {
        var sums: [Int: (red: Int, green: Int, blue: Int, count: Int)] = [:]
        var index = 0
        while index + 3 < rgba.count {
            defer { index += 4 }
            guard rgba[index + 3] >= 200 else { continue }
            let (red, green, blue) = (Int(rgba[index]), Int(rgba[index + 1]), Int(rgba[index + 2]))
            let key = (red >> 3) << 10 | (green >> 3) << 5 | (blue >> 3)
            let bucket = sums[key] ?? (0, 0, 0, 0)
            sums[key] = (bucket.red + red, bucket.green + green, bucket.blue + blue, bucket.count + 1)
        }
        let total = max(sums.values.reduce(0) { $0 + $1.count }, 1)
        var chosen: [(red: Int, green: Int, blue: Int, count: Int)] = []
        let ranked = sums.sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }
        for (_, bucket) in ranked {
            let color = (red: bucket.red / bucket.count, green: bucket.green / bucket.count, blue: bucket.blue / bucket.count, count: bucket.count)
            // A shade too close to a color already taken adds its pixels to that color, so the list
            // shows distinct colors and each one's share includes its shades.
            if let index = chosen.firstIndex(where: { taken in
                let (dr, dg, db) = (Double(taken.red - color.red), Double(taken.green - color.green), Double(taken.blue - color.blue))
                return (dr * dr + dg * dg + db * db).squareRoot() < 28
            }) {
                chosen[index].count += color.count
            } else if chosen.count < maxColors {
                chosen.append(color)
            }
        }
        // Merging can lift a color above one listed earlier: rank by the final shares.
        chosen.sort { $0.count > $1.count }
        return chosen.map { color in
            [
                "hex": String(format: "#%02X%02X%02X", color.red, color.green, color.blue),
                "red": color.red, "green": color.green, "blue": color.blue,
                "percent": Double(color.count) * 100 / Double(total)
            ]
        }
    }

    // MARK: - View hierarchy

    /// Android stops at the same size, so a huge screen stays quick to read on both.
    private static let treeLimit = 2500

    /// The app window's views as a tree, in window points, without the debugger's own views.
    private func viewTree() -> [String: Any] {
        guard let window = Self.appWindow() else { return ["error": "No app window is available."] }
        var budget = 0
        let root = Self.node(for: window, in: window, budget: &budget)
        return [
            "windowWidth": Int(window.bounds.width),
            "windowHeight": Int(window.bounds.height),
            // Points: the screen reports them as they are.
            "density": 1.0,
            "root": root,
            "truncated": budget >= Self.treeLimit
        ]
    }

    private static func node(for view: UIView, in window: UIWindow, budget: inout Int) -> [String: Any] {
        budget += 1
        let frame = view.convert(view.bounds, to: window)
        let className = NSStringFromClass(type(of: view))
        let name = className.split(separator: ".").last.map(String.init) ?? className
        var node: [String: Any] = [
            // Hosting views and SwiftUI's own platform views, told apart from plain UIKit ones.
            "kind": className.contains("SwiftUI") ? "swiftui" : "uikit",
            "name": name,
            "className": className,
            "resourceId": view.accessibilityIdentifier ?? "",
            "left": Int(frame.minX.rounded()),
            "top": Int(frame.minY.rounded()),
            "width": Int(frame.width.rounded()),
            "height": Int(frame.height.rounded()),
            "visible": !view.isHidden && view.alpha > 0.01,
            "alpha": Double(view.alpha),
            "clickable": view.isUserInteractionEnabled && (view is UIControl || !(view.gestureRecognizers ?? []).isEmpty),
            "enabled": (view as? UIControl)?.isEnabled ?? true
        ]
        if let text = Self.text(of: view), !text.isEmpty { node["text"] = text }
        if let label = view.accessibilityLabel, !label.isEmpty { node["description"] = label }
        var children: [[String: Any]] = []
        for child in view.subviews where budget < treeLimit && !isDebuggerView(child)
            && child.accessibilityIdentifier != "DebugSwiftHighlight" {
            children.append(Self.node(for: child, in: window, budget: &budget))
        }
        node["children"] = children
        return node
    }

    private static func text(of view: UIView) -> String? {
        switch view {
        case let label as UILabel: label.text
        case let button as UIButton: button.currentTitle
        case let field as UITextField: field.text
        case let textView as UITextView: textView.text
        default: nil
        }
    }

    private weak var highlightView: UIView?
    private var highlightRemoval: DispatchWorkItem?

    /// Boxes over the given elements of the app's window for five seconds, as on Android.
    /// `rects` is "left,top,right,bottom;…" in window points.
    private func highlight(_ rects: String) -> Int {
        clearHighlight()
        let frames: [CGRect] = rects.split(separator: ";").compactMap { entry in
            let values = entry.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard values.count == 4 else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1])
        }
        guard let window = Self.appWindow(), !frames.isEmpty else { return 0 }
        let overlay = UIView(frame: window.bounds)
        overlay.isUserInteractionEnabled = false
        overlay.accessibilityIdentifier = "DebugSwiftHighlight"
        for frame in frames {
            let box = UIView(frame: frame)
            box.backgroundColor = UIColor.systemRed.withAlphaComponent(0.2)
            box.layer.borderColor = UIColor.systemRed.cgColor
            box.layer.borderWidth = 3
            overlay.addSubview(box)
        }
        window.addSubview(overlay)
        highlightView = overlay
        let removal = DispatchWorkItem { [weak overlay] in overlay?.removeFromSuperview() }
        highlightRemoval = removal
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: removal)
        return frames.count
    }

    private func clearHighlight() {
        highlightRemoval?.cancel()
        highlightView?.removeFromSuperview()
    }

    // MARK: - Windows

    /// Draws the window without the shared panel. Presented as a sheet, the panel lives in the
    /// app's window, in a container of its own above the app; that container is hidden while drawing.
    static func drawApp(_ window: UIWindow, in context: CGContext) {
        let panels = panelContainers(in: window).filter { !$0.isHidden }
        panels.forEach { $0.isHidden = true }
        defer { panels.forEach { $0.isHidden = false } }
        if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: !panels.isEmpty) {
            window.layer.render(in: context)
        }
    }

    /// The window's direct subviews that hold the shared panel, other than the app's own root view.
    static func panelContainers(in window: UIWindow) -> [UIView] {
        var containers: [UIView] = []
        var pending: [UIView] = [window]
        while let view = pending.popLast() {
            if view is SharedPanelMarkerView {
                var top = view
                while let parent = top.superview, parent !== window { top = parent }
                if top.superview === window, top !== window.rootViewController?.view, !containers.contains(top) {
                    containers.append(top)
                }
            }
            pending.append(contentsOf: view.subviews)
        }
        return containers
    }

    /// DebugSwift's own windows (the debugger, the floating ball, overlays) are not the app.
    static func isAppWindow(_ window: UIWindow) -> Bool {
        // DebugSwift's own windows by type, and the system's keyboard windows by exact class name,
        // so an app window class that happens to share a name isn't mistaken for them.
        if window is CustomWindow || window is MeasurementWindow { return false }
        let name = NSStringFromClass(type(of: window))
        if name == "UITextEffectsWindow" || name == "UIRemoteKeyboardWindow" { return false }
        return window.windowLevel < .alert
    }

    /// Whether a view belongs to the debugger rather than the app: it is in one of DebugSwift's
    /// windows, or inside the container the shared panel occupies in the app's window. The render
    /// tracker leaves these out, so its statistics measure the app.
    static func isDebuggerView(_ view: UIView) -> Bool {
        guard let window = view.window else { return false }
        if !isAppWindow(window) { return true }
        for marker in SharedPanelMarkerView.all.allObjects where marker.window === window {
            var top: UIView = marker
            while let parent = top.superview, parent !== window { top = parent }
            if top !== window.rootViewController?.view, view.isDescendant(of: top) { return true }
        }
        return false
    }

    /// The app's window in the scene the user is using: the foreground active scene first, so a
    /// background scene's key window is never captured.
    static func appWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for state in [UIScene.ActivationState.foregroundActive, .foregroundInactive] {
            let windows = scenes.filter { $0.activationState == state }
                .flatMap(\.windows)
                .filter { !$0.isHidden && isAppWindow($0) }
            if let window = windows.first(where: \.isKeyWindow) ?? windows.first { return window }
        }
        return nil
    }
}

/// See `SharedPanelData.makePanelMarker()`.
final class SharedPanelMarkerView: UIView {
    /// The markers alive now, so the render tracker can find the panel without walking the window.
    static let all = NSHashTable<SharedPanelMarkerView>.weakObjects()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        Self.all.add(self)
    }

    required init?(coder: NSCoder) { nil }
}

extension UIWindow {
    /// Swapped with `sendEvent(_:)` while the documentation recorder has ever been on.
    @objc func sharedPanel_sendEvent(_ event: UIEvent) {
        MainActor.assumeIsolated { SharedPanelInterface.shared.record(event, in: self) }
        sharedPanel_sendEvent(event)
    }
}
