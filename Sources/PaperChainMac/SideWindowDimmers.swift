import AppKit
import ApplicationServices

/// Front-to-back WindowServer metadata. Owner, number, level and geometry are public
/// even without Screen Recording access.
struct NativeLayerSurface {
    let pid: pid_t
    let number: CGWindowID
    let layer: Int
    let frame: CGRect

    static func visible() -> [Self]? {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        var result: [Self] = []
        for row in rows where (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0 {
            guard let pid = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let number = row[kCGWindowNumber as String] as? NSNumber,
                  let layer = row[kCGWindowLayer as String] as? NSNumber,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            result.append(Self(pid: pid.int32Value, number: number.uint32Value, layer: layer.intValue, frame: frame))
        }
        return result
    }
}

@MainActor
final class SideWindowDimmers {
    private var panels: [CGWindowID: ShadePanel] = [:]

    var windowNumbers: Set<CGWindowID> {
        Set(panels.values.compactMap { CGWindowID(exactly: $0.windowNumber) })
    }

    func clear() {
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
    }

    /// Use actual onscreen frames, including a window's accepted minimum size.
    /// Ordering each panel immediately above its document preserves sheets, floating
    /// windows, the selected document and other applications in their native layers.
    func update(windows: [NativeDesktop.Window], bounds: CGRect) {
        guard !windows.isEmpty, let top = NSScreen.screens.first?.frame.maxY,
              let surfaces = NativeLayerSurface.visible() else { clear(); return }
        let ourNumbers = windowNumbers
        let documents = surfaces.filter { $0.layer == 0 && !ourNumbers.contains($0.number) }
        var active = Set<CGWindowID>()
        var ordered = false
        for window in windows {
            guard let surface = surface(for: window, among: documents, bounds: bounds) else { continue }
            let visible = surface.frame.intersection(bounds)
            guard !visible.isEmpty else { continue }
            active.insert(surface.number)
            let frame = CGRect(x: visible.minX, y: top - visible.maxY, width: visible.width, height: visible.height)
            let panel = panels[surface.number] ?? ShadePanel(frame: frame)
            panels[surface.number] = panel
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            // Round the document's corners, including when the screen clips one edge.
            panel.shade.document = CGRect(x: surface.frame.minX - visible.minX, y: visible.maxY - surface.frame.maxY,
                                          width: surface.frame.width, height: surface.frame.height)
            let inOrder = zip(surfaces, surfaces.dropFirst()).contains { above, below in
                Int(above.number) == panel.windowNumber && below.number == surface.number
            }
            if !panel.isVisible || !inOrder {
                panel.order(.above, relativeTo: Int(surface.number))
                ordered = true
            }
        }
        if ordered {
            // A document can close while its AX identity is being resolved. Discard
            // any orphaned panel before returning from the ordering pass.
            let current = NSWindow.windowNumbers(options: .allApplications) ?? []
            active.formIntersection(current.map(\.uint32Value))
        }
        for number in Set(panels.keys).subtracting(active) {
            panels.removeValue(forKey: number)?.orderOut(nil)
        }
    }

    private func surface(for window: NativeDesktop.Window, among documents: [NativeLayerSurface],
                         bounds: CGRect) -> NativeLayerSurface? {
        let candidates = documents.filter { $0.pid == window.app.processIdentifier }
        if let key = window.quartzIdentifier, key.hasPrefix("q:"), let number = CGWindowID(key.dropFirst(2)),
           let known = candidates.first(where: { $0.number == number }) { return known }
        // Two windows may have shared a frame during inventory. Once tiled, accept
        // a unique matching surface only when an exposed point hits the very same AX window.
        let matches = candidates.filter { $0.frame.approximatelyEquals(window.rect) }
        guard matches.count == 1, let candidate = matches.first else { return nil }
        let visible = candidate.frame.intersection(bounds)
        guard !visible.isEmpty else { return nil }
        for fraction: CGFloat in [0.5, 0.1, 0.9] {
            let x = visible.minX + fraction * visible.width
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(x), Float(visible.midY), &hit) == .success,
               let hit, CFEqual(NativeAX.element(hit, kAXWindowAttribute) ?? hit, window.element) {
                return candidate
            }
        }
        return nil
    }
}

@MainActor
private final class ShadePanel: NSPanel {
    let shade = ShadeView()
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .normal
        isFloatingPanel = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace]
        isExcludedFromWindowsMenu = true
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
        shade.setAccessibilityElement(false)
        shade.setAccessibilityHidden(true)
        contentView = shade
    }
}

@MainActor
private final class ShadeView: NSView {
    var document: CGRect = .zero {
        didSet { if document != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        let radius: CGFloat
        if #available(macOS 26, *) { radius = 16 } else { radius = 10 }
        NSBezierPath(roundedRect: document, xRadius: radius, yRadius: radius).fill()
    }
}
