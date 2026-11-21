import AppKit
import ApplicationServices
import ChainCore

extension NativeDesktop {
    /// AppKit can acknowledge AXSize and AXPosition immediately, then commit each
    /// against the previous frame. A resize therefore owns a single serialized
    /// sequence. Scroll moves of already-sized windows do not enter this path.
    func beginResize(_ id: String, desired: CGRect, on screen: ScreenInfo) {
        guard let window = entries[id] else { return }
        moveReadbacks.remove(id)
        let request = PlacementSettlement(screen: screen, desired: desired, write: NativeFrameWrite(before: window.rect))
        request.resizeSequence = NativeResizeSequence()
        request.sizeWritable = NativeAX.settableState(window.element, kAXSizeAttribute) != false
        settlingPlacements[id] = request
        sampleResize(id, request)
    }

    private func scheduleResize(_ id: String, _ request: PlacementSettlement, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.sampleResize(id, request) }
    }

    private func sampleResize(_ id: String, _ request: PlacementSettlement) {
        guard running, trusted, settlingPlacements[id] === request, var sequence = request.resizeSequence,
              let window = entries[id] else { return }
        let screen = request.screen
        guard draggingID != id, !owned.contains(id), !suspendedIDs.contains(id), screens.contains(screen) else {
            settlingPlacements.removeValue(forKey: id)
            return
        }
        let desired = request.desired
        if request.lastWritten != desired {
            // Navigation can retarget a strip while a prior AX write is still in flight.
            // Keep the latest target and the time of the last physical write.
            sequence = NativeResizeSequence()
            request.resizeSequence = sequence
            request.lastWritten = desired
        }
        if NativeAX.flag(window.element, kAXMinimizedAttribute) == true {
            settlingPlacements.removeValue(forKey: id)
            queueScan()
            return
        }
        let measured = NativeAX.frame(window.element)
        if request.lastGeometryWrite != nil, request.firstSample == nil { request.firstSample = measured }
        if let measured { entries[id]?.rect = measured }

        let action = sequence.next(measured: measured.map(Box.init), target: Box(desired), display: screen.bounds,
                                   neighbors: neighboringDisplays[screen.id] ?? [], sizeWritable: request.sizeWritable)
        let now = ProcessInfo.processInfo.systemUptime
        if action != .settled, let previous = request.lastGeometryWrite {
            // A read can confirm a one-setter operation promptly. A *second write*
            // must wait for AppKit to commit the first, even after an immediate ACK.
            let remaining = 0.38 - (now - previous)
            if remaining > 0 {
                scheduleResize(id, request, after: remaining)
                return
            }
        }
        request.resizeSequence = sequence
        switch action {
        case .anchor(let frame):
            request.write.coarsePosition = NativeAX.setOrigin(frame.nativeRect.origin, of: window.element)
            request.write.afterCoarse = NativeAX.frame(window.element)
        case .resize:
            request.beforeRetry = measured
            request.write.size = NativeAX.setSize(desired.size, of: window.element)
            request.write.afterSize = NativeAX.frame(window.element)
            if request.write.size == .attributeUnsupported || request.write.size == .notImplemented {
                request.sizeWritable = false
            }
        case .position(let frame):
            request.write.position = NativeAX.setOrigin(frame.nativeRect.origin, of: window.element)
            request.write.afterPosition = NativeAX.frame(window.element)
        case .wait:
            scheduleResize(id, request, after: 0.16)
            return
        case .settled:
            guard let measured else { return }
            entries[id]?.lastRequestedSize = desired.size
            entries[id]?.lastRequestedOrigin = measured.origin
            settlingPlacements.removeValue(forKey: id)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running else { return }
                self.onEvent?(.reconcilePlacement)
                if self.deferredActivation == id { self.deferredActivation = nil; self.raise(id, activate: true) }
            }
            return
        case .refused:
            NativePlacementLog.rejected(initial: request.initialWrite, latest: request.write, target: desired, actual: measured,
                                        usable: screen.bounds.nativeRect, neighbors: neighboringDisplays[screen.id] ?? [],
                                        minimized: NativeAX.flag(window.element, kAXMinimizedAttribute),
                                        firstSample: request.firstSample, beforeRetry: request.beforeRetry)
            release(id)
            onEvent?(.cannotTile(id))
            return
        }
        request.lastGeometryWrite = ProcessInfo.processInfo.systemUptime
        // An anchor for a true resize necessarily needs another write. Resize or
        // final position can already match, so those get a cheap early confirmation.
        if case .anchor = action { scheduleResize(id, request, after: 0.38) }
        else { scheduleResize(id, request, after: 0.065) }
    }
}
