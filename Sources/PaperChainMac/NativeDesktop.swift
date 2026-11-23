import AppKit
import ApplicationServices
import ChainCore

/// The only owner of AX elements. All callbacks and writes are serialized on the main run loop.
@MainActor
final class NativeDesktop {
    enum Event {
        case windowsChanged, screensChanged, reconcilePlacement
        case pointerDown, bodyClicked(String, sameApplication: Bool), focused(String, sameApplication: Bool)
        case restored(String), closed(String), cannotTile(String)
        case dragged(String, Box)
        case permissionChanged(Bool)
    }

    struct Window {
        var info: WindowInfo
        let app: NSRunningApplication
        let element: AXUIElement
        let identifier: String?
        let axIdentifier: String?
        let quartzIdentifier: String?
        var rect: CGRect
        var lastRequestedSize: CGSize?
        var lastRequestedOrigin: CGPoint?
    }

    struct Original {
        let frame: CGRect
        let screen: String?
    }

    struct Gesture {
        let window: String
        let origin: CGPoint
        let startFrame: CGRect
        let bodyClick: Bool
        let closeButton: Bool
        let sameApplication: Bool
    }

    var onEvent: ((Event) -> Void)?
    var exposurePlan: ((String) -> (screen: ScreenInfo, order: [String])?)?
    var sideDimmingPlan: ((String) -> (bounds: Box, windows: [String])?)?
    let sideDimmers = SideWindowDimmers()
    var dimmedAround: String?
    var pendingSideDimming: DispatchWorkItem?
    var dimSideWindows = false {
        didSet {
            if dimSideWindows { scheduleSideDimming() }
            else { clearSideDimming() }
        }
    }
    var activeStripLocation: ((_ id: String) -> (screen: String, clipped: Bool)?)?
    var exposureCheck: ExposureCheck?
    private(set) var screens: [ScreenInfo] = []
    private(set) var trusted = false
    var windows: [WindowInfo] {
        scanOrder.compactMap { focusObservation.awaitingFocus($0) ? nil : entries[$0]?.info }
    }
    var draggingID: String? { gesture?.window }
    var suspendedIDs = Set<String>()
    var focusObservation = NativeFocusObservation()
    var completedInitialInventory = false
    var pendingAdmission: DispatchWorkItem?
    var focusedID: String? { focusObservation.focusedID }

    var entries: [String: Window] = [:]
    var appIcons: [pid_t: NSImage] = [:]
    var scanOrder: [String] = []
    var originals: [String: Original] = [:]
    var physicalScreens: [String: CGRect] = [:]
    var neighboringDisplays: [String: [Box]] = [:]
    final class PlacementSettlement {
        let screen: ScreenInfo
        let initialWrite: NativeFrameWrite
        var desired: CGRect
        var lastWritten: CGRect
        var write: NativeFrameWrite
        var retry = NativePlacementRetry()
        var firstSample: CGRect?
        var beforeRetry: CGRect?
        var resizeSequence: NativeResizeSequence?
        var sizeWritable = true
        var lastGeometryWrite: TimeInterval?

        init(screen: ScreenInfo, desired: CGRect, write: NativeFrameWrite) {
            self.screen = screen
            self.desired = desired
            self.lastWritten = desired
            self.write = write
            self.initialWrite = write
        }
    }

    var settlingPlacements: [String: PlacementSettlement] = [:]
    var pendingRelease = Set<String>()
    var moveReadbacks = NativeMoveReadbacks()
    private var readbackWork: DispatchWorkItem?
    var owned = Set<String>()
    var parkedAt: [String: TimeInterval] = [:]
    var userMinimized = Set<String>()
    final class ObserverContext {
        weak var desktop: NativeDesktop?
        let observesWindow: Bool

        init(_ desktop: NativeDesktop, observesWindow: Bool) {
            self.desktop = desktop
            self.observesWindow = observesWindow
        }
    }
    lazy var appNotifications = ObserverContext(self, observesWindow: false)
    lazy var windowNotifications = ObserverContext(self, observesWindow: true)
    var observers: [pid_t: AXObserver] = [:]
    var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    var lastMouseDown: TimeInterval = 0
    var deferredPointerFocus = false
    var mouseMonitor: Any?
    var gesture: Gesture?
    var skippedDuringGesture = false
    var lastDrop: (x: Double, y: Double, detach: Bool)?
    var localMouseUp: Any?
    var suppressFocusUntil: TimeInterval = 0
    var lastManagerFocus: TimeInterval = 0
    var lastAppActivation: TimeInterval = 0
    // Correlate a delayed manager-initiated deminiaturize notification with its window.
    var expectedRestore = Set<String>()
    var restores: [String: RestoreRequest] = [:]
    var recoveryJournalIDs: [String: String] = [:]
    var deferredActivation: String?
    var unconfirmedPark = Set<String>()
    var running = false
    private var grantRequest: Task<Void, Never>?
    var pendingScan: DispatchWorkItem?
    var fullScanQueued = false
    var appScans = Set<pid_t>()
    var creationChecks: [pid_t: DispatchWorkItem] = [:]
    let journal = NativeParkingJournal()

    func start() {
        guard !running else { return }
        running = true
        installNotifications()
        rescan()
    }

    func stop() {
        guard running else { return }
        running = false
        clearSideDimming()
        cancelExposureCheck()
        grantRequest?.cancel()
        grantRequest = nil
        pendingScan?.cancel()
        pendingScan = nil
        fullScanQueued = false
        appScans.removeAll()
        for work in creationChecks.values { work.cancel() }
        creationChecks.removeAll()
        gesture = nil
        skippedDuringGesture = false
        removeObservers()
        for (center, token) in notificationTokens { center.removeObserver(token) }
        notificationTokens.removeAll()
        // Issue one final restore on exit. Unconfirmed restores remain in the durable journal.
        restores.removeAll()
        deferredActivation = nil
        releaseAll()
        readbackWork?.cancel()
        readbackWork = nil
        moveReadbacks = NativeMoveReadbacks()
        entries.removeAll()
        appIcons.removeAll()
        scanOrder.removeAll()
        owned.removeAll()
        restores.removeAll()
        recoveryJournalIDs.removeAll()
        unconfirmedPark.removeAll()
        originals.removeAll()
        expectedRestore.removeAll()
        suspendedIDs.removeAll()
        userMinimized.removeAll()
        parkedAt.removeAll()
        settlingPlacements.removeAll()
        pendingRelease.removeAll()
        focusObservation = NativeFocusObservation()
        completedInitialInventory = false
        pendingAdmission?.cancel()
        pendingAdmission = nil
    }

    func requestAccess() {
        guard running else { return }
        grantRequest?.cancel()
        grantRequest = Task { @MainActor [weak self] in
            await AccessibilityGrantRequest.run(requestTrust: {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                return AXIsProcessTrustedWithOptions(options as CFDictionary)
            }, openSettings: {
                // A prior denial can suppress the system prompt. Always take this explicit request to the pane.
                let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                NSWorkspace.shared.open(pane)
            }, isTrusted: { AXIsProcessTrusted() }, onGrant: { self?.rescan() })
        }
    }

    func icon(for window: String) -> NSImage? {
        guard let app = entries[window]?.app else { return nil }
        let pid = app.processIdentifier
        if let cached = appIcons[pid] { return cached }
        appIcons[pid] = app.icon
        return appIcons[pid]
    }

    func frame(of id: String) -> Box? { entries[id].map { Box($0.rect) } }

    func screenID(of id: String) -> String? {
        guard let rect = entries[id]?.rect else { return nil }
        return bestScreen(for: rect)?.id
    }

    func bestScreen(for rect: CGRect) -> ScreenInfo? {
        // In display gaps or after unplugging, use the nearest reachable display.
        screens.min { lhs, rhs in
            func overlap(_ screen: ScreenInfo) -> CGFloat {
                let intersection = screen.bounds.nativeRect.intersection(rect)
                return intersection.isNull ? 0 : intersection.width * intersection.height
            }
            func distance(_ screen: ScreenInfo) -> CGFloat {
                let b = screen.bounds.nativeRect
                return hypot(max(b.minX - rect.midX, rect.midX - b.maxX, 0),
                             max(b.minY - rect.midY, rect.midY - b.maxY, 0))
            }
            let a = overlap(lhs), b = overlap(rhs)
            return a == b ? distance(lhs) < distance(rhs) : a > b
        }
    }

    func isProcessGone(for window: String) -> Bool {
        let parts = window.split(separator: ":", maxSplits: 2)
        guard parts.count == 3, let pid = Int32(parts[0]), let stamp = Int64(parts[1]) else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return true }
        return stamp > 0 && Self.launchToken(app) > 0 && stamp != Self.launchToken(app)
    }

    static func launchToken(_ app: NSRunningApplication) -> Int64 {
        Int64(((app.launchDate?.timeIntervalSince1970 ?? 0) * 1_000).rounded())
    }

    func rescan() {
        guard running else { return }
        let oldScreens = screens
        let displays = Self.currentScreens()
        screens = displays.map(\.info)
        let physical = Dictionary(displays.map { ($0.info.id, $0.physical) }, uniquingKeysWith: { first, _ in first })
        let topologyChanged = physical != physicalScreens
        let screenChanged = screens != oldScreens || topologyChanged
        if topologyChanged {
            neighboringDisplays = physical.mapValues { own in
                physical.values.filter { $0 != own }.map(Box.init)
            }
        }
        physicalScreens = physical
        if screenChanged { invalidatePlacementCache(retryRestores: false) }
        let oldTrusted = trusted
        trusted = AXIsProcessTrusted()
        if trusted {
            grantRequest?.cancel()
            grantRequest = nil
            installMouseMonitor()
            scanWindows()
        } else {
            clearSideDimming()
            moveReadbacks = NativeMoveReadbacks()
            settlingPlacements.removeAll()
            removeObservers()
        }
        if oldTrusted != trusted { onEvent?(.permissionChanged(trusted)) }
        if screenChanged { onEvent?(.screensChanged) }
    }

    func invalidatePlacementCache(retryRestores: Bool = true) {
        moveReadbacks = NativeMoveReadbacks()
        settlingPlacements.removeAll()
        if retryRestores, trusted { retryUnconfirmedRestores() }
        for id in Array(entries.keys) {
            entries[id]?.lastRequestedSize = nil
            entries[id]?.lastRequestedOrigin = nil
        }
    }

    static func currentScreens() -> [(info: ScreenInfo, physical: CGRect)] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let displayID = n.uint32Value
            let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
            let id = uuid.map { CFUUIDCreateString(nil, $0) as String } ?? String(displayID)
            let f = screen.visibleFrame
            let frame = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
            guard !frame.isEmpty else { return nil }
            let physical = CGRect(x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY,
                                  width: screen.frame.width, height: screen.frame.height)
            return (ScreenInfo(id: id, name: screen.localizedName, bounds: Box(frame)), physical)
        }
    }

    func rememberFrame(_ id: String, _ window: Window) {
        if originals[id] == nil {
            originals[id] = Original(frame: window.rect, screen: bestScreen(for: window.rect)?.id)
        }
    }

    func place(_ id: String, in frame: Box, on screenID: String) {
        if draggingID == id { skippedDuringGesture = true; return }
        guard trusted, !pendingRelease.contains(id), !suspendedIDs.contains(id),
              let target = screens.first(where: { $0.id == screenID }), let window = entries[id] else { return }
        let rect = frame.nativeRect
        guard !rect.isNull, !rect.isInfinite, rect.width >= 1, rect.height >= 1 else { return }
        if let settlement = settlingPlacements[id], settlement.screen == target {
            settlement.desired = rect
            return
        }
        settlingPlacements.removeValue(forKey: id)
        // Read the actual flag before changing an owned minimize. A user's Dock action may
        // have completed before AX delivers the matching notification.
        if owned.contains(id), !unpark(id, intent: .show) { return }
        rememberFrame(id, window)
        if window.lastRequestedSize != rect.size, !NativeResizeSequence.sizeMatches(Box(window.rect), target: frame) {
            beginResize(id, desired: rect, on: target)
            return
        }
        let write = writeFrame(rect, for: id, on: target, purpose: .strip)
        if !write.verified {
            rejectPlacement(id, desired: rect, on: target, write: write)
        }
    }

    private func rejectPlacement(_ id: String, desired: CGRect, on screen: ScreenInfo, write: NativeFrameWrite) {
        moveReadbacks.remove(id)
        let settlement = PlacementSettlement(screen: screen, desired: desired, write: write)
        settlingPlacements[id] = settlement
        scheduleSettlement(id, settlement)
    }

    private func scheduleSettlement(_ id: String, _ settlement: PlacementSettlement) {
        guard let delay = settlement.retry.nextDelay() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.trusted, self.settlingPlacements[id] === settlement,
                  let window = self.entries[id] else { return }
            let screen = settlement.screen
            guard self.draggingID != id, !self.owned.contains(id), !self.suspendedIDs.contains(id),
                  self.screens.contains(screen) else {
                self.settlingPlacements.removeValue(forKey: id)
                return
            }
            let desired = settlement.desired
            let actual = NativeAX.frame(window.element)
            let minimized = NativeAX.flag(window.element, kAXMinimizedAttribute)
            let targetChanged = desired != settlement.lastWritten
            if let actual, !targetChanged, minimized == false, self.placed(actual, at: desired, on: screen) {
                self.entries[id]?.rect = actual
                self.settlingPlacements.removeValue(forKey: id)
                self.onEvent?(.reconcilePlacement)
                if self.deferredActivation == id { self.deferredActivation = nil; self.raise(id, activate: true) }
                return
            }
            if targetChanged || settlement.retry.shouldReissue {
                if targetChanged { settlement.retry = NativePlacementRetry() }
                settlement.beforeRetry = actual
                if let actual, minimized == false {
                    if !NativeResizeSequence.sizeMatches(Box(actual), target: Box(desired),
                                                        afterWrite: window.lastRequestedSize == desired.size) {
                        self.beginResize(id, desired: desired, on: screen)
                        return
                    }
                    self.entries[id]?.rect = actual
                    self.entries[id]?.lastRequestedOrigin = nil
                    settlement.write = self.writeFrame(desired, for: id, on: screen, purpose: .strip)
                }
                settlement.lastWritten = desired
            } else if settlement.firstSample == nil {
                settlement.firstSample = actual
            }
            if settlement.retry.isFinalCheck {
                NativePlacementLog.rejected(initial: settlement.initialWrite, latest: settlement.write, target: desired, actual: actual, usable: screen.bounds.nativeRect,
                                            neighbors: self.neighboringDisplays[screen.id] ?? [], minimized: minimized,
                                            firstSample: settlement.firstSample, beforeRetry: settlement.beforeRetry)
                // This main-queue callback still owns the current target. Releasing
                // immediately avoids scheduling a stale failure behind a new park/drop.
                self.release(id)
                self.onEvent?(.cannotTile(id))
            } else {
                self.scheduleSettlement(id, settlement)
            }
        }
    }

    private func failOpen(_ id: String) {
        guard pendingRelease.insert(id).inserted else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running, self.pendingRelease.contains(id), self.entries[id] != nil else { return }
            if self.draggingID == id {
                self.pendingRelease.remove(id)
                self.settlingPlacements.removeValue(forKey: id)
                self.skippedDuringGesture = true
                return
            }
            self.release(id)
            self.onEvent?(.cannotTile(id))
            self.pendingRelease.remove(id)
        }
    }

    @discardableResult
    func writeFrame(_ rect: CGRect, for id: String, on screen: ScreenInfo, purpose: NativePlacement.Purpose) -> NativeFrameWrite {
        var write = NativeFrameWrite()
        guard var window = entries[id] else { return write }
        let desired = purpose == .restoreOriginal ? rect.bounded(in: screen.bounds.nativeRect) : rect
        let neighbors = neighboringDisplays[screen.id] ?? []
        var actual = window.rect
        write.before = actual
        let originOnly = window.lastRequestedSize == desired.size && window.lastRequestedOrigin != nil
        if window.lastRequestedSize != desired.size {
            if purpose == .restoreOriginal, abs(actual.width - desired.width) > 0.5 || abs(actual.height - desired.height) > 0.5 {
                moveReadbacks.remove(id)
                let safe = NativePlacement.safeToGrow(at: Box(actual), to: Box(desired), neighbors: neighbors)
                if !safe,
                   let anchor = NativePlacement.projection(for: Box(desired), measured: Box(actual), on: screen.bounds,
                                                           neighbors: neighbors, purpose: purpose) {
                    write.coarsePosition = NativeAX.setOrigin(anchor.frame.nativeRect.origin, of: window.element)
                    write.afterCoarse = NativeAX.frame(window.element)
                    if let measured = write.afterCoarse { actual = measured }
                }
                guard NativePlacement.safeToGrow(at: Box(actual), to: Box(desired), neighbors: neighbors) else {
                    // An accepted origin write can still be in flight. Do not grow into
                    // another display until an observed anchor makes that resize safe.
                    entries[id]?.rect = actual
                    return write
                }
                write.size = NativeAX.setSize(desired.size, of: window.element)
                guard let measured = NativeAX.frame(window.element) else { return write }
                actual = measured
                write.afterSize = measured
            }
            window.lastRequestedSize = desired.size
            window.lastRequestedOrigin = nil
        }
        guard let projected = NativePlacement.projection(for: Box(desired), measured: Box(actual), on: screen.bounds,
                                                         neighbors: neighbors, purpose: purpose) else {
            window.rect = actual
            entries[id] = window
            return write
        }
        let origin = projected.frame.nativeRect.origin
        if window.lastRequestedOrigin != origin {
            if abs(actual.minX - origin.x) > 0.5 || abs(actual.minY - origin.y) > 0.5 ||
                !placed(actual, at: desired, on: screen, purpose: purpose) {
                write.position = NativeAX.setOrigin(origin, of: window.element)
                if write.position == .success, purpose == .strip, originOnly,
                   moveReadbacks.deferMove(id, from: Box(actual), to: Box(desired), on: screen,
                                           neighbors: neighbors) {
                    actual.origin = origin
                    scheduleMoveReadbacks()
                } else {
                    moveReadbacks.remove(id)
                    guard let measured = NativeAX.frame(window.element) else { return write }
                    actual = measured
                    write.afterPosition = measured
                }
            }
            window.lastRequestedOrigin = origin
        }
        window.rect = actual
        entries[id] = window
        write.verified = placed(actual, at: desired, on: screen, purpose: purpose)
        return write
    }

    private func placed(_ actual: CGRect, at desired: CGRect, on screen: ScreenInfo,
                        purpose: NativePlacement.Purpose = .strip) -> Bool {
        NativePlacement.accepts(Box(actual), for: Box(desired), on: screen.bounds,
                                neighbors: neighboringDisplays[screen.id] ?? [], purpose: purpose)
    }

    private func scheduleMoveReadbacks() {
        guard readbackWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.readbackWork = nil
            let batch = self.moveReadbacks.takeAll()
            guard self.running, self.trusted else { return }
            for (id, target) in batch {
                guard self.draggingID != id, !self.suspendedIDs.contains(id), !self.owned.contains(id),
                      self.screens.contains(target.screen), let window = self.entries[id] else { continue }
                let desired = target.frame.nativeRect
                let measured = NativeAX.frame(window.element)
                if let measured { self.entries[id]?.rect = measured }
                if measured.map({ self.placed($0, at: desired, on: target.screen) }) != true {
                    self.rejectPlacement(id, desired: desired, on: target.screen, write: NativeFrameWrite(position: .success))
                }
            }
        }
        readbackWork = work
        // One timer per batch, even if successive display ticks keep replacing targets.
        DispatchQueue.main.asyncAfter(deadline: .now() + NativeMoveReadbacks.interval, execute: work)
    }

    // Flush a predicted frame before changing ownership or restoring original geometry.
    private func refreshPendingMove(_ id: String) {
        guard moveReadbacks.remove(id) != nil, trusted, let window = entries[id] else { return }
        if let measured = NativeAX.frame(window.element) { entries[id]?.rect = measured }
        entries[id]?.lastRequestedOrigin = nil
        entries[id]?.lastRequestedSize = nil
    }

    func raise(_ id: String, activate: Bool) {
        if activate { deferredActivation = nil }
        if draggingID != nil { skippedDuringGesture = true; return }
        guard trusted, !pendingRelease.contains(id), !suspendedIDs.contains(id), let w = entries[id] else { return }
        if settlingPlacements[id] != nil {
            if activate { deferredActivation = id }
            return
        }
        if owned.contains(id), !unpark(id, intent: .show, retry: activate) {
            if activate { deferredActivation = id }
            return
        }
        performNativeRaise(id, window: w, activate: activate)
    }

    func park(_ id: String) {
        if draggingID == id { skippedDuringGesture = true; return }
        refreshPendingMove(id)
        guard trusted, !pendingRelease.contains(id),
              !suspendedIDs.contains(id), let w = entries[id] else { return }
        settlingPlacements.removeValue(forKey: id)
        if deferredActivation == id { deferredActivation = nil }
        if let request = restores[id] {
            if request.policy.intent != .park { replaceRestore(id, intent: .park) }
            return
        }
        guard !owned.contains(id) else { return }
        let minimized = NativeAX.flag(w.element, kAXMinimizedAttribute)
        if minimized == true {
            userMinimized.insert(id)
            suspendedIDs.insert(id)
            queueScan()
            return
        }
        guard minimized == false else {
            NativePlacementLog.parkingFailed("minimized flag unreadable")
            failOpen(id)
            return
        }
        guard NativeAX.settable(w.element, kAXMinimizedAttribute) else {
            NativePlacementLog.parkingFailed("minimized flag unwritable")
            failOpen(id)
            return
        }
        guard let record = parkingRecord(w) else {
            NativePlacementLog.parkingFailed("process launch unavailable")
            failOpen(id)
            return
        }
        let siblings = entries.values.filter { $0.app.processIdentifier == w.app.processIdentifier }
        guard NativeParkingJournal.canRecover(record, among: parkingCandidates(for: record, windows: siblings)) else {
            NativePlacementLog.parkingFailed("window recovery match ambiguous")
            failOpen(id)
            return
        }
        // Journal before hiding anything, so a crash between steps is recoverable.
        do { try journal.remember(record) } catch {
            NativePlacementLog.parkingFailed("journal write failed")
            failOpen(id)
            return
        }
        rememberFrame(id, w)
        ignoreGeneratedFocus()
        let accepted = NativeAX.setFlag(w.element, kAXMinimizedAttribute, true)
        let confirmed = NativeAX.flag(w.element, kAXMinimizedAttribute)
        if accepted || confirmed == true {
            owned.insert(id)
            let time = ProcessInfo.processInfo.systemUptime
            parkedAt[id] = time
            if confirmed != true {
                unconfirmedPark.insert(id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                    guard let self, self.running, self.parkedAt[id] == time else { return }
                    self.unconfirmedPark.remove(id)
                    if NativeAX.flag(w.element, kAXMinimizedAttribute) != true {
                        NativePlacementLog.parkingFailed("minimize unconfirmed")
                        self.failOpen(id)
                    }
                }
            }
        } else {
            NativePlacementLog.parkingFailed("minimize setter refused")
            if confirmed == false { try? journal.forget(id) }
            else { owned.insert(id) } // The write timed out; retain ownership until a read resolves it.
            failOpen(id)
        }
    }

    func release(_ id: String) {
        refreshPendingMove(id)
        guard trusted, let w = entries[id] else { return }
        settlingPlacements.removeValue(forKey: id)
        let wasOwned = owned.contains(id)
        if deferredActivation == id { deferredActivation = nil }
        if wasOwned, !unpark(id, intent: .release) { return }
        guard let original = originals.removeValue(forKey: id), !suspendedIDs.contains(id),
              NativeAX.flag(w.element, "AXFullScreen") != true,
              wasOwned || NativeAX.flag(w.element, kAXMinimizedAttribute) == false,
              let display = screens.first(where: { $0.id == original.screen }) ?? bestScreen(for: original.frame)
        else { return }
        entries[id]?.lastRequestedSize = nil
        entries[id]?.lastRequestedOrigin = nil
        writeFrame(original.frame, for: id, on: display, purpose: .restoreOriginal)
    }

    func releaseAll() {
        for id in Set(originals.keys).union(owned) { release(id) }
    }

    func parkingRecord(_ w: Window) -> NativeParkingJournal.Record? {
        parkingRecord(w, identifier: w.identifier)
    }

    func parkingCandidates(for saved: NativeParkingJournal.Record, windows: [Window]) -> [NativeParkingJournal.Record] {
        // AX identifiers can lose uniqueness as new windows open, and minimized windows
        // may disappear from Quartz. Compare candidates in the original identifier space.
        windows.compactMap { w in
            let key = saved.identifier?.hasPrefix("a:") == true ? w.axIdentifier : w.quartzIdentifier
            return parkingRecord(w, identifier: key)
        }
    }

    private func parkingRecord(_ w: Window, identifier: String?) -> NativeParkingJournal.Record? {
        guard let time = w.app.launchDate?.timeIntervalSince1970 else { return nil }
        return .init(pid: w.app.processIdentifier, launchTime: time, bundleID: w.app.bundleIdentifier ?? "",
                     id: w.info.id, identifier: identifier, title: w.info.title, frame: w.rect)
    }

    func ignoreGeneratedFocus() {
        lastManagerFocus = ProcessInfo.processInfo.systemUptime
        suppressFocusUntil = lastManagerFocus + NativeFocusObservation.suppressionInterval
    }
}
