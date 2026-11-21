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
                   presentation: view, at: 0)
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
}
