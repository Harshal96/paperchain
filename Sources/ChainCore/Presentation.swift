public enum WindowCommand: Equatable {
    case place(String, Box, String)
    case park(String)
    case release(String)
    case raise(String, activate: Bool)
}

/// Maps a logical strip onto real windows. Only update() examines the entire workspace.
/// tick() visits the handful of visible columns, irrespective of the length of the chain.
public struct Presentation {
    private struct Track {
        var groupID: String
        var columns: [[String]]
        var logicalIndices: [Int]
        var selected: String?
        var selectedColumn: Int
        var bounds: Box
        var motion: ScrollMotion
        var target: Double
    }

    private struct Placement: Equatable {
        var frame: Box
        var screen: String
    }

    private var tracks: [String: Track] = [:]
    private var padding = Strip.defaultPadding
    private var owned = Set<String>()
    private var deferredRelease = Set<String>()
    // Keep inactive portions of the active strip behind the visible columns.
    // Only windows belonging to an inactive group need a manager-owned minimize.
    private var placements: [String: Placement] = [:]
    private var edgeWindows = Set<String>()
    private var parked = Set<String>()
    private var foreground: [String: [String]] = [:]
    private var pendingActivation: String?
    private var foregroundDuringScroll: String?
    private var unsettledScreens = Set<String>()

    public init() {}

    public mutating func cancelActivation() {
        pendingActivation = nil
        foregroundDuringScroll = nil
    }

    /// A verified click lifts an already exposed window. Keep that window on top while the camera catches up.
    public mutating func clickedBody(_ id: String, sameApplication: Bool = false) {
        if !sameApplication { observedFocus(id) }
        foregroundDuringScroll = id
    }

    /// Focus belongs to the most recent user action, including a click on another monitor.
    public mutating func observedFocus(_ id: String, sameApplication: Bool = false) {
        if pendingActivation != id { pendingActivation = nil }
        if foregroundDuringScroll != id { foregroundDuringScroll = nil }
        guard let screen = placements[id]?.screen else { return }
        // Native focus can arrive after mouse-up. Keep the exposed window that received it
        // above the outgoing center while the strip moves.
        let exposed = edgeWindows.contains(id) || foreground[screen]?.contains(id) == true
        if exposed { foregroundDuringScroll = id }
        // Activating another app or a covered window can reorder the visible stack.
        if !sameApplication || !exposed { foreground.removeValue(forKey: screen) }
    }

    public func isMoving(at time: Double) -> Bool {
        tracks.values.contains { $0.motion.isMoving(at: time) }
    }

    /// Back-to-front order last sent for this selection on its settled display.
    public func exposure(for selectedID: String, at time: Double) -> [String] {
        guard let screen = placements[selectedID]?.screen, let track = tracks[screen],
              track.selected == selectedID, !unsettledScreens.contains(screen), !track.motion.isMoving(at: time),
              let order = foreground[screen], order.last == selectedID else { return [] }
        return order
    }

    package func isClipped(_ id: String) -> Bool { edgeWindows.contains(id) }

    /// Shade peers only when the settled, focused column has visible columns on both sides.
    public func sideWindows(whenFocusing id: String, at time: Double) -> (bounds: Box, windows: [String])? {
        guard let focus = placements[id], let bounds = tracks[focus.screen]?.bounds else { return nil }
        let peers = exposure(for: id, at: time).dropLast()
        let origins = peers.compactMap { placements[$0]?.frame.x }
        guard origins.contains(where: { $0 < focus.frame.x }),
              origins.contains(where: { $0 > focus.frame.x }) else { return nil }
        return (bounds, Array(peers))
    }

    /// Convert a physical drop point into an insertion gap in the currently displayed strip.
    public func gap(on screen: String, atX x: Double, time: Double) -> Int? {
        guard x.isFinite, let track = tracks[screen], track.bounds.width > 0 else { return nil }
        let coordinate = x - track.bounds.x + track.motion.position(at: time)
        let pitch = Strip.stride(for: track.bounds.width, padding: padding)
        let columnWidth = Strip.columnWidth(for: track.bounds.width, count: track.columns.count, padding: padding)
        // Each window's center divides its before and after drop regions.
        let slot = ((coordinate - columnWidth / 2) / pitch).rounded(.down) + 1
        let gap = Int(min(Double(track.columns.count), max(0, slot)))
        return gap < track.logicalIndices.count ? track.logicalIndices[gap] : (track.logicalIndices.last.map { $0 + 1 } ?? 0)
    }

    /// Measure a drag from its starting column. Native placement can tuck a clipped window inside a display seam.
    package func reorderGap(on screen: String, from source: Int, movingBy distance: Double) -> Int? {
        guard distance.isFinite, let track = tracks[screen], track.bounds.width.isFinite, track.bounds.width > 0,
              let sourceSlot = track.logicalIndices.firstIndex(of: source) else { return nil }
        let pitch = Strip.stride(for: track.bounds.width, padding: padding)
        let slot = Double(sourceSlot) + (distance / pitch).rounded()
        let target = track.logicalIndices[Int(min(Double(track.logicalIndices.count - 1), max(0, slot)))]
        guard target != source else { return nil }
        // The insertion gap is measured before removing the dragged window.
        return target < source ? target : target + 1
    }

    public mutating func update(_ workspace: Workspace, available observed: Set<String>, at time: Double,
                                activate: String? = nil, force: Bool = false, reduceMotion: Bool = false,
                                windowPadding: Int = Strip.defaultPadding) -> [WindowCommand] {
        let newPadding = Strip.clampedPadding(windowPadding)
        let paddingChanged = padding != newPadding
        padding = newPadding
        if paddingChanged && activate == nil { cancelActivation() }
        let available = workspace.placementPaused.isEmpty ? observed : observed.subtracting(workspace.placementPaused)
        var commands: [WindowCommand] = []
        var nextOwned = Set<String>()
        var inactive = Set<String>()
        var background: [String: Placement] = [:]
        var currentScreens = Set<String>()
        for screen in workspace.screens.values where screen.enabled && screen.isConnected {
            let id = screen.info.id
            guard let group = screen.activeGroup else { continue }
            currentScreens.insert(id)
            for chain in screen.groups where chain.id != group.id {
                for column in chain.columns { inactive.formUnion(column.filter(available.contains)) }
            }
            let bounds = screen.info.bounds
            let geometryChanged = paddingChanged || tracks[id]?.bounds != bounds
            var columns: [[String]] = []
            var indices: [Int] = []
            for (index, column) in group.columns.enumerated() {
                let reachable = column.filter(available.contains)
                guard !reachable.isEmpty else { continue }
                columns.append(reachable)
                indices.append(index)
                nextOwned.formUnion(reachable)
                let staging = reachable.filter { window in
                    // After a group switch, restore already minimized windows on first
                    // exposure instead of waiting for GUI applications to restore a whole group.
                    (!parked.contains(window) || window == activate)
                        && (force || geometryChanged || placements[window]?.screen != id)
                }
                if !staging.isEmpty {
                    // Background windows occupy the first of two padded slots so
                    // bringing one into the strip only needs a position change.
                    let tiles = Strip.frames(columns: [reachable, []], bounds: bounds, offset: 0, padding: padding)
                    for window in staging {
                        if let tile = tiles[window] { background[window] = Placement(frame: tile, screen: id) }
                    }
                }
            }
            let selection = group.selectedID.flatMap { available.contains($0) ? $0 : nil } ?? columns.first?.first
            let index = selection.flatMap { selected in columns.firstIndex { $0.contains(selected) } } ?? 0
            let target = Strip.offset(column: index, count: columns.count, width: bounds.width, padding: padding)
            var motion = ScrollMotion(offset: target)
            if !reduceMotion, !geometryChanged, let previous = tracks[id], previous.groupID == group.id {
                motion = previous.motion
                if previous.target != target { motion.retarget(to: target, at: time) }
            }
            tracks[id] = Track(groupID: group.id, columns: columns, logicalIndices: indices, selected: selection, selectedColumn: index,
                               bounds: bounds, motion: motion, target: target)
        }
        tracks = tracks.filter { currentScreens.contains($0.key) }
        nextOwned.formUnion(inactive)
        let released = owned.subtracting(nextOwned)
        // A hidden app may reappear after its display was disabled. Keep the release
        // pending until its window is reachable or its closure is confirmed.
        deferredRelease.formUnion(released)
        deferredRelease.subtract(nextOwned)
        deferredRelease = deferredRelease.filter { workspace.windows[$0] != nil }
        let ready = deferredRelease.intersection(observed)
        commands += ready.sorted().map(WindowCommand.release)
        deferredRelease.subtract(ready)
        for id in released { placements.removeValue(forKey: id) }
        parked.formIntersection(nextOwned)
        let toPark = force ? inactive : inactive.subtracting(parked)
        for id in toPark.sorted() {
            commands.append(.park(id))
            placements.removeValue(forKey: id)
        }
        parked.formUnion(toPark)
        owned = nextOwned
        if let activate {
            pendingActivation = activate
            if foregroundDuringScroll != activate { foregroundDuringScroll = nil }
        }
        if let pendingActivation, !tracks.values.contains(where: { $0.selected == pendingActivation }) {
            cancelActivation()
        }
        commands += render(at: time, background: background, force: force, windows: workspace.windows)
        return commands
    }

    public mutating func tick(at time: Double) -> [WindowCommand] {
        guard !unsettledScreens.isEmpty else { return [] }
        return render(at: time, background: [:], force: false)
    }

    private mutating func render(at time: Double, background: [String: Placement], force: Bool,
                                 windows: [String: WindowInfo] = [:]) -> [WindowCommand] {
        var next: [String: Placement] = [:]
        var front: [String: [String]] = [:]
        var movingScreens = Set<String>()
        var nextEdges = Set<String>()
        for (id, track) in tracks {
            let offset = track.motion.position(at: time)
            if track.motion.isMoving(at: time) { movingScreens.insert(id) }
            let tiles = Strip.frames(columns: track.columns, bounds: track.bounds, offset: offset, padding: padding)
            for (window, box) in tiles {
                next[window] = Placement(frame: box, screen: id)
                if box.x < track.bounds.x || box.x + box.width > track.bounds.x + track.bounds.width {
                    nextEdges.insert(window)
                }
            }
            if !track.columns.isEmpty && track.bounds.width > 0 {
                let center = offset / Strip.stride(for: track.bounds.width, padding: padding) + 0.5
                // Shared display seams and app minimum sizes can make physical
                // windows overlap. The central stack stays above those neighbors.
                let nearest = abs(Double(track.selectedColumn) - center) <= 0.500001
                    ? track.selectedColumn : min(track.columns.count - 1, max(0, Int(center.rounded())))
                let centerRows = track.columns[nearest]
                let layers: [String]
                if movingScreens.contains(id), let selected = track.selected, tiles[selected] != nil,
                   track.selectedColumn == 0 || track.selectedColumn == track.columns.count - 1,
                   !background.contains(where: { $0.value.screen == id && tiles[$0.key] == nil }),
                   foreground[id] != nil || !hasCoveredSibling(of: selected, in: track, tiles: tiles, windows: windows) {
                    // The departing preview may be tucked under the middle window at a display seam.
                    // Move it with the strip, but only raise the two columns sliding into place.
                    let pair = track.selectedColumn == 0 ? track.columns.prefix(2) : track.columns.suffix(2)
                    layers = pair.flatMap { $0 }.filter { tiles[$0] != nil }
                } else {
                    layers = Array(tiles.keys)
                }
                let edges = layers.filter { !centerRows.contains($0) }.sorted()
                front[id] = edges + centerRows.filter { $0 != track.selected }
                if let selected = track.selected, centerRows.contains(selected) { front[id]?.append(selected) }
                if let focused = foregroundDuringScroll, track.selected == focused, tiles[focused] != nil {
                    front[id]?.removeAll { $0 == focused }
                    front[id]?.append(focused)
                }
            }
        }
        var commands: [WindowCommand] = []
        var changedLayers = Set<String>()
        var staging = background
        for id in edgeWindows where next[id] == nil && staging[id] == nil {
            guard var placement = placements[id], let bounds = tracks[placement.screen]?.bounds else { continue }
            // Once the window leaves the viewport, bring it wholly onto its owner
            // behind the new visible columns. This also handles jumps that skip several tiles.
            placement.frame.x = max(bounds.x, min(placement.frame.x, bounds.x + bounds.width - placement.frame.width))
            staging[id] = placement
        }
        for (id, placement) in staging.sorted(by: { $0.key < $1.key }) where next[id] == nil {
            commands.append(.place(id, placement.frame, placement.screen))
            placements[id] = placement
            parked.remove(id)
            changedLayers.insert(placement.screen)
        }
        for (id, placement) in next.sorted(by: { $0.key < $1.key }) {
            if force || placements[id] != placement {
                commands.append(.place(id, placement.frame, placement.screen))
                placements[id] = placement
                parked.remove(id)
            }
        }
        for (screen, windows) in front.sorted(by: { $0.key < $1.key }) {
            if force || changedLayers.contains(screen) || foreground[screen] != windows {
                var raises = windows[...]
                if !force, !changedLayers.contains(screen), let focused = foregroundDuringScroll, windows.last == focused,
                   let old = foreground[screen] {
                    // Keep the longest prefix already layered in order above every outgoing tile.
                    // Raising only the remaining suffix avoids giving key focus back to a sibling.
                    var below = old.lastIndex(where: { !windows.contains($0) }) ?? -1
                    raises = windows.drop(while: { id in
                        guard let i = old.firstIndex(of: id), i > below else { return false }
                        below = i
                        return true
                    })
                }
                commands += raises.map { .raise($0, activate: false) }
            }
        }
        if let id = pendingActivation, let placement = next[id], !movingScreens.contains(placement.screen) {
            commands.append(.raise(id, activate: true))
            pendingActivation = nil
        }
        if let focused = foregroundDuringScroll, let placement = next[focused], !movingScreens.contains(placement.screen) {
            foregroundDuringScroll = nil
        }
        unsettledScreens = movingScreens
        edgeWindows = nextEdges
        foreground = front
        return commands
    }

    // App activation can also lift a covered sibling over the departing preview.
    // Rebuild all exposed layers once when the previous native order is unknown.
    private func hasCoveredSibling(of id: String, in track: Track, tiles: [String: Box], windows: [String: WindowInfo]) -> Bool {
        guard let selected = windows[id] else { return false }
        let app = selected.bundleID ?? selected.app
        return track.columns.joined().contains { peer in
            guard tiles[peer] == nil, let window = windows[peer] else { return false }
            return (window.bundleID ?? window.app) == app
        }
    }
}
