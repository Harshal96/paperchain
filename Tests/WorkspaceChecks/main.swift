import ChainCore
import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    guard value() else { fatalError("Line \(line): \(message)") }
}

func window(_ id: String, title: String? = nil) -> WindowInfo {
    WindowInfo(id: id, app: "Editor", title: title ?? id)
}

let wide = ScreenInfo(id: "wide", name: "Desk", bounds: Box(x: -1600, y: 0, width: 1600, height: 900))
let tall = ScreenInfo(id: "tall", name: "Portrait", bounds: Box(x: 0, y: -400, width: 900, height: 1600))
var work = Workspace()
work.syncScreens([wide, tall])
let inbox = work.screens[wide.id]!.activeGroupID
expect(work.screens[wide.id]?.activeGroup?.name == "Inbox", "initial group")
expect(work.screens[tall.id]?.enabled == true, "new monitor enabled")

work.rescan(["a", "b", "c"].map { (window($0), wide.id) })
work.select("b")
work.discover(window("d"), on: wide.id)
expect(work.screens[wide.id]?.activeGroup?.columns == [["a"], ["c"], ["b"], ["d"]], "insert beside focus")
expect(work.screens[wide.id]?.activeGroup?.selectedID == "b", "discovery retains focus")
work.rescan([(window("b", title: "Renamed"), tall.id)])
expect(work.location(of: "b")?.screenID == wide.id, "geometry feedback cannot migrate membership")
expect(work.windows["b"]?.title == "Renamed" && work.location(of: "a") != nil, "partial scans update metadata only")
work.close("b")
expect(work.screens[wide.id]?.activeGroup?.selectedID == "d", "close selects the window in the vacated slot")
work.close("d")
expect(work.screens[wide.id]?.activeGroup?.selectedID == "c", "last item falls back to previous")

work.move("a", to: wide.id, at: 2)
expect(work.screens[wide.id]?.activeGroup?.columns == [["c"], ["a"]], "gap index is measured before removing the source")
work.move("a", to: wide.id, at: 2)
expect(work.screens[wide.id]?.activeGroup?.columns == [["c"], ["a"]], "drop at end is stable")
let other = work.createGroup(named: "Research", on: wide.id)!
work.move("a", to: wide.id, group: other)
work.renameGroup(other, to: "References", on: wide.id)
work.switchGroup(inbox, on: wide.id)
expect(work.screens[wide.id]?.activeGroup?.selectedID == "c", "group focus restored")
work.select("a")
expect(work.screens[wide.id]?.activeGroup?.name == "References", "selection reveals the containing group")
work.detach("a")
work.discover(window("a"), on: wide.id)
expect(work.location(of: "a") == nil && work.detached.contains("a"), "explicit detach survives discovery")
work.move("a", to: tall.id)
work.move("c", to: tall.id)
expect(work.screens[tall.id]?.activeGroup?.columns == [["a", "c"]], "portrait fills second row")
work.unstack("c")
expect(work.screens[tall.id]?.activeGroup?.columns == [["a"], ["c"]], "unstack creates adjacent column")
work.stack("c", with: "a")
expect(work.screens[tall.id]?.activeGroup?.columns == [["a", "c"]], "stack keeps both members")
work.setEnabled(false, on: tall.id)
work.discover(window("new"), on: tall.id)
expect(work.location(of: "new") == nil, "disabled screen skips acquisition")
work.move("c", to: tall.id)
expect(work.location(of: "c") == nil, "explicit drag to disabled display releases membership")
work.discover(window("c"), on: wide.id)
expect(work.location(of: "c") == nil, "stale frames cannot reclaim a window released onto a disabled display")
work.setEnabled(true, on: tall.id)
work.discover(window("c"), on: tall.id)
work.discover(window("new"), on: tall.id)
expect(work.location(of: "c") != nil && work.location(of: "new") != nil, "reenable permits rediscovery")
work.syncScreens([wide])
expect(work.screens[tall.id]?.isConnected == false && work.location(of: "new") != nil, "disconnect preserves ownership")
work.syncScreens([tall, wide])
work.applyClassification(["a": "Writing", "c": "Writing", "unknown": "Ghost"])
for screen in [wide, tall] {
    expect(work.screens[screen.id]!.groups.filter { $0.name == "Writing" }.count == 1, "category available on every screen")
}
expect(work.location(of: "a")?.screenID == tall.id, "classification preserves monitor")
let third = ScreenInfo(id: "third", name: "TV", bounds: wide.bounds)
work.syncScreens([wide, tall, third])
expect(work.screens[third.id]?.groups.contains(where: { $0.name == "Writing" }) == true, "new monitors inherit categories")
let classified = work
work.applyClassification(["a": "writing", "c": "Writing"])
expect(work == classified, "repeated classification is idempotent")
let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(work))
expect(restored == work, "workspace round trip")
work.detach("new")
work.close("new")
work.discover(window("new", title: "Reused"), on: wide.id)
expect(work.location(of: "new")?.screenID == wide.id, "proven closure clears exclusion for future IDs")

var rotation = Workspace()
rotation.syncScreens([wide])
for id in ["1", "2", "3", "4", "5", "6", "7"] {
    rotation.discover(window(id), on: wide.id)
    rotation.select(id)
}
rotation.stack("3", with: "2")
rotation.select("4")
let firstGroup = rotation.screens[wide.id]!.activeGroupID
let secondGroup = rotation.createGroup(named: "Second", on: wide.id)!
rotation.discover(window("x"), on: wide.id)
rotation.discover(window("y"), on: wide.id)
rotation.switchGroup(firstGroup, on: wide.id)
let rotated = ScreenInfo(id: wide.id, name: wide.name, bounds: tall.bounds)
rotation.syncScreens([rotated])
let packed = [["1"], ["2", "3"], ["4", "5"], ["6", "7"]]
expect(rotation.screens[wide.id]?.activeGroup?.columns == packed, "rotation pairs adjacent singletons while keeping existing stacks")
expect(rotation.screens[wide.id]?.activeGroup?.selectedID == "4", "rotation preserves selection")
expect(rotation.screens[wide.id]?.groups.first(where: { $0.id == secondGroup })?.columns == [["x", "y"]], "rotation packs inactive groups")
rotation.syncScreens([wide])
expect(rotation.screens[wide.id]?.activeGroup?.columns == packed, "landscape retains the existing stacks")
var reopened = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(rotation))
reopened.rescan([(window("3", title: "Changed"), "missing"), (window("4", title: "Other"), wide.id)])
expect(reopened.screens == rotation.screens, "reopening followed by observation preserves membership")
expect(reopened.windows["3"]?.title == "Changed", "observations refresh titles regardless of reported monitor")
var refusal = Workspace()
refusal.syncScreens([wide])
for id in ["first", "second", "third"] {
    refusal.discover(window(id), on: wide.id)
    refusal.select(id)
}
let originalColumns = refusal.screens[wide.id]!.activeGroup!.columns
refusal.pausePlacement("third")
expect(refusal.screens[wide.id]?.activeGroup?.columns == originalColumns, "native rejection keeps the third window's slot")
expect(!refusal.detached.contains("third") && refusal.placementPaused.contains("third"), "refused placement is temporary")
refusal.rescan([(window("third"), wide.id)])
expect(refusal.placementPaused.contains("third"), "passive inventory cannot start a refusal loop")
let relaunched = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(refusal))
expect(relaunched.placementPaused.isEmpty && relaunched.location(of: "third") != nil, "relaunch automatically retries rejected placement")
refusal.retryPlacement("third")
expect(refusal.placementPaused.isEmpty, "explicit selection retries the third window")
refusal.detach("second")
refusal.retryAllPlacements()
expect(refusal.detached.contains("second"), "retry preserves a user's manual detach")
refusal.syncScreens([wide, tall])
refusal.setEnabled(false, on: tall.id)
refusal.reattachDetached([(window("second"), tall.id)])
expect(refusal.detached.contains("second"), "batch recovery respects disabled displays")
refusal.reattachDetached([(window("second"), wide.id)])
expect(refusal.location(of: "second")?.screenID == wide.id && refusal.detached.isEmpty,
       "explicit recovery reattaches a previously excluded window")
var timing = NativeFocusObservation()
func observe(_ id: String, at time: Double, suppressed: Bool, dragging: Bool = false,
             userInput: Bool = false) -> Bool {
    timing.observe(id, at: time, suppressed: suppressed, dragging: dragging, userInput: userInput)
}
expect(observe("second", at: 0, suppressed: false), "initial native focus")
timing.discovered("third", at: 0.04)
expect(!observe("second", at: 0.05, suppressed: true), "a background creation retains the current focus")
expect(timing.awaitingFocus("third"), "before the app sets focus, a new edge window stays out of the layer order")
expect(!timing.raise("third", activate: false, at: 0.09), "a passive edge raise cannot overwrite an opening application's focus")
expect(observe("third", at: 0.12, suppressed: true), "late focus on a new window survives recent layout writes")
expect(!timing.awaitingFocus("third"), "actual native focus admits the third window immediately")
expect(!observe("third", at: 0.15, suppressed: false), "duplicate native focus does not restart scrolling")
timing.discovered("background", at: 0.2)
expect(!timing.admitBackground(at: 0.3), "a background creation gets time to publish native focus")
expect(timing.admitBackground(at: 0.56), "the bounded focus wait admits a background window")
expect(timing.raise("background", activate: false, at: 0.57), "after settling the edge can be layered normally")
expect(!observe("background", at: 0.6, suppressed: true), "a manager raise cannot promote a new background window")
expect(!observe("background", at: 0.8, suppressed: false), "repeated observations of the same raise remain echoes")
expect(observe("background", at: 0.81, suppressed: false, userInput: true), "user input can select a window after a manager echo")
expect(!observe("third", at: 0.82, suppressed: true), "defer ambiguous focus during a native write")
expect(observe("third", at: 1.4, suppressed: false), "a deferred observation does not consume the next genuine focus")
expect(!observe("second", at: 1.5, suppressed: false, dragging: true), "native focus during a drag is deferred")
expect(observe("second", at: 1.6, suppressed: false), "the drag does not consume a confirmed focus change")
expect(timing.raise("third", activate: true, at: 2), "an explicit focus request may raise immediately")
expect(!observe("third", at: 2.1, suppressed: true), "a second manager raise is ignored")
timing.beganClick()
expect(observe("third", at: 2.2, suppressed: false), "a click on the system Dock can activate the same raised window")
expect(!NativeWindowAvailability.suspended(previously: false, hidden: false, fullScreen: false,
                                            minimized: false, owned: false, movable: nil),
       "a timed-out position capability leaves a known tile available")
expect(!NativeWindowAvailability.suspended(previously: false, hidden: false, fullScreen: nil,
                                            minimized: nil, owned: false, movable: nil),
       "an incomplete observation preserves a known reachable window")
expect(NativeWindowAvailability.suspended(previously: nil, hidden: false, fullScreen: nil,
                                           minimized: nil, owned: false, movable: nil),
       "a new window requires positive evidence before tiling")
expect(NativeWindowAvailability.suspended(previously: true, hidden: false, fullScreen: false,
                                           minimized: nil, owned: false, movable: true),
       "an incomplete observation cannot revive a user-minimized window")
expect(NativeWindowAvailability.suspended(previously: false, hidden: false, fullScreen: false,
                                           minimized: false, owned: false, movable: false),
       "a confirmed immovable window is suspended")
expect(!NativeWindowAvailability.suspended(previously: true, hidden: false, fullScreen: false,
                                            minimized: true, owned: true, movable: nil),
       "manager-parked windows remain reachable")
await checkGrantRecovery()
checkBodyClicks()
checkDisplayDrops()
checkSideWindows()
print("Workspace checks passed")
