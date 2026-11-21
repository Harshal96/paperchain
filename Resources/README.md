# App resources

[Info.plist](Info.plist) tells macOS how to launch Paper Chain as a menu bar app. It sets the bundle identifier, executable name, app version, build number, and minimum macOS version. It also supplies the Accessibility permission description and allows the local Ollama connection on `127.0.0.1`.

The [bundle script](../scripts/bundle) copies this file to `Paper Chain.app/Contents/Info.plist` before signing the app.
