# Paper Chain

Paper Chain is a menu bar app for macOS 14 and later. It arranges your windows in a horizontal strip on each display. Click the visible edge of a neighboring window to slide it into view. Your other displays keep their place.

**[Download Paper Chain for macOS](https://github.com/Harshal96/paperchain/releases/latest/download/Paper-Chain.dmg)** · [Installation guide](docs/installation.md) · [User guide](docs/user-guide.md)

Sign in to GitHub with access to the project. Open the downloaded disk image, drag **Paper Chain** into **Applications**, then open it from there.

![Strip preview. At first, Field notes and Contact sheet share the display. Selecting Contact sheet centers it between the visible edges of Field notes and Project brief.](docs/window-strip.png)

Use the small dock on each display to jump between windows. Keep a project’s windows in a named group, stack two to read them together, or detach one to move it freely.

<details>
<summary>Inside the repository</summary>

- [Guides](docs/README.md) for installation and everyday use
- [Source code](Sources/README.md) and how the window manager works
- [Tests and simulator](Tests/README.md) for checks, benchmarks and a replay of the strip
- [Scripts](scripts/README.md) for building and signing the app
- [App resources](Resources/README.md) for macOS bundle metadata
- [GitHub Actions](.github/README.md#github-actions) for automated checks

</details>

The scrolling strip and window stacks draw on [ChainYourMac](https://chainyourmac.com/). Paper Chain is available under the [MIT license](LICENSE).
