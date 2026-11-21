import ChainCore

func runWindowPaddingChecks() {
    let screen = ScreenInfo(id: "desk", name: "Desk", bounds: Box(x: 0, y: 0, width: 1000, height: 600))
    var workspace = Workspace()
    workspace.syncScreens([screen])
    let ids = ["A", "B", "C", "D", "E", "F"]
    for id in ids {
        workspace.discover(WindowInfo(id: id, app: "Editor", title: id), on: screen.id)
        workspace.select(id)
    }
    workspace.stack("F", with: "E")
    workspace.select("A")
    let available = Set(ids)
    var presentation = Presentation()
    _ = presentation.update(workspace, available: available, at: 0)
    workspace.select("C")
    _ = presentation.update(workspace, available: available, at: 1, activate: "C")
    precondition(presentation.isMoving(at: 1.05))

    let reflow = presentation.update(workspace, available: available, at: 1.05, windowPadding: 32)
    precondition(reflow.contains(.place("C", Box(x: 258, y: 0, width: 484, height: 600), screen.id)),
                 "editing the padding should snap the selected column to its new center")
    precondition(!presentation.isMoving(at: 1.05) && presentation.exposure(for: "C", at: 1.05) == ["B", "D", "C"])
    precondition(!reflow.contains(.raise("C", activate: true)), "editing padding should not reclaim keyboard focus")
    precondition(reflow.contains(.place("E", Box(x: 0, y: 0, width: 484, height: 284), screen.id))
                 && reflow.contains(.place("F", Box(x: 0, y: 316, width: 484, height: 284), screen.id)),
                 "staged rows should receive the new dimensions before scrolling into view")
    precondition(presentation.tick(at: 2).isEmpty)

    workspace.select("A")
    _ = presentation.update(workspace, available: available, at: 3, reduceMotion: true, windowPadding: 32)
    precondition(presentation.gap(on: screen.id, atX: 241, time: 3) == 0
                 && presentation.gap(on: screen.id, atX: 242, time: 3) == 1,
                 "drop regions should follow the padded width")
    let touching = presentation.update(workspace, available: available, at: 4, windowPadding: -5)
    precondition(touching.contains(.place("B", Box(x: 500, y: 0, width: 500, height: 600), screen.id)),
                 "zero padding should allow neighboring tiles to meet")
    let largest = presentation.update(workspace, available: available, at: 5, windowPadding: 100)
    precondition(largest.contains(.place("B", Box(x: 524, y: 0, width: 476, height: 600), screen.id)))
    precondition(presentation.update(workspace, available: available, at: 6, windowPadding: 48).isEmpty,
                 "equivalent clamped settings should leave a settled strip idle")
}
