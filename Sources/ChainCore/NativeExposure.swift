import Foundation

/// Interior AX hit-test points for the measured frames of the expected back-to-front stack.
public enum NativeExposure {
    public static func samples(order: [String], frames: [String: Box], bounds: Box)
        -> [(id: String, x: Double, y: Double)] {
        guard let display = rect(bounds) else { return [] }
        var layers: [(id: String, frame: CGRect)] = []
        for id in order {
            guard let box = frames[id], let frame = rect(box) else { return [] }
            let clipped = display.intersection(frame)
            if !clipped.isEmpty { layers.append((id, clipped)) }
        }
        var samples: [(id: String, x: Double, y: Double)] = []
        for (index, layer) in layers.enumerated() {
            let blockers = layers.dropFirst(index + 1)
                .map { layer.frame.intersection($0.frame) }
                .filter { !$0.isEmpty }
                .sorted { $0.minY < $1.minY }
            if let visible = largestGap(in: layer.frame, blockers: blockers) {
                samples.append((layer.id, visible.midX, visible.midY))
            }
        }
        return samples
    }

    private static func rect(_ box: Box) -> CGRect? {
        guard box.x.isFinite, box.y.isFinite, box.width > 0, box.height > 0,
              (box.x + box.width).isFinite, (box.y + box.height).isFinite else { return nil }
        return CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
    }

    private static func largestGap(in frame: CGRect, blockers: [CGRect]) -> CGRect? {
        guard !blockers.isEmpty else { return frame }
        // The largest free rectangle ends at window edges. For each horizontal
        // span between two edges, sweep the covering intervals from top to bottom.
        let edges = Set([frame.minX, frame.maxX] + blockers.flatMap { [$0.minX, $0.maxX] }).sorted()
        var best: CGRect?
        var bestArea = 0.0
        for (index, left) in edges.enumerated() {
            for right in edges.dropFirst(index + 1) {
                let width = right - left
                var top = frame.minY
                func considerGap(endingAt bottom: CGFloat) {
                    let height = bottom - top
                    let area = width * height
                    if area > bestArea {
                        bestArea = area
                        best = CGRect(x: left, y: top, width: width, height: height)
                    }
                }
                for blocker in blockers where blocker.minX < right && left < blocker.maxX {
                    considerGap(endingAt: blocker.minY)
                    top = max(top, blocker.maxY)
                }
                considerGap(endingAt: frame.maxY)
            }
        }
        return best
    }
}
