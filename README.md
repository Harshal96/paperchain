# Paper Chain

Paper Chain is a macOS menu bar app that gives each enabled monitor a horizontally scrolling strip of windows. Every group has its own order and focus. The strip uses the display’s usable area, including its global position relative to other displays.

## Try it without touching your desktop

With Swift 5.9 or later on Linux or macOS, run these commands from the repository root.

~~~sh
sh scripts/check
sh scripts/swiftpm run -c release chain-sim --benchmark
sh scripts/swiftpm run chain-sim --preview strip-preview.html
~~~

The checks use synthetic windows, a virtual clock, a temporary recovery journal and a fake HTTP transport. You can open the generated replay in a browser and step through the frames that the real presentation engine produced. The simulator and the Linux build have no Accessibility adapter, Keychain dependency, or app launch step.

This command runs the checks in an isolated Linux container with the source mounted read-only.

~~~sh
docker run --rm --network none -v "$PWD:/src:ro" -w /src swift:6.1 \
  sh scripts/check --scratch-path /tmp/paperchain-build
~~~

The benchmark measures projection time for 50 and 500 virtual windows, counts frame writes, and checks the idle state. Desktop frame delivery also depends on macOS and on how quickly each application responds to Accessibility requests. The GitHub Actions workflow runs the simulator and contract checks on Linux and compiles the app separately on macOS.

The opening regression starts on B, opens C, then revisits A, B and C without minimizing or restoring any window. In the synthetic 120 Hz native-move fixture, 30 moves and 30 associated notifications required three geometry reads. Transfers between displays and shared-edge placements use immediate checks. With 500 single-window columns, the release benchmark issued up to five placements per tick, including windows leaving the viewport, and zero commands across 2,160 idle ticks. The simulator’s peak resident memory was about 7.8 MiB on Apple Silicon. Live application memory and desktop frame pacing require separate measurement.

## How the strip moves

On a landscape display, A and B initially share the width. Click B in a longer chain and B slides to the center, with A and C visible on either side. Click C to continue. At the end, the final two columns sit flush against the outer edges. A single window keeps its half-width slot.

Use **Settings → Appearance → Window padding** to set the gap between columns and stacked rows on all managed displays. The default is 8 points. Choose any whole number from 0 to 48 points. Changes apply immediately and are saved for the next launch.

The neighbors are real windows. With B centered on a single display, A’s right side and C’s left side remain visible across the gaps. Click either neighbor to slide it into view. Where an extension would cross onto a second monitor, the window snaps flush to its own monitor and tucks behind the center window. Windows that scroll out of view stay behind the strip and can show through a gap. A second selection during a slide retargets the motion from its current position and velocity. The display link stops at rest and Reduce Motion snaps to the destination.

Turn on **Settings → Appearance → Dim side windows** to darken neighboring windows and stacked peers when the focused window settles in the middle, with a visible column on each side. Two side-by-side columns stay at full brightness, including at either end of a longer chain. Click a dimmed window to focus it. This setting starts off.

When a window first joins, Paper Chain moves it to a safe origin, resizes it, and verifies the resulting frame before issuing another geometry change. TextEdit can acknowledge back-to-back move and resize requests and then restore the old dimensions. Once a window fits its tile, navigation only changes its position. Apps with fixed sizing increments can keep the size they repeatedly accept.

A click on the exposed body of a neighboring window selects it when you release the mouse. After activation, Paper Chain checks the visible part of each intended window once. If another managed window covers a neighbor, Paper Chain restores the stacking order with the selected window in front.

A portrait display fills two rows per column, giving four visible windows across two full columns. Rotating into portrait packs adjacent single windows together and retains existing pairs. On either orientation, use a window icon’s **Stack with** or **Unstack window** command to edit a column.

## Dock and groups

Click the small handle on a monitor to expand its dock. A colored pill shows the active group’s name. Other groups appear as circles with a symbol or initials. Hover over a circle to read its full name. When the groups exceed the available space, scroll through them or use the **Show all groups** (•••) menu. A divider separates the groups from the active group’s windows. Side-mounted docks use the same order vertically. Hover over a window icon to see its app name and window title.

- Click a group to switch. Click **+** at the end of the group list, enter a name, and choose **Create group**. The dock opens the new group. To rename a group, Control-click it and choose **Rename group…**.
- To move a window between groups, drag its dock icon onto the destination group. You can also Control-click the window icon, choose **Move to group**, and select a group under the destination monitor’s name. The destination group opens with the moved window selected.
- Click a window icon to focus it. Drag it onto another window icon to place it before that window.
- Drag the dock handle to position it freely. **Dock position** snaps it to an edge. Each monitor remembers its own position.
- Drag a native window by its title bar onto an enabled display to insert it there. Drag it to a disabled display to take it out of that chain. On an enabled display, Option-drag the title bar or choose **Detach window** to float it. Use **Attach window** in the dock options or drag it back into the strip to rejoin.
- In **Settings → Displays**, toggle management for each monitor. Disabling a display releases its windows. Its named groups and order are retained for when you enable it again.

## Menu bar and Decisions API

**Rescan all windows** refreshes the inventory and reapplies the current layout. It preserves group assignments and deliberate detachments. A window missing from one inventory update keeps its place until the app can confirm it closed.

If an app temporarily refuses a tile, its window floats and keeps its group, slot, and dock icon. Click that icon or rescan to retry. Version 1.0 could save a failed tile as a permanent detachment. Use **Reattach detached windows on enabled displays** to return all available detached windows, or use **Attach window** in a group's dock to choose one.

If an application delays restoring a minimized window, Paper Chain keeps its recovery record until macOS reports the window visible. Selecting it again or rescanning retries the restore. If the app continues to refuse Accessibility requests, use its minimized window in the macOS Dock.

Choose a regrouping provider in **Settings → Decisions API**.

- **TypeSafe** is the default. Save your TypeSafe API key in Settings to use hosted Jev. Paper Chain keeps the key in the macOS login Keychain. [TypeSafe System One API](https://docs.typesafe.ai/api/system-one)
- **Ollama (local)** uses a model installed on this Mac, without an API key. Start Ollama 0.35.1 or later on its default port, 11434, and download a model, for example with `ollama pull clef-flash` or `ollama pull llama3.2`. Click **Refresh** and choose the model. Paper Chain detects decision models such as Clef and uses structured chat for models such as Llama. Local decision models support up to 26 categories. [Ollama decision models](https://docs.ollama.com/capabilities/decision) · [Ollama structured outputs](https://docs.ollama.com/capabilities/structured-outputs)

Choose **Regroup windows** in the menu bar to group eligible windows across enabled displays. Paper Chain sends each app name, window title, and the allowed category names to the selected provider. With a single category, it assigns windows directly. Start with **Social Media**, **Writing**, and **Work & Coding**, or enter your own names, one per line. Each window stays on its monitor.

Paper Chain creates matching groups as needed after all batches succeed. It skips windows moved to another group or screen, renamed, closed, or detached during a request. Generic titles may need a manual correction.

## Build the Mac app

On macOS 14 or later with a Swift toolchain and the macOS SDK, build the app with this command.

~~~sh
sh scripts/bundle
~~~

The command builds `dist/Paper Chain.app` and signs it with the existing **Paperchain Local Signing** identity when available. Set `PAPERCHAIN_SIGN_IDENTITY` to use another signing certificate. Using the same certificate and bundle identifier preserves the app’s signing identity across updates. Without a certificate the script uses an ad-hoc signature, and a changed build can require a new Accessibility grant.

Open the installed copy, expand its dock, and choose **Grant Accessibility Access** if needed. Under **System Settings → Privacy & Security → Accessibility**, enable the copy in Applications. If macOS already lists Paper Chain as enabled but the app still asks for access after an update, remove its stale entry and add the installed copy again. The app checks for access after you request it and loads the windows when macOS grants it. **Rescan all windows** also checks immediately. Quit from the menu bar to release managed windows.

## Implementation

- **ChainCore** owns window identities, group membership, per-display layout and scroll motion. The presentation layer converts visible columns into place, raise, park and release commands. It inspects at most three columns per display during an animation tick. The same command stream drives the simulator.
- **PaperChainMac** uses AppKit, SwiftUI, Quartz window metadata and Accessibility. Observer events update the inventory. Physical drags change ownership. Programmatic frame changes cannot transfer a window to the adjacent monitor. Native windows and app icons supply the visuals without screen capture.
- **Parking and recovery** use macOS minimization for inactive groups. Returning to a group restores its windows as they enter view. The adapter records its own minimizes in an atomic journal before hiding a window. It checks the process launch and window identity before recovery. Windows minimized by the user are excluded from tiling. The workspace and dock positions are persisted separately from the key.
- **Decisions** validates complete bounded batches and maps temporary request references back to window IDs. The HTTP transport is injectable for offline checks.

The scrolling strip and stack interaction draw on ChainYourMac. Its site documents separate strips per display and vertically stacked windows within a column. [ChainYourMac](https://chainyourmac.com/)
