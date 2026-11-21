# Paper Chain

Paper Chain gives each display on your Mac its own scrolling strip of windows. Click a neighboring window to bring it into view, stack two windows in a column, or switch a whole group from the dock on that display.

**[Download Paper Chain for macOS 14 or later](https://github.com/Harshal96/paperchain/releases/latest/download/Paper-Chain.dmg)** · [Installation guide](../docs/installation.md) · [User guide](../docs/user-guide.md)

Sign in to GitHub with access to the project. Open the downloaded disk image, drag **Paper Chain** into **Applications**, then open it from there.

![Strip preview. Selecting Contact sheet slides it from the right half of the display to the center, with a neighboring window visible on each side.](../docs/window-strip.png)

<details>
<summary>Repository information</summary>

## GitHub Actions

The [Headless checks workflow](workflows/check.yml) runs on pushes and pull requests. Its Linux job runs the [checks and simulator](../Tests/README.md) in a Swift container. Its macOS job builds and signs the app with the [bundle script](../scripts/bundle).

Browse the [repository overview](../README.md) for the source map, project credits and license.

</details>
