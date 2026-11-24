import AppKit
import ChainCore
import Decisions
import QuartzCore

@MainActor
final class Runtime: NSObject, PaperActions {
    static let shared = Runtime()
    static let defaults = ["Social Media", "Writing", "Work & Coding"]
    private static let windowPaddingKey = "appearance.windowPadding"
    private static let floatingAppsKey = "windows.floatingApps"
    @Published private(set) var workspace = Workspace()
    @Published private(set) var availableWindowIDs = Set<String>()
    @Published private(set) var categories = defaults
    @Published private(set) var floatingApps = UserDefaults.standard.dictionary(forKey: floatingAppsKey)
        as? [String: String] ?? [:]
    @Published private var regroupSettings = RegroupSettings()
    var decisionProvider: DecisionProvider { regroupSettings.provider }
    var ollamaModel: String { regroupSettings.ollamaModel }
    var canRegroup: Bool {
        hasAccessibility && !isRegrouping && regroupSettings.isReady(categoryCount: categories.count, hasTypeSafeKey: hasAPIKey)
    }
    @Published private(set) var hasAPIKey = false
    @Published private(set) var hasAccessibility = false
    @Published private(set) var windowPadding = Strip.clampedPadding(
        UserDefaults.standard.object(forKey: windowPaddingKey) as? Int ?? Strip.defaultPadding)
    @Published private(set) var dimSideWindows = UserDefaults.standard.bool(forKey: "appearance.dimSideWindows")
    @Published private(set) var statusText = ""
    @Published private(set) var isRegrouping = false

    private let desktop = NativeDesktop()
    private var presentation = Presentation()
    private var dockFocus = DockFocusSelection()
    private lazy var docks = PaperDocks(actions: self)
    private var clock: CADisplayLink?
    private var writeBack: DispatchWorkItem?
    private var inventoryChange: DispatchWorkItem?
    private var displayLayoutChanged = false
    private var recentSessionIsWritable = true
    private var running = false
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func start() {
        guard !running else { return }
        running = true
        categories = UserDefaults.standard.stringArray(forKey: "decision.categories") ?? Self.defaults
        do { workspace = try SessionFile.load() } catch {
            recentSessionIsWritable = false
            statusText = "Could not read the saved workspace. Running in memory."
        }
        if decisionProvider == .typeSafe { refreshKeyStatus() }
        desktop.onEvent = { [weak self] in self?.receive($0) }
        desktop.sideDimmingPlan = { [weak self] id in
            guard let self else { return nil }
            return self.presentation.sideWindows(whenFocusing: id, at: self.now)
        }
        desktop.dimSideWindows = dimSideWindows
        desktop.exposurePlan = { [weak self] id in
            guard let self, !self.workspace.placementPaused.contains(id),
                  let screen = self.workspace.screens.values.first(where: {
                      $0.enabled && $0.isConnected && $0.activeGroup?.selectedID == id
                  }) else { return nil }
            return (screen.info, self.presentation.exposure(for: id, at: self.now))
        }
        desktop.activeStripLocation = { [weak self] id in
            guard let self, self.availableWindowIDs.contains(id), !self.workspace.placementPaused.contains(id),
                  let owner = self.workspace.location(of: id), let screen = self.workspace.screens[owner.screenID],
                  screen.isConnected, screen.enabled, screen.activeGroupID == owner.groupID else { return nil }
            return (screen.id, self.presentation.isClipped(id))
        }
        desktop.setFloatingAppBundleIDs(Set(floatingApps.keys))
        desktop.start()
        ingest(force: true, selectFrontmost: true)
    }

    func stop() {
        guard running else { return }
        running = false
        writeBack?.cancel()
        inventoryChange?.cancel()
        displayLayoutChanged = false
        clock?.invalidate()
        clock = nil
        dockFocus = DockFocusSelection()
        desktop.onEvent = nil
        desktop.stop()
        persist()
    }

    private func receive(_ event: NativeDesktop.Event) {
        guard running else { return }
        switch event {
        case .windowsChanged, .screensChanged, .permissionChanged:
            // Adding a display can turn a free edge into a shared edge while
            // every logical frame on the original display stays identical.
            if case .screensChanged = event { displayLayoutChanged = true }
            // Multiple observer notifications may describe the same inventory update.
            if inventoryChange == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.inventoryChange = nil
                    self?.ingest()
                }
                inventoryChange = work
                DispatchQueue.main.async(execute: work)
            }
        case let .closed(id):
            edit { $0.close(id) }
        case let .cannotTile(id):
            guard workspace.location(of: id) != nil else { return }
            edit { $0.pausePlacement(id) }
            statusText = "A window is floating. Select its chain icon or rescan to retry."
        case .reconcilePlacement:
            install(workspace, activate: nil, force: true)
        case .pointerDown:
            presentation.cancelActivation()
            dockFocus = DockFocusSelection()
        case let .focused(id, sameApplication):
            desktop.cancelExposureCheck()
            presentation.observedFocus(id, sameApplication: sameApplication)
            selectNativeWindow(id, activate: false)
            desktop.checkExposureAfterActivation(id)
        case let .bodyClicked(id, sameApplication):
            presentation.clickedBody(id, sameApplication: sameApplication)
            selectNativeWindow(id, activate: true)
        case let .restored(id):
            ingest(selectWindow: id, activateSelection: true)
        case let .dragged(id, frame, horizontalMovement):
            dockFocus = DockFocusSelection()
            let drop = desktop.lastDrop
            let x = drop?.x ?? (frame.x + frame.width / 2)
            let y = drop?.y ?? (frame.y + frame.height / 2)
            let target = desktop.dropScreen(of: id, x: x, y: y)
            // A dropped window may have moved before its creation notification was processed.
            ingestInventoryBeforeDrop(id)
            let view = presentation, time = now
            edit(activate: id, force: true) {
                $0.drop(id, x: x, y: y, float: drop?.detach == true, fallbackScreen: target,
                        presentation: view, at: time, horizontalMovement: horizontalMovement)
            }
        }
    }

    private func selectNativeWindow(_ id: String, activate: Bool) {
        if dockFocus.floater != id { dockFocus = DockFocusSelection() }
        if desktop.deferredActivation != id { desktop.deferredActivation = nil }
        if !availableWindowIDs.contains(id) {
            ingest(selectWindow: id, activateSelection: activate)
            return
        }
        guard !workspace.placementPaused.contains(id), let here = workspace.location(of: id),
              let screen = workspace.screens[here.screenID], screen.isConnected, screen.enabled else { return }
        edit(activate: activate ? id : nil) { $0.select(id) }
    }

    private func ingestInventoryBeforeDrop(_ id: String) {
        if workspace.windows[id] == nil, let window = desktop.windows.first(where: { $0.id == id }),
           let screen = desktop.screenID(of: id) {
            workspace.discover(window, on: screen)
        }
    }

    private func ingest(force: Bool = false, retryPlacements: Bool = false, selectFrontmost: Bool = false,
                        selectWindow: String? = nil, activateSelection: Bool = false) {
        inventoryChange?.cancel()
        inventoryChange = nil
        let reapplyLayout = force || displayLayoutChanged
        displayLayoutChanged = false
        let accessChanged = hasAccessibility != desktop.trusted
        if accessChanged {
            hasAccessibility = desktop.trusted
            if hasAccessibility, statusText == Self.missingAccessMessage { statusText = "" }
        }
        let inventory = desktop.trusted ? desktop.windows : []
        let available = Set(inventory.map(\.id)).subtracting(desktop.suspendedIDs)
        let availabilityChanged = availableWindowIDs != available
        if availabilityChanged { availableWindowIDs = available }
        var next = workspace
        if retryPlacements { next.retryAllPlacements() }
        next.syncScreens(desktop.screens)
        let observations = inventory.compactMap { window -> (WindowInfo, String)? in
            guard available.contains(window.id), let screen = desktop.screenID(of: window.id) else { return nil }
            return (window, screen)
        }
        next.rescan(observations)
        for window in next.windows.values where !available.contains(window.id) {
            if desktop.isProcessGone(for: window.id) ||
                (!next.detached.contains(window.id) && desktop.isFloatingWindow(window)) {
                next.close(window.id)
            }
        }
        let selected = selectWindow ?? (selectFrontmost ? desktop.focusedID : nil)
        if let id = selected, available.contains(id), let owner = next.location(of: id),
           next.screens[owner.screenID]?.enabled == true { next.select(id) }
        let changed = next != workspace
        install(next, activate: activateSelection ? selected : nil, force: reapplyLayout)
        if (accessChanged || availabilityChanged) && !changed && !reapplyLayout { docks.refresh() }
    }

    private func edit(activate: String? = nil, force: Bool = false, _ change: (inout Workspace) -> Void) {
        var next = workspace
        change(&next)
        install(next, activate: activate, force: force)
    }

    private func install(_ next: Workspace, activate: String?, force: Bool) {
        dockFocus.reconcile(next, activating: activate)
        if let activate { desktop.focusObservation.supersedeBodyClick(with: activate) }
        if let activate, desktop.deferredActivation != activate { desktop.deferredActivation = nil }
        let changed = next != workspace
        if changed {
            workspace = next
            writeBack?.cancel()
            let write = DispatchWorkItem { [weak self] in self?.persist() }
            writeBack = write
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: write)
        }
        let time = now
        let commands = presentation.update(workspace, available: availableWindowIDs, at: time, activate: activate,
                                           force: force, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                           windowPadding: windowPadding)
        apply(commands)
        if desktop.dimSideWindows {
            if let id = desktop.dimmedAround, presentation.sideWindows(whenFocusing: id, at: time) == nil {
                desktop.clearSideDimming()
            }
            desktop.scheduleSideDimming()
        }
        if force || changed { docks.refresh() }
        if clock == nil, presentation.isMoving(at: time),
           let screen = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) {
            let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
            let refresh = Float(max(30, screen.maximumFramesPerSecond))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: refresh, preferred: refresh)
            link.add(to: .main, forMode: .common)
            clock = link
        }
    }

    @objc private func frame(_ sender: CADisplayLink) {
        let time = now
        apply(presentation.tick(at: time))
        if !presentation.isMoving(at: time) {
            sender.invalidate()
            clock = nil
            desktop.scheduleSideDimming()
        }
    }

    private func apply(_ commands: [WindowCommand]) {
        for command in commands {
            switch command {
            case let .place(id, box, screen): desktop.place(id, in: box, on: screen)
            case let .park(id): desktop.park(id)
            case let .release(id): desktop.release(id)
            case let .raise(id, activate):
                // A rejected selected tile floats above the strip. Raising a sibling
                // during settlement (or its failure reflow) would cover it again.
                if !activate, let floater = dockFocus.floater,
                   dockFocus.coversPassiveRaise(id, in: workspace, settling: desktop.awaitingPlacement(floater)) { continue }
                desktop.raise(id, activate: activate)
            }
        }
        if let floater = dockFocus.floater, !workspace.placementPaused.contains(floater),
           !desktop.awaitingPlacement(floater) { dockFocus = DockFocusSelection() }
        desktop.resumeExposureCheck()
    }

    private func persist() {
        guard recentSessionIsWritable else { return }
        do { try SessionFile.save(workspace) } catch { statusText = "Could not save the workspace." }
    }

    func requestAccessibility() { desktop.requestAccess() }
    func setWindowPadding(_ points: Int) {
        let padding = Strip.clampedPadding(points)
        guard padding != windowPadding else { return }
        windowPadding = padding
        UserDefaults.standard.set(padding, forKey: Self.windowPaddingKey)
        if running {
            desktop.deferredActivation = nil
            install(workspace, activate: nil, force: false)
        }
    }

    func setDimSideWindows(_ enabled: Bool) {
        dimSideWindows = enabled
        UserDefaults.standard.set(enabled, forKey: "appearance.dimSideWindows")
        desktop.dimSideWindows = enabled
    }
    func setAppFloating(_ bundleID: String, name: String?) {
        guard floatingApps[bundleID] != name else { return }
        floatingApps[bundleID] = name
        UserDefaults.standard.set(floatingApps, forKey: Self.floatingAppsKey)
        desktop.setFloatingAppBundleIDs(Set(floatingApps.keys))
        if running {
            desktop.rescan()
            ingest()
        }
    }

    private static let missingAccessMessage = "Grant Accessibility access in Settings."
    func rescan() {
        desktop.rescan()
        desktop.invalidatePlacementCache()
        ingest(force: true, retryPlacements: true)
        statusText = hasAccessibility ? "Rescanned \(availableWindowIDs.count) eligible windows." : Self.missingAccessMessage
    }

    func setEnabled(_ enabled: Bool, screen: String) {
        edit { $0.setEnabled(enabled, on: screen) }
        if enabled { rescan() }
    }

    func createGroup(screen: String, name: String) { edit { _ = $0.createGroup(named: name, on: screen) } }
    func renameGroup(_ id: String, screen: String, name: String) { edit { $0.renameGroup(id, to: name, on: screen) } }
    func selectGroup(_ id: String, screen: String) {
        dockFocus = DockFocusSelection()
        let target = workspace.screens[screen]?.groups.first { $0.id == id }?.selectedID
        edit(activate: target) { $0.switchGroup(id, on: screen) }
    }

    func focus(_ window: String) {
        guard availableWindowIDs.contains(window) else { return }
        desktop.deferredActivation = nil
        presentation.observedFocus(window)
        var raisedOn: String?
        if workspace.placementPaused.contains(window) || desktop.awaitingPlacement(window),
           let location = workspace.location(of: window), desktop.focusFloatingWindow(window) {
            raisedOn = location.screenID
        }
        let activate = dockFocus.clicked(window, directlyRaisedOn: raisedOn)
        edit(activate: activate) {
            $0.retryPlacement(window)
            $0.select(window)
        }
    }

    func reattachDetachedWindows() {
        let observed = desktop.windows.compactMap { window -> (WindowInfo, String)? in
            guard availableWindowIDs.contains(window.id), let screen = desktop.screenID(of: window.id) else { return nil }
            return (window, screen)
        }
        let before = workspace.detached.count
        edit { $0.reattachDetached(observed) }
        statusText = "Reattached \(before - workspace.detached.count) windows on enabled displays."
    }

    func icon(for window: String) -> NSImage? { desktop.icon(for: window) }
    func moveWindow(_ window: String, to group: String, screen: String, before: String?) {
        guard let destination = workspace.screens[screen]?.groups.first(where: { $0.id == group }) else { return }
        let gap = before.flatMap { anchor in destination.columns.firstIndex { $0.contains(anchor) } } ?? destination.columns.count
        edit(activate: window) { $0.move(window, to: screen, group: group, at: gap) }
    }
    func detach(_ window: String) { edit { $0.detach(window) } }
    func stack(_ window: String, with other: String) { edit(activate: window) { $0.stack(window, with: other) } }
    func unstack(_ window: String) { edit(activate: window) { $0.unstack(window) } }

    func setCategories(_ names: [String]) {
        var seen = Set<String>()
        let clean = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        guard clean.count <= 255 else { statusText = "Choose up to 255 categories."; return }
        categories = clean.isEmpty ? Self.defaults : clean
        UserDefaults.standard.set(categories, forKey: "decision.categories")
        statusText = "Categories saved."
    }

    func saveAPIKey(_ key: String) {
        do {
            try KeyStore.save(key)
            hasAPIKey = !key.isEmpty
            statusText = hasAPIKey ? "API key saved in Keychain." : "API key removed."
        } catch { statusText = "Keychain could not save this change." }
    }

    private func refreshKeyStatus() {
        do { hasAPIKey = try KeyStore.read() != nil }
        catch { hasAPIKey = false; statusText = "Keychain is unavailable." }
    }

    func setDecisionProvider(_ provider: DecisionProvider) {
        guard !isRegrouping, provider != decisionProvider else { return }
        regroupSettings.provider = provider
        regroupSettings.save()
        statusText = ""
        if provider == .typeSafe { refreshKeyStatus() }
    }

    func setOllamaModel(_ model: String) {
        guard !isRegrouping, model != ollamaModel else { return }
        regroupSettings.ollamaModel = model
        regroupSettings.save()
        statusText = ""
    }

    func regroup() {
        guard !isRegrouping else { return }
        guard hasAccessibility else { statusText = Self.missingAccessMessage; return }
        let request = RegroupRequest(workspace: workspace, available: availableWindowIDs, categories: categories)
        let windows = request.windows.map { DecisionWindow(id: $0.id, app: $0.app, title: $0.title) }
        guard !windows.isEmpty else { statusText = "No managed windows to group."; return }
        let settings = regroupSettings
        isRegrouping = true
        Task {
            defer { isRegrouping = false }
            do {
                let labels = try await settings.classify(windows: windows, categories: request.categories, typeSafeKey: KeyStore.read)
                guard running else { return }
                let valid = request.applicable(labels, in: workspace, available: availableWindowIDs, categories: categories)
                edit { $0.applyClassification(valid) }
                statusText = "Grouped \(valid.count) of \(windows.count) windows."
            } catch {
                statusText = "Regroup failed. \(error.localizedDescription)"
            }
        }
    }
}
