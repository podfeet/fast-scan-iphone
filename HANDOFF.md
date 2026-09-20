# Fast Scan iPhone — Developer Handoff

Last updated 2026-09-20. For usage and troubleshooting, see [README.md](README.md).
This file is for whoever changes the code next: how it works, what was learned,
what was tried and abandoned, and what is still untested.

## Goal

A one-click automation that scans documents from the user's iPhone into
whatever Finder folder is currently open, without navigating the manual menu
path: right-click empty space → "Import from iPhone or iPad" → [device] →
"Scan Documents". It must never trigger "Take Photo", "Add Sketch" or (critically)
anything under an iPad entry.

Delivery: a Finder toolbar button (`FastScan.app`, an AppleScript applet,
Command-dragged onto the toolbar so it appears in every Finder window).

## Status (2026-09-20)

Confirmed working by the user in real runs: column view with and without "Use
Groups", list view and icon view with blank space at the bottom, and the Desktop
folder. Error messages confirmed correct for: no blank space (list and icon view),
a file selected in column view, and the Applications folder.

The self-contained app is confirmed working (2026-09-20): a real run from
`/Applications/FastScan.app/` (line 2 of the log) scanned into a Dropbox folder, and the
bundled `click-helper.js` (the right-click) and `ax-menu` (its `probe` line) both ran from
inside the app. The permission flow also has a **Finder** Automation prompt ("FastScan.app"
wants access to control "Finder.app") besides the System Events one.

Not tested: whether a copy in /Applications keeps the permission grants from the
build (the CDHash is identical, so it should; the user did go through prompts, so it's not
established), whether the app still runs with the project folder renamed away, the x86_64
slice of `ax-menu` (no Rosetta here, so only compiled), a copy that came through a browser
download or AirDrop (quarantine may block the bundled helper; `xattr -cr` on the app is the
expected fix), the phone-unreachable error path, gallery view, a selection in list or
icon view (expected to be harmless, since right-clicking blank space deselects),
multiple files selected in column view, and a *folder* selected in column view
(expected to scan into that subfolder, because its contents are the rightmost
column; if a run there fails, the "Something is selected" message would be
slightly misleading, since a folder gets a real column, not a preview).

At the time of writing none of this work was committed; `HEAD` is still
`1881234`, tagged `v1.0-no-groups-support`, the last commit before the grouped-column work.

## Files

| File | Role |
|---|---|
| `scan-from-iphone.applescript` | Source of truth. Compiled into the app by `build.sh`. |
| `FastScan.app` | The compiled applet. Bundle id `com.podfeet.fastscaniphone` (added by hand; `osacompile` doesn't set one). |
| `ax-menu.swift` → `ax-menu` | Swift helper: finds the open context menu by hit-testing screen coordinates and drives it. Commands: `import-scan x y`, `probe x y`, `selftest`. Built universal (arm64 + x86_64, macOS 13+) and shipped inside the app. |
| `click-helper.js` | JXA: posts a real right-mouse click via CoreGraphics (`CGEventPost` at the HID tap). Shipped inside the app. |
| `escape-helper.js` | JXA: posts Escape the same way. Used by `dismissMenu()` to close a stray menu. Shipped inside the app. |
| `build.sh` | The whole dev loop (see below). |
| `make-icon.sh`, `icon-matte.swift`, `icon-source.svg` | Icon pipeline. Outputs `AppIcon.iconset`, `AppIcon.icns`, `fast-scan-iphone-icon.png`. |
| `make-zip.sh` | Packages the app as `FastScan.zip` (just the app) for a GitHub release, and verifies it by unzipping. The zip is git-ignored (`.gitignore`). |
| `~/Library/Logs/FastScan/scan-log.txt` | Not in the repo. Every step, timestamped in seconds, written immediately so a crash leaves a trail. The previous run's log is kept beside it as `scan-log-previous.txt`. |

**The app is self-contained.** `build.sh` copies `click-helper.js`, `escape-helper.js` and
`ax-menu` into `FastScan.app/Contents/Resources/`, and the script finds them from its own
location (`POSIX path of (path to me)` plus `Contents/Resources/`), so the app can live
anywhere and the repo is only needed to rebuild it. There are no hard-coded paths. The
resolved app path is the second line of every log (`App: …`).

## How it works

In order of the run:

1. **Window.** Activate Finder, then pick the window whose `AXMain` is true. `window 1`
   is Finder's internal ordering and once grabbed an unrelated Desktop window; the
   `focused` attribute is usually false for every window. The chosen window is bound
   *by name* when the name is unique, because clicking a background window raises
   it and shifts every positional index.
2. **Pre-flight checks**, before any click of ours:
   - *Applications folder.* Ask Finder for `target of Finder window 1` (trusted only if
     that window's name matches the target). If it is `/Applications`, stop with a
     specific message: Finder never offers the import item there.
   - *Selection.* Count Finder's selection the same way. A click that lands on a
     row selects it, so this must be read first. Used only for the final error.
3. **Find the column.** Collect scroll areas, not lists/outlines:
   - A list's own reported size is its full *scrollable* height (3229px for 100+ rows),
     but a scroll area always reports the visible viewport.
   - Scroll areas nest (outer wrapper containing one per column), so recurse through
     them. Never recurse into a list/outline's rows: that makes Finder's
     `NSTableView` materialize a view for every row (confirmed with `sample`), a
     multi-second stall in big folders.
   - On an X tie (single column: wrapper and column start at the same X) use `>=`, so
     the later, deeper match wins.
   - The search retries up to 3 times, 1s apart, for slow renders.
4. **Choose where to click** (routes, tried in order until one gives a usable menu):
   - *Column bottom*: just above the bottom edge of the column. This is the proven
     route, but only empty if the folder is short enough.
   - *Blank right*: empty space right of the last column (column view only, needs a gap
     over 40px).
   - If the column exposes no accessibility children at all ("opaque": grouped columns,
     the Desktop folder) the order is reversed, because we can't tell whether the
     bottom edge is a row, and a click on a row selects it.
5. **Right-click and find the menu.** A real `CGEvent` right-click (System Events'
   `click`, even with Control held, is ignored by Finder's view). Then:
   - *Tree route:* `menu 1 of` a set of plausible owners: the clicked element, the
     children of the column's scroll area (the list/outline inside is the usual owner),
     the browser elements, the window. Works for ordinary columns.
   - *Helper route* for opaque columns: `ax-menu import-scan x y`. The popup is a real
     window even when the tree doesn't link it to anything, so the helper samples screen
     points around the click (nearest first, both sides and above/below, since macOS
     slides a menu that would run off screen), takes the first hit that belongs to Finder,
     and walks up to its `AXMenu`. Two weaker fallbacks: Finder's focused element and
     Finder's direct children. It then presses "Import from iPhone…", polls until the
     submenu shows an iPhone's Scan Documents, and presses it. Its output ends with one
     `RESULT …` line: `OK`, `NOMENU`, `NOIMPORT folder|item|unknown menu`, `NOSCAN`,
     `FAIL …`.
6. **Which menu opened.** A menu with no import item means two different things, told
   apart by the item names: the folder's own menu always has **"New Folder"**, a file's
   or folder's item menu never does. Folder menu without import → iPhone unreachable.
   Item menu → the click landed on a row (no blank space).
7. **Wording.** The item is "Import from iPhone or iPad" only when an iPhone *and* an
   iPad are reachable, and "Import from iPhone" when only the iPhone is. Match the
   prefix `Import from iPhone`.
8. **Choosing the device.** The submenu is a flat list: a disabled header row per
   device, then Take Photo / Scan Documents / Add Sketch, then a separator, then the
   next device. Walk it in order, find the first header containing "iPhone", take the
   next "Scan Documents" before any further disabled header. That structurally cannot
   select an iPad's entry. The AppleScript and `ax-menu` implement the same rule;
   `ax-menu selftest` checks it on mock menus (including iPad listed first).
9. **Error ladder** when every route fails, most specific first: real folder menu without
   import (iPhone unreachable) → column view with a selection → item menu (no blank
   space) → menu of unknown kind (both explanations) → nothing opened.

## Known limitations (final)

- **Blank space is needed** somewhere the right-click can land. If the folder is full
  there is no safe place, and the error says so.
- **Column view with a file selected.** Finder adds a preview column at the far right,
  and the rightmost scroll area is what gets picked, so the click lands in the preview
  and opens the file's menu. This is only *reported* (the error tells the user to
  Command-click the item). See "Tried and abandoned". Selecting a *folder* is different
  (untested): the rightmost column is its contents, so a scan should go into that
  subfolder, which would match Finder's window title.
- **Applications folder:** Finder never offers the import item.
- **English only:** menu text is matched by English names.
- **Permissions reset on every rebuild** (next section).
- Depends on Finder's UI internals, so a macOS update can break it.

## Dev / test loop

`./build.sh` does, in order: compile `ax-menu` for arm64 and x86_64 (target macOS 13.0),
`lipo` them together, re-sign, and run its selftest → `osacompile` the script into the app →
copy the three helpers into the app's Resources → install the icon (delete
`CFBundleIconName` and `Assets.car`, copy `AppIcon.icns`) → `xattr -cr` → ad-hoc
`codesign` → `touch` and `lsregister -f` the app → `tccutil reset` Accessibility and
AppleEvents.

Why the helper is built universal with a low target: by default `swiftc` builds for this
Mac's architecture and exact OS version. The first helper was arm64-only with minimum OS
27.0, so a copied app would have failed at the helper on an Intel Mac or an older macOS.
A rehearsal on a scratch copy showed the seal stays valid with the executable in
Resources, a copy in another folder verifies, and the copy has the identical CDHash (so
the same identity for permission grants).

Every rebuild changes the ad-hoc signature, which invalidates the Accessibility and
Automation grants, so each cycle needs: click the button, approve the "control System
Events" and "control Finder" prompts (the user confirmed the Finder one exists), let it
fail once with "not allowed assistive access", enable FastScan in
System Settings → Privacy & Security → Device Control & Data Access (where the
Accessibility grant lives on this macOS), click again. Note the error dialog opens
*behind* the Finder window; flip to it and dismiss it first. A locally
self-signed certificate would keep the identity stable and end this, but it needs a
new root cert to be trusted; that was blocked by a guardrail and the user declined to
run it themselves. The user's call.

**Only the user runs the automation.** It drives their live screen and forces the
permission dance. Verify statically instead:
- `osacompile -o <scratch>/x.scpt scan-from-iphone.applescript` (never into the app).
- `swiftc` the helper and run `ax-menu selftest`.
- After a build, `osadecompile FastScan.app/Contents/Resources/Scripts/main.scpt` and grep
  it, to confirm the app holds the new code; `codesign --verify --deep --strict`.
- Pure-logic checks in isolated AppleScript that names no application.

**Read the log before the next run.** The log is `~/Library/Logs/FastScan/scan-log.txt`; it
is overwritten on every run, but the previous run's survives as `scan-log-previous.txt`
(added after a later run destroyed the log of a failing one and the cause was never
established). Two runs later it's gone, so read it promptly.

Log lines worth knowing: `Target folder: …`, `Items selected in the window: N` (-1 =
unknown), `Column exposes no accessibility children`, `under (x, y): …` (what is at
each click point, printed before clicking), `found the menu by hit test`,
`Found menu … (folder|item menu) with items: …`, `RESULT …`, and
`ax-menu helper is missing from the app` (rebuild with `./build.sh`).

## Tried and abandoned (don't retry without a new idea)

- **NSCollectionView hypothesis for grouped columns.** Wrong. Finder's binary has
  `TColumnGroupHeaderRowView`, `TColumnRowView`, `TBrowserTableView`: still table-based,
  with group-header rows. "Zero children" was never proven to mean none: every
  `UI elements of` sat in a bare `try`, so an AX error looked like an empty column.
  The real cause was that the popup isn't linked into the tree for those columns; the
  hit-test helper sidesteps that.
- **Toolbar "Action" menu route.** The user's toolbar has no Action button (Back/Forward,
  two app buttons, view switcher, Group, Share, Search, `»`), System Events reports
  classes as raw codes (`«class butT»`), so its name matching could never have worked,
  and it sent a stray Escape after finding nothing to close.
- **`AXDocument` for the window's folder.** Finder windows return `missing value` for it.
  (The first version treated that text as an answer and never reached its fallback.)
- **Finder's `set selection to {}` to clear a selection.** Does nothing in column view:
  the count stayed 1 and the preview column stayed.
- **Steering the column picker around the preview column** by its `Preview of <file>`
  label (nested scroll areas at the far right; in one run the folder column was x=451
  w=380, the preview container x=831, its contents x=841), then right-clicking the
  folder's own column. The user reported it didn't work, but that run's log was lost,
  so it is unknown whether the label wasn't matched or the folder column simply had no
  blank space (Downloads is probably full). It may have been sound. It also had a
  hazard: keying it on Finder's selection instead of the label would drop the real
  column for anyone with the preview column turned off.
- **Blind keyboard navigation of the open menu.** Rejected as too risky (item positions
  shift; a wrong Return could hit Move to Trash).
- **Rendering the icon with ImageMagick.** Its own SVG renderer paints this file solid
  black (no `rsvg` delegate).

## Finder internals seen (from `strings`/`otool` on the Finder binary)

`importFromDevice:` is an action on `TBaseBrowserViewController`; the item comes from
`standardImportFromDeviceMenuItem`; menus are built by `TContextMenu` /
`buildContextMenu:forContext:…`, shown with `popUpContextMenu:withEvent:forView:`;
no nib references the import action. In the accessibility tree the column view is
`AXBrowser "column view"` containing nested `AXScrollArea`s. The preview column's image
area is labelled `Preview of <file>`.

## Icon

The original rasterization had opaque white corners: Quick Look (`qlmanage -t`) is the
only local renderer that handles the SVG's blur filter, and it always composites onto
white. `make-icon.sh` renders the SVG over white and over black, and `icon-matte.swift`
recovers exact transparency from the pair (`a = 1 − (W−K)/255`, `C = K/a`); it re-composites
both to check itself and refuses to write on any error. Verified: corner alpha 0 at every
size.

The icon also never showed on the app, for two separate reasons, both now handled by
`build.sh`: (1) `osacompile` leaves `CFBundleIconName = applet` and a stock `Assets.car`,
which macOS prefers over `CFBundleIconFile`; (2) LaunchServices keeps its own copy of the
app's `Info.plist` (see `lsregister -dump`) and re-reads it only when the bundle *folder's*
mtime changes, which a rebuild never does, hence `touch` + `lsregister -f`. If Finder still
draws the old icon, it's Finder's in-memory copy: `killall Finder`.

## Releasing

Users get the app from a GitHub release, not from the repo: `FastScan.app` is a folder in the
repo, and GitHub can't download a single folder. To publish: `./build.sh`, then `./make-zip.sh`
(builds `FastScan.zip` with `ditto`, which keeps the signature and permissions; Finder's Compress
would add a `__MACOSX` folder because every file in the app carries a `com.apple.provenance`
attribute), then on GitHub: Releases → Draft a new release → choose the tag → attach
`FastScan.zip` → publish. The README links to `releases/latest`, so a release must exist. The app
is ad-hoc signed, not notarized, so a browser download gets quarantined and the README tells users
to run `xattr -cr` on it (expected macOS behavior; not tested on a real download).

## Ideas not done

- Keyboard Maestro and Shortcuts versions (would wrap the same script in an "Execute
  AppleScript" action). Only the toolbar button exists.
- A stable signing identity, to end the permission dance.
- The root-level `ax-menu` build artifact is tracked in git although the app carries its own copy
  and every build changes it: `git rm --cached ax-menu` and add it to `.gitignore`.
