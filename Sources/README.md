# Source code

The macOS app and the headless simulator share the same layout engine. The [package manifest](../Package.swift) defines five source targets.

| Target | Responsibility |
| --- | --- |
| [ChainCore](ChainCore/) | Tracks displays, groups, window order and focus. Computes strip geometry, scroll motion and the commands needed to update windows. |
| [PaperChainMac](PaperChainMac/) | Runs the menu bar app, settings and per-display docks. Uses Accessibility to move native windows and Quartz metadata to check which windows are visible. |
| [NativeAXMetadata](NativeAXMetadata/) | Reads Accessibility attributes in batches and handles missing values, timeouts and apps that require individual reads. |
| [Decisions](Decisions/) | Classifies windows with TypeSafe or Ollama. It splits requests into bounded batches, validates responses and maps temporary references back to window IDs. |
| [ChainSimulation](ChainSimulation/) | Applies the layout engine’s commands to virtual windows on a deterministic clock. See the [simulator commands](../Tests/README.md#simulator) for a replay and benchmarks. |

## Following a layout change

[Workspace](ChainCore/Workspace.swift) stores membership and selection. [Presentation](ChainCore/Presentation.swift) turns that state into commands to place, raise, park or release windows. During a slide, it updates the visible columns and returns departing windows to the background. The macOS adapter applies the commands to real windows.

- **Placement.** Some apps acknowledge a resize before committing the new frame. The [resize sequence](PaperChainMac/NativeResize.swift) stages position and size changes and reads the frame back between writes. Once a window fits its tile, scrolling only changes its position.
- **Recovery.** Before minimizing a window in an inactive group, the app records it in the [parking journal](ChainCore/ParkingJournal.swift). Recovery checks the process launch and window identity. A delayed restore keeps its record until the app confirms that the window is visible.
- **Regrouping.** While a provider processes a batch, the user can still move, rename or close windows. Once all batches succeed, the [regroup request](ChainCore/Interactions.swift) checks which results still apply before the app updates the workspace.
