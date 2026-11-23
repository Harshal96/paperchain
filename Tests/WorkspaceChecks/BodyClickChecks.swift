import ChainCore
import Foundation

func checkBodyClicks() {
    var focus = NativeFocusObservation()
    expect(focus.observe("A", at: 1, suppressed: false, dragging: false, userInput: false), "initial focus on A")
    for (releasedOn, eligible) in [("C", true), ("B", false)] {
        focus.beganClick()
        expect(focus.confirmClick("B", on: wide.id, bodyWindow: eligible ? releasedOn : nil,
                                  nativeFocused: false, at: 1.1) == nil,
               "a mismatched release or ineligible window must not select B")
        expect(focus.focusedID == "A", "a rejected body click changed the accepted focus")
    }
    focus.beganClick()
    expect(focus.confirmClick("B", on: wide.id, bodyWindow: "B",
                              nativeFocused: false, at: 2) == .body,
           "pressing and releasing on B should select it even while its app still reports A")
    expect(!focus.observe("A", at: 2.01, suppressed: false, dragging: false, userInput: false) && focus.focusedID == "B",
           "an old focus notification overrode B before the manager raised anything")

    var keyboard = focus
    expect(keyboard.observe("A", at: 2.02, suppressed: false, dragging: false, userInput: true) && keyboard.focusedID == "A",
           "a genuine keyboard focus change must supersede the accepted click")
    focus.beganClick()
    expect(focus.observe("A", at: 2.02, suppressed: false, dragging: false, userInput: false) && focus.focusedID == "A",
           "a fresh mouse-down must allow the next native focus observation")

    // A click just across the seam can be followed by focus on a previously
    // raised sibling, even when the AX hit does not identify any window.
    var seam = NativeFocusObservation()
    seam.clicked("source center")
    _ = seam.raise("source edge", activate: false, at: 4)
    _ = seam.observe("source edge", at: 4.1, suppressed: true, dragging: false, userInput: false)
    let displays = [wide.id: CGRect(x: -1600, y: 0, width: 1600, height: 900),
                    tall.id: CGRect(x: 0, y: -400, width: 900, height: 1600)]
    func screen(at x: Double) -> String? { Workspace.physicalScreen(at: CGPoint(x: x, y: 100), in: displays) }
    func press(_ x: Double, at time: Double, in focus: inout NativeFocusObservation,
               hit: (screen: String, clipped: Bool)? = nil) {
        focus.beganClick()
        focus.locatePress(at: CGPoint(x: x, y: 100), time: time, displays: displays, hit: hit)
    }
    press(0, at: 4.15, in: &seam)
    var foreignHit = seam
    foreignHit.releasedPointer(on: screen(at: 0), at: 4.2)
    for body in [nil, "source edge"] {
        expect(foreignHit.confirmClick("source edge", on: wide.id, bodyWindow: body,
                                       nativeFocused: true, at: 4.2) == nil,
               "an AX hit on a source window across the seam must not center that window")
    }
    foreignHit.releasedPointer(on: screen(at: -1), at: 4.21)
    expect(foreignHit.confirmClick("source edge", on: wide.id, bodyWindow: "source edge",
                                   nativeFocused: true, at: 4.21) == nil,
           "a one-point motion into the owner cannot turn a foreign press into a local click")
    press(-1, at: 4.22, in: &foreignHit)
    foreignHit.releasedPointer(on: screen(at: 0), at: 4.23)
    expect(foreignHit.confirmClick("source edge", on: wide.id, bodyWindow: "source edge",
                                   nativeFocused: true, at: 4.23) == nil,
           "releasing on the neighbor cannot complete a source-display click")
    var crossed = foreignHit
    expect(!crossed.observe("source sibling", on: wide.id, at: 4.24, suppressed: false, dragging: false, userInput: false),
           "an AX callback after a release across the seam cannot select an unrelated source sibling")
    press(-1, at: 4.24, in: &foreignHit)
    foreignHit.releasedPointer(on: screen(at: -1), at: 4.25)
    expect(foreignHit.confirmClick("source edge", on: wide.id, bodyWindow: "source edge",
                                   nativeFocused: true, at: 4.25) == .body,
           "the last point on the source display still selects its exposed edge")
    var launcher = seam
    press(450, at: 4.4, in: &launcher)
    launcher.releasedPointer(on: screen(at: 450), at: 4.45)
    expect(launcher.confirmClick("launcher", on: tall.id, bodyWindow: nil, nativeFocused: false, at: 4.45) == nil,
           "an interior launcher action can transfer focus away from the clicked window")
    expect(launcher.observe("source edge", on: wide.id, at: 4.46, suppressed: false, dragging: false, userInput: false),
           "an interior launcher action can open an existing window on another display")
    for (x, hit) in [(899.0, nil), (450.0, (screen: wide.id, clipped: false)), (175.0, (screen: tall.id, clipped: true))] {
        var outside = seam
        press(x, at: 4.5, in: &outside, hit: hit)
        expect(!outside.observe("source edge", on: wide.id, at: 4.51, suppressed: false, dragging: false, userInput: false),
               "the outer edge, a foreign AX hit, and a clipped preview each protect the other strip")
    }
    expect(NativeFocusObservation.awaitingMouseDown(at: 4.7, handledThrough: 4.5, downAge: 0.02, keyAge: 1),
           "an AX notification arriving before a queued press must wait for mouse-up routing")
    expect(!NativeFocusObservation.awaitingMouseDown(at: 4.7, handledThrough: 4.5, downAge: 0.02, keyAge: 0.01),
           "a keyboard shortcut after a queued click still takes precedence")
    seam.releasedPointer(on: screen(at: 0), at: 5)
    let staleFocus = seam.observe("source edge", on: wide.id, at: 5.01, suppressed: false, dragging: false, userInput: false)
    expect(!staleFocus && seam.focusedID == "source center",
           "an edge click on the other display must preserve the source strip selection")

    var replay = seam
    expect(replay.inputBaseline(at: 6, lastManagerFocus: 4) >= 4.15,
           "a key from before the click cannot qualify a later replay as new user input")
    let baseline = replay.inputBaseline(at: 6, lastManagerFocus: 0)
    expect(!replay.observe("source edge", on: wide.id, at: 6, suppressed: false, dragging: false, userInput: 4 < 6 - baseline),
           "a key at time 2 cannot legitimize a stale focus report at time 6")
    expect(replay.observe("source edge", on: wide.id, at: 6, suppressed: false, dragging: false, userInput: 0.1 < 6 - baseline),
           "a key at time 5.9 can switch focus even after suppression expires")
    expect(seam.inputBaseline(at: 5.02, lastManagerFocus: 4) == 4.15,
           "a key pressed before this click cannot bypass its display check")
    var keySwitch = seam
    expect(keySwitch.observe("source edge", on: wide.id, at: 5.03, suppressed: false, dragging: false, userInput: true),
           "a subsequent keyboard shortcut may switch focus to the source display")
    expect(seam.observe("destination", on: tall.id, at: 5.03, suppressed: false, dragging: false, userInput: false),
           "focus on the clicked display should select its own window")
    seam.beganClick() // macOS Dock activation can target any display
    expect(seam.observe("source edge", on: wide.id, at: 5.05, suppressed: false, dragging: false, userInput: false),
           "clicking the system Dock should still select an existing window on another display")

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
