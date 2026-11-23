import AppKit
import ApplicationServices
import ChainCore
import OSLog

private let pointerLog = Logger(subsystem: "app.paperchain.mac", category: "pointer")

private func desktopNotification(_ observer: AXObserver, _ element: AXUIElement, _ name: CFString,
                                 _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let registration = Unmanaged<NativeDesktop.ObserverContext>.fromOpaque(context).takeUnretainedValue()
    // Each observer's source is installed exclusively on the main run loop.
    MainActor.assumeIsolated {
        registration.desktop?.received(name as String, element: element, from: observer,
                                       observedWindow: registration.observesWindow)
    }
}

extension NativeDesktop {
    func installNotifications() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            observe(name, on: workspace) { [weak self] _ in self?.queueScan() }
        }
        observe(NSWorkspace.activeSpaceDidChangeNotification, on: workspace) { [weak self] _ in
            self?.clearSideDimming()
            self?.queueScan()
        }
        observe(NSWorkspace.didLaunchApplicationNotification, on: workspace) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            self?.queueScan(for: pid)
            // An application may register with NSWorkspace before its AX server is ready.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.queueScan(for: pid) }
        }
        observe(NSWorkspace.didActivateApplicationNotification, on: workspace) { [weak self] note in
            guard let self else { return }
            self.lastAppActivation = ProcessInfo.processInfo.systemUptime
            self.scheduleSideDimming()
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let id = self.exposureCheck?.id {
                if self.entries[id]?.app.processIdentifier == app?.processIdentifier {
                    self.checkExposureAfterActivation(id)
                } else {
                    self.cancelExposureCheck()
                }
            }
            if !self.trusted || !AXIsProcessTrusted() || app?.bundleIdentifier == "com.apple.systempreferences" ||
                app?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                self.queueScan()
            } else if !self.reportFocus() {
                self.queueScan(for: app?.processIdentifier)
            }
        }
        observe(NSWorkspace.didTerminateApplicationNotification, on: workspace) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            self.appIcons.removeValue(forKey: pid)
            if let observer = self.observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            let ids = self.entries.filter { $0.value.app.processIdentifier == pid }.map(\.key)
            for id in ids { self.forgetWindow(id) }
            for id in ids { self.onEvent?(.closed(id)) }
            if !ids.isEmpty { self.onEvent?(.windowsChanged) }
            self.queueScan()
        }
        observe(NSApplication.didChangeScreenParametersNotification, on: .default) { [weak self] _ in self?.queueScan() }
        observe(NSApplication.didBecomeActiveNotification, on: .default) { [weak self] _ in self?.queueScan() }
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter,
                         perform: @escaping @MainActor (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { perform(note) }
        }
        notificationTokens.append((center, token))
    }

    func installObserver(for pid: pid_t, app: AXUIElement) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, desktopNotification, &observer) == .success, let observer else { return }
        let context = Unmanaged.passUnretained(appNotifications).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXUIElementDestroyedNotification, kAXTitleChangedNotification,
                     kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowMovedNotification,
                     kAXWindowResizedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
        // Reattach when Accessibility returns and inventory still has the old windows.
        for window in entries.values where window.app.processIdentifier == pid {
            observeWindowDestruction(window.element, for: pid)
        }
    }

    func observeWindowDestruction(_ element: AXUIElement, for pid: pid_t) {
        guard let observer = observers[pid] else { return }
        AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString,
                                  Unmanaged.passUnretained(windowNotifications).toOpaque())
    }

    func removeObservers() {
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseUp { NSEvent.removeMonitor(localMouseUp) }
        mouseMonitor = nil
        localMouseUp = nil
        gesture = nil
    }

    func queueScan(for pid: pid_t? = nil) {
        guard running else { return }
        if let pid { appScans.insert(pid) } else { fullScanQueued = true }
        guard pendingScan == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.pendingScan = nil
            let full = self.fullScanQueued || !self.trusted || !AXIsProcessTrusted()
            let pids = self.appScans
            self.fullScanQueued = false
            self.appScans.removeAll()
            if full { self.rescan() } else { self.scanWindows(for: pids) }
        }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.065, execute: work)
    }

    private func appPID(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    private func created(_ element: AXUIElement) {
        guard let pid = appPID(of: element) else { queueScan(); return }
        queueScan(for: pid)
        // Some apps publish the creation notification before they expose the new window's geometry.
        creationChecks[pid]?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.creationChecks.removeValue(forKey: pid)
            guard self.trusted else { return }
            if let id = self.id(of: element), !self.suspendedIDs.contains(id) { return }
            self.queueScan(for: pid)
        }
        creationChecks[pid] = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: check)
    }

    func received(_ name: String, element: AXUIElement, from observer: AXObserver, observedWindow: Bool) {
        guard running, trusted else { return }
        switch name {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            if !reportFocus() { queueScan(for: NSWorkspace.shared.frontmostApplication?.processIdentifier) }
        case kAXUIElementDestroyedNotification:
            let change = NativeWindowDestruction(windowID: id(of: element), observedWindow: observedWindow,
                                                 observerPID: observers.first(where: { CFEqual($0.value, observer) })?.key) {
                CFEqual(element, AXUIElementCreateApplication($0))
            }
            switch change {
            case let .close(id):
                forgetWindow(id)
                onEvent?(.closed(id))
                onEvent?(.windowsChanged)
            case let .scan(pid):
                // The destroyed element cannot be queried. Verify the observed app's inventory.
                queueScan(for: pid)
            case .ignore:
                break
            }
        case kAXWindowMiniaturizedNotification:
            guard let id = id(of: element) else { queueScan(for: appPID(of: element)); return }
            if NativeAX.flag(element, kAXMinimizedAttribute) == true {
                unconfirmedPark.remove(id)
                if owned.contains(id) { return }
                expectedRestore.remove(id)
                userMinimized.insert(id)
                if suspendedIDs.insert(id).inserted { onEvent?(.windowsChanged) }
            }
        case kAXWindowDeminiaturizedNotification:
            guard let id = id(of: element), let minimized = NativeAX.flag(element, kAXMinimizedAttribute) else { return }
            if expectedRestore.remove(id) != nil {
                // This echo may belong to a restore preceding the current park/restore.
                // A positive visible read can resolve the latest request independently.
                if !minimized, let current = restores[id],
                   ProcessInfo.processInfo.systemUptime >= current.settleAfter {
                    completeRestore(id, fromNotification: true)
                }
                return
            }
            if let request = restores[id] {
                if !minimized {
                    completeRestore(id, fromNotification: true)
                } else if request.policy.intent == .park {
                    // Our later park already took effect.
                    restores.removeValue(forKey: id)
                    parkedAt[id] = ProcessInfo.processInfo.systemUptime
                } else {
                    // The notification confirms a restore, and the newer read confirms
                    // another minimize. Preserve that user action and cancel our retries.
                    clearOwnership(id)
                    expectedRestore.remove(id)
                    if deferredActivation == id { deferredActivation = nil }
                    userMinimized.insert(id)
                    if suspendedIDs.insert(id).inserted { onEvent?(.windowsChanged) }
                }
                return
            }
            guard !minimized else { return }
            clearOwnership(id)
            userMinimized.remove(id)
            suspendedIDs.remove(id)
            onEvent?(.restored(id))
            queueScan(for: appPID(of: element))
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            guard let id = id(of: element) else { return }
            if name == kAXWindowMovedNotification, moveReadbacks.coversMoveNotification(id, dragging: draggingID) {
                return
            }
            windowFrameChanged(NativeAX.frame(element), for: id)
            // Resizing is the AX transition delivered by applications entering or leaving full screen.
            if name == kAXWindowResizedNotification,
               NativeAX.flag(element, "AXFullScreen") == true || suspendedIDs.contains(id) { queueScan() }
        case kAXWindowCreatedNotification:
            created(element)
        case kAXTitleChangedNotification:
            // Title notifications can also belong to controls within a window.
            if id(of: element) != nil { queueScan(for: appPID(of: element)) }
        default:
            break
        }
    }

    func windowFrameChanged(_ actual: CGRect?, for id: String) {
        if let actual, let window = entries[id], !window.rect.approximatelyEquals(actual) {
            entries[id]?.rect = actual
            entries[id]?.lastRequestedSize = nil
            entries[id]?.lastRequestedOrigin = nil
        }
        // AX can repeat a move or resize notification while the mouse is held still.
        if let gesture, gesture.window == id {
            guard let actual, gesture.startFrame.approximatelyEquals(actual) else {
                clearSideDimming()
                return
            }
        }
        scheduleSideDimming()
    }

    func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        lastMouseDown = ProcessInfo.processInfo.systemUptime
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouse(event) }
        }
        // A drag can finish on our own panel; global monitors only receive other apps' events.
        localMouseUp = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseDown { self?.beginPointerPress(at: event.timestamp) }
                else { self?.handleMouse(event) }
            }
            return event
        }
    }

    private func beginPointerPress(at time: Double) {
        lastMouseDown = time
        cancelExposureCheck()
        gesture = nil
        deferredActivation = nil
        suppressFocusUntil = 0
        focusObservation.beganClick()
        onEvent?(.pointerDown)
    }

    private func hit(at point: CGPoint) -> (element: AXUIElement, window: AXUIElement)? {
        var result: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &result) == .success,
              let result else { return nil }
        return (result, NativeAX.element(result, kAXWindowAttribute) ?? result)
    }

    func dropScreen(of id: String, x: Double, y: Double) -> String? {
        Workspace.dropScreen(at: CGPoint(x: x, y: y), physical: physicalScreens, windowScreen: screenID(of: id))
    }

    private func isBody(_ hit: (element: AXUIElement, window: AXUIElement)) -> Bool {
        if CFEqual(hit.element, hit.window) { return true }
        // AXWindow also names the parent of a sheet or drawer. AXTopLevelUIElement distinguishes them.
        guard let top = NativeAX.element(hit.element, kAXTopLevelUIElementAttribute),
              CFEqual(top, hit.window) else { return false }
        var node = hit.element
        for _ in 0..<12 {
            switch NativeAX.attribute(node, kAXRoleAttribute) as? String {
            case kAXTextAreaRole, kAXScrollAreaRole, kAXSplitGroupRole, kAXLayoutAreaRole, "AXWebArea":
                return true
            case kAXStaticTextRole, kAXGroupRole:
                // A static label inside a button or a toolbar belongs to that control.
                guard let parent = NativeAX.element(node, kAXParentAttribute), !CFEqual(node, parent) else { return false }
                if CFEqual(parent, hit.window) { return true }
                node = parent
            default:
                return false
            }
        }
        return false
    }

    func handleMouse(_ event: NSEvent) {
        guard running, trusted, let point = event.cgEvent?.location else { return }
        if event.type == .leftMouseDown {
            beginPointerPress(at: event.timestamp)
            let hit = hit(at: point)
            let id = hit.flatMap { self.id(of: $0.window) }
            if let element = hit?.element, let role = NativeAX.attribute(element, kAXRoleAttribute) as? String,
               [kAXDockItemRole, kAXMenuBarItemRole, kAXMenuItemRole, kAXMenuRole].contains(role) {
                // A Dock or Window menu item can intentionally activate a window on another monitor.
                return
            }
            focusObservation.locatePress(at: point, time: event.timestamp, displays: physicalScreens,
                                         hit: id.flatMap { activeStripLocation?($0) })
            guard let hit else { return }
            let windowElement = hit.window
            guard let id else {
                // A direct click can be the first observation for apps that omit the create event.
                if let pid = appPID(of: windowElement), NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular,
                   NativeAX.applicability(windowElement) == true { queueScan(for: pid) }
                return
            }
            guard let rect = NativeAX.frame(windowElement) else { return }
            if let target = moveReadbacks.remove(id),
               !NativePlacement.accepts(Box(rect), for: target.frame, on: target.screen.bounds,
                                        neighbors: neighboringDisplays[target.screen.id] ?? []) {
                entries[id]?.lastRequestedSize = nil
                entries[id]?.lastRequestedOrigin = nil
                skippedDuringGesture = true
            }
            if settlingPlacements.removeValue(forKey: id) != nil { skippedDuringGesture = true }
            entries[id]?.rect = rect
            let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            let body = plain && event.clickCount <= 1 && isBody(hit)
            let sameApp = focusedID.flatMap { entries[$0]?.app.processIdentifier } == entries[id]?.app.processIdentifier &&
                ProcessInfo.processInfo.systemUptime - lastAppActivation > NativeFocusObservation.suppressionInterval
            let closeButton = !body && NativeAX.element(windowElement, kAXCloseButtonAttribute)
                .map { CFEqual($0, hit.element) } == true
            gesture = Gesture(window: id, origin: point, startFrame: rect, bodyClick: body, closeButton: closeButton,
                              sameApplication: sameApp)
            pointerLog.debug("Managed pointer down body=\(body, privacy: .public)")
            return
        }
        focusObservation.releasedPointer(on: Workspace.physicalScreen(at: point, in: physicalScreens), at: event.timestamp)
        guard let candidate = gesture else {
            // Activation can precede delivery of the mouse event, including a click on the macOS Dock.
            if deferredPointerFocus || focusObservation.scopesPointerFocus { resamplePointerFocus() }
            return
        }
        let moved = hypot(point.x - candidate.origin.x, point.y - candidate.origin.y) > 3
        let detach = event.modifierFlags.contains(.option)
        if moved && !candidate.closeButton {
            // Some apps commit their final frame on the next run-loop iteration.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.065) { [weak self] in
                guard let self, self.gesture?.window == candidate.window,
                      self.gesture?.origin == candidate.origin else { return }
                self.finishGesture(candidate, at: point, detach: detach, moved: true)
            }
        } else {
            finishGesture(candidate, at: point, detach: detach, moved: moved)
        }
    }

    private func resamplePointerFocus() {
        deferredPointerFocus = false
        if !reportFocus() { queueScan(for: NSWorkspace.shared.frontmostApplication?.processIdentifier) }
    }

    func finishGesture(_ candidate: Gesture, at point: CGPoint, detach: Bool, moved: Bool) {
        gesture = nil
        defer {
            scheduleSideDimming()
            if skippedDuringGesture {
                skippedDuringGesture = false
                onEvent?(.reconcilePlacement)
            }
        }
        let id = candidate.window
        guard let window = entries[id] else { return }
        if candidate.closeButton {
            // Closing a background window need not change focus. Some apps omit or delay
            // the destroy notification, so reconcile just this app after the button fires.
            let pid = window.app.processIdentifier
            queueScan(for: pid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.running, self.trusted, let entry = self.entries[id],
                      CFEqual(entry.element, window.element) else { return }
                self.queueScan(for: pid)
            }
            return
        }
        guard let frame = moved ? NativeAX.frame(window.element) : candidate.startFrame else { return }
        let frameMoved = hypot(frame.minX - candidate.startFrame.minX, frame.minY - candidate.startFrame.minY) > 2
        let start = candidate.startFrame
        let resizedFromLeft = abs(start.width - frame.width) > 2 && abs(start.maxX - frame.maxX) <= 2 &&
            abs(candidate.origin.x - start.minX) <= 10
        let resizedFromTop = abs(start.height - frame.height) > 2 && abs(start.maxY - frame.maxY) <= 2 &&
            abs(candidate.origin.y - start.minY) <= 10
        if moved && frameMoved && !resizedFromLeft && !resizedFromTop {
            if focusObservation.awaitingFocus(id) { focusObservation.clicked(id) }
            entries[id]?.rect = frame
            entries[id]?.lastRequestedOrigin = nil
            entries[id]?.lastRequestedSize = nil
            originals.removeValue(forKey: id)
            lastDrop = (Double(point.x), Double(point.y), detach)
            onEvent?(.dragged(id, Box(frame)))
        } else if !suspendedIDs.contains(id) {
            let focused = NativeAX.element(AXUIElementCreateApplication(window.app.processIdentifier), kAXFocusedWindowAttribute)
            let matchesFocus = focused.map { CFEqual($0, window.element) } == true
            let active = window.app.isActive
            let eligible = candidate.bodyClick && !moved && active && !owned.contains(id)
            let releaseHit = eligible ? hit(at: point) : nil
            let sameBody = releaseHit.map { CFEqual($0.window, window.element) && isBody($0) } == true
            pointerLog.debug("Managed pointer up eligible=\(eligible, privacy: .public) sameBody=\(sameBody, privacy: .public) active=\(active, privacy: .public) nativeFocused=\(matchesFocus, privacy: .public)")
            finishClick(candidate, sameBody: sameBody, nativeFocused: active && matchesFocus)
        }
    }

    func finishClick(_ candidate: Gesture, sameBody: Bool, nativeFocused: Bool) {
        let id = candidate.window
        let keepsDimming = nativeFocused && dimmedAround == id
        let time = ProcessInfo.processInfo.systemUptime
        // The center already has focus. Validate its display without requesting a body-click activation.
        let click = focusObservation.confirmClick(id, on: activeStripLocation?(id)?.screen,
                                                 bodyWindow: sameBody && !keepsDimming ? id : nil,
                                                 nativeFocused: nativeFocused, at: time)
        deferredPointerFocus = false
        switch click {
        case .body:
            let sameApp = candidate.sameApplication && time - lastAppActivation > NativeFocusObservation.suppressionInterval
            onEvent?(.bodyClicked(id, sameApplication: sameApp))
        case .focused where keepsDimming:
            checkExposureAfterActivation(id)
        case .focused:
            onEvent?(.focused(id))
        case nil:
            resamplePointerFocus()
        }
    }
}
