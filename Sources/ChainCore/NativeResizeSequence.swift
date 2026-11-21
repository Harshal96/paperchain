/// Each action represents at most one AX write. The caller samples the measured
/// frame again on a later run-loop turn before asking for another action.
public struct NativeResizeSequence {
    public enum Action: Equatable {
        case anchor(Box), resize, position(Box), wait, settled, refused
    }

    private var remainingSamples = 14
    private var anchorWrites = 0
    private var sizeWrites = 0
    private var positionWrites = 0
    private var awaiting: Action?
    private var beforeFirstResize: Box?
    private var beforeSecondResize: Box?

    public init() {}

    package static func sizeMatches(_ measured: Box, target: Box, afterWrite: Bool = false) -> Bool {
        // Request the nearest representable size. Once the app has had time to
        // apply the write, allow the usual one-point AX readback tolerance.
        let tolerance = afterWrite ? 1.0 : 0.5
        return abs(measured.width - target.width) <= tolerance && abs(measured.height - target.height) <= tolerance
    }

    public mutating func next(measured: Box?, target: Box, display: Box, neighbors: [Box],
                              sizeWritable: Bool = true) -> Action {
        guard remainingSamples > 0 else { return .refused }
        remainingSamples -= 1
        guard let measured else { return .wait }

        var anchor = NativePlacement.projection(for: target, measured: measured, on: display, neighbors: neighbors)?.frame
        var positioned = NativePlacement.accepts(measured, for: target, on: display, neighbors: neighbors)
        let widthError = measured.width - target.width
        let heightError = measured.height - target.height
        let sizeMatches = Self.sizeMatches(measured, target: target, afterWrite: sizeWrites > 0 && awaiting != .resize)
        // A window may enforce a larger minimum. Give its resize a further sample
        // before accepting that minimum, and require the minimum to fit its owner.
        let fittedMinimum = anchor != nil && sizeWrites > 0 && awaiting != .resize
            && widthError >= -1 && heightError >= -1
        let sizeReady = sizeMatches || fittedMinimum || !sizeWritable || negotiated(measured, target)
        if sizeReady && positioned { return .settled }
        // A one-point origin error can pass normal placement tolerance yet
        // make a resize extend onto the next display. Anchor before that write.
        let canResizeHere = sizeReady || NativePlacement.safeToGrow(at: measured, to: target, neighbors: neighbors)
        positioned = positioned && canResizeHere

        // A small source window can fit in a gap that its requested size would
        // cross. Stage its current size at the larger frame's safe origin first.
        if !sizeReady, let currentAnchor = anchor,
           !NativePlacement.safeToGrow(at: currentAnchor, to: target, neighbors: neighbors) {
            guard let destination = NativePlacement.projection(for: target, measured: target, on: display,
                                                               neighbors: neighbors) else { return .refused }
            var staged = currentAnchor
            staged.x = destination.frame.x
            staged.y = destination.frame.y
            guard NativePlacement.accepts(staged, for: staged, on: display, neighbors: neighbors),
                  NativePlacement.safeToGrow(at: staged, to: target, neighbors: neighbors) else { return .refused }
            anchor = staged
            positioned = NativePlacement.accepts(measured, for: staged, on: display, neighbors: neighbors)
                && canResizeHere
        }

        let last = awaiting
        awaiting = nil
        switch last {
        case .anchor?, .position?:
            if !positioned { return .wait }
        case .resize?:
            if !sizeReady { return .wait }
        default:
            break
        }

        if let anchor, !positioned {
            if sizeReady {
                guard positionWrites < 2 else { return .refused }
                positionWrites += 1
                awaiting = .position(anchor)
                return .position(anchor)
            }
            guard anchorWrites < 2 else { return .refused }
            anchorWrites += 1
            awaiting = .anchor(anchor)
            return .anchor(anchor)
        }

        // An oversized source frame has no safe anchor yet. Shrinking it in
        // place is allowed if that write adds no new overlap with another screen.
        guard sizeWritable, !sizeReady, sizeWrites < 2, canResizeHere else { return .refused }
        if sizeWrites == 0 { beforeFirstResize = measured } else { beforeSecondResize = measured }
        sizeWrites += 1
        awaiting = .resize
        return .resize
    }

    /// A cell-based app can stop between points we can request. Two independent
    /// attempts must yield the same size, and each missed dimension must have
    /// moved closer to the target than it was before the first write.
    private func negotiated(_ measured: Box, _ target: Box) -> Bool {
        guard awaiting != .resize, let original = beforeFirstResize, let first = beforeSecondResize,
              abs(first.width - measured.width) <= 1, abs(first.height - measured.height) <= 1 else { return false }
        func progressed(_ actual: Double, from start: Double, toward wanted: Double) -> Bool {
            let error = abs(wanted - actual)
            return error <= 1 || error + 1 < abs(wanted - start)
        }
        return progressed(measured.width, from: original.width, toward: target.width)
            && progressed(measured.height, from: original.height, toward: target.height)
    }
}
