# Fast Scan iPhone

A Finder toolbar button that scans documents from your iPhone straight into the folder you're looking at.

## The Problem to be Solved

Your iPhone is an excellent document scanner, and macOS will even drop the finished PDF into whatever folder you have open. That's genuinely great, right up until you ask how to make it happen. Here is the entire process, which Apple presumably considers a feature:

1. **Right-click** on empty space in a Finder window. (You didn't fill the window with files, did you? Finder needs somewhere blank to right-click, and it won't be telling you that.)
2. **Slide over** onto the menu that appears. It isn't in the File menu, where a reasonable person would look.
3. **Slide down** to *Import from iPhone or iPad*, past everything you didn't want.
4. **Slide over** again, into the submenu.
5. **Click** *Scan Documents*, and not the one right below it that belongs to your iPad, sitting in the same list and eager to send your scan to the wrong device. *Take Photo* and *Add Sketch* are also right there, hoping you'll drift.

Right-click, slide, slide, slide, click: five carefully aimed mouse movements to do something you had already decided to do, repeated for every single scan. A fine way to spend an afternoon, if you enjoy tiny precision tasks in a submenu.

Fast Scan does the sliding for you. You click one button. It right-clicks the empty space, slides over, slides down, slides over again, and clicks the right *Scan Documents*, every time, without once being tempted by the iPad.

## Installation & Permissions Process

FastScan.app is self-contained: everything it needs is inside it, so you don't need this project folder to *run* it. You need a Mac and an iPhone that support Continuity Camera (iPhone nearby, unlocked, same Apple ID, Wi-Fi and Bluetooth on), and English-language macOS. It was developed and tested on macOS 27.0 (Apple silicon); it's built to also run on Intel Macs and macOS 13 or later, but that hasn't been tried.

**1. Get `FastScan.app`.** Download `FastScan.zip` from the [latest release](https://github.com/podfeet/fast-scan-iphone/releases/latest); it contains just the app. Unzip it and copy `FastScan.app` to your Applications folder, or anywhere you like. (The app is also the `FastScan.app` folder at the top of this repository, but GitHub can't download a single folder, so from there you'd have to use the green **Code** button, then **Download ZIP**, or `git clone`, and take the app out of the whole project.) If macOS refuses to open it because it came from a download, clearing the download flag once with `xattr -cr /Applications/FastScan.app` in Terminal usually fixes it.

**2. Put the app in the Finder toolbar.** Hold Command and drag `FastScan.app` onto the toolbar of any Finder window. The toolbar is in every Finder window, so the button follows you into every folder and you can scan from anywhere.

**3. Grant the permissions.** macOS asks a few times before it lets an app click around on your behalf, and the last time isn't friendly about it:

1. Click the FastScan button. macOS asks whether FastScan may control **System Events**, and in another popup whether it may control **Finder** (“FastScan.app” wants access to control “Finder.app”). Click **Allow** on each.
2. After that, macOS shows an error instead of a prompt, and it opens *behind* the Finder window, so it looks like nothing happened. Flip over to it (Command-Tab) and dismiss it with **Cancel**.
3. Open **System Settings > Privacy & Security > Device Control & Data Access** and toggle on **FastScan.app**.
4. Click the button again. Now it works.

### Building it yourself

Only needed if you change the code. You need Xcode or its command line tools (the build compiles a small Swift helper).

```bash
git clone https://github.com/podfeet/fast-scan-iphone.git
cd fast-scan-iphone
./build.sh
```

That rebuilds `FastScan.app` in the project folder; copy it to Applications again afterwards. Rebuilding resets the app's permissions on purpose (a rebuild changes its signature, which invalidates them anyway), so repeat step 3 after every `./build.sh`.

## Using It

1. Open a folder in Finder.
2. Make sure there's **blank space to click**: below the last item, or, in column view, the empty area to the right of the last column (the spot where the preview shows up when you select something). In column view, also make sure **nothing is selected**.
3. Click the FastScan button. The scanner opens on your iPhone, and the finished PDF lands in that folder.

Tested in column view (with and without *Use Groups*), list view, icon view, and on the Desktop folder. Gallery view hasn't been tried.

Note that you can't scan into some special folders, such as the Applications Folder.

## Solution Design

`FastScan.app` is a compiled AppleScript with its helpers bundled inside it. When you click it, it:

- finds the front Finder window and the folder area inside it, and checks that it's a folder Finder will actually import into;
- **right-clicks empty space** with a real synthetic mouse event, posted through CoreGraphics by a small JavaScript helper (Finder ignores the clicks that System Events makes);
- **finds the context menu** that opens, either by walking the accessibility tree or, for views that expose nothing there (grouped columns, the Desktop folder), with a small Swift helper, `ax-menu`, that finds the menu by where it is on screen;
- picks *Import from iPhone…* and then **Scan Documents under the iPhone's entry**, and only that: never an iPad, never Take Photo or Add Sketch;
- logs every step and, when it can't finish, says why (see below).

The details are in the comments in `scan-from-iphone.applescript` and `ax-menu.swift`. What was tried and abandoned is in [HANDOFF.md](HANDOFF.md).

## Limitations

- **Blank space is required.** Finder only offers the import menu when you right-click empty space, so Fast Scan needs somewhere blank to click: below the last item, or, in column view, the empty area to the right of the last column. A completely full window with neither gives it nowhere to click.
- **In column view, nothing may be selected.** A selected file makes Finder add a preview column, and the click lands in that. (A selection shouldn't matter in list or icon view, but that hasn't been tested.)
- **Not in the Applications folder.** Finder never offers importing there.
- **iPhone only.** An iPad is never used, even if it's listed first.
- **English only**, and it drives Finder's own menus, so a macOS update could break it.

## When Something Goes Wrong

Each run writes a step-by-step trail to `~/Library/Logs/FastScan/scan-log.txt`, and the run before it is kept next to it as `scan-log-previous.txt`.

| The dialog says (beginning) | What it means | What to do |
|---|---|---|
| *Finder doesn't offer "Import from iPhone" in the Applications folder…* | Finder never offers import there. | Use another folder. |
| *Something is selected in this folder…* | Column view, and a selected file put a preview column in the way. | Command-click the selected item to deselect it, then try again. |
| *There's no empty space at the bottom of this folder's window…* | The right-click landed on a file, so Finder showed the file's menu. | Make the window larger so blank space shows below the last item. |
| *The folder's menu has no "Import from iPhone…" item…* | Finder's folder menu didn't offer it, so the iPhone isn't reachable. | Bring the iPhone nearby, unlock it, and check Wi-Fi and Bluetooth. |
| *Could not find an iPhone with a Scan Documents option…* | The import menu opened but had no usable iPhone entry. | Same as above. |
| *Could not find an "Import from iPhone…" menu item. Either…* | It can't tell whether the iPhone is unreachable or the click hit a file. | Check the iPhone, then check for blank space. |
| *Couldn't open a folder context menu at any of the places tried…* | No menu opened anywhere. | Make sure blank space is visible. |
| *Could not find the active folder column…* | Finder wasn't showing a folder list (still loading, or an item is selected). | Deselect, wait a moment, and try again. |

If the log says the `ax-menu` helper is missing from the app, rebuild it with `./build.sh`.
