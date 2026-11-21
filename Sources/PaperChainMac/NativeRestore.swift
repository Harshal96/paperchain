import AppKit
import ApplicationServices
import ChainCore

extension NativeDesktop {
    final class RestoreRequest {
        var policy: ParkingRestore
        var exhausted = false
        var sentWrite = false
        var settleAfter: TimeInterval = 0

        init(_ intent: ParkingRestore.Intent) { policy = ParkingRestore(intent) }
    }

    /// True only after a visible read. Repeated animation frames share the same attempt.
    func unpark(_ id: String, intent: ParkingRestore.Intent, retry: Bool = false) -> Bool {
        guard owned.contains(id), let window = entries[id] else { return false }
        if let request = restores[id] {
            if request.policy.intent == .park || request.exhausted && (retry || request.policy.intent != intent) {
                restores.removeValue(forKey: id)
            } else {
                request.policy.intent = intent
                return false
            }
        }
        let request = RestoreRequest(intent)
        restores[id] = request
        parkedAt.removeValue(forKey: id)
        let previousHideInFlight = unconfirmedPark.remove(id) != nil
        if previousHideInFlight { request.settleAfter = ProcessInfo.processInfo.systemUptime + 0.2 }
        let minimized = NativeAX.flag(window.element, kAXMinimizedAttribute)
        if minimized == false && !previousHideInFlight {
            clearOwnership(id)
            return true
        }
        if minimized == true || previousHideInFlight {
            sendRestore(window, request: request)
            if !previousHideInFlight, NativeAX.flag(window.element, kAXMinimizedAttribute) == false {
                if request.sentWrite { expectedRestore.insert(id) }
                clearOwnership(id)
                return true
            }
        }
        if running { verifyRestore(id, request: request, after: 0.22) }
        return false
    }

    private func sendRestore(_ window: Window, request: RestoreRequest) {
        ignoreGeneratedFocus()
        // Even an AX timeout can apply later. The return code never clears ownership.
        _ = NativeAX.setFlag(window.element, kAXMinimizedAttribute, false)
        request.sentWrite = true
    }

    func replaceRestore(_ id: String, intent: ParkingRestore.Intent) {
        let next = RestoreRequest(intent)
        next.sentWrite = restores[id]?.sentWrite == true
        restores[id] = next
        if running { verifyRestore(id, request: next, after: 0.22) }
    }

    private func verifyRestore(_ id: String, request: RestoreRequest, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.restores[id] === request, let window = self.entries[id] else { return }
            guard self.trusted else { request.exhausted = true; return }
            switch request.policy.check(minimized: NativeAX.flag(window.element, kAXMinimizedAttribute)) {
            case .confirmed:
                self.completeRestore(id, fromNotification: false)
            case .retry:
                self.sendRestore(window, request: request)
                self.verifyRestore(id, request: request, after: 0.55)
            case .wait:
                self.verifyRestore(id, request: request, after: 0.55)
            case .keepParked:
                // The reversal won. Continue to own the still-minimized window.
                self.restores.removeValue(forKey: id)
                self.parkedAt[id] = ProcessInfo.processInfo.systemUptime
            case .exhausted:
                // A later AX observation, explicit selection/rescan or shutdown can retry.
                // Leave the exact journal record in place, without an idle polling loop.
                request.exhausted = true
                if self.deferredActivation == id { self.deferredActivation = nil }
            }
        }
    }

    /// Used for a positive read or a matched AX deminiaturization notification.
    func completeRestore(_ id: String, fromNotification: Bool) {
        guard let request = restores[id] else { return }
        if request.sentWrite && !fromNotification { expectedRestore.insert(id) }
        clearOwnership(id)
        userMinimized.remove(id)
        if let window = entries[id], !window.app.isHidden, NativeAX.flag(window.element, "AXFullScreen") != true {
            suspendedIDs.remove(id)
        }
        switch request.policy.intent {
        case .park:
            park(id)
        case .release:
            release(id)
        case .show:
            break
        }
        // Presentation may be midway through an inventory pass. Reproject the current
        // layout on the next turn, then deliver explicit focus if it is still wanted.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            self.onEvent?(.reconcilePlacement)
            if self.deferredActivation == id {
                self.deferredActivation = nil
                if !self.owned.contains(id) { self.raise(id, activate: true) }
            }
        }
    }

    func clearOwnership(_ id: String) {
        restores.removeValue(forKey: id)
        owned.remove(id)
        parkedAt.removeValue(forKey: id)
        unconfirmedPark.remove(id)
        try? journal.forget(recoveryJournalIDs.removeValue(forKey: id) ?? id)
    }

    func retryUnconfirmedRestores() {
        for (id, request) in Array(restores) where request.exhausted {
            let intent = request.policy.intent
            if intent == .park {
                replaceRestore(id, intent: intent)
            } else if unpark(id, intent: intent, retry: true), intent == .release {
                release(id)
            }
        }
    }
}
