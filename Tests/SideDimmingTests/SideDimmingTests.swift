import AppKit
import Testing
@testable import PaperChainMac

@MainActor
struct SideDimmingTests {
    private let frame = CGRect(x: 300, y: 20, width: 600, height: 600)

    private func press(_ id: String, body: Bool = true) -> NativeDesktop.Gesture {
        .init(window: id, origin: frame.origin, startFrame: frame, bodyClick: body, sameApplication: true)
    }

    @Test func refreshDuringStationaryPressKeepsDimmingUntilFocusChanges() {
        let desktop = NativeDesktop()
        desktop.sideDimmingPlan = { id in
            id == "center" ? (.init(x: 0, y: 0, width: 1200, height: 800), []) : nil
        }
        desktop.updateSideDimming(focused: "center")
        desktop.gesture = press("center")
        desktop.updateSideDimming(focused: "center")
        #expect(desktop.dimmedAround == "center")

        desktop.updateSideDimming(focused: nil)
        #expect(desktop.dimmedAround == nil)
        desktop.updateSideDimming(focused: "center")
        #expect(desktop.dimmedAround == nil, "A held press must not start a new set of dimmers")
        desktop.gesture = nil
        desktop.updateSideDimming(focused: "center")
        #expect(desktop.dimmedAround == "center")
        desktop.gesture = press("left")
        desktop.updateSideDimming(focused: "center")
        #expect(desktop.dimmedAround == nil)
    }

    @Test func releasingOnDimmedFocusLeavesWindowOrderAlone() {
        let desktop = NativeDesktop()
        desktop.dimmedAround = "center"
        var selected: [String] = []
        desktop.onEvent = { event in
            switch event {
            case let .bodyClicked(id, _), let .focused(id): selected.append(id)
            default: break
            }
        }
        for body in [true, false] {
            desktop.finishClick(press("center", body: body), sameBody: body, nativeFocused: true)
        }
        #expect(selected.isEmpty)
        #expect(desktop.focusedID == "center")
        desktop.finishClick(press("left"), sameBody: true, nativeFocused: true)
        #expect(selected == ["left"])
        desktop.finishClick(press("center"), sameBody: true, nativeFocused: false)
        #expect(selected == ["left", "center"], "A stale AX focus must still allow an explicit body click")
    }

    @Test func geometryNotificationsOnlyClearDimmingWhenThePressedWindowMovesOrResizes() {
        let desktop = NativeDesktop()
        desktop.gesture = press("center")
        let resized = CGRect(origin: frame.origin, size: CGSize(width: frame.width + 20, height: frame.height))
        for changed in [frame.offsetBy(dx: 20, dy: 0), resized] {
            desktop.dimmedAround = "center"
            desktop.windowFrameChanged(changed, for: "left")
            desktop.windowFrameChanged(frame, for: "center")
            #expect(desktop.dimmedAround == "center")
            desktop.windowFrameChanged(changed, for: "center")
            #expect(desktop.dimmedAround == nil)
        }
    }
}
