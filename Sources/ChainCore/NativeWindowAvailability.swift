package enum NativeWindowAvailability {
    /// Preserve the last confirmed state across incomplete AX reads. New windows must
    /// first present enough evidence to tile, and our own minimizes stay accessible.
    package static func suspended(previously: Bool?, hidden: Bool, fullScreen: Bool?,
                                  minimized: Bool?, owned: Bool, movable: Bool?) -> Bool {
        if hidden || fullScreen == true || minimized == true && !owned { return true }
        if minimized == false && movable == false { return true }
        if fullScreen == false, (minimized == false && movable == true) || (minimized == true && owned) { return false }
        return previously ?? true
    }
}
