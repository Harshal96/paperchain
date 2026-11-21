# PaperChain user guide

PaperChain arranges windows in a horizontal strip on each enabled display. Each display starts with a group called **Inbox**. If this is your first launch, grant PaperChain permission to move windows by following the [installation guide](installation.md).

## Try your first strip

1. On a landscape display, open three regular windows, such as three Finder windows. Keep them out of full screen.
2. Click the small dark handle near the bottom center of that display to open the PaperChain dock. After the divider, you’ll see an icon for each window in the current group. Hover over an icon to read its window title.
3. Click the middle window’s icon. Its window slides to the center, leaving part of a neighbor visible on either side. Click the visible part of either neighbor to bring it into focus. At either end of the strip, two windows share the width.

Use the dock icons to jump straight to a window farther along the strip. Click the handle again to collapse the dock. Where two displays meet, a neighboring window tucks behind the center window so it stays on its own display.

## Work with groups

Click **+** in the PaperChain dock, enter a name such as **Writing**, and click **Create group**. New windows on that display now join **Writing**. To bring an existing window over, switch back to its group and drag its icon onto **Writing**. The destination group opens with the window selected.

Click a group to return to its windows. PaperChain minimizes windows in inactive groups and remembers each group’s order and selection. Hover over a group symbol to see its name, or use **Show all groups** (•••) if the dock is crowded. To change a name, Control-click the group and choose **Rename group…**.

## Arrange individual windows

| What you want | How to do it |
| --- | --- |
| Reorder a window | Drag its dock icon onto another window icon to place it before that window. For the last position, Control-click its icon and choose **Reorder → Move to end**. |
| Stack two windows vertically | Control-click one window’s dock icon, choose **Stack with**, and pick a window that has its own column. Use **Unstack window** to give a stacked window its own column again. Portrait displays pair windows automatically, so two columns can show four windows. |
| Move a window to another display | Drag its title bar to the destination display. On an enabled display it joins the active group. To pick a specific group, Control-click its dock icon and choose **Move to group**, then the group under the destination display’s name. |
| Float a window | Option-drag its title bar, or Control-click its dock icon and choose **Detach window**. Dragging it to a disabled display also takes it out of the strip. |
| Bring a detached window back | Open the destination group, click **Group and dock options** (the circled ellipsis), and choose the window under **Attach window**. |

## Adjust your displays

Open **Settings…** from PaperChain’s linked-paper icon in the menu bar.

- Under **Displays**, turn off a display to release its windows. Its groups and their order are there when you enable it again.
- Under **Appearance**, **Window padding** sets the gap between columns and stacked windows on all enabled displays. It starts at 8 points and ranges from 0 to 48. Turn on **Dim side windows** to darken the other windows when the selected window has a neighbor on both sides. This starts off.
- For instant movement between windows, turn on **Reduce motion** in macOS Accessibility settings.

To move the dock itself, drag its handle or choose **Group and dock options → Dock position** to pick an edge. Each display remembers its dock position.

## Regroup windows automatically

Manual groups work without a provider. To sort windows by topic, open **Settings… → Categories**, enter one category name per line, and click **Save categories**. The defaults are **Social Media**, **Writing**, and **Work & Coding**.

With one category, choose **Regroup windows** from the menu bar to move eligible windows into groups with that name. This runs entirely on your Mac.

For two or more categories, choose a provider under **Decisions API**. When you regroup, the provider receives app names, window titles, and your category names. Titles can include document or website names.

- **TypeSafe** sorts windows on its hosted service. Enter your TypeSafe API key and click **Save key** to store it in the macOS login Keychain. [TypeSafe API](https://docs.typesafe.ai/api/system-one)
- **Ollama (local)** sorts windows on your Mac. Open Ollama and download a local model, for example by running `ollama pull llama3.2` in Terminal. Leave Ollama running on its default port (11434), click **Refresh** in PaperChain, and select the model. Decision models such as Clef support up to 26 categories. [Llama 3.2 for Ollama](https://ollama.com/library/llama3.2) · [Ollama decision models](https://docs.ollama.com/capabilities/decision)

Choose **Regroup windows** from the menu bar. PaperChain creates matching groups as needed and keeps each window on its display.

## Troubleshooting

- **The dock is empty.** Check **Settings… → Window access** for **Accessibility access granted**. Bring the app out of hiding, restore a minimized window from the macOS Dock, or exit full screen. Then choose **Rescan all windows** in the PaperChain menu bar.
- **A window floats but still has a dock icon.** Click the icon to retry its place in the strip. For a window you deliberately detached, use **Attach window**. To bring back all available detached windows at once, choose **Reattach detached windows on enabled displays** in the menu bar.
- **You want to stop arranging windows.** Choose **Quit PaperChain** in the menu bar to release the windows it manages.
