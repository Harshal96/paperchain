import AppKit
import SwiftUI

@MainActor
private final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { Runtime.shared.start() }
    func applicationWillTerminate(_ notification: Notification) { Runtime.shared.stop() }
}

@MainActor
private struct CommandsMenu: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        PaperMenu(actions: Runtime.shared) {
            NSApp.activate()
            openSettings()
        }
    }
}

@main
@MainActor
struct PaperChainApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra("Paper Chain", systemImage: "rectangle.split.3x1") { CommandsMenu() }
        Settings { PaperSettings(actions: Runtime.shared) }
    }
}
