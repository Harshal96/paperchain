# Build and check scripts

Run these commands from the repository root.

| Command | What it does |
| --- | --- |
| `sh scripts/bundle` | Builds `dist/PaperChain.app` in release mode, bundles the app and menu bar icons, signs the app and verifies its signature. See the [installation guide](../docs/installation.md) for the steps in Finder and System Settings. |
| `sh scripts/dmg` | Packages the same resources into a universal app for Apple silicon and Intel, signs it, then creates and verifies `dist/PaperChain.dmg`. Open the **PaperChain** volume in Finder and drag **PaperChain** onto **Applications**. |
| `sh scripts/check` | Runs the offline checks and window simulator on macOS or Linux. See [Tests](../Tests/README.md) for individual suites, the visual replay and benchmarks. |
| `sh scripts/swiftpm build` | Builds the Swift package. The [SwiftPM wrapper](swiftpm) forwards the command and its arguments to Swift and works around conflicting module definitions on affected Apple Command Line Tools installations. |

## Signing local builds

Both the [bundle script](bundle) and the [DMG script](dmg) use the **Paperchain Local Signing** certificate if one is available. To select a different certificate, set `PAPERCHAIN_SIGN_IDENTITY` to the identity name or hash when running either script. Using the same identity and bundle identifier across builds helps preserve the macOS Accessibility grant.

When no matching certificate is available, the script signs the app ad hoc. You can also select ad-hoc signing explicitly with `PAPERCHAIN_SIGN_IDENTITY=- sh scripts/bundle`. After replacing an ad-hoc build, macOS may ask for Accessibility access again.
