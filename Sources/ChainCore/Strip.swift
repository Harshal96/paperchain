public enum Strip {
    public static let defaultPadding = 8
    public static let paddingRange = 0...48

    public static func clampedPadding(_ value: Int) -> Int {
        min(max(value, paddingRange.lowerBound), paddingRange.upperBound)
    }

    /// Distance between consecutive column origins. Two columns plus their
    /// shared gap exactly span the display, with no padding at the outer edges.
    static func stride(for width: Double, padding: Int) -> Double {
        width / 2 + min(Double(clampedPadding(padding)), width / 2) / 2
    }

    static func columnWidth(for width: Double, count: Int, padding: Int) -> Double {
        count == 1 ? width / 2 : width - stride(for: width, padding: padding)
    }

    /// Camera offset in points. Interior columns center. At either end two columns fit flush.
    public static func offset(column: Int, count: Int, width: Double, padding: Int = defaultPadding) -> Double {
        guard count > 2, width.isFinite, width > 0 else { return 0 }
        let slot = min(max(Double(column) - 0.5, 0), Double(count - 2))
        return slot * stride(for: width, padding: padding)
    }

    /// Full logical frames of columns that intersect the viewport. Clipping these
    /// frames to the display exposes the preceding window's trailing content and
    /// the following window's leading content.
    public static func frames<Columns: RandomAccessCollection>(
        columns: Columns, bounds: Box, offset: Double, padding: Int = defaultPadding
    ) -> [String: Box] where Columns.Element == [String] {
        let count = columns.count
        let pitch = stride(for: bounds.width, padding: padding)
        let columnWidth = columnWidth(for: bounds.width, count: count, padding: padding)
        guard count > 0, bounds.x.isFinite, bounds.y.isFinite,
              columnWidth > 0, columnWidth.isFinite, bounds.height > 0, bounds.height.isFinite,
              offset.isFinite else { return [:] }

        let finalSlot = max(0, count - 2)
        let camera = min(max(offset / pitch, 0), Double(finalSlot))
        let first = camera >= Double(finalSlot) ? finalSlot : Int(camera)
        let fraction = camera - Double(first)
        let visibleCount = min(count - first, fraction > 0 ? 3 : 2)
        let firstX = bounds.x - fraction * pitch
        let rightEdge = bounds.x + bounds.width
        var frames: [String: Box] = [:]

        for slot in 0..<visibleCount {
            let x = firstX + Double(slot) * pitch
            guard x < rightEdge && x + columnWidth > bounds.x else { continue }
            let index = columns.index(columns.startIndex, offsetBy: first + slot)
            let rows = columns[index]
            guard !rows.isEmpty else { continue }
            let rowCount = Double(rows.count)
            let rowGap = min(Double(clampedPadding(padding)), bounds.height / rowCount)
            let usableHeight = bounds.height - rowGap * (rowCount - 1)
            for (row, id) in rows.enumerated() {
                let top = bounds.y + usableHeight * (Double(row) / rowCount) + rowGap * Double(row)
                let bottom = bounds.y + usableHeight * (Double(row + 1) / rowCount) + rowGap * Double(row)
                frames[id] = Box(x: x, y: top, width: columnWidth, height: bottom - top)
            }
        }
        return frames
    }
}

/// A finite-duration cubic Hermite segment in monotonic seconds. Retargeting splices
/// a new segment to the current position and velocity, including during reversals.
public struct ScrollMotion {
    private var origin: Double
    private var destination: Double
    private var initialVelocity = 0.0
    private var startTime = 0.0
    private var duration = 0.0

    public init(offset: Double) {
        origin = offset
        destination = offset
    }

    public func position(at time: Double) -> Double {
        guard duration > 0 else { return destination }
        let t = (time - startTime) / duration
        guard t > 0 else { return origin }
        guard t < 1 else { return destination }
        let eased = t * t * (3 - 2 * t)
        let carry = t * (1 - t) * (1 - t)
        return origin + (destination - origin) * eased + initialVelocity * duration * carry
    }

    public mutating func retarget(to offset: Double, at time: Double) {
        guard offset.isFinite, time.isFinite, offset != destination else { return }
        let current = position(at: time)
        let velocity = velocity(at: time)
        let distance = abs(offset - current)
        // Limit the inherited tangent on short moves so a fast interrupted gesture
        // cannot send the camera far past its new destination.
        duration = distance > 0 ? 0.24 : 0
        if velocity != 0 {
            duration = min(duration, 3 * distance / abs(velocity))
        }
        origin = current
        destination = offset
        initialVelocity = velocity
        startTime = time
    }

    public func isMoving(at time: Double) -> Bool {
        duration > 0 && time >= startTime && time - startTime < duration
    }

    private func velocity(at time: Double) -> Double {
        guard isMoving(at: time) else { return 0 }
        let t = (time - startTime) / duration
        return 6 * t * (1 - t) * (destination - origin) / duration
            + initialVelocity * (1 - t) * (1 - 3 * t)
    }
}
