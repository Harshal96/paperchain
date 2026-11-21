/// Follows an explicit Accessibility request while the user can stay in System Settings.
package enum AccessibilityGrantRequest {
    @MainActor
    package static func run(requestTrust: () -> Bool, openSettings: () -> Void, isTrusted: () -> Bool,
                            wait: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
                            onGrant: () -> Void) async {
        guard !Task.isCancelled else { return }
        if requestTrust() {
            onGrant()
            return
        }
        openSettings()
        for _ in 0..<120 {
            do { try await wait() } catch { return }
            guard !Task.isCancelled else { return }
            if isTrusted() {
                onGrant()
                return
            }
        }
    }
}
