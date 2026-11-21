/// Reconciles the tile requested by the strip with the size an app actually accepts.
public enum NativePlacement {
    public enum Purpose { case strip, restoreOriginal }
    public enum Edge { case interior, outer, shared }

    public struct Projection {
        public let frame: Box
        public let edge: Edge
    }

    private static let rounding = 1.0

    // A strip can cross zero in global coordinates. Equal half-point offsets
    // must round in the same direction to keep adjacent integral widths abutting.
    private static func nearestPoint(_ value: Double) -> Double { (value + 0.5).rounded(.down) }

    /// Retain native size when applications enclose AX position writes in integer
    /// points. Round only within the available travel on each axis.
    public static func pointAligned(_ fitted: Box, in display: Box) -> Box {
        func align(_ coordinate: Double, from lower: Double, through upper: Double) -> Double {
            let first = lower.rounded(.up)
            let last = upper.rounded(.down)
            guard first <= last else { return coordinate }
            return min(max(nearestPoint(coordinate), first), last)
        }
        return Box(x: align(fitted.x, from: display.x, through: display.x + display.width - fitted.width),
                   y: align(fitted.y, from: display.y, through: display.y + display.height - fitted.height),
                   width: fitted.width, height: fitted.height)
    }

    public static func fittedFrame(for tile: Box, measured: Box, on display: Box, purpose: Purpose = .strip) -> Box? {
        guard valid(tile), valid(measured), valid(display),
              measured.width <= display.width + rounding,
              measured.height <= display.height + rounding else { return nil }
        let right = display.x + display.width
        let bottom = display.y + display.height
        let x: Double
        if purpose == .strip, measured.width > tile.width, tile.width < display.width {
            // An app's minimum width leaves less room to slide. Map the tile's
            // position onto that smaller range so a centered tile exposes both neighbors.
            let fraction = min(1, max(0, (tile.x - display.x) / (display.width - tile.width)))
            x = display.x + fraction * max(0, display.width - measured.width)
        } else {
            x = max(display.x, min(tile.x, right - measured.width))
        }
        let y = max(display.y, min(tile.y, bottom - measured.height))
        return Box(x: x, y: y, width: measured.width, height: measured.height)
    }

    /// Maps the visible logical column to an AX frame. The owner supplies its
    /// usable area; neighbors supply their full physical rectangles, including
    /// any menu bar or Dock. Only a real intersection requires native overlap.
    public static func projection(for tile: Box, measured: Box, on display: Box, neighbors: [Box],
                                  purpose: Purpose = .strip) -> Projection? {
        guard let contained = fittedFrame(for: tile, measured: measured, on: display, purpose: purpose) else { return nil }
        let aligned = purpose == .strip ? pointAligned(contained, in: display) : contained
        let right = display.x + display.width
        let tileRight = tile.x + tile.width
        let crossesLeft = tile.x < display.x
        let crossesRight = tileRight > right
        let edge: Edge
        if purpose == .strip && (crossesLeft || crossesRight) {
            guard tileRight > display.x, tile.x < right, !(crossesLeft && crossesRight) else { return nil }
            var outer = aligned
            if crossesLeft {
                // Keep the same fraction of a constrained window's content visible.
                let hiddenFraction = (display.x - tile.x) / tile.width
                outer.x = nearestPoint(tile.x + hiddenFraction * (tile.width - measured.width))
                outer.x = max(outer.x, (display.x - measured.width).rounded(.down) + 1)
            } else {
                let visibleFraction = (right - tile.x) / tile.width
                outer.x = nearestPoint(tile.x + visibleFraction * min(0, tile.width - measured.width))
                outer.x = min(outer.x, right.rounded(.up) - 1)
            }
            if !neighbors.contains(where: { intersects(outer, $0) }) {
                return Projection(frame: outer, edge: .outer)
            }
            edge = .shared
        } else {
            edge = .interior
        }
        guard !neighbors.contains(where: { intersects(aligned, $0) }) else { return nil }
        return Projection(frame: aligned, edge: edge)
    }

    public static func accepts(_ actual: Box, for tile: Box, on display: Box, neighbors: [Box], purpose: Purpose = .strip) -> Bool {
        guard let projected = projection(for: tile, measured: actual, on: display, neighbors: neighbors, purpose: purpose),
              abs(actual.x - projected.frame.x) <= rounding, abs(actual.y - projected.frame.y) <= rounding,
              intersects(actual, display), actual.y >= display.y - rounding,
              actual.y + actual.height <= display.y + display.height + rounding else { return false }
        if projected.edge != .outer,
           actual.x < display.x - rounding || actual.x + actual.width > display.x + display.width + rounding { return false }
        // Rounding inside the work area is harmless. A positive-area overlap with
        // another physical display is visible to the user, including subpoint spill.
        return !neighbors.contains { intersects(actual, $0) }
    }

    private static func intersects(_ a: Box, _ b: Box) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
    }

    /// AXSize changes the size at the window's measured origin. During a display
    /// transfer the old window can already overlap a neighbor. Permit shrinking
    /// and require every point of the new overlap to stay within the old footprint.
    public static func safeToGrow(at current: Box, to tile: Box, neighbors: [Box]) -> Bool {
        let right = current.x + tile.width
        let bottom = current.y + tile.height
        guard valid(current), valid(tile), right.isFinite, bottom.isFinite else { return false }
        return !neighbors.contains { neighbor in
            let overlapRight = min(right, neighbor.x + neighbor.width)
            let overlapBottom = min(bottom, neighbor.y + neighbor.height)
            guard max(current.x, neighbor.x) < overlapRight,
                  max(current.y, neighbor.y) < overlapBottom else { return false }
            return overlapRight > current.x + current.width || overlapBottom > current.y + current.height
        }
    }

    private static func valid(_ box: Box) -> Bool {
        box.x.isFinite && box.y.isFinite && box.width > 0 && box.height > 0 &&
        (box.x + box.width).isFinite && (box.y + box.height).isFinite
    }
}
