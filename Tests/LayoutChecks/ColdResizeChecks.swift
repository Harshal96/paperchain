import ChainCore

private let screen = Box(x: 0, y: 34, width: 1710, height: 1073)
private let neighbors = [Box(x: 1710, y: 0, width: 1000, height: 1107),
                         Box(x: 0, y: 1107, width: 1710, height: 1000)]
private let document = Box(x: 240, y: 141, width: 656, height: 422)

/// Setters echo their result immediately but compute from the last committed frame.
/// A second setter in the same turn therefore replaces the first one's work.
private struct DeferredDocument {
    var committed = document
    var measured = document
    var resizedThisTurn = false
    var conflictingPositionY = 578.0

    mutating func apply(_ action: NativeResizeSequence.Action, target: Box, drift: Double = 0) {
        switch action {
        case .resize:
            resizedThisTurn = true
            measured = Box(x: committed.x + drift, y: committed.y, width: target.width,
                           height: min(target.height, 1107 - committed.y))
        case let .anchor(anchor), let .position(anchor):
            let y = resizedThisTurn ? conflictingPositionY : anchor.y
            measured = Box(x: anchor.x, y: y, width: committed.width, height: committed.height)
        default:
            break
        }
    }

    mutating func nextTurn() {
        committed = measured
        resizedThisTurn = false
    }
}

func runColdResizeChecks() {
    let target = Box(x: 0, y: 34, width: 855, height: 1073)
    // Clearing two points between two columns asks each window to grow by one.
    // A writable window must receive that request before retaining a rounded size.
    var adjacent = target
    adjacent.width -= 1
    var unpadding = NativeResizeSequence()
    precondition(unpadding.next(measured: adjacent, target: target, display: screen, neighbors: neighbors) == .resize,
                 "Clearing a two-point gap must request the missing point of window width")
    precondition(unpadding.next(measured: target, target: target, display: screen, neighbors: neighbors) == .settled)
    var constrained = NativeResizeSequence()
    precondition(constrained.next(measured: adjacent, target: target, display: screen, neighbors: neighbors) == .resize)
    precondition(constrained.next(measured: adjacent, target: target, display: screen, neighbors: neighbors) == .wait)
    precondition(constrained.next(measured: adjacent, target: target, display: screen, neighbors: neighbors) == .settled,
                 "A sustained one-point app sizing constraint must settle after the single write")
    var fractional = target
    fractional.height -= 0.5
    var rounding = NativeResizeSequence()
    precondition(rounding.next(measured: fractional, target: target, display: screen, neighbors: neighbors) == .settled,
                 "Normal nearest-point rounding must not provoke a resize")
    let oldRight = Box(x: 856, y: 34, width: 854, height: 1073)
    let flushRight = Box(x: 855, y: 34, width: 855, height: 1073)
    var stagedRight = oldRight
    stagedRight.x -= 1
    var seam = NativeResizeSequence()
    precondition(seam.next(measured: oldRight, target: flushRight, display: screen, neighbors: neighbors) == .anchor(stagedRight),
                 "Move the window back one point before growing against an adjacent display")
    precondition(seam.next(measured: stagedRight, target: flushRight, display: screen, neighbors: neighbors) == .resize)
    precondition(seam.next(measured: flushRight, target: flushRight, display: screen, neighbors: neighbors) == .settled)
    var eager = DeferredDocument()
    eager.apply(.resize, target: target)
    precondition(eager.measured == Box(x: 240, y: 141, width: 855, height: 966))
    eager.apply(.position(target), target: target)
    precondition(eager.measured == Box(x: 0, y: 578, width: 656, height: 422),
                 "same-turn writes must reproduce the captured stale TextEdit readback")
    eager.nextTurn()
    eager.conflictingPositionY = 141
    eager.apply(.anchor(target), target: target)
    precondition(eager.measured == Box(x: 0, y: 34, width: 656, height: 422))
    eager.apply(.resize, target: target)
    precondition(eager.measured == Box(x: 0, y: 578, width: 855, height: 529))
    eager.apply(.position(target), target: target)
    precondition(eager.measured == Box(x: 0, y: 141, width: 656, height: 422),
                 "an eager three-setter retry also discards the size")

    for left in [0.0, 855.0] {
        let tile = Box(x: left, y: 34, width: 855, height: 1073)
        var app = DeferredDocument()
        var sequence = NativeResizeSequence()
        var writes: [NativeResizeSequence.Action] = []
        var settled = false
        for _ in 0..<16 {
            let action = sequence.next(measured: app.committed, target: tile, display: screen, neighbors: neighbors)
            if action == .settled { settled = true; break }
            precondition(action != .refused, "a cooperating TextEdit window was refused")
            if action != .wait { writes.append(action) }
            // Simulate a small horizontal drift during resize to exercise final positioning.
            app.apply(action, target: tile, drift: left == 0 ? 8 : -8)
            precondition(app.measured.x >= 0 && app.measured.y >= 34 &&
                         app.measured.x + app.measured.width <= 1710 &&
                         app.measured.y + app.measured.height <= 1107, "a write crossed a display edge")
            app.nextTurn()
        }
        let anchor = Box(x: left, y: 34, width: document.width, height: document.height)
        precondition(settled && app.committed == tile && writes == [.anchor(anchor), .resize, .position(tile)],
                     "anchor, resize and corrected positioning must settle on distinct turns")
    }

    let undersized = Box(x: 0, y: 34, width: 656, height: 422)
    var stalled = NativeResizeSequence()
    var writes = 0
    var refused = false
    for _ in 0..<20 {
        let action = stalled.next(measured: undersized, target: target, display: screen, neighbors: neighbors)
        precondition(action != .settled, "an AX success code cannot confirm an undersized resizable window")
        if action == .refused { refused = true; break }
        if action == .resize { writes += 1 }
    }
    precondition(refused && (1...2).contains(writes), "persistent undersizing must end after bounded resize attempts")
    var fixed = NativeResizeSequence()
    precondition(fixed.next(measured: undersized, target: target, display: screen, neighbors: neighbors,
                           sizeWritable: false) == .settled, "a fixed-size window may keep its fitted size")

    var delayed = NativeResizeSequence()
    let lower = Box(x: 0, y: 607, width: 656, height: 422)
    precondition(!NativePlacement.safeToGrow(at: lower, to: target, neighbors: neighbors))
    let anchor = delayed.next(measured: lower, target: target, display: screen, neighbors: neighbors)
    precondition(anchor == .anchor(undersized))
    precondition(delayed.next(measured: lower, target: target, display: screen, neighbors: neighbors) == .wait,
                 "stale readback after an accepted anchor must never issue an unsafe resize")
    precondition(delayed.next(measured: undersized, target: target, display: screen, neighbors: neighbors) == .resize)
    precondition(delayed.next(measured: undersized, target: target, display: screen, neighbors: neighbors) == .wait,
                 "an accepted size that still reads the old document dimensions needs another sample")
    precondition(delayed.next(measured: target, target: target, display: screen, neighbors: neighbors) == .settled)

    let wider = Box(x: 0, y: 34, width: 960, height: 1073)
    var minimum = NativeResizeSequence()
    precondition(minimum.next(measured: wider, target: target, display: screen, neighbors: neighbors) == .resize)
    precondition(minimum.next(measured: wider, target: target, display: screen, neighbors: neighbors) == .wait)
    precondition(minimum.next(measured: wider, target: target, display: screen, neighbors: neighbors) == .settled,
                 "a verified app minimum that fits its owner remains usable")
    var oversized = NativeResizeSequence()
    let overWide = Box(x: 0, y: 34, width: 2000, height: 1073)
    precondition(oversized.next(measured: overWide, target: target, display: screen, neighbors: neighbors) == .resize,
                 "shrinking an oversized source can remove an existing neighboring overlap")

    // A near-target size may already be the closest the app can produce. Keep
    // the allowance bounded when neither resize changes the measured dimension.
    for (shortfall, expected) in [(4.0, NativeResizeSequence.Action.settled), (5.0, .refused)] {
        var actual = target
        actual.height -= shortfall
        var sequence = NativeResizeSequence()
        var outcome = NativeResizeSequence.Action.wait
        for _ in 0..<16 {
            outcome = sequence.next(measured: actual, target: target, display: screen, neighbors: neighbors)
            if outcome == .settled || outcome == .refused { break }
        }
        precondition(outcome == expected, "unchanged sizes beyond the rounding allowance still require progress")
    }

    // Two consistent writes can confirm a larger cell-size increment when the app makes progress.
    let rounded = Box(x: 0, y: 34, width: 848, height: 1068)
    let partlyStuck = Box(x: 0, y: 34, width: 848, height: 422)
    let unstable = Box(x: 0, y: 34, width: 841, height: 1056)
    for (first, second, expected) in [(rounded, rounded, NativeResizeSequence.Action.settled),
                                      (partlyStuck, partlyStuck, .refused), (rounded, unstable, .refused)] {
        var sequence = NativeResizeSequence()
        var actual = undersized
        var writes = 0
        var outcome = NativeResizeSequence.Action.wait
        for _ in 0..<16 {
            outcome = sequence.next(measured: actual, target: target, display: screen, neighbors: neighbors)
            if outcome == .settled || outcome == .refused { break }
            if outcome == .resize {
                writes += 1
                actual = writes == 1 ? first : second
            }
        }
        precondition(outcome == expected && writes == 2,
                     "only stable, independently negotiated dimensions may settle below the request")
    }
}
