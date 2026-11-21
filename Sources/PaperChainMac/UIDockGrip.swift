import AppKit
import SwiftUI

/// Mouse motion is measured in screen coordinates because the panel moves under the pointer.
/// A short click on the same grip expands or collapses without activating Paper Chain.
struct DockGrip: NSViewRepresentable {
    let expanded: Bool
    let vertical: Bool
    let toggle: () -> Void
    let drag: (CGPoint) -> Void
    let endDrag: () -> Void

    func makeNSView(context: Context) -> Grip {
        let view = Grip()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        return view
    }

    func updateNSView(_ view: Grip, context: Context) {
        view.expanded = expanded
        view.vertical = vertical
        view.toggle = toggle
        view.drag = drag
        view.endDrag = endDrag
        view.setAccessibilityLabel(expanded ? "Collapse Paper Chain dock" : "Expand Paper Chain dock")
        view.toolTip = expanded ? "Click to collapse · Drag to move" : "Paper Chain · Click to expand · Drag to move"
        view.needsDisplay = true
    }

    final class Grip: NSView {
        var toggle: (() -> Void)?
        var drag: ((CGPoint) -> Void)?
        var endDrag: (() -> Void)?
        var expanded = false
        var vertical = false
        private var start: CGPoint?
        private var dragging = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func accessibilityPerformPress() -> Bool { toggle?(); return true }

        override func mouseDown(with event: NSEvent) {
            start = NSEvent.mouseLocation
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let now = NSEvent.mouseLocation
            let delta = CGPoint(x: now.x - start.x, y: now.y - start.y)
            guard dragging || hypot(delta.x, delta.y) >= 3 else { return }
            dragging = true
            drag?(delta)
        }

        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            if dragging { dragging = false; endDrag?() }
            else { toggle?() }
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .openHand)
        }

        override func draw(_ dirtyRect: NSRect) {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            if expanded {
                NSColor.secondaryLabelColor.setFill()
                for x in [-2.3, 2.3] {
                    for y in [-4.2, 0, 4.2] {
                        let dot = CGPoint(x: center.x + (vertical ? y : x),
                                          y: center.y + (vertical ? x : y))
                        NSBezierPath(ovalIn: NSRect(x: dot.x - 1, y: dot.y - 1, width: 2, height: 2)).fill()
                    }
                }
            } else {
                NSColor.white.withAlphaComponent(0.90).setFill()
                let width: CGFloat = vertical ? 3 : 20
                let height: CGFloat = vertical ? 24 : 2.5
                let rect = NSRect(x: center.x - width / 2, y: center.y - height / 2,
                                  width: width, height: height)
                let radius = min(width, height) / 2
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            }
        }
    }
}
