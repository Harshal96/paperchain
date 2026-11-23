import AppKit
import ChainCore
import Decisions
import SwiftUI

@MainActor
protocol PaperActions: AnyObject, ObservableObject {
    var workspace: Workspace { get }
    var windowPadding: Int { get }
    var dimSideWindows: Bool { get }
    var floatingApps: [String: String] { get }
    var categories: [String] { get }
    var hasAPIKey: Bool { get }
    var decisionProvider: DecisionProvider { get }
    var ollamaModel: String { get }
    var canRegroup: Bool { get }
    var hasAccessibility: Bool { get }
    var statusText: String { get }
    var isRegrouping: Bool { get }
    var availableWindowIDs: Set<String> { get }

    func requestAccessibility()
    func rescan()
    func reattachDetachedWindows()
    func regroup()
    func setEnabled(_ enabled: Bool, screen: String)
    func setWindowPadding(_ points: Int)
    func setDimSideWindows(_ enabled: Bool)
    func setAppFloating(bundleID: String, name: String, floating: Bool)
    func setCategories(_ names: [String])
    func setDecisionProvider(_ provider: DecisionProvider)
    func setOllamaModel(_ model: String)
    func saveAPIKey(_ key: String)
    func selectGroup(_ id: String, screen: String)
    func createGroup(screen: String, name: String)
    func renameGroup(_ id: String, screen: String, name: String)
    func icon(for window: String) -> NSImage?
    func focus(_ window: String)
    func moveWindow(_ window: String, to group: String, screen: String, before: String?)
    func detach(_ window: String)
    func stack(_ window: String, with other: String)
    func unstack(_ window: String)
}

enum DockEdge: String, CaseIterable {
    case top, bottom, left, right

    var symbol: String {
        switch self {
        case .top: "rectangle.topthird.inset.filled"
        case .bottom: "rectangle.bottomthird.inset.filled"
        case .left: "rectangle.leftthird.inset.filled"
        case .right: "rectangle.rightthird.inset.filled"
        }
    }

    var isSide: Bool { self == .left || self == .right }
}

private final class ChainPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DockHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Each display retains its own position as a fraction of the available travel.
/// This keeps an edge-anchored handle at the same edge when the dock expands.
@MainActor
final class PaperDocks<A: PaperActions> {
    private final class Dock {
        let panel: NSPanel
        let state: DockAppearance
        var frame: NSRect
        var position: CGPoint
        var dragOrigin: CGPoint?

        init(panel: NSPanel, state: DockAppearance, frame: NSRect, position: CGPoint) {
            self.panel = panel
            self.state = state
            self.frame = frame
            self.position = position
        }
    }

    private let actions: A
    private var docks: [String: Dock] = [:]
    private let defaults = UserDefaults.standard

    init(actions: A) { self.actions = actions }

    func refresh() {
        var visible: Set<String> = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let identity = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
            let id = identity.map { CFUUIDCreateString(nil, $0) as String } ?? String(number.uint32Value)
            guard let model = actions.workspace.screens[id], model.enabled && model.isConnected else { continue }
            visible.insert(id)
            let dock = docks[id] ?? makeDock(id: id, frame: screen.visibleFrame)
            docks[id] = dock
            dock.frame = screen.visibleFrame
            layout(dock, screen: id)
            if !dock.panel.isVisible { dock.panel.orderFrontRegardless() }
        }
        for id in Set(docks.keys).subtracting(visible) {
            docks.removeValue(forKey: id)?.panel.close()
        }
    }

    func position(_ edge: DockEdge, screen id: String) {
        guard let dock = docks[id] else { return }
        switch edge {
        case .top: dock.position = CGPoint(x: 0.5, y: 1)
        case .bottom: dock.position = CGPoint(x: 0.5, y: 0)
        case .left: dock.position = CGPoint(x: 0, y: 0.5)
        case .right: dock.position = CGPoint(x: 1, y: 0.5)
        }
        dock.state.vertical = edge.isSide
        layout(dock, screen: id)
        save(dock, screen: id)
    }

    private func makeDock(id: String, frame: NSRect) -> Dock {
        let saved = defaults.dictionary(forKey: "PaperChain.Dock.\(id)")
        let position = CGPoint(x: saved?["x"] as? Double ?? 0.5, y: saved?["y"] as? Double ?? 0)
        let state = DockAppearance(vertical: saved?["vertical"] as? Bool ?? false)
        let panel = ChainPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.title = "PaperChain"
        let view = DockContent(actions: actions, state: state, screenID: id,
            toggle: { [weak self] in self?.toggle(id) },
            drag: { [weak self] delta in self?.drag(id, delta: delta) },
            endDrag: { [weak self] in self?.endDrag(id) },
            position: { [weak self] edge in self?.position(edge, screen: id) })
        let host = DockHost(rootView: view)
        host.sizingOptions = []
        panel.contentView = host
        return Dock(panel: panel, state: state, frame: frame, position: position)
    }

    private func toggle(_ id: String) {
        guard let dock = docks[id] else { return }
        dock.state.expanded.toggle()
        layout(dock, screen: id)
    }

    private func drag(_ id: String, delta: CGPoint) {
        guard let dock = docks[id] else { return }
        if dock.dragOrigin == nil { dock.dragOrigin = dock.panel.frame.origin }
        guard let start = dock.dragOrigin else { return }
        let bounds = dock.frame.insetBy(dx: 4, dy: 4)
        dock.position = CGPoint(
            x: fraction(start.x + delta.x - bounds.minX, of: bounds.width - dock.panel.frame.width),
            y: fraction(start.y + delta.y - bounds.minY, of: bounds.height - dock.panel.frame.height))
        layout(dock, screen: id)
    }

    private func endDrag(_ id: String) {
        guard let dock = docks[id] else { return }
        dock.dragOrigin = nil
        save(dock, screen: id)
    }

    private func save(_ dock: Dock, screen id: String) {
        defaults.set(["x": dock.position.x, "y": dock.position.y, "vertical": dock.state.vertical],
                     forKey: "PaperChain.Dock.\(id)")
    }

    private func fraction(_ value: CGFloat, of length: CGFloat) -> CGFloat {
        length > 0 ? min(1, max(0, value / length)) : 0.5
    }

    private func layout(_ dock: Dock, screen id: String) {
        let area = dock.frame.insetBy(dx: 4, dy: 4)
        guard area.width > 0, area.height > 0 else { return }
        let size: CGSize
        if !dock.state.expanded {
            size = dock.state.vertical ? CGSize(width: 24, height: 56) : CGSize(width: 48, height: 20)
        } else {
            guard let screen = actions.workspace.screens[id] else { return }
            let windows = actions.hasAccessibility
                ? screen.activeGroup?.orderedIDs.filter(actions.availableWindowIDs.contains).count ?? 0 : 0
            size = DockSizing.expandedSize(for: screen, windowCount: windows,
                                           vertical: dock.state.vertical, available: area.size)
        }
        let origin = CGPoint(
            x: area.minX + (area.width - size.width) * min(1, max(0, dock.position.x)),
            y: area.minY + (area.height - size.height) * min(1, max(0, dock.position.y)))
        let next = NSRect(origin: origin, size: size).integral
        if dock.panel.frame != next { dock.panel.setFrame(next, display: true) }
    }
}
