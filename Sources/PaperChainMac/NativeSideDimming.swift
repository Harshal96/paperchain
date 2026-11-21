import AppKit
import ApplicationServices
import ChainCore

extension NativeDesktop {
    func clearSideDimming() {
        pendingSideDimming?.cancel()
        pendingSideDimming = nil
        dimmedAround = nil
        sideDimmers.clear()
    }

    /// Coalesce a burst of AX notifications and stack changes into one WindowServer snapshot.
    func scheduleSideDimming() {
        guard dimSideWindows, running, trusted, pendingSideDimming == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSideDimming = nil
            self.refreshSideDimming()
        }
        pendingSideDimming = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: work)
    }

    private func refreshSideDimming() {
        // The strip remembers its selection across app switches. Only dim when that
        // window actually has focus, including after switching to Settings or a floater.
        guard dimSideWindows, running, trusted, draggingID == nil,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            clearSideDimming()
            return
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.18)
        guard let focused = NativeAX.element(application, kAXFocusedWindowAttribute),
              let id = id(of: focused), !suspendedIDs.contains(id), !owned.contains(id), !awaitingPlacement(id),
              let plan = sideDimmingPlan?(id) else {
            clearSideDimming()
            return
        }
        let targets = plan.windows.compactMap { id -> Window? in
            guard !suspendedIDs.contains(id), !owned.contains(id), !awaitingPlacement(id),
                  let window = entries[id], !window.app.isHidden else { return nil }
            return window
        }
        sideDimmers.update(windows: targets, bounds: plan.bounds.nativeRect)
        dimmedAround = id
    }
}
