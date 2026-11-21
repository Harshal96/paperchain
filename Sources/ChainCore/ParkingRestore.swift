/// Verifies an accepted restore against subsequent observations of the window.
/// Ownership stays with the caller until the window is observed visible.
package struct ParkingRestore {
    package enum Intent: Equatable { case show, release, park }
    package enum Next: Equatable { case confirmed, retry, wait, keepParked, exhausted }

    package var intent: Intent
    private var checkedOnce = false

    package init(_ intent: Intent) {
        self.intent = intent
    }

    package mutating func check(minimized: Bool?) -> Next {
        if minimized == false { return .confirmed }
        if checkedOnce { return intent == .park ? .keepParked : .exhausted }

        checkedOnce = true
        if intent == .park || minimized == nil { return .wait }
        return .retry
    }
}
