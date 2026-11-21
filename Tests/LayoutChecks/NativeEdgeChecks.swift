import ChainCore

func runNativeEdgeChecks() {
    func require(_ passes: Bool, _ message: String, line: UInt = #line) {
        precondition(passes, message, line: line)
    }

    let usable = Box(x: -1400, y: -180, width: 1200, height: 800)
    let leftDisplay = Box(x: -2600, y: -180, width: 1200, height: 800)
    let rightDisplay = Box(x: -200, y: -180, width: 1200, height: 800)
    let left = Box(x: -1550, y: -180, width: 600, height: 800)
    let center = Box(x: -1100, y: -180, width: 600, height: 800)
    let right = Box(x: -450, y: -180, width: 600, height: 800)
    for (logical, opposite, adjoining, tuckedX) in [
        (left, rightDisplay, leftDisplay, -1400.0),
        (right, leftDisplay, rightDisplay, -800.0)
    ] {
        let outer = NativePlacement.projection(for: logical, measured: logical, on: usable, neighbors: [opposite])
        require(outer?.edge == .outer && outer?.frame == logical,
                "an unoccupied outer edge must expose the correct part of the native window")
        require(NativePlacement.accepts(logical, for: logical, on: usable, neighbors: [opposite]),
                "an off-edge origin is a valid outer readback")
        let shared = NativePlacement.projection(for: logical, measured: logical, on: usable, neighbors: [opposite, adjoining])
        var tucked = logical
        tucked.x = tuckedX
        require(shared?.edge == .shared && shared?.frame == tucked,
                "a shared side must keep the native window within the owner display")
        require(NativePlacement.accepts(tucked, for: logical, on: usable, neighbors: [adjoining]),
                "the contained shared-edge fallback must verify against the original logical frame")
        require(!NativePlacement.accepts(logical, for: logical, on: usable, neighbors: [adjoining]),
                "a truthful off-edge position becomes invalid when a neighbor occupies it")
        var spilled = tucked
        spilled.x += logical == left ? -0.25 : 0.25
        require(!NativePlacement.accepts(spilled, for: logical, on: usable, neighbors: [adjoining]),
                "a quarter-point overlap is visible on a neighboring display")
    }
    let interior = NativePlacement.projection(for: center, measured: center, on: usable, neighbors: [leftDisplay, rightDisplay])
    require(interior?.edge == .interior && interior?.frame == center, "only protruding windows need edge treatment")

    // A staggered display shares the upper row's right edge and meets the lower row at one point.
    let topNeighbor = Box(x: -200, y: -180, width: 1200, height: 400)
    let upper = Box(x: right.x, y: -180, width: 600, height: 400)
    let lower = Box(x: right.x, y: 220, width: 600, height: 400)
    let near = NativePlacement.projection(for: upper, measured: upper, on: usable, neighbors: [topNeighbor])
    let clear = NativePlacement.projection(for: lower, measured: lower, on: usable, neighbors: [topNeighbor])
    require(near?.edge == .shared && clear?.edge == .outer && clear?.frame == lower,
            "rows in one column may have different physical edges")
    let tall = Box(x: lower.x, y: lower.y, width: lower.width, height: 460)
    let shifted = NativePlacement.projection(for: lower, measured: tall, on: usable, neighbors: [topNeighbor])
    require(shifted?.edge == .shared && shifted?.frame.y == 160,
            "an app minimum shifts the lower window upward into its neighbor's vertical span")

    let inset = Box(x: 64, y: 24, width: 1136, height: 800)
    let physicalLeft = Box(x: -1200, y: 0, width: 1200, height: 824)
    let inDockGap = Box(x: 40, y: 24, width: 568, height: 800)
    let gap = NativePlacement.projection(for: inDockGap, measured: inDockGap, on: inset, neighbors: [physicalLeft])
    require(gap?.edge == .outer && gap?.frame == inDockGap,
            "crossing a Dock inset can leave the physical neighbor untouched")

    let odd = Box(x: 0, y: 34, width: 1001, height: 731)
    let fractional = Box(x: 750.75, y: 34, width: 500.5, height: 731)
    let oddNeighbor = Box(x: 1001, y: 0, width: 800, height: 900)
    let oddOuter = NativePlacement.projection(for: fractional, measured: fractional, on: odd, neighbors: [])
    require(oddOuter?.edge == .outer && oddOuter?.frame.x == 751 && oddOuter?.frame.width == 500.5,
            "whole-point origin alignment must preserve an odd display's measured half-point width")
    let oddShared = NativePlacement.projection(for: fractional, measured: fractional, on: odd, neighbors: [oddNeighbor])
    require(oddShared?.edge == .shared && oddShared?.frame.x == 500 && oddShared?.frame.width == 500.5,
            "rounding an odd shared edge must keep its half-point width on the owning display")

    // A 1710-point display makes all three origins half-integral. Fractional
    // positions must share a tie rule even when a negative global x crosses zero.
    for ownerX in [-1710.0, 0.0, 1710.0] {
        let display = Box(x: ownerX, y: 34, width: 1710, height: 1073)
        let frames = [-427.5, 427.5, 1282.5].compactMap { localX -> Box? in
            let tile = Box(x: ownerX + localX, y: 34, width: 855, height: 1073)
            return NativePlacement.projection(for: tile, measured: tile, on: display, neighbors: [])?.frame
        }
        require(frames.map(\.x) == [-427, 428, 1283].map { ownerX + $0 },
                "half-point ties must round consistently in global coordinates")
        require(frames[0].x + frames[0].width == frames[1].x && frames[1].x + frames[1].width == frames[2].x,
                "whole-point native neighbors must remain contiguous across zero")
    }

    var outerResize = NativeResizeSequence()
    require(outerResize.next(measured: right, target: right, display: usable, neighbors: []) == .settled,
            "cold resize must settle a measured outer projection")
    var sharedResize = NativeResizeSequence()
    let safer = Box(x: -800, y: -180, width: 600, height: 800)
    require(sharedResize.next(measured: right, target: right, display: usable, neighbors: [rightDisplay]) == .position(safer),
            "cold resize must correct a shared-edge spill even when size matches")
    // A small source can fit at the raw logical origin before growing would
    // cross the seam. The resize must stage at the future width's safe origin.
    let small = Box(x: right.x, y: right.y, width: 150, height: right.height)
    let staged = Box(x: safer.x, y: safer.y, width: small.width, height: small.height)
    var grow = NativeResizeSequence()
    require(grow.next(measured: small, target: right, display: usable, neighbors: [rightDisplay]) == .anchor(staged),
            "a window fitting in the gap must move before growing across a seam")
    require(grow.next(measured: small, target: right, display: usable, neighbors: [rightDisplay]) == .wait,
            "a stale anchor acknowledgement must not allow unsafe growth")
    require(grow.next(measured: staged, target: right, display: usable, neighbors: [rightDisplay]) == .resize,
            "AX may grow only after the safe measured origin is confirmed")
    require(grow.next(measured: safer, target: right, display: usable, neighbors: [rightDisplay]) == .settled,
            "a cold phased resize settles at the physical seam")
    var moves = NativeMoveReadbacks()
    let screen = ScreenInfo(id: "left", name: "Left", bounds: usable)
    require(!moves.deferMove("spill", from: right, to: right, on: screen, neighbors: [rightDisplay]),
            "a readback on the adjacent display cannot qualify for deferred verification")
}
