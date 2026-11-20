import SwiftUI
#if os(iOS)
import DebugSwift
#endif

/// The panel `DebugSwiftRuntime.panel(onDone:)` returns: `DebugPanel` with the content given to
/// `DebugSwiftRuntime.install`. On iOS it tells the debugger it is on screen, which hides the
/// floating ball while it is open.
struct DebugSwiftRuntimePanel: View {
    /// False when the debugger's own window shows the panel, which already hides the floating ball.
    var managesFloatingBall = true
    let onDone: (@MainActor () -> Void)?

    var body: some View {
        content
        #if os(iOS)
        .onAppear { if managesFloatingBall { DebugSwift.debugViewControllerWillPresent() } }
        .onDisappear { if managesFloatingBall { DebugSwift.debugViewControllerDidDismiss() } }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(Android)
        if let route = DebugSwiftPresentation.shared.route, let tool = DebugSwiftArea.tool(withID: route) {
            NavigationStack {
                DebugSwiftFeatureDestination(feature: tool)
                    .navigationTitle(tool.title)
                    .toolbar {
                        if let onDone {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { onDone() }
                            }
                        }
                    }
            }
        } else {
            panel
        }
        #else
        panel
        #endif
    }

    private var panel: DebugPanel {
        DebugPanel(
            title: DebugSwiftRuntime.panelTitle,
            tools: tools,
            actions: DebugSwiftRuntime.panelActions,
            info: DebugSwiftRuntime.panelInfo,
            // Captured requests are listed under Network → HTTP Inspector on both platforms.
            showsNetworkInspector: false,
            onDone: onDone
        )
    }

    private var tools: [DebugTool] {
        #if os(Android)
        DebugSwiftRuntime.panelTools + (DebugSwift.App.shared.customTools?() ?? [])
        #else
        DebugSwiftRuntime.panelTools
        #endif
    }
}

extension DebugSwiftRuntime {
    /// Closes the panel and shows the app's window taken apart into 3D layers. Android only; iOS
    /// has its own view debugger under Interface.
    @MainActor
    static func showViewDebugger3D() {
        #if os(Android)
        DebugSwiftPresentation.shared.dismiss()
        Task { @MainActor in
            // Let the panel's sheet leave the screen so the capture shows the app.
            try? await Task.sleep(nanoseconds: 700_000_000)
            DebugSwiftHost.call("interface.viewDebugger3D")
        }
        #endif
    }
}

extension DebugSwiftArea {
    /// The feature with this ID in any area, for opening it directly.
    @MainActor
    static func tool(withID id: String) -> DebugSwiftTool? {
        for area in allCases {
            if let tool = area.features.first(where: { $0.id == id }) { return tool }
        }
        return nil
    }
}

public extension View {
    /// Presents the debug panel over this view when the floating button, `DebugSwift.App.presentDebugger()`
    /// or `DebugSwift.Measurement.activate()` asks for it. Apply it to the app's root view.
    func debugSwiftPanel() -> some View {
        modifier(DebugSwiftPanelPresenter())
    }
}

struct DebugSwiftPanelPresenter: ViewModifier {
    #if os(Android)
    @State var presentation = DebugSwiftPresentation.shared
    #endif

    func body(content: Content) -> some View {
        #if os(Android)
        content
            .sheet(isPresented: $presentation.isPresented, onDismiss: { presentation.route = nil }) {
                DebugSwiftRuntime.panel { presentation.dismiss() }
            }
            .onAppear {
                presentation.isAttached = true
                DebugFloatingButton.onTap = { DebugSwiftPresentation.shared.present(route: nil) }
            }
            .onDisappear { presentation.isAttached = false }
        #else
        // iOS opens the debugger from its floating ball and `DebugSwift.App.presentDebugger()`.
        content
        #endif
    }
}
