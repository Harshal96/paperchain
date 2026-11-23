import ChainCore
import Foundation

func checkDisplayDrops() {
    let left = ScreenInfo(id: "left", name: "Left", bounds: Box(x: -1280, y: -776, width: 1280, height: 776))
    let right = ScreenInfo(id: "right", name: "Right", bounds: Box(x: 0, y: -776, width: 1280, height: 776))
    let physical = ["left": CGRect(x: -1280, y: -800, width: 1280, height: 800),
                    "right": CGRect(x: 0, y: -800, width: 1280, height: 800)]
    func target(_ x: Double, _ y: Double, frameOn screen: String) -> String? {
        Workspace.dropScreen(at: CGPoint(x: x, y: y), physical: physical, windowScreen: screen)
    }

    var workspace = Workspace()
    workspace.syncScreens([left, right])
    workspace.discover(window("edge"), on: left.id)
    workspace.rescan([(window("edge"), right.id)])
    expect(workspace.location(of: "edge")?.screenID == left.id,
           "geometry observed during a slide cannot transfer a managed window")
    let view = Presentation()
    // The frame still lies mainly on the left. The pointer crosses the shared
    // edge into the right display's menu bar, outside both usable rectangles.
    workspace.drop("edge", x: 0, y: -790, float: false, fallbackScreen: target(0, -790, frameOn: left.id),
                   presentation: view, at: 0, horizontalMovement: 0)
    expect(workspace.location(of: "edge")?.screenID == right.id, "release at the shared edge must transfer right")
    workspace.drop("edge", x: -0.5, y: -790, float: false, fallbackScreen: target(-0.5, -790, frameOn: right.id),
                   presentation: view, at: 1)
    expect(workspace.location(of: "edge")?.screenID == left.id, "release in the left menu bar must transfer back")
    expect(target(2600, -790, frameOn: left.id) == left.id, "a pointer outside all displays uses the frame fallback")
    let stacked = ["upper": physical["left"]!, "lower": CGRect(x: -1280, y: 0, width: 1280, height: 800)]
    expect(Workspace.dropScreen(at: CGPoint(x: -4, y: 0), physical: stacked, windowScreen: "upper") == "lower",
           "the horizontal seam belongs to the physical display starting at that y coordinate")
    let mirrored = ["one": physical["left"]!, "two": physical["left"]!]
    expect(Workspace.dropScreen(at: CGPoint(x: -4, y: -790), physical: mirrored, windowScreen: "two") == "two",
           "mirrored physical pixels cannot identify a new owner")

    workspace.setEnabled(false, on: right.id)
    workspace.drop("edge", x: 0, y: -790, float: false, fallbackScreen: target(0, -790, frameOn: left.id),
                   presentation: view, at: 2)
    expect(workspace.location(of: "edge") == nil, "dropping in a disabled monitor's menu bar must release the window")

    // A narrow preview remains hittable even when the native window's center lies outside the display.
    let partial = Box(x: -1780, y: -776, width: 640, height: 776)
    let samples = NativeExposure.samples(order: ["edge", "center"], frames: ["edge": partial,
        "center": Box(x: -960, y: -776, width: 640, height: 776)], bounds: left.bounds)
    expect(samples.first?.id == "edge" && samples.first?.x == -1210,
           "the exposure point must be at the center of the visible 140-point slice")

    checkReorderingByWindowFrame()
    checkVerticalDragAtDisplaySeam()
}

private func checkReorderingByWindowFrame() {
    let wide = ScreenInfo(id: "wide", name: "Wide", bounds: Box(x: 0, y: 0, width: 1920, height: 1080))
    var strip = Workspace()
    strip.syncScreens([wide])
    for id in ["left", "right"] { strip.discover(window(id), on: wide.id) }
    strip.select("right")
    var layout = Presentation()
    _ = layout.update(strip, available: ["left", "right"], at: 0)
    let rightSlot = Box(x: 964, y: 0, width: 956, height: 1080)
    let leftSlot = Box(x: 0, y: 0, width: 956, height: 1080)
    strip.drop("right", x: 748, y: 40, float: false, fallbackScreen: nil, presentation: layout, at: 0,
               horizontalMovement: 218 - rightSlot.x)
    expect(strip.screens[wide.id]?.activeGroup?.orderedIDs == ["right", "left"],
           "a window whose frame moves into the left slot must move before the left column")
    let placements = layout.update(strip, available: ["left", "right"], at: 1, force: true)
    expect(placements.contains(.place("right", leftSlot, wide.id)),
           "the reordered window is placed in the left slot")

    strip.drop("right", x: 800, y: 40, float: false, fallbackScreen: nil, presentation: layout, at: 1,
               horizontalMovement: 746 - leftSlot.x)
    expect(strip.screens[wide.id]?.activeGroup?.orderedIDs == ["left", "right"],
           "a window whose frame moves into the right slot must follow the right column")
}

private func checkVerticalDragAtDisplaySeam() {
    let main = ScreenInfo(id: "main", name: "Main", bounds: Box(x: 0, y: 24, width: 1000, height: 776))
    let neighbor = ScreenInfo(id: "neighbor", name: "Neighbor", bounds: Box(x: -1000, y: 24, width: 1000, height: 776))
    var strip = Workspace()
    strip.syncScreens([main, neighbor])
    for id in ["A", "B", "C", "stacked"] {
        strip.discover(window(id), on: main.id)
        strip.select(id)
    }
    strip.stack("stacked", with: "A")
    strip.select("B")
    var layout = Presentation()
    _ = layout.update(strip, available: ["A", "B", "C", "stacked"], at: 0)
    // Native placement tucks the left stack inside the shared edge at x = 0.
    // A small sideways drift during a vertical drag must keep it in its starting column.
    strip.drop("A", x: 53, y: 60, float: false, fallbackScreen: main.id, presentation: layout, at: 0,
               horizontalMovement: 3)
    expect(strip.screens[main.id]?.activeGroup?.columns == [["A", "stacked"], ["B"], ["C"]],
           "a vertical drag beside a display seam preserves the order and stack")

    strip.drop("A", x: -1, y: 60, float: false, fallbackScreen: main.id, presentation: layout, at: 0,
               horizontalMovement: -1)
    expect(strip.location(of: "A")?.screenID == neighbor.id,
           "a release on another display transfers ownership even when the frame stays on the source display")
}
