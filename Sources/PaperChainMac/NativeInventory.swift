import AppKit
import ApplicationServices
import ChainCore
import NativeAXMetadata

extension NativeDesktop {
    struct Candidate {
        let element: AXUIElement
        let frame: CGRect
        let title: String
        let identifier: String?
        let minimized: Bool?
        let fullScreen: Bool?
    }

    func scanWindows(for appPIDs: Set<pid_t>? = nil) {
        let before = windows
        let suspendedBefore = suspendedIDs
        var numbers: [pid_t: [NativeWindowNumber]]?
        var closed: [String] = []
        var restored: [String] = []
        var discovered: [String] = []
        let requested = appPIDs.map { $0.compactMap(NSRunningApplication.init(processIdentifier:)) }
        // Excluded apps still need their native inventory while recovering a previously
        // managed window. Read siblings too so journal matching can detect ambiguity.
        let retainedPIDs: Set<pid_t> = floatingAppBundleIDs.isEmpty ? [] :
            Set(journal.records.map(\.pid)).union(entries.values.map { $0.app.processIdentifier })
        let apps = (requested ?? NSWorkspace.shared.runningApplications).filter { app in
            guard !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
            if isFloatingApp(app.bundleIdentifier) { return retainedPIDs.contains(app.processIdentifier) }
            return app.activationPolicy == .regular
        }
        let pids = Set(apps.map(\.processIdentifier))
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var visible = Set<String>()
        // Persist aliases under a process launch, allowing a window to reconnect when
        // several identical Quartz bounds obscure its window number on the next launch.
        let defaults = UserDefaults.standard
        var aliases = defaults.dictionary(forKey: "nativeWindowAliases") as? [String: String] ?? [:]
        let oldAliases = aliases
        for app in apps {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.18)
            installObserver(for: pid, app: appElement)
            if app.isHidden {
                suspendedIDs.formUnion(entries.values.filter { $0.app.processIdentifier == pid }.map { $0.info.id })
            }
            let list = NativeAX.attribute(appElement, kAXWindowsAttribute) as? [AXUIElement]
            var elements = list ?? []
            // AXFocusedWindow can publish a newly opened window before AXWindows includes it.
            if pid == frontPID, let focus = NativeAX.element(appElement, kAXFocusedWindowAttribute),
               !elements.contains(where: { CFEqual($0, focus) }) { elements.append(focus) }
            guard list != nil || !elements.isEmpty else { continue }
            let existing = entries.values.filter { $0.app.processIdentifier == pid }
            var unreadable = Set<String>()
            let candidates: [Candidate] = elements.compactMap { element in
                AXUIElementSetMessagingTimeout(element, 0.18)
                let metadata = NativeWindowMetadata.read(element)
                guard metadata.applicable == true, let frame = metadata.frame else {
                    if metadata.applicable != false, let known = existing.first(where: { CFEqual($0.element, element) }) {
                        unreadable.insert(known.info.id)
                    }
                    return nil
                }
                return Candidate(element: element, frame: frame, title: metadata.title ?? "", identifier: metadata.identifier,
                                 minimized: metadata.minimized, fullScreen: metadata.fullScreen)
            }
            let prefix = "\(pid):\(Self.launchToken(app)):"
            for seed in candidates {
                let previous = existing.first { CFEqual($0.element, seed.element) }
                let rawKey = seed.identifier.flatMap { $0.isEmpty ? nil : "a:" + NativeAX.identityHash($0) }
                var quartzKey = previous?.quartzIdentifier
                if quartzKey == nil, candidates.filter({ $0.frame.approximatelyEquals(seed.frame) }).count == 1 {
                    if numbers == nil { numbers = NativeWindowNumber.inventory() }
                    let matching = numbers?[pid]?.filter { $0.frame.approximatelyEquals(seed.frame) } ?? []
                    if matching.count == 1 { quartzKey = "q:\(matching[0].number)" }
                }
                let identifier: String?
                if let rawKey, candidates.filter({ $0.identifier == seed.identifier }).count == 1 {
                    identifier = rawKey
                } else {
                    identifier = quartzKey
                }
                let titleKey = prefix + NativeAX.identityHash(seed.title)
                let uniqueTitle = !seed.title.isEmpty && candidates.filter { $0.title == seed.title }.count == 1
                var id = previous?.info.id
                if id == nil {
                    // Reuse a title alias only when stronger evidence agrees or is unavailable.
                    if uniqueTitle, let alias = aliases[titleKey], entries[alias] == nil,
                       identifier == nil || [rawKey, quartzKey].compactMap({ $0 }).contains(where: { alias == prefix + $0 }) ||
                        alias.hasPrefix(prefix + "u:") {
                        id = alias
                    } else if let identifier, entries[prefix + identifier] == nil {
                        id = prefix + identifier
                    } else {
                        id = prefix + "u:" + UUID().uuidString
                    }
                }
                guard let id else { continue }
                let info = WindowInfo(id: id, app: app.localizedName ?? app.bundleIdentifier ?? "Application",
                                      title: seed.title, bundleID: app.bundleIdentifier)
                var entry = Window(info: info, app: app, element: seed.element, identifier: identifier,
                                   axIdentifier: rawKey, quartzIdentifier: quartzKey,
                                   rect: seed.frame, acceptedSize: previous?.acceptedSize,
                                   lastRequestedOrigin: previous?.lastRequestedOrigin)
                entry.observeFrame(seed.frame)
                // A browser tab or editor title can change hundreds of times in one launch.
                if uniqueTitle, aliases[titleKey] != id {
                    aliases = aliases.filter { $0.value != id }
                    aliases[titleKey] = id
                }
                if previous == nil {
                    observeWindowDestruction(seed.element, for: pid)
                    scanOrder.append(id)
                    if completedInitialInventory && !isFloatingApp(info.bundleID) { discovered.append(id) }
                }
                entries[id] = entry
                visible.insert(id)
                if seed.minimized == false {
                    // Some apps never emit AXWindowDeminiaturized. An inventory scan can
                    // reconcile the user's Dock restore after the system's animation settles.
                    let previouslyParked = parkedAt[id].map { ProcessInfo.processInfo.systemUptime - $0 > 0.8 } ?? false
                    if let request = restores[id] {
                        if ProcessInfo.processInfo.systemUptime >= request.settleAfter {
                            completeRestore(id, fromNotification: false)
                        }
                    } else if userMinimized.remove(id) != nil || previouslyParked {
                        clearOwnership(id)
                        restored.append(id)
                    }
                } else if seed.minimized == true, !owned.contains(id) {
                    expectedRestore.remove(id)
                    userMinimized.insert(id)
                } else if seed.minimized == true {
                    unconfirmedPark.remove(id)
                }
                let movable = seed.minimized == false ? NativeAX.settableState(seed.element, kAXPositionAttribute) : nil
                if NativeWindowAvailability.suspended(previously: previous.map { _ in suspendedIDs.contains(id) },
                                                      hidden: app.isHidden, fullScreen: seed.fullScreen,
                                                      minimized: seed.minimized, owned: owned.contains(id), movable: movable) {
                    suspendedIDs.insert(id)
                } else {
                    suspendedIDs.remove(id)
                }
            }
            // A missing window can be on another Space. Only an invalid AX object is
            // evidence of a close; a timeout or temporary absence preserves its identity.
            for w in existing where list != nil && !visible.contains(w.info.id) && !unreadable.contains(w.info.id) {
                var role: CFTypeRef?
                if AXUIElementCopyAttributeValue(w.element, kAXRoleAttribute as CFString, &role) == .invalidUIElement {
                    closed.append(w.info.id)
                } else {
                    suspendedIDs.insert(w.info.id)
                }
            }
        }
        for w in entries.values where (appPIDs?.contains(w.app.processIdentifier) ?? true) && !pids.contains(w.app.processIdentifier) {
            if w.app.isTerminated { closed.append(w.info.id) }
            else { suspendedIDs.insert(w.info.id) }
        }
        for id in closed {
            forgetWindow(id)
            aliases = aliases.filter { $0.value != id }
        }
        if appPIDs == nil { aliases = aliases.filter { !isProcessGone(for: $0.value) } }
        if oldAliases != aliases { defaults.set(aliases, forKey: "nativeWindowAliases") }

        let observationTime = ProcessInfo.processInfo.systemUptime
        for id in discovered { focusObservation.discovered(id, at: observationTime) }
        recoverParked(among: visible.compactMap { entries[$0] }, for: appPIDs)
        releaseFloatingWindows(retrying: suspendedBefore)
        for id in closed { onEvent?(.closed(id)) }
        for id in restored where !suspendedIDs.contains(id) && managedWindow(id) != nil { onEvent?(.restored(id)) }
        if before != windows || suspendedBefore != suspendedIDs { onEvent?(.windowsChanged) }
        reportFocus()
        completedInitialInventory = true
        scheduleAdmission()
    }

    private func scheduleAdmission() {
        guard pendingAdmission == nil, let deadline = focusObservation.nextAdmission else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.pendingAdmission = nil
            // Until this sample, normal layout has left the newly born windows alone.
            // The frontmost one can now be selected without mistaking our raise for the app's choice.
            self.reportFocus()
            if self.focusObservation.admitBackground(at: ProcessInfo.processInfo.systemUptime) {
                self.onEvent?(.windowsChanged)
            }
            self.scheduleAdmission()
        }
        pendingAdmission = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: work)
    }

    func recoverParked(among windows: [Window], for appPIDs: Set<pid_t>?) {
        for saved in journal.records where (appPIDs?.contains(saved.pid) ?? true) && !owned.contains(saved.id) {
            if isProcessGone(for: saved.id) {
                try? journal.forget(saved.id)
                continue
            }
            let records = parkingCandidates(for: saved, windows: windows.filter { $0.app.processIdentifier == saved.pid })
            guard let match = NativeParkingJournal.match(saved, among: records),
                  let w = entries[match.id], !owned.contains(match.id),
                  let isMinimized = NativeAX.flag(w.element, kAXMinimizedAttribute) else { continue }
            if !isMinimized {
                try? journal.forget(saved.id)
                continue
            }
            if isFloatingApp(w.info.bundleID), w.app.isHidden { continue }
            owned.insert(match.id)
            recoveryJournalIDs[match.id] = saved.id
            userMinimized.remove(match.id)
            if !w.app.isHidden && NativeAX.flag(w.element, "AXFullScreen") != true {
                suspendedIDs.remove(match.id)
            }
            // Retry through the same confirmation path as a normal Dock reveal.
            // The matched journal record can have a different ID than this AX handle.
            _ = unpark(match.id, intent: .release)
        }
    }

    func forgetWindow(_ id: String) {
        guard entries.removeValue(forKey: id) != nil else { return }
        scanOrder.removeAll { $0 == id }
        originals.removeValue(forKey: id)
        suspendedIDs.remove(id)
        userMinimized.remove(id)
        settlingPlacements.removeValue(forKey: id)
        moveReadbacks.remove(id)
        pendingRelease.remove(id)
        expectedRestore.remove(id)
        clearOwnership(id)
        if deferredActivation == id { deferredActivation = nil }
        focusObservation.forget(id)
        if gesture?.window == id { gesture = nil }
        let defaults = UserDefaults.standard
        if let aliases = defaults.dictionary(forKey: "nativeWindowAliases") as? [String: String],
           aliases.values.contains(id) {
            defaults.set(aliases.filter { $0.value != id }, forKey: "nativeWindowAliases")
        }
    }

    func id(of element: AXUIElement) -> String? {
        entries.first(where: { CFEqual($0.value.element, element) })?.key
    }

    func focusIsInSameApp(as id: String, at time: Double) -> Bool {
        guard let focusedID, let previous = entries[focusedID], let target = entries[id] else { return false }
        return previous.app.processIdentifier == target.app.processIdentifier &&
            time - lastAppActivation > NativeFocusObservation.suppressionInterval
    }

    func managedID(of element: AXUIElement) -> String? {
        guard let id = id(of: element), managedWindow(id) != nil else { return nil }
        return id
    }

    /// A true result means the focus observation is resolved from existing registrations.
    @discardableResult
    func reportFocus() -> Bool {
        // Even a suppressed AX focus event can change which native window is bright.
        defer { scheduleSideDimming() }
        guard trusted, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !isFloatingApp(app.bundleIdentifier) else { return true }
        let pid = app.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.18)
        guard let window = NativeAX.element(application, kAXFocusedWindowAttribute) else {
            return app.activationPolicy != .regular
        }
        guard let id = id(of: window) else { return NativeAX.applicability(window) == false }
        if suspendedIDs.contains(id) || owned.contains(id) {
            return app.isHidden || NativeAX.flag(window, kAXMinimizedAttribute) == true ||
                NativeAX.flag(window, "AXFullScreen") == true
        }
        let now = ProcessInfo.processInfo.systemUptime
        // Command-Tab can follow an automatic raise. Query only the age of the
        // last key press (never its contents) to recognize intervening user input.
        let inputBaseline = focusObservation.inputBaseline(at: now, lastManagerFocus: lastManagerFocus)
        let keyAge = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let downAge = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        if NSEvent.pressedMouseButtons & 1 != 0 ||
            NativeFocusObservation.awaitingMouseDown(at: now, handledThrough: lastMouseDown, downAge: downAge, keyAge: keyAge) {
            deferredPointerFocus = true
            return true
        }
        let userKeyAfterRaise = inputBaseline > 0 && keyAge < now - inputBaseline
        let sameApp = focusIsInSameApp(as: id, at: now)
        if focusObservation.observe(id, on: activeStripLocation?(id)?.screen, at: now, suppressed: now < suppressFocusUntil,
                                    dragging: draggingID != nil, userInput: userKeyAfterRaise) {
            if deferredActivation != id { deferredActivation = nil }
            onEvent?(.focused(id, sameApplication: sameApp))
        }
        return true
    }
}
