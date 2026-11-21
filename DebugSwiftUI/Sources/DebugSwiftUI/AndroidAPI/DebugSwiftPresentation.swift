#if os(Android)
import Foundation
import Observation
#if canImport(SkipFuse)
// Bridges `@Observable` to Compose: without it, the sheets never see `isPresented` change.
import SkipFuse
#endif

/// Whether the shared panel is on screen, and which `.debugSwiftPanel()` presenter shows it.
/// `DebugSwift.App.presentDebugger()`, `DebugSwift.Measurement` and the floating button change it;
/// each presenter's sheet reads it through `isShowing(for:)`.
@MainActor
@Observable
final class DebugSwiftPresentation {
    static let shared = DebugSwiftPresentation()

    /// Whether the panel is open, whichever presenter shows it.
    var isPresented = false
    /// A feature the panel opens directly, for example `measurement`.
    var route: String?
    /// The `.debugSwiftPanel()` presenters on screen, oldest first. The newest one presents the panel.
    private var presenters: [UUID] = []
    /// The host's own floating-button handler, put back when the last presenter leaves the screen.
    private var hostTap: (@MainActor () -> Void)?

    var isAttached: Bool { !presenters.isEmpty }

    /// The presenter that shows the panel: the newest one on screen.
    var activePresenter: UUID? { presenters.last }

    /// Called by a `.debugSwiftPanel()` presenter when it appears: the floating button opens the
    /// panel through the presenters from now on.
    func attach(_ id: UUID) {
        if presenters.isEmpty { hostTap = DebugFloatingButton.onTap }
        presenters.removeAll { $0 == id }
        presenters.append(id)
        DebugFloatingButton.onTap = { DebugSwiftPresentation.shared.present(route: nil) }
    }

    /// Called when a presenter disappears. Others still on screen keep presenting; when the last
    /// one leaves, the panel closes with it (so `Measurement.isActive` is false and a later presenter
    /// doesn't reopen an old route) and the handler the host had before comes back, so `present`
    /// never calls itself.
    func detach(_ id: UUID) {
        guard presenters.contains(id) else { return }
        presenters.removeAll { $0 == id }
        guard presenters.isEmpty else { return }
        dismiss()
        DebugFloatingButton.onTap = hostTap
        hostTap = nil
    }

    func present(route: String?) {
        self.route = route
        if isAttached {
            isPresented = true
        } else if let hostTap = DebugFloatingButton.onTap {
            // No presenter on screen: the host shows the panel itself (`DebugFloatingButton.onTap`).
            hostTap()
        }
    }

    func dismiss() {
        isPresented = false
        route = nil
    }

    // MARK: - A presenter's sheet

    /// Whether this presenter's sheet is up: the panel is open and this is the newest presenter.
    func isShowing(for id: UUID) -> Bool {
        isPresented && activePresenter == id
    }

    /// What a presenter's sheet binding reports. Only the presenter showing the panel can close
    /// it; a sheet that SwiftUI closes because a newer presenter took the panel over changes nothing.
    func setShowing(_ showing: Bool, for id: UUID) {
        guard !showing, activePresenter == id else { return }
        isPresented = false
    }

    /// Called when a presenter's sheet has gone. The route (say, the measurement tool) is cleared
    /// only when the panel was really closed; on a handoff it stays for the new presenter.
    func sheetDidDismiss(for id: UUID) {
        if !isPresented { route = nil }
    }
}
#endif
