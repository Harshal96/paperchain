import Foundation

extension Workspace {
    package static func physicalScreen(at point: CGPoint, in physical: [String: CGRect]) -> String? {
        let hits = physical.compactMap { id, bounds in
            bounds.contains(point) ? id : nil
        }
        return hits.count == 1 ? hits[0] : nil
    }

    package static func dropScreen(at point: CGPoint, physical: [String: CGRect],
                                   windowScreen: @autoclosure () -> String?) -> String? {
        // A title-bar drag can finish over the menu bar or Dock, outside all work areas.
        // In a genuine display gap (or on mirrored screens), retain the frame-based fallback.
        physicalScreen(at: point, in: physical) ?? windowScreen()
    }

    /// An observed frame never calls this method. Only mouse-up after a physical window drag does.
    public mutating func drop(_ window: String, x: Double, y: Double, float: Bool,
                              fallbackScreen: String?, presentation: Presentation, at time: Double,
                              horizontalMovement: Double? = nil) {
        if float {
            detach(window)
            return
        }
        let destination = screens.values.first {
            let b = $0.info.bounds
            return $0.isConnected && x >= b.x && x < b.x + b.width && y >= b.y && y < b.y + b.height
        }?.id ?? fallbackScreen
        guard let destination, let screen = screens[destination], screen.isConnected else { return }
        let source = location(of: window)
        if let horizontalMovement, !placementPaused.contains(window), let source,
           source.screenID == destination, source.groupID == screen.activeGroupID {
            let gap = presentation.reorderGap(on: destination, from: source.column, movingBy: horizontalMovement)
            move(window, to: destination, at: gap)
            return
        }
        let gap = presentation.gap(on: destination, atX: x, time: time)
        // Importing onto a portrait screen fills a half-empty stack first.
        let fillRow = screen.info.bounds.height > screen.info.bounds.width && source?.screenID != destination
        move(window, to: destination, at: fillRow ? nil : gap)
    }
}

/// A slow network result must not undo a user's intervening edits.
public struct RegroupRequest {
    private struct Entry {
        var window: WindowInfo
        var group: String
        var screen: String
    }
    private var entries: [String: Entry] = [:]
    public let categories: [String]
    public var windows: [WindowInfo] { entries.values.map(\.window).sorted { $0.id < $1.id } }

    public init(workspace: Workspace, available: Set<String>, categories: [String]) {
        self.categories = categories
        for screen in workspace.screens.values where screen.enabled && screen.isConnected {
            for group in screen.groups {
                for id in group.orderedIDs where available.contains(id) {
                    if let window = workspace.windows[id] {
                        entries[id] = Entry(window: window, group: group.id, screen: screen.id)
                    }
                }
            }
        }
    }

    public func applicable(_ labels: [String: String], in workspace: Workspace, available: Set<String>,
                           categories currentCategories: [String]) -> [String: String] {
        guard categories == currentCategories else { return [:] }
        let allowed = Set(categories)
        var result: [String: String] = [:]
        for screen in workspace.screens.values where screen.enabled && screen.isConnected {
            for group in screen.groups {
                for id in group.orderedIDs where available.contains(id) {
                    guard let start = entries[id], start.group == group.id, start.screen == screen.id,
                          workspace.windows[id] == start.window, let label = labels[id], allowed.contains(label) else { continue }
                    result[id] = label
                }
            }
        }
        return result
    }
}
