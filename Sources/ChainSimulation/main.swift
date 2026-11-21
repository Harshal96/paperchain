import ChainCore
import Foundation

// A fake WindowServer with a deterministic clock. This target can run on Linux.
struct VirtualDesktop {
    var requestedFrames: [String: Box] = [:]
    var frames: [String: Box] = [:]
    var parked = Set<String>()
    var layers: [String] = []
    var focused: String?
    var writes = 0

    func topWindow(x: Double, y: Double) -> String? {
        layers.reversed().first { id in
            guard let f = frames[id] else { return false }
            return x >= f.x && x < f.x + f.width && y >= f.y && y < f.y + f.height
        }
    }

    /// Every window edge partitions the display into cells with identical z-order.
    /// Sampling their interiors excludes completely covered native windows.
    func exposed(in bounds: Box, within logicalTiles: [Box]) -> Set<String> {
        // Use the same whole-point origins as native windows. Project with free
        // edges here because shared-edge containment can tuck a window under another tile.
        let tiles = logicalTiles.compactMap { NativePlacement.projection(for: $0, measured: $0, on: bounds, neighbors: [])?.frame }
        let maxX = bounds.x + bounds.width, maxY = bounds.y + bounds.height
        var xEdges: Set<Double> = [bounds.x, maxX], yEdges: Set<Double> = [bounds.y, maxY]
        for f in Array(frames.values) + tiles where f.x < maxX && f.x + f.width > bounds.x && f.y < maxY && f.y + f.height > bounds.y {
            xEdges.formUnion([max(bounds.x, f.x), min(maxX, f.x + f.width)])
            yEdges.formUnion([max(bounds.y, f.y), min(maxY, f.y + f.height)])
        }
        let xs = xEdges.sorted(), ys = yEdges.sorted()
        var ids = Set<String>()
        for (x1, x2) in zip(xs, xs.dropFirst()) {
            for (y1, y2) in zip(ys, ys.dropFirst()) {
                let x = (x1 + x2) / 2, y = (y1 + y2) / 2
                // Native windows behind the strip can show through its gutters.
                // Inspect every cell within an intended tile, including narrow edge crops.
                if tiles.contains(where: { x >= $0.x && x < $0.x + $0.width && y >= $0.y && y < $0.y + $0.height }),
                   let id = topWindow(x: x, y: y) { ids.insert(id) }
            }
        }
        return ids
    }

    func exposes(_ expected: Set<String>, in bounds: Box) -> Bool {
        exposed(in: bounds, within: expected.compactMap { requestedFrames[$0] }) == expected
    }

    mutating func consume(_ commands: [WindowCommand], screens: [String: ScreenState]) {
        for command in commands {
            switch command {
            case let .place(id, frame, screen):
                let area = screens[screen]!.info.bounds
                // The fixtures have no reserved menu-bar or Dock area. Connected
                // displays still have physical edges when tiling is disabled on them.
                let neighbors = screens.values.filter { $0.isConnected && $0.id != screen }.map(\.info.bounds)
                guard let projected = NativePlacement.projection(for: frame, measured: frame, on: area, neighbors: neighbors) else {
                    preconditionFailure("A logical strip tile must have a native projection")
                }
                let actual = projected.frame
                precondition(actual.y >= area.y && actual.y + actual.height <= area.y + area.height + 0.0001)
                precondition(!neighbors.contains { other in
                    actual.x < other.x + other.width && other.x < actual.x + actual.width &&
                    actual.y < other.y + other.height && other.y < actual.y + actual.height
                }, "Physical window spilled onto the neighboring display")
                parked.remove(id)
                if frames[id] == nil { layers.append(id) }
                requestedFrames[id] = frame
                frames[id] = actual
                writes += 1
            case let .park(id):
                requestedFrames.removeValue(forKey: id)
                frames.removeValue(forKey: id)
                layers.removeAll { $0 == id }
                parked.insert(id)
            case let .release(id):
                requestedFrames.removeValue(forKey: id)
                frames.removeValue(forKey: id)
                layers.removeAll { $0 == id }
                parked.remove(id)
            case let .raise(id, activate):
                precondition(frames[id] != nil, "Raised a parked window")
                layers.removeAll { $0 == id }
                layers.append(id)
                if activate { focused = id }
            }
        }
    }
}

runOcclusionChecks()
runNativePerformanceChecks()
var workspace = Workspace()
let left = ScreenInfo(id: "L", name: "Landscape", bounds: Box(x: -1600, y: 0, width: 1600, height: 900))
let right = ScreenInfo(id: "R", name: "Portrait", bounds: Box(x: 0, y: -160, width: 900, height: 1600))
workspace.syncScreens([left, right])
// Add sequentially while focusing the newest window so the named fixtures stay in order.
for i in 0..<50 {
    let id = "editor-\(i)"
    workspace.discover(WindowInfo(id: id, app: "Editor", title: "Document \(i)"), on: "L")
    workspace.select(id)
}
for i in 0..<4 {
    workspace.discover(WindowInfo(id: "note-\(i)", app: "Notes", title: "\(i)"), on: "R")
}
let originalOrder = workspace.screens["L"]!.activeGroup!.orderedIDs
precondition(originalOrder.count == 50)
var surface = VirtualDesktop()
var show = Presentation()
var now = 0.0
var maxCommands = 0
func update(focus: String? = nil) {
    let commands = show.update(workspace, available: Set(workspace.windows.keys), at: now, activate: focus)
    surface.consume(commands, screens: workspace.screens)
}
func tick(_ count: Int) {
    for _ in 0..<count {
        now += 1 / 120.0
        let commands = show.tick(at: now)
        maxCommands = max(commands.count, maxCommands)
        surface.consume(commands, screens: workspace.screens)
        // Stage and endpoint commands sit flush with the owner. Check the
        // bodies of all scrolling columns; the settled endpoints are checked below.
        let traveling = commands.compactMap { command -> Box? in
            guard case let .place(_, frame, screen) = command, screen == left.id,
                  frame.x != left.bounds.x, frame.x + frame.width != left.bounds.x + left.bounds.width else { return nil }
            return frame
        }
        precondition(surface.exposed(in: left.bounds, within: traveling).count <= 3)
        precondition(Set(surface.frames.keys).isDisjoint(with: surface.parked))
    }
}
func navigate(_ index: Int) {
    let id = originalOrder[index]
    workspace.select(id)
    update(focus: id)
}
navigate(0)
tick(120)
precondition(surface.frames[originalOrder[0]]?.x == -1600 && surface.frames[originalOrder[1]]?.x == -796)
precondition(surface.exposes(Set(originalOrder.prefix(2)), in: left.bounds))
navigate(1)
tick(120)
precondition(surface.frames[originalOrder[1]]?.x == -1198)
precondition(surface.frames[originalOrder[0]]?.x == -2002,
             "The left neighbor must continue past a free display edge, exposing the right side of its contents")
precondition(surface.frames[originalOrder[2]]?.x == -796, "The right neighbor must sit flush against the shared edge")
precondition(surface.requestedFrames[originalOrder[2]]?.x == -394)
// A click 100 pt into the display lands 502 pt into the left neighbor's own document.
precondition(surface.topWindow(x: -1500, y: 450) == originalOrder[0])
precondition(-1500 - surface.frames[originalOrder[0]]!.x == 502)
precondition(surface.layers.last(where: { $0.hasPrefix("editor") }) == originalOrder[1])
precondition(surface.exposes(Set(originalOrder.prefix(3)), in: left.bounds))
// Clicking a real neighbor supersedes a pending dock activation, even when
// the former dock target remains half-visible at the new destination.
navigate(2)
tick(3)
workspace.select(originalOrder[1])
update()
surface.focused = originalOrder[1]
tick(60)
precondition(surface.focused == originalOrder[1], "An interrupted dock jump stole focus back")
navigate(4)
tick(3)
show.observedFocus("note-0")
surface.focused = "note-0"
tick(60)
precondition(surface.focused == "note-0", "A pending dock activation stole focus from the other monitor")
navigate(49)
tick(8)
navigate(0)
tick(120)
precondition(surface.focused == originalOrder[0])
navigate(49)
tick(120)
precondition(surface.frames[originalOrder[48]]?.x == -1600 && surface.frames[originalOrder[49]]?.x == -796)
precondition(workspace.screens["L"]!.activeGroup!.orderedIDs == originalOrder)
precondition(surface.exposes(Set((0..<4).map { "note-\($0)" }), in: right.bounds))

let group = workspace.createGroup(named: "Research", on: "L")!
workspace.move(originalOrder[2], to: "L", group: group)
workspace.switchGroup(group, on: "L")
update(focus: originalOrder[2])
tick(120)
precondition(surface.frames[originalOrder[2]] != nil && surface.parked.contains(originalOrder[49]))
let classification = RegroupRequest(workspace: workspace, available: Set(workspace.windows.keys), categories: ["Writing"])
workspace.drop(originalOrder[2], x: 300, y: 600, float: false, fallbackScreen: "L",
               presentation: show, at: now)
update()
tick(120)
precondition(workspace.location(of: originalOrder[2])?.screenID == "R")
precondition(classification.applicable([originalOrder[2]: "Writing"], in: workspace,
    available: Set(workspace.windows.keys), categories: ["Writing"]).isEmpty)
workspace.drop(originalOrder[2], x: 300, y: 600, float: true, fallbackScreen: "R",
               presentation: show, at: now)
update()
precondition(!surface.parked.contains(originalOrder[2]))
workspace.discover(workspace.windows[originalOrder[2]]!, on: "R")
precondition(workspace.location(of: originalOrder[2]) == nil)
workspace.setEnabled(false, on: "L")
update()
precondition(!surface.parked.contains(where: { $0.hasPrefix("editor") }))
tick(120) // The portrait strip completes its own return after the selected window detaches.
precondition(!show.isMoving(at: now))
precondition(show.tick(at: now + 100).isEmpty)
// AX may temporarily omit an entire app. A subsequent display disable must still
// unpark that app's windows when they become observable again.
workspace.setEnabled(true, on: "L")
update()
let hiddenID = originalOrder[0]
precondition(surface.parked.contains(hiddenID))
let others = Set(workspace.windows.keys).subtracting([hiddenID])
surface.consume(show.update(workspace, available: others, at: now), screens: workspace.screens)
workspace.setEnabled(false, on: "L")
surface.consume(show.update(workspace, available: others, at: now), screens: workspace.screens)
update()
precondition(!surface.parked.contains(hiddenID))
// Visible gap 2 is logical gap 3 when column zero is user-minimized.
var filtered = Workspace()
filtered.syncScreens([left])
for id in ["A", "B", "C"] {
    filtered.discover(WindowInfo(id: id, app: id, title: id), on: "L")
    filtered.select(id)
}
var filteredView = Presentation()
_ = filteredView.update(filtered, available: ["B", "C"], at: now)
filtered.drop("B", x: -10, y: 200, float: false, fallbackScreen: "L", presentation: filteredView, at: now)
precondition(filtered.screens["L"]?.activeGroup?.orderedIDs == ["A", "C", "B"])
// A native refusal releases the real frame, but the dock still knows its ID.
filtered.select("C")
let known = Set(filtered.windows.keys)
_ = filteredView.update(filtered, available: known, at: now, reduceMotion: true)
let beforeFailure = filtered.screens["L"]!.activeGroup!.columns
filtered.pausePlacement("C")
let onFailure = filteredView.update(filtered, available: known, at: now)
precondition(onFailure.contains(.release("C")) && filtered.detached.isEmpty)
precondition(filtered.screens["L"]?.activeGroup?.columns == beforeFailure)
filtered.retryPlacement("C")
let afterRetry = filteredView.update(filtered, available: known, at: now, activate: "C", reduceMotion: true)
precondition(afterRetry.contains(.raise("C", activate: true)))
// Reopen a v1 session with the same counts as the reported failure. A normal scan
// preserves intentional detachments. Explicit recovery returns all five dock entries.
var oldSession = Workspace()
oldSession.syncScreens([left])
let five = ["one", "two", "three", "four", "five"].map { WindowInfo(id: $0, app: "Fixture", title: $0) }
for w in five { oldSession.discover(w, on: "L"); oldSession.select(w.id) }
for w in five.suffix(3) { oldSession.detach(w.id) }
var reopened = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(oldSession))
let seen = five.map { (window: $0, screenID: "L") }
reopened.rescan(seen)
precondition(reopened.screens["L"]?.activeGroup?.orderedIDs.count == 2)
reopened.reattachDetached(seen)
let repaired = reopened.screens["L"]!.activeGroup!.orderedIDs
precondition(Set(repaired) == Set(five.map(\.id)))
reopened.select(repaired[2])
var repairedView = Presentation(), repairedSurface = VirtualDesktop()
let repairedCommands = repairedView.update(reopened, available: Set(repaired), at: now)
repairedSurface.consume(repairedCommands, screens: reopened.screens)
precondition(repairedSurface.exposes(Set(repaired[1...3]), in: left.bounds))
print("Headless scenario passed: 54 windows, two adjacent displays, interrupted jumps, endpoints, portrait grid, group transfer, detach and disable.")
print("Virtual 120 Hz clock: \(surface.writes) frame writes, at most \(maxCommands) commands in an animation tick, zero idle commands.")
if CommandLine.arguments.contains("--benchmark") {
    measureThirdWindow()
    runBenchmark()
}
if let index = CommandLine.arguments.firstIndex(of: "--preview") {
    guard CommandLine.arguments.indices.contains(index + 1) else {
        fatalError("--preview requires an output HTML path")
    }
    let file = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    try writePreview(to: file)
    print("Wrote virtual display replay to \(file.path)")
}
