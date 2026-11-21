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

    private static let menuBarIcon: Image = {
        guard let url = Bundle.main.url(forResource: "PaperChainMenu", withExtension: "png"),
              let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0
        else { return Image(systemName: "link") }

        let scale = 20 / max(image.size.width, image.size.height)
        image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.isTemplate = true
        return Image(nsImage: image)
    }()

    var body: some Scene {
        MenuBarExtra {
            CommandsMenu()
        } label: {
            Self.menuBarIcon
                .accessibilityLabel("PaperChain")
                .help("PaperChain")
        }
        Settings { PaperSettings(actions: Runtime.shared) }
    }
}
