import AppKit
import ApplicationServices
import ChainCore

extension NativeDesktop {
    final class ExposureCheck {
        let id: String
        let started = ProcessInfo.processInfo.systemUptime
        var work: DispatchWorkItem?

        init(_ id: String) { self.id = id }
    }

    func cancelExposureCheck() {
        exposureCheck?.work?.cancel()
        exposureCheck?.work = nil
        exposureCheck = nil
    }

    func checkExposureAfterActivation(_ id: String) {
        cancelExposureCheck()
        guard running, trusted, draggingID == nil else { return }
        exposureCheck = ExposureCheck(id)
        // A previously paused Dock target can receive its native activation just
        // before Runtime commits the selection into the workspace.
        DispatchQueue.main.async { [weak self] in self?.resumeExposureCheck() }
    }

    /// Projection ticks and resize completions can make the stack ready. No timer
    /// or window query runs while waiting for those events or after the one check.
    func resumeExposureCheck() {
        guard let check = exposureCheck, check.work == nil else { return }
        guard running, trusted, draggingID == nil,
              ProcessInfo.processInfo.systemUptime - check.started < 3,
              let plan = exposurePlan?(check.id) else { cancelExposureCheck(); return }
        if plan.order.count == 1 { cancelExposureCheck(); return }
        guard plan.order.count > 1, plan.order.last == check.id,
              !plan.order.contains(where: awaitingPlacement) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.exposureCheck === check else { return }
            check.work = nil
            guard let latest = self.exposurePlan?(check.id), latest.order == plan.order,
                  !latest.order.contains(where: self.awaitingPlacement) else {
                self.resumeExposureCheck()
                return
            }
            self.exposureCheck = nil
            self.verifyExposure(check, screen: latest.screen, order: latest.order)
        }
        check.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func verifyExposure(_ check: ExposureCheck, screen: ScreenInfo, order: [String]) {
        guard running, trusted, draggingID == nil, inputUnchanged(since: check.started),
              let active = entries[check.id], active.app.isActive,
              let focused = NativeAX.element(AXUIElementCreateApplication(active.app.processIdentifier), kAXFocusedWindowAttribute),
              CFEqual(active.element, focused) else { return }
        var frames: [String: Box] = [:]
        for id in order {
            guard let window = entries[id], !owned.contains(id), !suspendedIDs.contains(id),
                  !window.app.isHidden, let frame = NativeAX.frame(window.element) else { return }
            frames[id] = Box(frame)
        }
        let samples = NativeExposure.samples(order: order, frames: frames, bounds: screen.bounds)
        guard samples.count > 1, let surfaces = NativeLayerSurface.visible() else { return }
        let dimmers = sideDimmers.windowNumbers
        var firstCovered: Int?
        for sample in samples {
            let point = CGPoint(x: sample.x, y: sample.y)
            // Preserve menus, panels, sheets and intentional floating windows.
            // Both the WindowServer surface and the accessible top-level window
            // must identify an ordinary, managed window on this display.
            guard let surface = surfaces.first(where: { !dimmers.contains($0.number) && $0.frame.contains(point) }), surface.layer == 0,
                  let hit = exposureWindow(at: point, surface: surface) else { return }
            if sample.id != hit, let index = order.firstIndex(of: sample.id) {
                guard activeStripLocation?(hit)?.screen == screen.id else { return }
                firstCovered = min(firstCovered ?? index, index)
            }
        }
        guard let firstCovered, inputUnchanged(since: check.started), active.app.isActive,
              let current = NativeAX.element(AXUIElementCreateApplication(active.app.processIdentifier), kAXFocusedWindowAttribute),
              CFEqual(current, active.element) else { return }
        // The remaining suffix preserves edge-before-center order. The selected
        // app is already active; activating it again could reorder all siblings.
        for id in order[firstCovered...] {
            guard let window = entries[id] else { return }
            if id == check.id { NativeAX.setFlag(window.element, kAXMainAttribute, true) }
            performNativeRaise(id, window: window, activate: false)
        }
        scheduleSideDimming()
    }

    private func inputUnchanged(since start: TimeInterval) -> Bool {
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        guard elapsed < 3, NSEvent.pressedMouseButtons == 0 else { return false }
        // This also catches input arriving while a synchronous AX read is in progress.
        for type: CGEventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown] {
            if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type) < elapsed { return false }
        }
        return true
    }

    private func exposureWindow(at point: CGPoint, surface: NativeLayerSurface) -> String? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        let window = NativeAX.element(element, kAXWindowAttribute) ?? element
        guard let id = id(of: window), let managed = entries[id], managed.app.processIdentifier == surface.pid else { return nil }
        if !CFEqual(element, window) {
            if let top = NativeAX.element(element, kAXTopLevelUIElementAttribute) {
                guard CFEqual(top, window) else { return nil }
            } else {
                // Some Electron controls expose AXWindow but omit AXTopLevelUIElement.
                // Require their layer-zero surface's exact public Quartz window number.
                guard managed.quartzIdentifier == "q:\(surface.number)" else { return nil }
            }
        }
        return id
    }
}
