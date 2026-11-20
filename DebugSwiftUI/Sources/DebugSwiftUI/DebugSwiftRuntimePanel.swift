import SwiftUI
#if os(iOS)
import DebugSwift
#endif

/// The panel `DebugSwiftRuntime.panel(onDone:)` returns: `DebugPanel` with the content given to
/// `DebugSwiftRuntime.install`. On iOS it tells the debugger it is on screen, which hides the
/// floating ball while it is open.
struct DebugSwiftRuntimePanel: View {
    let onDone: (@MainActor () -> Void)?

    var body: some View {
        DebugPanel(
            title: DebugSwiftRuntime.panelTitle,
            tools: DebugSwiftRuntime.panelTools,
            actions: DebugSwiftRuntime.panelActions,
            info: DebugSwiftRuntime.panelInfo,
            // Captured requests are listed under Network → HTTP Inspector on both platforms.
            showsNetworkInspector: false,
            onDone: onDone
        )
        #if os(iOS)
        .onAppear { DebugSwift.debugViewControllerWillPresent() }
        .onDisappear { DebugSwift.debugViewControllerDidDismiss() }
        #endif
    }
}
