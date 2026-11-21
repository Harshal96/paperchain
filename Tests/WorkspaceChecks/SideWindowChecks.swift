import ChainCore

func checkSideWindows() {
    var workspace = Workspace()
    workspace.syncScreens([wide, tall])
    for id in ["A", "B", "C", "D", "peer"] {
        workspace.discover(window(id), on: wide.id)
        workspace.select(id)
    }
    workspace.stack("peer", with: "B")
    for id in ["notes", "calendar", "mail", "tasks"] { workspace.discover(window(id), on: tall.id) }
    let inbox = workspace.screens[wide.id]!.activeGroupID
    _ = workspace.createGroup(named: "Other", on: wide.id)
    workspace.discover(window("other"), on: wide.id)
    workspace.switchGroup(inbox, on: wide.id)
    workspace.select("B")

    var available = Set(workspace.windows.keys)
    var presentation = Presentation()
    _ = presentation.update(workspace, available: available, at: 0)
    let center = presentation.sideWindows(whenFocusing: "B", at: 0)
    expect(center?.bounds == wide.bounds && center?.windows == ["A", "C", "peer"],
           "dimming includes the visible neighbors and stack peer on the focused display in layer order")
    for id in ["A", "D", "other", "unmanaged"] {
        expect(presentation.sideWindows(whenFocusing: id, at: 0) == nil,
               "a side, covered, parked, or unmanaged window cannot start dimming")
    }
    workspace.select("D")
    _ = presentation.update(workspace, available: available, at: 1)
    expect(presentation.sideWindows(whenFocusing: "B", at: 1) == nil &&
           presentation.sideWindows(whenFocusing: "D", at: 1.1) == nil,
           "scrolling must discard previous targets and wait for the new selection to settle")
    _ = presentation.tick(at: 2)
    expect(presentation.sideWindows(whenFocusing: "D", at: 2) == nil,
           "dimming stays off at the far endpoint, even after the scroll settles")
    workspace.select("B")
    _ = presentation.update(workspace, available: available, at: 3)
    _ = presentation.tick(at: 4)
    expect(presentation.sideWindows(whenFocusing: "B", at: 4)?.windows == ["A", "C", "peer"],
           "returning to the center restores dimming")
    workspace.detach("C")
    workspace.close("peer")
    _ = presentation.update(workspace, available: available, at: 5, reduceMotion: true)
    expect(presentation.sideWindows(whenFocusing: "B", at: 5)?.windows == ["A", "D"],
           "dimming follows the new neighbors after a peer is closed and a side is detached")
    available.remove("A")
    _ = presentation.update(workspace, available: available, at: 6, reduceMotion: true)
    expect(presentation.sideWindows(whenFocusing: "B", at: 6) == nil,
           "losing the last available window on the left makes the focused window an endpoint")
    workspace.select("D")
    _ = presentation.update(workspace, available: available, at: 6, reduceMotion: true)
    expect(presentation.sideWindows(whenFocusing: "D", at: 6) == nil,
           "focusing the right window of the remaining pair also keeps both bright")
    workspace.select("B")
    available.insert("A")
    workspace.pausePlacement("D")
    _ = presentation.update(workspace, available: available, at: 7, reduceMotion: true)
    expect(presentation.sideWindows(whenFocusing: "B", at: 7) == nil,
           "a paused right neighbor cannot keep dimming active")

    // Four visible windows in two portrait columns still form two endpoints.
    for id in ["notes", "calendar", "mail", "tasks"] {
        workspace.select(id)
        _ = presentation.update(workspace, available: available, at: 8, reduceMotion: true)
        expect(presentation.sideWindows(whenFocusing: id, at: 8) == nil,
               "selecting either row on either side of a two-column display leaves every window bright")
    }
    workspace.discover(window("music"), on: tall.id)
    available.insert("music")
    workspace.select("mail")
    _ = presentation.update(workspace, available: available, at: 9, reduceMotion: true)
    expect(presentation.sideWindows(whenFocusing: "mail", at: 9) != nil,
           "a third portrait column gives the middle stack neighbors on both sides")
    workspace.setEnabled(false, on: tall.id)
    _ = presentation.update(workspace, available: available, at: 10)
    expect(presentation.sideWindows(whenFocusing: "mail", at: 10) == nil,
           "disabling a monitor clears its targets")
}
