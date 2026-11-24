import AppKit
import ChainCore
import Testing
@testable import PaperChainMac

@MainActor
struct NativeWindowFrameTests {
    private func window(at actual: CGRect, requested: CGSize) -> NativeDesktop.Window {
        .init(
            info: .init(id: "terminal", app: "Terminal", title: ""),
            app: .current, element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
            identifier: nil, axIdentifier: nil, quartzIdentifier: nil, rect: actual,
            acceptedSize: (requested, actual.size), lastRequestedOrigin: actual.origin)
    }

    @Test func smallFrameChangesAccumulateFromTheAcceptedSizeAndRequestedOrigin() {
        let original = CGRect(x: 20, y: 24, width: 700, height: 761)
        let requested = CGSize(width: 704, height: 768)
        var moved = window(at: original, requested: requested)
        let jitter = original.offsetBy(dx: 0.75, dy: 0)
        moved.observeFrame(jitter)
        #expect(moved.rect == jitter)
        #expect(moved.lastRequestedOrigin == original.origin)
        moved.observeFrame(jitter.offsetBy(dx: 0.75, dy: 0))
        #expect(moved.lastRequestedOrigin == nil)
        for step in 1...2 {
            let frame = CGRect(x: original.minX + CGFloat(step * 10), y: original.minY,
                               width: original.width + CGFloat(step), height: original.height)
            moved.observeFrame(frame)
            #expect(moved.rect == frame)
            #expect((moved.acceptedSize?.requested == requested) == (step == 1))
        }
    }

    @Test func movingAGridSizedWindowPreservesItsAcceptedTileSizeUntilResized() {
        let desktop = NativeDesktop()
        let actual = CGRect(x: 18, y: 24, width: 700, height: 761)
        let requested = CGSize(width: 704, height: 768)
        desktop.entries["terminal"] = window(at: actual, requested: requested)
        let jitter = CGRect(x: 18.5, y: 24, width: 700.5, height: 761)
        desktop.windowFrameChanged(jitter, for: "terminal")
        #expect(desktop.entries["terminal"]?.acceptedSize?.requested == requested)
        #expect(desktop.entries["terminal"]?.lastRequestedOrigin == actual.origin)

        let dropped = jitter.offsetBy(dx: 380, dy: 25)
        desktop.windowFrameChanged(dropped, for: "terminal")
        #expect(desktop.entries["terminal"]?.rect == dropped)
        #expect(desktop.entries["terminal"]?.acceptedSize?.requested == requested)
        #expect(desktop.entries["terminal"]?.lastRequestedOrigin == nil)
        let adjacentTile = CGRect(origin: .zero, size: requested)
        #expect(desktop.entries["terminal"]?.needsResize(to: adjacentTile) == false)
        let stackedTile = CGRect(origin: .zero, size: CGSize(width: requested.width, height: 380))
        #expect(desktop.entries["terminal"]?.needsResize(to: stackedTile) == true)

        let screen = ScreenInfo(id: "main", name: "Main", bounds: .init(x: 0, y: 0, width: 1400, height: 768))
        let settled = CGRect(origin: adjacentTile.origin, size: actual.size)
        #expect(desktop.entries["terminal"]?.acceptsPlacement(settled, at: adjacentTile, on: screen, neighbors: []) == true)
        // The position write landed, but the app resized at the same time.
        let resized = CGRect(origin: settled.origin, size: CGSize(width: 616, height: 700))
        #expect(desktop.entries["terminal"]?.acceptsPlacement(resized, at: adjacentTile, on: screen, neighbors: []) == false)
        #expect(desktop.entries["terminal"]?.rect == resized)
        #expect(desktop.entries["terminal"]?.acceptedSize == nil)
        #expect(desktop.entries["terminal"]?.needsResize(to: adjacentTile) == true)
    }
}
