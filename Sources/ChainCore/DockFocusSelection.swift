/// A dock click can focus a released native window before its tile has settled.
/// The strip may continue placing its neighbors while that window is in front.
package struct DockFocusSelection {
    package private(set) var floater: String?
    private var display: String?

    package init() {}

    /// Returns the activation still owed by the presenter.
    package mutating func clicked(_ id: String, directlyRaisedOn screen: String?) -> String? {
        floater = screen == nil ? nil : id
        display = screen
        return screen == nil ? id : nil
    }

    package mutating func reconcile(_ workspace: Workspace, activating: String?) {
        guard let floater, let display else { return }
        guard activating == nil || activating == floater, let screen = workspace.screens[display],
              screen.enabled, screen.isConnected, screen.activeGroup?.selectedID == floater else {
            self = Self()
            return
        }
    }

    package func coversPassiveRaise(_ target: String, in workspace: Workspace, settling: Bool) -> Bool {
        guard let floater, target != floater, settling || workspace.placementPaused.contains(floater) else { return false }
        return workspace.location(of: target)?.screenID == display
    }
}
