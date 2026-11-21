import Foundation
import ChainCore

/// Replay opening C from the second column, then navigating back and forth.
func measureThirdWindow() {
    var world = Workspace()
    let screen = ScreenInfo(id: "display", name: "Virtual display", bounds: Box(x: 0, y: 0, width: 1440, height: 850))
    world.syncScreens([screen])
    func open(_ id: String) {
        world.discover(WindowInfo(id: id, app: "Fixture", title: id), on: screen.id)
        world.select(id)
    }
    var view = Presentation()
    var minimized = Set<String>()
    var parks = 0, restores = 0, writes = 0
    var now = 0.0
    func count(_ commands: [WindowCommand]) {
        for command in commands {
            switch command {
            case .park(let id):
                if minimized.insert(id).inserted { parks += 1 }
            case .place(let id, _, _):
                if minimized.remove(id) != nil { restores += 1 }
                writes += 1
            case .release(let id): minimized.remove(id)
            case .raise: break
            }
        }
    }
    open("A")
    open("B")
    count(view.update(world, available: Set(world.windows.keys), at: now))
    open("C")
    for id in ["C", "B", "A", "B", "C", "B"] {
        world.select(id)
        view.observedFocus(id)
        count(view.update(world, available: Set(world.windows.keys), at: now))
        for _ in 0..<36 {
            now += 1.0/120
            count(view.tick(at: now))
        }
    }
    print("Open C and revisit A/B/C: \(parks) minimize requests, \(restores) restores, \(writes) frame placements.")
}
