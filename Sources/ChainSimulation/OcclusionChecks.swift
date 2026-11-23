import ChainCore

func runOcclusionChecks() {
    checkDisplayConnectionAtRest()
    checkDepartingEdge()
    checkClickedNeighborDuringMotion()
    checkNativeExposure()
    let screen = ScreenInfo(id: "strip", name: "Strip", bounds: Box(x: -1000, y: 0, width: 1000, height: 600))
    var workspace = Workspace()
    workspace.syncScreens([screen])
    var presentation = Presentation()
    var desktop = VirtualDesktop()
    func add(_ id: String) {
        workspace.discover(WindowInfo(id: id, app: "Editor", title: id), on: screen.id)
        workspace.select(id)
    }
    func update(at time: Double) {
        desktop.consume(presentation.update(workspace, available: Set(workspace.windows.keys), at: time),
                        screens: workspace.screens)
    }
    func sample(_ time: Double) {
        desktop.consume(presentation.tick(at: time), screens: workspace.screens)
    }
    func top(at x: Double, y: Double = 300) -> String? {
        desktop.layers.last { id in
            guard let box = desktop.frames[id] else { return false }
            return x >= box.x && x < box.x + box.width && y >= box.y && y < box.y + box.height
        }
    }
    add("A")
    add("B")
    update(at: 0)
    add("C")
    update(at: 1)
    precondition(desktop.parked.isEmpty && desktop.frames["C"] != nil,
                 "Opening a third window minimized it on the first animation frame")
    precondition(top(at: -750) == "A" && top(at: -250) == "B", "Covered window obscured the endpoint")
    sample(2)
    precondition(top(at: -750) == "B" && top(at: -250) == "C")
    workspace.select("B")
    update(at: 3)
    sample(4)
    precondition(top(at: -875) == "A" && top(at: -500) == "B" && top(at: -125) == "C",
                 "Both neighbors must have a clickable quarter beside an interior window")
    precondition(-875 - desktop.frames["A"]!.x == 377 && -125 - desktop.frames["C"]!.x == 119,
                 "Free left and right edges must show the trailing and leading portions of their own documents")
    workspace.select("A")
    update(at: 5)
    sample(6)
    precondition(desktop.parked.isEmpty && top(at: -750) == "A" && top(at: -250) == "B")

    // Cmd-Tab can raise a fully covered native window before the first tick.
    desktop.consume([.raise("C", activate: true)], screens: workspace.screens)
    workspace.select("C")
    presentation.observedFocus("C")
    update(at: 7)
    precondition(top(at: -750) == "A" && top(at: -250) == "B", "A covered window escaped the starting layers")
    sample(8)
    precondition(top(at: -750) == "B" && top(at: -250) == "C")

    let original = workspace.screens[screen.id]!.activeGroupID
    _ = workspace.createGroup(named: "Other", on: screen.id)
    add("D")
    update(at: 9)
    precondition(desktop.parked == ["A", "B", "C"])
    workspace.switchGroup(original, on: screen.id)
    update(at: 10)
    precondition(desktop.parked == ["A", "D"], "Switching back restored an entire inactive chain")
    workspace.select("B")
    update(at: 11)
    sample(12)
    precondition(desktop.parked == ["D"] && top(at: -875) == "A")
    workspace.select("C")
    update(at: 13)
    sample(14)
    precondition(desktop.parked == ["D"], "Returning to an endpoint minimized a previously restored window")
}

private func checkDisplayConnectionAtRest() {
    let main = ScreenInfo(id: "main", name: "Main", bounds: Box(x: 0, y: 0, width: 1000, height: 600))
    let right = ScreenInfo(id: "right", name: "Right", bounds: Box(x: 1000, y: 0, width: 800, height: 600))
    var workspace = Workspace()
    workspace.syncScreens([main])
    let ids = ["A", "B", "C"]
    for id in ids {
        workspace.discover(WindowInfo(id: id, app: "Editor", title: id), on: main.id)
        workspace.select(id)
    }
    workspace.select("B")
    var presentation = Presentation()
    var desktop = VirtualDesktop()
    for (step, connected) in [false, true, false].enumerated() {
        workspace.syncScreens(connected ? [main, right] : [main])
        let commands = presentation.update(workspace, available: Set(ids), at: Double(step), force: true)
        desktop.consume(commands, screens: workspace.screens)
        precondition(desktop.frames["C"]?.x == (connected ? 504 : 756),
                     "Connecting or removing a monitor must reproject the settled edge without another click")
        precondition(desktop.frames["A"]?.x == -252 && desktop.frames["B"]?.x == 252)
        precondition(desktop.topWindow(x: 875, y: 300) == "C" && workspace.location(of: "C")?.screenID == main.id)
    }
}

private func checkDepartingEdge() {
    let bounds = Box(x: 0, y: 0, width: 1000, height: 600)
    var workspace = Workspace()
    workspace.syncScreens([ScreenInfo(id: "display", name: "Display", bounds: bounds)])
    let ids = ["A", "B", "C", "D", "E"]
    for id in ids {
        workspace.discover(WindowInfo(id: id, app: "Editor", title: id), on: "display")
        workspace.select(id)
    }
    var presentation = Presentation()
    func select(_ id: String, at time: Double) -> [WindowCommand] {
        workspace.select(id)
        return presentation.update(workspace, available: Set(ids), at: time, activate: id, reduceMotion: true)
    }
    let centered = select("B", at: 0)
    let raw = Box(x: -252, y: 0, width: 496, height: 600)
    precondition(centered.contains(.place("D", Box(x: 0, y: 0, width: 496, height: 600), "display")),
                 "staged windows should already fit the width of a visible column")
    precondition(centered.contains(.place("A", raw, "display")), "An exposed outer neighbor lost its logical strip position")
    presentation.observedFocus("C")
    let jumped = select("E", at: 1)
    precondition(presentation.gap(on: "display", atX: 247, time: 1) == 3
                 && presentation.gap(on: "display", atX: 248, time: 1) == 4,
                 "the center of the padded D tile separates the before and after drop targets")
    precondition(jumped.contains(.place("A", Box(x: 0, y: 0, width: 496, height: 600), "display")),
                 "A jump stranded the old edge window partly beyond the display")
    precondition(!jumped.contains(.park("A")))
    precondition(select("B", at: 2).contains(.place("A", raw, "display")),
                 "The returning neighbor must move from its staging position back to the strip")
}

private func checkNativeExposure() {
    let bounds = Box(x: -1000, y: 20, width: 1000, height: 600)
    var workspace = Workspace()
    workspace.syncScreens([ScreenInfo(id: "owner", name: "Owner", bounds: bounds)])
    for id in ["A", "B", "C", "D"] {
        workspace.discover(WindowInfo(id: id, app: "Editor", title: id), on: "owner")
        workspace.select(id)
    }
    workspace.select("A")
    let available = Set(workspace.windows.keys)
    var presentation = Presentation()
    _ = presentation.update(workspace, available: available, at: 0)
    precondition(presentation.exposure(for: "A", at: 0) == ["B", "A"])
    workspace.select("B")
    _ = presentation.update(workspace, available: available, at: 1, activate: "B")
    precondition(presentation.exposure(for: "A", at: 1).isEmpty)
    precondition(presentation.exposure(for: "B", at: 1.1).isEmpty)
    precondition(presentation.exposure(for: "B", at: 2).isEmpty, "The final native layout is still pending")
    _ = presentation.tick(at: 2)
    let order = presentation.exposure(for: "B", at: 2)
    precondition(order == ["A", "C", "B"])
    // The selected app accepted a wider minimum than its logical tile.
    let frames = ["A": Box(x: -1000, y: 20, width: 500, height: 600),
                  "B": Box(x: -900, y: 20, width: 800, height: 600),
                  "C": Box(x: -500, y: 20, width: 500, height: 600)]
    let samples = NativeExposure.samples(order: order, frames: frames, bounds: bounds)
    precondition(samples.map(\.id) == order && samples.map(\.x) == [-950, -50, -500])
    precondition(samples.allSatisfy { $0.y == 320 })
    workspace.stack("D", with: "B")
    _ = presentation.update(workspace, available: available, at: 3, reduceMotion: true)
    precondition(presentation.exposure(for: "D", at: 3) == ["A", "C", "B", "D"])

    // The largest horizontal strip beneath this top row crosses several
    // blocker edges. A single grid cell would place its midpoint too far left.
    let stacked = ["base": Box(x: -1100, y: 0, width: 1300, height: 800),
                   "row": Box(x: -600, y: 20, width: 300, height: 200)]
    let points = NativeExposure.samples(order: ["base", "row"], frames: stacked, bounds: bounds)
    precondition(points.count == 2 && points[0].x == -500 && points[0].y == 420)
    precondition(points[1].x == -450 && points[1].y == 120)
    let covered = NativeExposure.samples(order: ["base", "front"], frames: ["base": bounds, "front": bounds],
                                         bounds: bounds)
    precondition(covered.map(\.id) == ["front"], "Fully hidden windows offer no hit-test point")
    precondition(NativeExposure.samples(order: ["base", "unmeasured"], frames: ["base": bounds], bounds: bounds).isEmpty,
                 "A missing foreground measurement must prevent a speculative repair")
}

private func checkClickedNeighborDuringMotion() {
    let left = ScreenInfo(id: "left", name: "Left", bounds: Box(x: -1000, y: 0, width: 1000, height: 600))
    let right = ScreenInfo(id: "right", name: "Right", bounds: Box(x: 0, y: 0, width: 1000, height: 600))
    var workspace = Workspace()
    workspace.syncScreens([left, right])
    // Deliberately avoid lexical ordering. The outgoing center still needs to
    // sit above the rear edge when the incoming window comes to the front.
    let chain = ["Z", "B", "C", "A", "D"]
    for (screen, ids) in [(left, chain), (right, ["X", "Y"])] {
        for id in ids {
            workspace.discover(WindowInfo(id: id, app: "Editor", title: id), on: screen.id)
            workspace.select(id)
        }
    }
    workspace.select("B")
    let available = Set(workspace.windows.keys)
    var presentation = Presentation()
    var desk = VirtualDesktop()
    desk.consume(presentation.update(workspace, available: available, at: 0), screens: workspace.screens)
    @discardableResult
    func click(_ id: String, at time: Double, sameApplication: Bool = true) -> [WindowCommand] {
        desk.consume([.raise(id, activate: true)], screens: workspace.screens)
        presentation.clickedBody(id, sameApplication: sameApplication)
        workspace.select(id)
        let commands = presentation.update(workspace, available: available, at: time, activate: id)
        desk.consume(commands, screens: workspace.screens)
        return commands
    }
    func checkFrame(_ time: Double, selected: String, exposed: Set<String>) {
        desk.consume(presentation.tick(at: time), screens: workspace.screens)
        precondition(desk.layers.last(where: chain.contains) == selected,
                     "A managed raise covered the neighbor that received the body click")
        precondition(desk.exposes(exposed, in: left.bounds), "A neighboring preview was lost during a body click at \(time)")
        precondition(desk.exposes(["X", "Y"], in: right.bounds))
    }
    let initial = click("C", at: 1)
    for case let .raise(id, _) in initial {
        precondition(id == "C", "A click within the same app re-raised a sibling whose layer was already correct")
    }
    // Both halves of the slide have three clickable windows. At its exact
    // midpoint two whole columns fit and neither far neighbor is exposed.
    for frame in 0...28 {
        let time = 1 + Double(frame) / 120
        checkFrame(time, selected: "C", exposed: frame <= 14 ? ["Z", "B", "C"] : ["B", "C", "A"])
    }
    checkFrame(1.3, selected: "C", exposed: ["B", "C", "A"])
    // Reverse a second motion before the neighboring window reaches center.
    click("B", at: 2)
    checkFrame(2.035, selected: "B", exposed: ["B", "C", "A"])
    click("C", at: 2.035, sameApplication: false)
    checkFrame(2.045, selected: "C", exposed: ["B", "C", "A"])
    checkFrame(2.4, selected: "C", exposed: ["B", "C", "A"])
    click("B", at: 3)
    click("X", at: 3.035)
    desk.consume(presentation.tick(at: 3.4), screens: workspace.screens)
    precondition(desk.focused == "X", "A click on the second monitor lost focus to the first")
    precondition(desk.exposes(["Z", "B", "C"], in: left.bounds))
    click("Z", at: 4)
    checkFrame(4.03, selected: "Z", exposed: ["Z", "B", "C"])
    checkFrame(4.4, selected: "Z", exposed: ["Z", "B"])

    click("B", at: 5)
    checkFrame(5.4, selected: "B", exposed: ["Z", "B", "C"])
    // A control in the left preview can gain focus at mouse-up, gain it later, or open the right preview.
    for (immediate, destination, sameApp) in [(true, "Z", true), (false, "Z", false), (false, "C", true)] {
        var focus = NativeFocusObservation()
        var view = presentation
        var model = workspace
        var surface = desk
        focus.clicked("B")
        focus.beganClick()
        view.cancelActivation()
        let result = focus.confirmClick("Z", on: left.id, bodyWindow: nil, nativeFocused: immediate, at: 6)
        if immediate {
            precondition(result == .focused)
        } else {
            precondition(result == nil && focus.focusedID == "B", "A control click must wait for native focus")
            precondition(focus.observe(destination, at: 6.01, suppressed: false, dragging: false, userInput: false))
        }
        surface.consume([.raise(destination, activate: true)], screens: model.screens)
        view.observedFocus(destination, sameApplication: sameApp)
        model.select(destination)
        func checkControlFocus(_ commands: [WindowCommand]) {
            for case .raise(_, activate: true) in commands {
                preconditionFailure("The strip requested activation after a native control click")
            }
            surface.consume(commands, screens: model.screens)
            precondition(surface.layers.last(where: chain.contains) == destination, "The old center covered native focus")
        }
        let firstFrame = view.update(model, available: available, at: 6.01)
        if sameApp {
            for case let .raise(id, _) in firstFrame {
                precondition(id == destination, "A control click re-raised a correctly layered sibling")
            }
        }
        checkControlFocus(firstFrame)
        for frame in 1...36 { checkControlFocus(view.tick(at: 6.01 + Double(frame) / 120)) }
    }
}
