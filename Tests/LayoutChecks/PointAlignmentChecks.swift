import ChainCore
import Foundation

func runPointAlignmentChecks() {
    let screen = Box(x: 0, y: 34, width: 1710, height: 1073)
    let neighbor = Box(x: 1710, y: 0, width: 1280, height: 1107)
    // An app enclosing a moved rectangle in whole points adopts that wider
    // footprint as its next native size. Two fractional moves reproduce the drift.
    let first = CGRect(x: 427.5, y: 34, width: 855, height: 1073).integral
    let second = CGRect(x: 102.25, y: 34, width: first.width, height: first.height).integral
    precondition(first.width == 856 && second.width == 857)

    var measured = Box(x: 0, y: 34, width: 851, height: 1073)
    for leg in 0..<10 {
        for step in 0...36 {
            let offset = Double(leg.isMultiple(of: 2) ? step : 36 - step) * 859 / 36
            let tile = Strip.frames(columns: [["a"], ["b"], ["c"]], bounds: screen, offset: offset)["b"]!
            let fitted = NativePlacement.fittedFrame(for: tile, measured: measured, on: screen)!
            let request = NativePlacement.pointAligned(fitted, in: screen)
            let actual = CGRect(x: request.x, y: request.y, width: measured.width, height: measured.height).integral
            measured = Box(x: actual.minX, y: actual.minY, width: actual.width, height: actual.height)
            precondition(measured.width == 851 && measured.height == 1073, "an origin-only focus move grew the window")
            precondition(abs(measured.x - tile.x) <= 0.5, "strip focus shifted beyond the nearest point")
            precondition(NativePlacement.accepts(measured, for: tile, on: screen, neighbors: [neighbor]))
        }
    }

    // Rounding a negative fractional edge can move a window out of bounds.
    // If a full-height tile has no legal integer y, keep its fitted coordinate.
    let fractional = Box(x: -1711.4, y: -48.75, width: 1711, height: 900)
    let end = Box(x: -855.4, y: -48.75, width: 855, height: 900)
    let aligned = NativePlacement.pointAligned(end, in: fractional)
    precondition(aligned == Box(x: -856, y: -48.75, width: 855, height: 900))
    let start = Box(x: fractional.x, y: fractional.y, width: 855, height: 900)
    precondition(NativePlacement.pointAligned(start, in: fractional).x == -1711)
}
