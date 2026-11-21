# Install Paper Chain

Paper Chain runs on macOS 14 Sonoma or later. Sign in to GitHub with an account that has access to the private Paper Chain repository.

## Download and install

1. **[Download Paper Chain for macOS](https://github.com/Harshal96/paperchain/releases/latest/download/Paper-Chain.dmg)**. If the download doesn’t start, choose **Paper-Chain.dmg** under **Assets** on the [latest release](https://github.com/Harshal96/paperchain/releases/latest).
2. Open **Paper-Chain.dmg** from **Downloads**. In the window that appears, drag **Paper Chain** onto the **Applications** folder.
3. In Finder, eject the **Paper Chain** disk image. Open **Applications** and double-click **Paper Chain**. Its icon appears in the menu bar.

### If macOS can’t verify the developer

Version 1.1.0 uses a local signing certificate and lacks Apple notarization. If macOS says it can’t verify the developer, continue only if you trust the copy you downloaded from the Paper Chain release. After trying to open the app, go to **System Settings → Privacy & Security**. Under **Security**, choose **Open Anyway** for **Paper Chain** and confirm when prompted. [Apple’s guide to opening Mac apps safely](https://support.apple.com/en-gb/102445)

## Give Paper Chain access to your windows

1. Click the **Paper Chain** icon in the Mac menu bar. It looks like a rectangle divided into three columns. Open **Settings… → Displays** and turn off any displays you want to arrange yourself. New displays are enabled by default.
2. In **Settings… → Window access**, click **Grant Accessibility Access…**. In **System Settings → Privacy & Security → Accessibility**, turn on **Paper Chain**. If it’s missing from the list, click **+** and select **Paper Chain** from **Applications**.
3. Return to Paper Chain’s settings. Under **Window access**, look for **Accessibility access granted**. Open a Finder window on an enabled display, then choose **Rescan all windows** from Paper Chain’s menu. Open the menu again to see how many eligible windows Paper Chain found.

For groups, stacks, and the controls on each display, see the [user guide](user-guide.md).

## Update or remove

To update, choose **Quit Paper Chain** from the menu bar. Download and open the latest disk image, drag **Paper Chain** into **Applications**, and choose **Replace**. Eject the image and reopen the app from **Applications**. If Paper Chain asks for Accessibility access again, check its entry in **System Settings → Privacy & Security → Accessibility**. If access is already on, remove the old entry and add the copy in **Applications**.

To remove the app, choose **Quit Paper Chain**, then move **Paper Chain** from **Applications** to the Trash.
