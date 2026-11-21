/// Origin-only moves clear of neighboring displays can share a readback. Verify
/// at physical seams and display transfers immediately and batch the other moves.
public struct NativeMoveReadbacks {
    public struct Target {
        public let frame: Box
        public let screen: ScreenInfo
    }

    public static let interval = 0.08
    private var pending: [String: Target] = [:]

    public init() {}

    public mutating func deferMove(_ id: String, from previous: Box, to desired: Box,
                                   on screen: ScreenInfo, neighbors: [Box]) -> Bool {
        guard NativePlacement.accepts(previous, for: previous, on: screen.bounds, neighbors: neighbors),
              let projected = NativePlacement.projection(for: desired, measured: previous, on: screen.bounds, neighbors: neighbors),
              projected.edge != .shared,
              !neighbors.contains(where: { other in
                  let fitted = projected.frame
                  return fitted.x - 1 < other.x + other.width && other.x < fitted.x + fitted.width + 1 &&
                  fitted.y - 1 < other.y + other.height && other.y < fitted.y + fitted.height + 1
              }) else {
            pending.removeValue(forKey: id)
            return false
        }
        pending[id] = Target(frame: desired, screen: screen)
        return true
    }

    public func coversMoveNotification(_ id: String, dragging: String?) -> Bool {
        dragging != id && pending[id] != nil
    }

    @discardableResult
    public mutating func remove(_ id: String) -> Target? {
        pending.removeValue(forKey: id)
    }

    public mutating func takeAll() -> [String: Target] {
        let batch = pending
        pending = [:]
        return batch
    }
}
