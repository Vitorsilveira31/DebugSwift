#if os(iOS)
import DebugSwift
import SwiftUI
import UIKit

/// Opt-in step towards one panel for both platforms: makes the iOS floating ball open the shared
/// SwiftUI `DebugPanel`, the same one Android shows, instead of the UIKit tab bar. Screens that
/// have not been rewritten in SwiftUI still open their UIKit implementation inside the panel.
///
///     DebugSwift().setup().show()
///     DebugSwiftSharedPanel.useForFloatingBall()
@MainActor
public enum DebugSwiftSharedPanel {
    /// Switches the floating ball to the shared panel. Call it after `DebugSwift().setup()`.
    public static func useForFloatingBall(
        title: String = "Debug",
        tools: [DebugTool] = [],
        actions: [DebugActionGroup] = [],
        info: [DebugInfoGroup] = []
    ) {
        DebugSwiftAndroidRuntime.markIOSDebuggerPrepared()
        DebugSwift.App.shared.panelProvider = {
            DebugSwiftSharedPanelController(
                rootView: AnyView(
                    DebugPanel(title: title, tools: tools, actions: actions, info: info) {
                        _ = DebugSwift.App.removeDebugger()
                    }
                )
            )
        }
    }

    /// Goes back to the UIKit tab bar.
    public static func useUIKitPanel() {
        DebugSwift.App.shared.panelProvider = nil
    }
}

/// Hosts the panel inside the debugger window's navigation controller, whose bar would otherwise
/// sit above the panel's own `NavigationStack`.
final class DebugSwiftSharedPanelController: UIHostingController<AnyView> {
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.hidesBackButton = true
        overrideUserInterfaceStyle = .dark
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }
}
#endif
