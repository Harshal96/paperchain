import Foundation

public struct Box: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ScreenInfo: Codable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var bounds: Box

    public init(id: String, name: String, bounds: Box) {
        self.id = id
        self.name = name
        self.bounds = bounds
    }
}

public struct WindowInfo: Codable, Equatable, Identifiable {
    public let id: String
    public var app: String
    public var title: String

    public init(id: String, app: String, title: String) {
        self.id = id
        self.app = app
        self.title = title
    }
}

public struct WindowLocation: Equatable {
    public let screenID: String
    public let groupID: String
    public let column: Int
    public let row: Int
}

public struct ChainGroup: Codable, Equatable, Identifiable {
    public let id: String
    public fileprivate(set) var name: String
    public fileprivate(set) var columns: [[String]] = []
    public fileprivate(set) var selectedID: String?

    public var orderedIDs: [String] { columns.flatMap { $0 } }

    fileprivate init(name: String) {
        self.id = UUID().uuidString
        self.name = name
    }

    fileprivate mutating func packForPortrait() {
        var packed: [[String]] = []
        for column in columns {
            if column.count == 1, packed.last?.count == 1 {
                packed[packed.count - 1].append(column[0])
            } else {
                packed.append(column)
            }
        }
        columns = packed
    }

    fileprivate mutating func remove(_ location: WindowLocation) {
        let position = columns.prefix(location.column).reduce(location.row) { $0 + $1.count }
        let removed = columns[location.column].remove(at: location.row)
        if columns[location.column].isEmpty { columns.remove(at: location.column) }
        if selectedID == removed {
            let remaining = orderedIDs
            selectedID = remaining.isEmpty ? nil : remaining[min(position, remaining.count - 1)]
        }
    }

    fileprivate mutating func insert(_ id: String, at gap: Int?, portrait: Bool, select: Bool) {
        let focused = selectedID.flatMap { id in columns.firstIndex { $0.contains(id) } }
        if let gap {
            columns.insert([id], at: max(0, min(gap, columns.count)))
        } else if portrait, let halfFull = focused.flatMap({ columns[$0].count == 1 ? $0 : nil })
                    ?? columns.firstIndex(where: { $0.count == 1 }) {
            columns[halfFull].append(id)
        } else {
            columns.insert([id], at: focused.map { $0 + 1 } ?? columns.count)
        }
        if select || selectedID == nil { selectedID = id }
    }
}

public struct ScreenState: Codable, Equatable, Identifiable {
    public var id: String { info.id }
    public fileprivate(set) var info: ScreenInfo
    public fileprivate(set) var enabled = true
    public fileprivate(set) var isConnected = true
    public fileprivate(set) var groups: [ChainGroup]
    public fileprivate(set) var activeGroupID: String

    public var activeGroup: ChainGroup? { groups.first { $0.id == activeGroupID } }
    fileprivate var isPortrait: Bool { info.bounds.height > info.bounds.width }

    fileprivate init(info: ScreenInfo) {
        let inbox = ChainGroup(name: "Inbox")
        self.info = info
        self.groups = [inbox]
        self.activeGroupID = inbox.id
    }

    fileprivate mutating func ensureGroup(named name: String) -> Int {
        if let existing = groups.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        groups.append(ChainGroup(name: name))
        return groups.count - 1
    }
}

public struct Workspace: Codable, Equatable {
    public private(set) var windows: [String: WindowInfo] = [:]
    public private(set) var screens: [String: ScreenState] = [:]
    public private(set) var detached: Set<String> = []
    // A native application can decline placement while starting or changing Space.
    // Keep its slot and dock icon. Only an explicit user detach survives relaunch.
    public private(set) var placementPaused: Set<String> = []
    private var categoryNames: [String] = []
    private var releasedOnScreen: [String: String] = [:]
    // A rescan can report every window on each pass. A membership check must not walk
    // every group for each title refresh. Rebuild this index from the columns on load.
    private var ownedIDs: Set<String> = []

    private enum CodingKeys: String, CodingKey {
        case windows, screens, detached, categoryNames, releasedOnScreen
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        windows = try saved.decode([String: WindowInfo].self, forKey: .windows)
        screens = try saved.decode([String: ScreenState].self, forKey: .screens)
        detached = try saved.decode(Set<String>.self, forKey: .detached)
        categoryNames = try saved.decodeIfPresent([String].self, forKey: .categoryNames) ?? []
        releasedOnScreen = try saved.decodeIfPresent([String: String].self, forKey: .releasedOnScreen) ?? [:]
        for screen in screens.values {
            for group in screen.groups {
                for column in group.columns { ownedIDs.formUnion(column) }
            }
        }
    }

    /// Entering portrait packs adjacent single-window columns in every group. Existing
    /// stacks survive both rotation directions, including a return to landscape.
    public mutating func syncScreens(_ connected: [ScreenInfo]) {
        let connectedIDs = Set(connected.map(\.id))
        for id in screens.keys where !connectedIDs.contains(id) { screens[id]?.isConnected = false }
        for info in connected {
            if var screen = screens[info.id] {
                let wasPortrait = screen.isPortrait
                screen.info = info
                screen.isConnected = true
                if !wasPortrait, screen.isPortrait {
                    for index in screen.groups.indices { screen.groups[index].packForPortrait() }
                }
                screens[info.id] = screen
            } else {
                var screen = ScreenState(info: info)
                for name in categoryNames { _ = screen.ensureGroup(named: name) }
                screens[info.id] = screen
            }
        }
    }

    public mutating func setEnabled(_ enabled: Bool, on screenID: String) {
        screens[screenID]?.enabled = enabled
    }

    public func location(of id: String) -> WindowLocation? {
        for (screenID, screen) in screens {
            for group in screen.groups {
                for (column, members) in group.columns.enumerated() {
                    if let row = members.firstIndex(of: id) {
                        return WindowLocation(screenID: screenID, groupID: group.id, column: column, row: row)
                    }
                }
            }
        }
        return nil
    }

    /// An omitted window may be minimized, occluded, on another Space, or temporarily inaccessible.
    /// Call close only after receiving independent evidence that its window was destroyed.
    public mutating func rescan(_ observed: [(window: WindowInfo, screenID: String)], floating: Set<String> = []) {
        // Keep known windows until any pending native release can restore them.
        // A separate manual detach still applies if the app is managed again.
        for id in floating { releaseMembership(of: id) }
        for (window, screenID) in observed where !floating.contains(window.id) {
            discover(window, on: screenID)
        }
    }

    public mutating func discover(_ window: WindowInfo, on screenID: String) {
        if windows[window.id] != window { windows[window.id] = window }
        guard !detached.contains(window.id), !ownedIDs.contains(window.id),
              let screen = screens[screenID], screen.isConnected,
              let index = groupIndex(screen.activeGroupID, on: screenID) else { return }
        if let released = releasedOnScreen[window.id], released != screenID { return }
        guard screen.enabled else {
            releasedOnScreen[window.id] = screenID
            return
        }
        releasedOnScreen.removeValue(forKey: window.id)
        screens[screenID]?.groups[index].insert(window.id, at: nil, portrait: screen.isPortrait, select: false)
        ownedIDs.insert(window.id)
    }

    @discardableResult
    public mutating func createGroup(named name: String, on screenID: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var screen = screens[screenID] else { return nil }
        let index = screen.ensureGroup(named: name)
        screen.activeGroupID = screen.groups[index].id
        screens[screenID] = screen
        return screen.activeGroupID
    }

    public mutating func renameGroup(_ groupID: String, to name: String, on screenID: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = groupIndex(groupID, on: screenID),
              let groups = screens[screenID]?.groups,
              !groups.contains(where: { $0.id != groupID && $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return }
        screens[screenID]?.groups[index].name = name
    }

    public mutating func switchGroup(_ groupID: String, on screenID: String) {
        guard groupIndex(groupID, on: screenID) != nil else { return }
        screens[screenID]?.activeGroupID = groupID
    }

    public mutating func select(_ windowID: String) {
        guard let owned = location(of: windowID), let index = groupIndex(owned.groupID, on: owned.screenID) else { return }
        screens[owned.screenID]?.groups[index].selectedID = windowID
        screens[owned.screenID]?.activeGroupID = owned.groupID
    }

    public mutating func close(_ windowID: String) {
        releaseMembership(of: windowID)
        windows.removeValue(forKey: windowID)
        detached.remove(windowID)
    }

    public mutating func detach(_ windowID: String) {
        guard windows[windowID] != nil else { return }
        releaseMembership(of: windowID)
        detached.insert(windowID)
    }

    public mutating func pausePlacement(_ id: String) {
        if ownedIDs.contains(id) { placementPaused.insert(id) }
    }

    public mutating func retryPlacement(_ id: String) { placementPaused.remove(id) }

    public mutating func retryAllPlacements() { placementPaused.removeAll() }

    /// Restore older detachments only when the user explicitly requests it. A
    /// hidden window stays excluded until its display and eligibility are known.
    public mutating func reattachDetached(_ observed: [(window: WindowInfo, screenID: String)]) {
        for (window, screenID) in observed {
            guard let screen = screens[screenID], screen.isConnected, screen.enabled,
                  detached.remove(window.id) != nil else { continue }
            discover(window, on: screenID)
        }
    }

    /// A gap is measured in the displayed columns before removing the source window.
    public mutating func move(_ windowID: String, to screenID: String, group groupID: String? = nil, at columnIndex: Int? = nil) {
        guard windows[windowID] != nil, let screen = screens[screenID], screen.isConnected else { return }
        let destination = groupID ?? screen.activeGroupID
        guard let index = groupIndex(destination, on: screenID) else { return }
        retryPlacement(windowID)
        let source = location(of: windowID)
        if screen.enabled, columnIndex == nil, source?.screenID == screenID, source?.groupID == destination {
            select(windowID)
            return
        }
        var gap = columnIndex
        if let source, source.screenID == screenID, source.groupID == destination,
           let columnIndex, columnIndex > source.column, screen.groups[index].columns[source.column].count == 1 {
            gap = columnIndex - 1
        }
        removeMembership(of: windowID)
        detached.remove(windowID)
        guard screen.enabled else {
            ownedIDs.remove(windowID)
            releasedOnScreen[windowID] = screenID
            return
        }
        releasedOnScreen.removeValue(forKey: windowID)
        screens[screenID]?.groups[index].insert(windowID, at: gap, portrait: screen.isPortrait, select: true)
        ownedIDs.insert(windowID)
        screens[screenID]?.activeGroupID = destination
    }

    public mutating func stack(_ windowID: String, with targetID: String) {
        guard windowID != targetID, windows[windowID] != nil, let target = location(of: targetID),
              let screen = screens[target.screenID], screen.enabled, screen.isConnected,
              let index = groupIndex(target.groupID, on: target.screenID),
              screen.groups[index].columns[target.column].count == 1 else { return }
        retryPlacement(windowID)
        retryPlacement(targetID)
        removeMembership(of: windowID)
        // Removing the source may have shifted the target column.
        guard let refreshed = location(of: targetID) else { return }
        detached.remove(windowID)
        releasedOnScreen.removeValue(forKey: windowID)
        screens[target.screenID]?.groups[index].columns[refreshed.column].append(windowID)
        ownedIDs.insert(windowID)
        select(windowID)
    }

    public mutating func unstack(_ windowID: String) {
        guard let source = location(of: windowID), let screen = screens[source.screenID],
              screen.enabled, screen.isConnected, let index = groupIndex(source.groupID, on: source.screenID),
              screen.groups[index].columns[source.column].count == 2 else { return }
        retryPlacement(windowID)
        screens[source.screenID]?.groups[index].remove(source)
        screens[source.screenID]?.groups[index].insert(windowID, at: source.column + 1, portrait: false, select: true)
        screens[source.screenID]?.activeGroupID = source.groupID
    }

    /// Apply completed decisions by window identity. A window keeps its monitor, even if it moved
    /// between the start of classification and receipt of the results.
    public mutating func applyClassification(_ labels: [String: String]) {
        // Stable traversal also keeps the original relative order inside each destination.
        for screenID in screens.keys.sorted() {
            guard let screen = screens[screenID], screen.enabled, screen.isConnected else { continue }
            let focused = screen.activeGroup?.selectedID
            let ordered = screen.groups.flatMap(\.orderedIDs)
            for id in ordered {
                guard let name = labels[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
                if !categoryNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    categoryNames.append(name)
                    for otherID in Array(screens.keys) { _ = screens[otherID]?.ensureGroup(named: name) }
                }
                guard let target = screens[screenID]?.ensureGroup(named: name),
                      let group = screens[screenID]?.groups[target], location(of: id)?.groupID != group.id else { continue }
                removeMembership(of: id)
                if screen.isPortrait, group.columns.last?.count == 1 {
                    screens[screenID]?.groups[target].columns[group.columns.count - 1].append(id)
                } else {
                    screens[screenID]?.groups[target].insert(id, at: group.columns.count, portrait: false, select: false)
                }
            }
            if let focused { select(focused) }
        }
    }

    private func groupIndex(_ groupID: String, on screenID: String) -> Int? {
        screens[screenID]?.groups.firstIndex { $0.id == groupID }
    }

    private mutating func removeMembership(of id: String) {
        guard let owned = location(of: id), let index = groupIndex(owned.groupID, on: owned.screenID) else { return }
        screens[owned.screenID]?.groups[index].remove(owned)
    }

    private mutating func releaseMembership(of id: String) {
        if ownedIDs.remove(id) != nil { removeMembership(of: id) }
        placementPaused.remove(id)
        releasedOnScreen.removeValue(forKey: id)
    }
}
