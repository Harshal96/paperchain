# App resources

[Info.plist](Info.plist) tells macOS how to launch PaperChain as a menu bar app. It sets the bundle identifier, executable name, app icon, version, build number, and minimum macOS version. It also supplies the Accessibility permission description and allows the local Ollama connection on `127.0.0.1`.

[PaperChain.icns](PaperChain.icns) supplies the Finder app icon. [PaperChainMenu.png](PaperChainMenu.png) supplies the menu bar icon.

The [bundle script](../scripts/bundle) copies the plist to `PaperChain.app/Contents/Info.plist` and both icons into `PaperChain.app/Contents/Resources/` before signing. The [DMG script](../scripts/dmg) uses the same bundle layout.
