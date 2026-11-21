import ChainCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        print("LayoutChecks failed: \(message)")
        exit(1)
    }
}

private let landscape = Box(x: -1_280, y: -120, width: 1_280, height: 960)
private let columns = [["a"], ["b"], ["c"], ["d"], ["e"]]

private let neighbor = Box(x: 0, y: -160, width: 1_440, height: 1_080)
private let edgeTile = Box(x: -640, y: -120, width: 640, height: 960)
private let appMinimum = Box(x: -775, y: -120, width: 775, height: 960)
check(NativePlacement.accepts(appMinimum, for: edgeTile, on: landscape, neighbors: [neighbor]),
      "a wide app minimum can fit against the shared edge")
var spilled = appMinimum
spilled.x += 0.5
check(!NativePlacement.accepts(spilled, for: edgeTile, on: landscape, neighbors: [neighbor]),
      "subpoint spill onto the neighboring display is rejected")
for refused in [Box(x: landscape.x, y: landscape.y, width: 1_300, height: 960),
                Box(x: -640, y: landscape.y, width: 640, height: 1_000)] {
    check(!NativePlacement.accepts(refused, for: edgeTile, on: landscape, neighbors: []),
          "an uncooperative minimum larger than the display cannot be tiled")
}

// App-enforced minimum width fills more of the display. An interior window
// still needs clickable neighbors on *both* sides as long as any space remains.
for (tileX, expectedX) in [(-1280.0, -1280.0), (-1120, -1216), (-960, -1152), (-640, -1024)] {
    let tile = Box(x: tileX, y: -120, width: 640, height: 960)
    let actual = Box(x: expectedX, y: -120, width: 1024, height: 960)
    check(NativePlacement.fittedFrame(for: tile, measured: actual, on: landscape) == actual,
          "wide minimum at logical x \(tileX) should leave the outer strip clickable at x \(expectedX)")
    check(NativePlacement.accepts(actual, for: tile, on: landscape, neighbors: [neighbor]),
          "the Accessibility readback must agree with the fitted tile")
}
private let stackedTile = Box(x: -960, y: 360, width: 640, height: 480)
private let stackedMinimum = Box(x: -1152, y: 190, width: 1024, height: 650)
check(NativePlacement.fittedFrame(for: stackedTile, measured: stackedMinimum, on: landscape) == stackedMinimum,
      "wide bottom-stack window must keep both horizontal neighbors and stay inside the display")
private let original = Box(x: -1100, y: 75, width: 640, height: 300)
private let resizedOriginal = Box(x: -1100, y: 75, width: 900, height: 350)
check(NativePlacement.fittedFrame(for: original, measured: resizedOriginal, on: landscape, purpose: .restoreOriginal) == resizedOriginal,
      "restoring a floating frame must keep its original origin when the app changes minimum size")
check(NativePlacement.accepts(resizedOriginal, for: original, on: landscape, neighbors: [neighbor], purpose: .restoreOriginal),
      "restoring an original frame validates its absolute coordinates")

// TextEdit acknowledged both AX setters, but the first readback still reported a
// cascaded, document-sized window. Exercise the same delayed rewrite decision as AX.
private let notebook = Box(x: 0, y: 34, width: 1710, height: 1073)
private let adjoining = [Box(x: 1710, y: 0, width: 1200, height: 1200),
                         Box(x: 0, y: 1107, width: 1710, height: 900)]
for (x, y) in [(0.0, 578.0), (855, 607), (0, 636)] {
    let requested = Box(x: x, y: 34, width: 855, height: 1073)
    let stale = Box(x: x, y: y, width: 656, height: 422)
    var retry = NativePlacementRetry()
    var measured = stale
    var writes = 0
    var confirmed = false
    var checks = 0
    while let delay = retry.nextDelay() {
        checks += 1
        check(delay > 0 && checks <= 3, "placement waits must be finite")
        if NativePlacement.accepts(measured, for: requested, on: notebook, neighbors: adjoining) {
            confirmed = true
            break
        }
        if checks == 1 { check(!retry.shouldReissue, "first delayed read lets the accepted AX write settle") }
        if retry.shouldReissue {
            // Resizing from the old y would cross the display seam at y=1107.
            check(!NativePlacement.safeToGrow(at: measured, to: requested, neighbors: adjoining),
                  "a stale acknowledgement of the coarse move must block a resize across the seam")
            let anchor = NativePlacement.fittedFrame(for: requested, measured: measured, on: notebook)!
            check(anchor == Box(x: x, y: 34, width: 656, height: 422), "stage the measured window before resizing")
            check(NativePlacement.accepts(anchor, for: anchor, on: notebook, neighbors: adjoining),
                  "the intermediate move must stay inside the owner display")
            check(NativePlacement.safeToGrow(at: anchor, to: requested, neighbors: adjoining),
                  "the new size is safe once the coarse move has been observed")
            measured = Box(x: anchor.x, y: anchor.y, width: requested.width, height: requested.height)
            writes += 1
        }
    }
    check(checks == 3 && writes == 1 && confirmed && measured == requested,
          "a stale success readback must trigger a fresh write and confirm the full tile")
}
private var refusal = NativePlacementRetry()
private var refusals = 0
private var rewrites = 0
while refusal.nextDelay() != nil {
    refusals += 1
    check(refusals <= 3, "a refusing app must stop receiving retry timers")
    check(refusal.isFinalCheck == (refusals == 3), "only the final readback can release a still-refusing window")
    if refusal.shouldReissue { rewrites += 1 }
}
check(refusals == 3 && rewrites == 1, "a persistent refusal has a bounded rewrite")

private let straddling = Box(x: 1650, y: 100, width: 100, height: 200)
check(NativePlacement.safeToGrow(at: straddling, to: Box(x: 0, y: 34, width: 90, height: 80), neighbors: adjoining),
      "shrinking an already overlapping window must remain possible")
check(!NativePlacement.safeToGrow(at: straddling, to: Box(x: 0, y: 34, width: 75, height: 205), neighbors: adjoining),
      "growing downwards may add new neighboring pixels even as total overlap shrinks")

for (focus, expected) in [0.0, 322, 966, 1_610, 1_932].enumerated() {
    check(Strip.offset(column: focus, count: 5, width: landscape.width) == expected,
          "camera destination for column \(focus)")
}
check(Strip.offset(column: -1, count: 5, width: 1_280) == 0, "clamp before first column")
check(Strip.offset(column: 10, count: 5, width: 1_280) == 1_932, "clamp after last column")
check(Strip.offset(column: 1, count: 2, width: 1_280) == 0, "both columns fit without scrolling")
check(Strip.frames(columns: [[String]](), bounds: landscape, offset: 0).isEmpty, "empty strip")

private let first = Strip.frames(columns: columns, bounds: landscape, offset: -500)
check(first["b"]!.x - (first["a"]!.x + first["a"]!.width) == 8, "eight-point gap between endpoint windows")
check(Set(first.keys) == ["a", "b"] && first["a"]?.x == -1_280 && first["b"]?.x == -636,
      "leading endpoint and exact intersection")
check(Strip.frames(columns: columns, bounds: landscape, offset: Double.ulpOfOne) == first,
      "rounding at the viewport boundary must not add a zero-width edge crop")
private let last = Strip.frames(columns: columns, bounds: landscape, offset: 2_500)
check(Set(last.keys) == ["d", "e"] && last["d"]?.x == -1_280 && last["e"]?.x == -636,
      "trailing endpoint")
private let middle = Strip.frames(columns: columns, bounds: landscape, offset: 966)
check(Set(middle.keys) == ["b", "c", "d"], "only centered column and both neighbors")
check(middle["c"] == Box(x: -958, y: -120, width: 636, height: 960), "centered full-size column")
check(middle["b"]?.x == -1_602 && middle["d"]?.x == -314, "both neighbors leave a gap beside the center")

// Express the visible portion in the source window's coordinates. This distinguishes
// the trailing half of A from the leading half when B sits in the middle.
private func visibleSourceX(_ frame: Box, on display: Box) -> Range<Double> {
    let start = max(frame.x, display.x)
    let end = min(frame.x + frame.width, display.x + display.width)
    return (start - frame.x)..<(end - frame.x)
}
private let abc = Strip.frames(columns: [["A"], ["B"], ["C"]], bounds: landscape, offset: 322)
check(visibleSourceX(abc["A"]!, on: landscape) == 322..<636, "left neighbor shows its trailing content")
check(visibleSourceX(abc["B"]!, on: landscape) == 0..<636, "center exposes its entire source window")
check(visibleSourceX(abc["C"]!, on: landscape) == 0..<314, "right neighbor shows its leading content")

private let odd = Box(x: 0, y: 38, width: 1001, height: 731)
private let fractional = Strip.frames(columns: [["A"], ["B"], ["C"]], bounds: odd, offset: 125.125)
check(visibleSourceX(fractional["A"]!, on: odd) == 125.125..<496.5, "fractional trailing crop")
check(fractional["B"]?.x == 379.375, "fractional camera preserves half-point widths")
check(visibleSourceX(fractional["C"]!, on: odd) == 0..<117.125, "fractional leading crop")

// The outermost crop can fall in a gutter during a slide. Inside the viewport,
// every pair of neighboring columns maintains the same spacing throughout.
for bounds in [landscape, Box(x: 0, y: 38, width: 1_513, height: 931)] {
    for offset in stride(from: 0.0, through: 2_800, by: 1.25) {
        let frames = Strip.frames(columns: columns, bounds: bounds, offset: offset)
        let ordered = frames.values.sorted { $0.x < $1.x }
        check((2...3).contains(ordered.count), "two or three columns in flight")
        for frame in ordered {
            check(frame.x < bounds.x + bounds.width && frame.x + frame.width > bounds.x,
                  "a column with no visible pixels should leave the strip")
            check(frame.width == (bounds.width - 8) / 2 && frame.y == bounds.y && frame.height == bounds.height,
                  "native window dimensions changed at a monitor edge")
        }
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            check(abs(right.x - left.x - left.width - 8) < 0.000001, "gap changed during navigation")
        }
        check(ordered.first!.x - bounds.x <= 8.000001
              && bounds.x + bounds.width - ordered.last!.x - ordered.last!.width <= 8.000001,
              "an edge of the viewport can reveal at most one gutter")
    }
}

private let portrait = Box(x: 100, y: -1_200, width: 720, height: 1_140)
private let grid = Strip.frames(columns: [["1", "2"], ["3", "4"]], bounds: portrait, offset: 0)
check(grid == [
    "1": Box(x: 100, y: -1_200, width: 356, height: 566),
    "2": Box(x: 100, y: -626, width: 356, height: 566),
    "3": Box(x: 464, y: -1_200, width: 356, height: 566),
    "4": Box(x: 464, y: -626, width: 356, height: 566)
], "two-by-two portrait grid, with global display coordinates")
private let portraitMiddle = Strip.frames(columns: [["1", "2"], ["3", "4"], ["5", "6"]],
                                         bounds: portrait, offset: 182)
for (row, y) in [-1200.0, -626].enumerated() {
    let left = portraitMiddle[String(1 + row)]!
    let center = portraitMiddle[String(3 + row)]!
    let right = portraitMiddle[String(5 + row)]!
    check(center == Box(x: 282, y: y, width: 356, height: 566)
          && left.y == y && right.y == y && left.height == 566 && right.height == 566, "stack row alignment")
    check(visibleSourceX(left, on: portrait) == 182..<356 && visibleSourceX(right, on: portrait) == 0..<174,
          "both portrait rows expose the correct source content")
}
check(Strip.frames(columns: [["1"]], bounds: portrait, offset: 2_000)["1"]
      == Box(x: 100, y: -1_200, width: 360, height: 1_140), "single-column endpoint")

// Generate column IDs on demand. Any accidental full-strip traversal is observable.
private final class CountedColumns: RandomAccessCollection {
    let startIndex = 0
    let endIndex = 1_000_000
    private(set) var columnsRead = 0
    subscript(index: Int) -> [String] {
        columnsRead += 1
        return [String(index)]
    }
}
private let long = CountedColumns()
for index in [0, 1, 50_000, 999_998, 999_999] {
    let initialReads = long.columnsRead
    let offset = Strip.offset(column: index, count: long.count, width: 1_280)
    let frames = Strip.frames(columns: long, bounds: landscape, offset: offset)
    check(frames[String(index)] != nil, "long-strip focus")
    check(frames.count <= 3 && long.columnsRead - initialReads == frames.count,
          "one source read per visible column")
}

private var motion = ScrollMotion(offset: -10)
check(!motion.isMoving(at: 0) && motion.position(at: 0) == -10, "initial rest")
motion.retarget(to: 400, at: 10)
check(motion.position(at: 10) == -10 && motion.isMoving(at: 10), "animation starts at current offset")
private var previous = -10.0
for tick in 1...240 {
    let position = motion.position(at: 10 + Double(tick) / 240)
    check(position >= previous && position <= 400, "monotonic movement from rest without overshoot")
    previous = position
}
check(previous == 400 && !motion.isMoving(at: 11), "exact and finite arrival")

motion.retarget(to: 0, at: 12)
private let interruption = 12.07
private let epsilon = 0.000001
private let current = motion.position(at: interruption)
private let oldSpeed = (current - motion.position(at: interruption - epsilon)) / epsilon
check(current < 400 && current > 0, "interrupt an in-flight animation")
motion.retarget(to: 650, at: interruption)
check(motion.position(at: interruption) == current, "reversal preserves position")
private let newSpeed = (motion.position(at: interruption + epsilon) - current) / epsilon
check(abs(newSpeed - oldSpeed) < 1, "reversal preserves velocity")
for tick in 1...120 {
    motion.retarget(to: 650, at: interruption + Double(tick) / 120)
}
check(motion.position(at: 13.07) == 650 && !motion.isMoving(at: 13.07), "duplicate intents still settle")

runWindowPaddingChecks()
runNativeEdgeChecks()
runColdResizeChecks()
runPointAlignmentChecks()
print("LayoutChecks passed (geometry, staged native placement, monitor containment, stacks, bounded column reads, and scroll motion)")
