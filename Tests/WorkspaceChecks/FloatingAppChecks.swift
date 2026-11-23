import ChainCore

func checkFloatingApps() {
    var workspace = Workspace()
    workspace.syncScreens([wide])
    let inbox = workspace.screens[wide.id]!.activeGroupID
    _ = workspace.createGroup(named: "Meeting", on: wide.id)
    workspace.discover(window("parked"), on: wide.id)
    workspace.switchGroup(inbox, on: wide.id)
    let observed = ["editor", "hidden", "detached", "paused"].map { (window($0), wide.id) }
    workspace.rescan(observed)
    workspace.detach("detached")
    workspace.pausePlacement("paused")
    var presentation = Presentation()
    let available = Set(workspace.windows.keys)
    let initial = presentation.update(workspace, available: available, at: 0)
    expect(initial.contains(.park("parked")), "the utility in the inactive group was parked")

    let floating: Set<String> = ["parked", "hidden", "detached", "paused", "new"]
    let reachable = available.subtracting(["hidden"]).union(["new"])
    let visible = reachable.map { (window($0), wide.id) }
    workspace.rescan(visible, floating: floating)
    expect(floating.allSatisfy { workspace.location(of: $0) == nil }, "floating apps leave every group")
    expect(workspace.windows["new"] == nil && workspace.placementPaused.isEmpty,
           "new utility windows bypass admission and old placement retries are cleared")
    expect(workspace.screens[wide.id]?.activeGroup?.columns == [["editor"]], "the editor takes the whole strip")
    let released = presentation.update(workspace, available: reachable, at: 1)
    expect(released.contains(.release("parked")) && !released.contains(.release("hidden")),
           "restore the parked utility immediately and defer the hidden window")

    let all = available.union(["new"])
    let allObserved = all.map { (window($0), wide.id) }
    workspace.rescan(allObserved, floating: floating)
    expect(presentation.update(workspace, available: all, at: 2) == [.release("hidden")],
           "the hidden utility is restored once when it becomes reachable")
    expect(presentation.update(workspace, available: all, at: 3).isEmpty, "floating windows stay untouched")
    workspace.rescan(allObserved)
    expect(floating.subtracting(["detached"]).allSatisfy { workspace.location(of: $0)?.groupID == inbox },
           "removing the app exclusion admits its eligible windows on the next scan")
    expect(workspace.detached == ["detached"] && workspace.location(of: "detached") == nil,
           "changing the app preference preserves an individual detach")
}
