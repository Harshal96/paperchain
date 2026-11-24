# Install PaperChain

PaperChain runs on macOS 14 Sonoma or later. Sign in to GitHub with an account that has access to the private PaperChain repository.

## Download and install

If you already have a copy in **Applications**, follow the [update steps](#update-or-remove).

1. **[Download PaperChain for macOS](https://github.com/Harshal96/paperchain/releases/latest/download/PaperChain.dmg)**. If the download doesn’t start, choose **PaperChain.dmg** under **Assets** on the [latest release](https://github.com/Harshal96/paperchain/releases/latest).
2. Open **PaperChain.dmg** from **Downloads**. In the window that appears, drag **PaperChain.app** onto the **Applications** folder.
3. In Finder, eject the disk image. Open **Applications** and double-click the app. Its icon appears in the menu bar.

### If macOS can’t verify the developer

Version 0.2.0 (build 12) uses a local signing certificate and lacks Apple notarization. If macOS says it can’t verify the developer, continue only if you trust the copy you downloaded from the PaperChain release. After trying to open the app, go to **System Settings → Privacy & Security**. Under **Security**, choose **Open Anyway** for the app and confirm when prompted. [Apple’s guide to opening Mac apps safely](https://support.apple.com/en-gb/102445)

## Give PaperChain access to your windows

1. Click the linked-paper icon in the Mac menu bar. Open **Settings… → Displays** and turn off any displays you want to arrange yourself. New displays are enabled by default.
2. In **Settings… → Window access**, click **Grant Accessibility Access…**. In **System Settings → Privacy & Security → Accessibility**, turn on **PaperChain**. If it’s missing from the list, click **+** and select the app from **Applications**.
3. Return to PaperChain’s settings. Under **Window access**, look for **Accessibility access granted**. Open a Finder window on an enabled display, then choose **Rescan all windows** from PaperChain’s menu. Open the menu again to see how many eligible windows PaperChain found.

For groups, stacks, and the controls on each display, see the [user guide](user-guide.md).

## Update or remove

To update, quit the running app from its menu bar icon. In **Applications**, remove the space from the old app’s name if present, so it reads **PaperChain** (or **PaperChain.app** if Finder shows extensions). Open the latest **PaperChain.dmg**, drag **PaperChain.app** into **Applications**, and choose **Replace**. Eject the image and reopen the app from **Applications**. If PaperChain asks for Accessibility access again, check its entry in **System Settings → Privacy & Security → Accessibility**. If access is already on, remove the old entry and add the copy in **Applications**.

To remove the app, choose **Quit PaperChain**, then move the app from **Applications** to the Trash.
