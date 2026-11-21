import ChainCore

func runNativePerformanceChecks() {
    checkFloatingDockClicks()
    let screen = ScreenInfo(id: "L", name: "Left", bounds: Box(x: -1600, y: 24, width: 1600, height: 900))
    let neighbor = Box(x: 0, y: 0, width: 1000, height: 1000)
    let start = Box(x: -1500, y: 24, width: 800, height: 900)
    var previous = start
    var readbacks = NativeMoveReadbacks()
    var deadline: Double?
    var reads = 0
    let ticks = 30
    for tick in 1...ticks {
        let time = Double(tick) / 120
        let desired = Box(x: start.x + Double(tick) * 10, y: 24, width: 800, height: 900)
        if readbacks.deferMove("w", from: previous, to: desired, on: screen, neighbors: [neighbor]) {
            if deadline == nil { deadline = time + NativeMoveReadbacks.interval }
        } else { reads += 1 }
        if !readbacks.coversMoveNotification("w", dragging: nil) { reads += 1 }
        if let due = deadline, time >= due {
            let batch = readbacks.takeAll()
            precondition(batch["w"]?.frame == desired, "Readback must confirm the latest requested tile")
            reads += batch.count
            deadline = nil
        }
        previous = desired
    }
    let final = readbacks.takeAll()
    if let target = final["w"] { precondition(target.frame == previous) }
    reads += final.count
    precondition(reads > 0 && reads <= 5, "Origin writes and their notifications caused repeated geometry reads")

    precondition(readbacks.deferMove("w", from: start, to: previous, on: screen, neighbors: [neighbor]))
    precondition(!readbacks.coversMoveNotification("w", dragging: "w"), "A user drag must retain its AX observations")
    let ignored = readbacks.takeAll()["w"]!
    precondition(!NativePlacement.accepts(start, for: ignored.frame, on: screen.bounds, neighbors: [neighbor]),
                 "A setter reporting success without moving must fail its final readback")

    let seam = Box(x: -800, y: 24, width: 800, height: 900)
    precondition(readbacks.deferMove("w", from: start, to: previous, on: screen, neighbors: [neighbor]))
    precondition(!readbacks.deferMove("w", from: start, to: seam, on: screen, neighbors: [neighbor]),
                 "A move against an adjacent physical display requires immediate confirmation")
    precondition(readbacks.takeAll().isEmpty, "A seam read must supersede an earlier queued estimate")
    let across = Box(x: 20, y: 24, width: 800, height: 900)
    precondition(!readbacks.deferMove("w", from: across, to: start, on: screen, neighbors: [neighbor]),
                 "A move from another screen requires immediate confirmation")
    precondition(readbacks.takeAll().isEmpty)
    print("Simulated AX geometry: \(ticks) origin writes + \(ticks) move notifications, \(reads) frame reads (eager baseline \(ticks * 2)).")
}

private func checkFloatingDockClicks() {
    let screen = ScreenInfo(id: "dock", name: "Dock", bounds: Box(x: 0, y: 24, width: 1200, height: 850))
    let second = ScreenInfo(id: "other", name: "Other", bounds: Box(x: 1200, y: 24, width: 1200, height: 850))
    for retryFailsBeforeSecondClick in [false, true] {
        var workspace = Workspace()
        workspace.syncScreens([screen, second])
        for id in ["A", "B", "C", "D"] {
            workspace.discover(WindowInfo(id: id, app: "Editor", title: id), on: id == "D" ? second.id : screen.id)
            workspace.select(id)
        }
        let available = Set(workspace.windows.keys)
        var view = Presentation()
        var focus = DockFocusSelection()
        var settling = false
        var front: String?
        var activations: [String] = []
        func apply(_ commands: [WindowCommand]) {
            for case let .raise(id, activate) in commands {
                if !activate, focus.coversPassiveRaise(id, in: workspace, settling: settling) { continue }
                if settling && id == "B" {
                    precondition(!activate, "Geometry settlement must never acquire a delayed activation for B")
                    continue
                }
                if activate { activations.append(id) }
                if id != "D" { front = id }
            }
        }
        func render(at time: Double, activate: String? = nil, force: Bool = false) {
            focus.reconcile(workspace, activating: activate)
            apply(view.update(workspace, available: available, at: time, activate: activate, force: force))
            apply(view.tick(at: time + 0.3))
        }
        workspace.pausePlacement("B")
        render(at: 0)
        for (step, id) in ["A", "B", "C", "B", "A"].enumerated() {
            let time = Double(step + 1)
            view.observedFocus(id)
            var raisedOn: String?
            if id == "B", workspace.placementPaused.contains(id) || settling {
                front = id
                activations.append(id)
                raisedOn = screen.id
                workspace.retryPlacement(id)
                settling = true
            }
            let activate = focus.clicked(id, directlyRaisedOn: raisedOn)
            workspace.select(id)
            render(at: time, activate: activate)
            precondition(front == id, "Dock click did not leave the chosen window in front")
            if id == "B" {
                precondition(!focus.coversPassiveRaise("D", in: workspace, settling: true))
                precondition(!focus.coversPassiveRaise("A", in: workspace, settling: false))
            }
            if step == 1 && retryFailsBeforeSecondClick {
                // The failed retry removes B from the projected strip and restacks A/C.
                settling = false
                workspace.pausePlacement("B")
                render(at: time + 0.4, force: true)
                precondition(front == "B", "Failure reflow covered the visible floating window")
            }
        }
        // A late observation can either confirm B or release it back to floating.
        settling = false
        if !retryFailsBeforeSecondClick { workspace.pausePlacement("B") }
        render(at: 7, force: true)
        precondition(front == "A" && activations == ["A", "B", "C", "B", "A"])

        // Interrupt an ordinary C activation before its animation has finished.
        workspace.retryPlacement("B")
        render(at: 8)
        workspace.select("C")
        let toC = focus.clicked("C", directlyRaisedOn: nil)
        apply(view.update(workspace, available: available, at: 9, activate: toC))
        precondition(view.isMoving(at: 9))
        settling = true
        view.observedFocus("B")
        front = "B"
        activations.append("B")
        workspace.select("B")
        render(at: 9.01, activate: focus.clicked("B", directlyRaisedOn: screen.id))
        precondition(front == "B" && activations.last == "B", "Interrupted C activation stole focus")
    }
}
