import ChainCore

@MainActor
func checkGrantRecovery() async {
    var events: [String] = []
    var trusted = false
    await AccessibilityGrantRequest.run(requestTrust: { events.append("request"); return false },
                                       openSettings: { events.append("settings") },
                                       isTrusted: { events.append("check"); return trusted },
                                       wait: { trusted = events.contains("check") },
                                       onGrant: { events.append("refresh") })
    expect(events == ["request", "settings", "check", "check", "refresh"],
           "a grant made in System Settings refreshes the inventory once without an activation event")

    events = []
    await AccessibilityGrantRequest.run(requestTrust: { true },
                                       openSettings: { events.append("settings") },
                                       isTrusted: { events.append("check"); return true },
                                       wait: { events.append("wait") },
                                       onGrant: { events.append("refresh") })
    expect(events == ["refresh"], "an existing grant refreshes immediately without polling")

    var checks = 0
    var settings = 0
    var refreshes = 0
    await AccessibilityGrantRequest.run(requestTrust: { false }, openSettings: { settings += 1 },
                                       isTrusted: {
                                           checks += 1
                                           expect(checks <= 120, "a denied request must stop checking")
                                           return false
                                       }, wait: {}, onGrant: { refreshes += 1 })
    expect(settings == 1 && checks > 0 && refreshes == 0, "remaining denied opens settings once and finishes")

    let stopped = Task { @MainActor in
        await AccessibilityGrantRequest.run(requestTrust: { false }, openSettings: { settings += 1 },
                                           isTrusted: { checks += 1; return true },
                                           wait: { withUnsafeCurrentTask { $0?.cancel() } },
                                           onGrant: { refreshes += 1 })
    }
    let beforeStop = checks
    await stopped.value
    expect(settings == 2 && checks == beforeStop && refreshes == 0,
           "repeated explicit requests can reopen settings and cancellation prevents a late rescan")
}
