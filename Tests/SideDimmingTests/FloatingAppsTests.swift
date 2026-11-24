import AppKit
import ApplicationServices
import ChainCore
import Testing
@testable import PaperChainMac

@MainActor
struct FloatingAppsTests {
    @Test func excludingAnAppRemovesAllItsWindowsFromNativeManagement() {
        let desktop = NativeDesktop()
        let fellow = "com.electron.fellow"
        let editor = "example.editor"
        let frame = CGRect(x: 30, y: 80, width: 300, height: 180)
        let app = NSRunningApplication.current
        let element = AXUIElementCreateApplication(app.processIdentifier)
        func register(_ id: String, bundleID: String) {
            let info = WindowInfo(id: id, app: "Example", title: id, bundleID: bundleID)
            desktop.entries[id] = .init(info: info, app: app, element: element,
                                        identifier: nil, axIdentifier: nil, quartzIdentifier: nil, rect: frame)
            desktop.scanOrder.append(id)
        }
        register("fellow-panel", bundleID: fellow)
        register("fellow-main", bundleID: fellow)
        register("editor", bundleID: editor)
        desktop.focusObservation.clicked("fellow-panel")
        desktop.gesture = .init(window: "fellow-panel", origin: frame.origin, startFrame: frame,
                                bodyClick: true, closeButton: false, sameApplication: true)
        desktop.deferredActivation = "fellow-panel"
        desktop.owned.insert("fellow-main")
        desktop.restores["fellow-main"] = .init(.show)
        desktop.suspendedIDs.insert("fellow-main")
        #expect(desktop.windows.map(\.id) == ["fellow-panel", "fellow-main", "editor"])

        desktop.setFloatingAppBundleIDs([fellow])
        register("fellow-new", bundleID: fellow)
        #expect(desktop.windows.map(\.id) == ["editor"])
        #expect(desktop.isFloatingWindow(desktop.entries["fellow-main"]!.info))
        #expect(desktop.focusedID == nil)
        #expect(desktop.gesture == nil)
        #expect(desktop.deferredActivation == nil)
        #expect(desktop.owned.contains("fellow-main"))
        #expect(desktop.restores["fellow-main"]?.policy.intent == .release)

        desktop.setFloatingAppBundleIDs([])
        #expect(desktop.windows.map(\.id) == ["fellow-panel", "fellow-main", "editor", "fellow-new"])
    }

    @Test func olderSavedWindowStillDecodesWithoutAnAppBundleIdentifier() throws {
        let data = Data(#"{"id":"old-window","app":"Editor","title":"Document"}"#.utf8)
        let restored = try JSONDecoder().decode(WindowInfo.self, from: data)
        #expect(restored.app == "Editor")
        #expect(restored.bundleID == nil)
    }
}
