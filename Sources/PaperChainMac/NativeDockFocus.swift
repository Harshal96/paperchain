import AppKit
import ApplicationServices

extension NativeDesktop {
    /// A paused tile has already been released. Raise its visible native window
    /// before a new placement can enter settlement and defer an ordinary raise.
    func focusFloatingWindow(_ id: String) -> Bool {
        guard running, trusted, draggingID == nil, !suspendedIDs.contains(id),
              !owned.contains(id),
              let window = entries[id], !window.app.isHidden,
              NativeAX.flag(window.element, kAXMinimizedAttribute) == false else { return false }
        performNativeRaise(id, window: window, activate: true)
        // The first placement of this retry must verify the application's real
        // geometry before the strip resumes normal layer ordering.
        if !awaitingPlacement(id) {
            entries[id]?.lastRequestedSize = nil
            entries[id]?.lastRequestedOrigin = nil
        }
        return true
    }

    func awaitingPlacement(_ id: String) -> Bool {
        settlingPlacements[id] != nil || pendingRelease.contains(id)
    }

    func performNativeRaise(_ id: String, window: Window, activate: Bool) {
        guard focusObservation.raise(id, activate: activate, at: ProcessInfo.processInfo.systemUptime) else { return }
        ignoreGeneratedFocus()
        if activate {
            _ = window.app.activate(options: [])
            NativeAX.setFlag(window.element, kAXMainAttribute, true)
        }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        if activate { checkExposureAfterActivation(id) }
    }
}
