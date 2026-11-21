import ChainCore

func checkBodyClicks() {
    var focus = NativeFocusObservation()
    expect(focus.observe("A", at: 1, suppressed: false, dragging: false, userInput: false), "initial focus on A")
    for (releasedOn, eligible) in [("C", true), ("B", false)] {
        focus.beganClick()
        expect(!focus.confirmBodyClick("B", releasedOn: releasedOn, eligible: eligible, at: 1.1),
               "a mismatched release or ineligible window must not select B")
        expect(focus.focusedID == "A", "a rejected body click changed the accepted focus")
    }
    focus.beganClick()
    expect(focus.confirmBodyClick("B", releasedOn: "B", eligible: true, at: 2),
           "pressing and releasing on B should select it even while its app still reports A")
    expect(!focus.observe("A", at: 2.01, suppressed: false, dragging: false, userInput: false) && focus.focusedID == "B",
           "an old focus notification overrode B before the manager raised anything")

    var keyboard = focus
    expect(keyboard.observe("A", at: 2.02, suppressed: false, dragging: false, userInput: true) && keyboard.focusedID == "A",
           "a genuine keyboard focus change must supersede the accepted click")
    focus.beganClick()
    expect(focus.observe("A", at: 2.02, suppressed: false, dragging: false, userInput: false) && focus.focusedID == "A",
           "a fresh mouse-down must allow the next native focus observation")

    var workspace = Workspace()
    workspace.syncScreens([wide, tall])
    for id in ["A", "B", "C"] {
        workspace.discover(window(id), on: wide.id)
        workspace.select(id)
    }
    workspace.discover(window("Notes"), on: tall.id)
    let available = Set(workspace.windows.keys)
    var presentation = Presentation()
    workspace.select("A")
    _ = presentation.update(workspace, available: available, at: 0)
    workspace.select("C")
    let opening = presentation.update(workspace, available: available, at: 1, activate: "C")
    expect(presentation.isMoving(at: 1) && !opening.contains(.raise("C", activate: true)),
           "the test must interrupt a queued activation before it reaches the viewport")
    var uninterrupted = presentation
    expect(uninterrupted.tick(at: 2).contains(.raise("C", activate: true)), "the queued activation should normally fire")
    // A mouse-down on another screen or app can arrive before AX identifies its window.
    presentation.cancelActivation()
    let settling = presentation.tick(at: 1.05) + presentation.tick(at: 2)
    expect(!settling.contains(.raise("C", activate: true)),
           "input outside the strip must cancel the queued activation while scrolling finishes")
}
