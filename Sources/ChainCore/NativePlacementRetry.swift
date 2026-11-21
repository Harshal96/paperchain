/// A successful AX setter can leave the old frame observable while the application
/// applies constraints or animates. The first sample observes, the second can issue
/// one fresh write, and the last sample confirms the result.
public struct NativePlacementRetry {
    private static let delays = [0.12, 0.35, 0.70]
    private var scheduled = 0

    public init() {}

    public var shouldReissue: Bool { scheduled == 2 }
    public var isFinalCheck: Bool { scheduled == Self.delays.count }

    public mutating func nextDelay() -> Double? {
        guard scheduled < Self.delays.count else { return nil }
        let delay = Self.delays[scheduled]
        scheduled += 1
        return delay
    }
}
