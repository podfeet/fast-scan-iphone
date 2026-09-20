-- Fast Scan iPhone
-- Right-clicks empty space in the active Finder column-view folder,
-- opens "Import from iPhone or iPad", and clicks "Scan Documents" under
-- whichever entry's name contains "iPhone" -- never iPad, never Take
-- Photo/Add Sketch. Logs progress to scan-log.txt for troubleshooting.
--
-- Some columns (grouped ones, the Desktop folder) expose nothing to
-- accessibility, so System Events can't find the popup menu by walking down
-- the window's tree even though the menu really opens. For those, the
-- ax-menu helper (built from ax-menu.swift by build.sh) finds the open popup
-- by hit-testing its position on screen and clicks through it itself.
--
-- The app is self-contained: build.sh copies the three helpers (click-helper.js,
-- escape-helper.js, ax-menu) into the app's Resources, and they're found
-- relative to the app itself, so FastScan.app can live anywhere. The log goes
-- to ~/Library/Logs/FastScan/, with the previous run's kept beside it.

global targetLists
global browserBoxes
global reportLines
global outPath
global axHelperPath
global clickHelperPath
global escapeHelperPath
global startTime
global lastMenuKind

on collectLists(el, depth, maxDepth)
	tell application "System Events"
		if depth > maxDepth then return
		-- Match the column's scroll area directly rather than the list or
		-- outline inside it: a grouped column ("Use Groups" on) renders as
		-- an outline whose rows are completely absent from accessibility,
		-- but its enclosing scroll area is always present with valid
		-- bounds either way. This also sidesteps the earlier bug where a
		-- list with more rows than fit on screen reports its full
		-- scrollable content height instead of the visible viewport -- a
		-- scroll area always reports the viewport.
		--
		-- Scroll areas can nest (the browser's outer wrapper scroll area
		-- contains one inner scroll area per column), so we keep
		-- recursing through them to find the innermost ones. What we must
		-- NOT recurse into is a list/outline's own rows -- for a folder
		-- with many items, walking every row forces Finder's NSTableView
		-- to fully materialize a view for each one (not just the visible
		-- ones), which is what caused multi-second-plus stalls on folders
		-- like Applications.
		try
			if (class of el) is «class scra» then
				set end of targetLists to el
			end if
		end try
		try
			if (class of el) is «class broW» then
				set end of browserBoxes to el
			end if
		end try
		set stopHere to false
		try
			if (class of el) is list or (class of el) is «class outl» then set stopHere to true
		end try
		if not stopHere and depth < maxDepth then
			try
				set kids to UI elements of el
				repeat with k in kids
					my collectLists(k, depth + 1, maxDepth)
				end repeat
			end try
		end if
	end tell
end collectLists

on dumpTree(el, depth, maxDepth)
	tell application "System Events"
		if depth > maxDepth then return
		set className to "?"
		set isList to false
		try
			set className to (class of el) as text
			if (class of el) is list or (class of el) is «class outl» then set isList to true
		end try
		set posText to "?"
		try
			set p to position of el
			set posText to ("{" & (item 1 of p) & "," & (item 2 of p) & "}")
		end try
		set sizeText to "?"
		try
			set s to size of el
			set sizeText to ("{" & (item 1 of s) & "," & (item 2 of s) & "}")
		end try
		set indentText to ""
		repeat depth times
			set indentText to indentText & "  "
		end repeat
		my logStep(indentText & className & " pos=" & posText & " size=" & sizeText)
		-- Skip a list's own rows -- same reasoning as collectLists: forces
		-- Finder to materialize every row's view, which is very slow for
		-- large folders and unnecessary for this diagnostic dump.
		if not isList and depth < maxDepth then
			try
				set kids to UI elements of el
				repeat with k in kids
					my dumpTree(k, depth + 1, maxDepth)
				end repeat
			end try
		end if
	end tell
end dumpTree

on joinList(lst, delim)
	set oldDelims to AppleScript's text item delimiters
	set AppleScript's text item delimiters to delim
	set joined to lst as text
	set AppleScript's text item delimiters to oldDelims
	return joined
end joinList

on writeTextToFile(theText, thePath)
	set fileRef to open for access thePath with write permission
	set eof of fileRef to 0
	write theText to fileRef as «class utf8»
	close access fileRef
end writeTextToFile

on logStep(msg)
	-- Seconds since the run started, so a stall in Finder's accessibility
	-- responses shows up in the log instead of just looking like slowness.
	set end of reportLines to "[" & ((current date) - startTime) & "s] " & msg
	try
		my writeTextToFile(my joinList(reportLines, linefeed), outPath)
	end try
end logStep

on dismissMenu()
	try
		do shell script "/usr/bin/osascript -l JavaScript " & quoted form of escapeHelperPath
	end try
	delay 0.3
end dismissMenu

on axHelperReady()
	try
		do shell script "test -x " & quoted form of axHelperPath
		return true
	end try
	return false
end axHelperReady

-- Runs ax-menu (import-scan or probe) and logs everything it printed.
-- Returns its final "RESULT ..." line: RESULT OK means it clicked Scan
-- Documents itself (import-scan) or described the point (probe).
on runAxHelper(subCommand, px, py)
	set helperCmd to (quoted form of axHelperPath) & " " & subCommand & " " & (px as text) & " " & (py as text) & " 2>&1"
	set helperOut to ""
	try
		set helperOut to do shell script helperCmd
	on error errH number errHN
		my logStep("  ax-menu couldn't run: " & errHN & " " & errH)
		return "RESULT ERROR"
	end try
	set resultLine to "RESULT ERROR the helper printed no result"
	repeat with helperLine in (paragraphs of helperOut)
		set helperLineText to helperLine as text
		if helperLineText is not "" then
			my logStep(helperLineText)
			if helperLineText starts with "RESULT" then set resultLine to helperLineText
		end if
	end repeat
	return resultLine
end runAxHelper

-- Logs a menu's items and returns its "Import from iPhone..." item, or
-- missing value if it doesn't have one (e.g. we opened a file's menu
-- because the click landed on a row).
--
-- Also sets lastMenuKind, because a menu with no Import item means two
-- different things: a folder's own menu (it always has "New Folder"; a
-- file's or folder's item menu never does) means the iPhone isn't
-- reachable, while an item menu means the click landed on a row because
-- there was no empty space to click. "unknown" if the items couldn't be read.
--
-- The exact wording varies: it's "Import from iPhone or iPad" only when
-- both an iPhone AND an iPad are currently reachable, and just "Import from
-- iPhone" when only iPhone is nearby. An exact-string match was silently
-- failing whenever the phrase shortened, so match the common prefix.
on findImportItem(ctxMenu)
	global lastMenuKind
	set lastMenuKind to "unknown"
	tell application "System Events"
		set ctxMenuName to "<no name>"
		try
			set ctxMenuName to (name of ctxMenu) as text
		end try
		try
			set itemDescriptions to {}
			repeat with mi in (menu items of ctxMenu)
				set miName to "-"
				try
					-- Separators have no name (missing value); log those as "-".
					set rawName to name of mi
					if rawName is not missing value then set miName to rawName as text
				end try
				set end of itemDescriptions to miName
			end repeat
			if itemDescriptions contains "New Folder" then
				set lastMenuKind to "folder"
			else if (count of itemDescriptions) > 0 then
				set lastMenuKind to "item"
			end if
			my logStep("Found menu \"" & ctxMenuName & "\" (" & lastMenuKind & " menu) with items: " & my joinList(itemDescriptions, ", "))
		on error errCtx
			my logStep("Found menu \"" & ctxMenuName & "\" but couldn't list its items: " & errCtx)
		end try
		try
			return (first menu item of ctxMenu whose name starts with "Import from iPhone")
		end try
	end tell
	return missing value
end findImportItem

-- True if this Finder window shows the /Applications folder. Finder doesn't
-- offer "Import from iPhone" there at all, so no amount of right-clicking
-- will find it -- and in a folder that full, the click would land on an app
-- and produce a misleading "no empty space" error instead. Ask Finder for
-- the folder the front window shows, but only when that window is the one
-- being targeted (same guard as selectedItemCount). Finder windows don't
-- expose their folder as AXDocument (it comes back as missing value), so
-- that isn't an option. Anything it can't work out counts as "no", so it
-- never blocks a scan by mistake.
on windowShowsApplications(winName)
	try
		tell application "Finder"
			if (name of Finder window 1) is winName then
				set folderPath to POSIX path of ((target of Finder window 1) as alias)
				my logStep("Target folder: " & folderPath)
				return {"/Applications/", "/Applications"} contains folderPath
			end if
		end tell
	end try
	my logStep("Target folder couldn't be determined")
	return false
end windowShowsApplications

-- How many items are selected in the target Finder window, or -1 if that
-- can't be told (Finder's selection is always the frontmost Finder window's,
-- so it's only trusted when that window is the one being targeted).
on selectedItemCount(winName)
	try
		tell application "Finder"
			if (name of Finder window 1) is not winName then return -1
			return count of ((get selection) as list)
		end tell
	end try
	return -1
end selectedItemCount

-- Opens the Import submenu and clicks Scan Documents. The submenu is a FLAT
-- list: a disabled (non-clickable) header row naming each device, followed
-- by that device's Take Photo / Scan Documents / Add Sketch rows, then a
-- separator, then the next device's header. Walk it in order, find the
-- first disabled header whose name contains "iPhone", and take the next
-- "Scan Documents" before any further disabled header -- which structurally
-- guarantees it can never select an iPad's entry, even if the ordering
-- changes.
on clickScanDocuments(importItem)
	tell application "System Events"
		click importItem
		delay 0.6
		my logStep("Opened Import submenu")

		set importMenu to menu 1 of importItem
		set importItems to UI elements of importMenu

		set foundHeader to false
		set scanItem to missing value
		repeat with ii in importItems
			set iiName to ""
			set iiEnabled to true
			try
				set iiName to name of ii
			end try
			try
				set iiEnabled to enabled of ii
			end try

			if not foundHeader then
				if iiName contains "iPhone" then
					set foundHeader to true
					my logStep("Found iPhone header: " & iiName)
				end if
			else
				if not iiEnabled and iiName is not "" then
					-- hit the next device's header before finding Scan Documents
					exit repeat
				end if
				if iiName is "Scan Documents" then
					set scanItem to ii
					exit repeat
				end if
			end if
		end repeat

		if scanItem is missing value then
			error "Could not find an iPhone with a Scan Documents option. Make sure your iPhone is nearby, unlocked, and on the same Wi-Fi/Bluetooth as this Mac."
		end if

		click scanItem
		my logStep("Clicked Scan Documents")
	end tell
end clickScanDocuments

set targetLists to {}
set browserBoxes to {}

-- Where the app is, and so where its helpers are (see the header comment).
set appPath to POSIX path of (path to me)
if appPath does not end with "/" then set appPath to appPath & "/"
set appResources to appPath & "Contents/Resources/"
set clickHelperPath to appResources & "click-helper.js"
set escapeHelperPath to appResources & "escape-helper.js"
set axHelperPath to appResources & "ax-menu"

-- The log lives outside the app, so it survives replacing the app. Keep the
-- previous run's log as scan-log-previous.txt: a failing run used to be
-- overwritten by the next run before anyone could read it.
set logFolder to (POSIX path of (path to library folder from user domain)) & "Logs/FastScan/"
set outPath to logFolder & "scan-log.txt"
set previousLogPath to logFolder & "scan-log-previous.txt"
try
	do shell script "mkdir -p " & quoted form of logFolder & " && if [ -f " & quoted form of outPath & " ]; then mv -f " & quoted form of outPath & " " & quoted form of previousLogPath & "; fi"
end try

set startTime to current date
set lastMenuKind to "unknown"
set reportLines to {}
my logStep("--- run start ---")
my logStep("App: " & appPath)

try
	tell application "Finder" to activate
	delay 0.3
	my logStep("Finder activated")

	tell application "System Events"
		tell process "Finder"
			-- window 1 reflects Finder's own internal window ordering,
			-- which isn't reliably the window that actually has focus
			-- when multiple Finder windows are open (we saw it grab an
			-- unrelated "Desktop" window while the user had two other
			-- windows open). The "focused" attribute is usually false for
			-- every window (the log shows it), but AXMain is true for the
			-- one Finder treats as its main window, which matches what's
			-- in front. So prefer AXMain, then "focused", and only then
			-- fall back to window 1.
			set frontWin to missing value
			repeat 4 times
				set winCount to count of windows
				repeat with wi from 1 to winCount
					try
						if (value of attribute "AXMain" of window wi) is true then
							set frontWin to window wi
							-- Bind by name when it's unique: clicking in a
							-- background window raises it, which would shift
							-- every window's index and leave a position-based
							-- reference pointing at a different window.
							try
								set mainName to (name of window wi) as text
								if (count of (windows whose name is mainName)) = 1 then set frontWin to window mainName
							end try
							my logStep("Got main window")
							exit repeat
						end if
					end try
				end repeat
				if frontWin is missing value then
					try
						set frontWin to (first window whose focused is true)
						my logStep("Got focused window")
					end try
				end if
				if frontWin is not missing value then exit repeat
				delay 0.3
			end repeat
			if frontWin is missing value then
				my logStep("--- diagnostic: all windows' properties ---")
				try
					set allWins to windows
					repeat with w in allWins
						set wName to "?"
						set wFocused to "?"
						set wMain to "?"
						try
							set wName to (name of w) as text
						end try
						try
							set wFocused to (focused of w) as text
						end try
						try
							set wMain to (value of attribute "AXMain" of w) as text
						end try
						my logStep("  window \"" & wName & "\" focused=" & wFocused & " AXMain=" & wMain)
					end repeat
				on error errDiagW
					my logStep("  FAILED: " & errDiagW)
				end try

				set frontWin to window 1
				my logStep("No main or focused window found, falling back to window 1")
			end if
			set frontWinName to ""
			try
				set frontWinName to (name of frontWin) as text
			end try
			my logStep("Target window: \"" & frontWinName & "\"")

			-- Finder never offers the import item in the Applications folder,
			-- so say so up front rather than right-clicking around for it.
			if my windowShowsApplications(frontWinName) then
				error "Finder doesn't offer \"Import from iPhone\" in the Applications folder, so Fast Scan can't scan into it. Open a different folder (your Desktop or Documents, say) and try again."
			end if

			-- With a file selected in column view, Finder adds a PREVIEW column at
			-- the far right, and the rightmost column is what gets picked below --
			-- so a right-click lands in the preview instead of the folder. There
			-- is no working way around that from here (Finder's own
			-- "set selection to {}" does nothing in column view, and steering
			-- around the preview column by its "Preview of" label didn't work
			-- when tried), so it's only reported, at the end. Count the selection
			-- NOW, before any click of ours: a click that lands on a row selects
			-- it, which would make every later failure look like a selection
			-- problem.
			set selectionAtStart to my selectedItemCount(frontWinName)
			my logStep("Items selected in the window: " & selectionAtStart & " (-1 means unknown)")

			-- The sidebar and toolbar can't contain the file-list columns,
			-- so skip straight past them to where the browser actually
			-- lives if possible -- this cuts the search from ~5s to
			-- under a second. Falls back to searching the whole window
			-- if that shortcut doesn't match (e.g. sidebar hidden).
			set searchRoot to frontWin
			try
				set searchRoot to splitter group 1 of splitter group 1 of frontWin
			end try

			-- Large folders can take a moment for Finder to finish
			-- rendering, and the frontmost item's info/preview column
			-- doesn't count as a real list -- so retry the whole search a
			-- couple of times before giving up.
			set bestList to missing value
			set bestPos to missing value
			set bestSize to missing value
			repeat with searchAttempt from 1 to 3
				my logStep("Starting search, attempt " & searchAttempt)
				set targetLists to {}
				set browserBoxes to {}

				my collectLists(searchRoot, 0, 6)
				my logStep("Fast search done, found: " & (count of targetLists))

				if (count of targetLists) = 0 then
					my logStep("Fast search found nothing, falling back to full window search")
					set targetLists to {}
					set browserBoxes to {}
					my collectLists(frontWin, 0, 8)
					my logStep("Full search done, found: " & (count of targetLists))
				end if

				set bestX to missing value
				set idx to 0
				repeat with lst in targetLists
					set idx to idx + 1
					try
						set thisPos to position of lst
						set thisSize to size of lst
						set thisX to item 1 of thisPos
						set thisHeight to item 2 of thisSize
						my logStep("  scroll area " & idx & ": pos={" & thisX & "," & (item 2 of thisPos) & "} size={" & (item 1 of thisSize) & "," & thisHeight & "}")
						-- >= (not just >) so that on a tie -- the outer browser
					-- wrapper and a single inner column both start at the
					-- same X in a one-column window -- we keep the LATER
					-- match, which (given depth-first traversal) is always
					-- the more deeply nested, more specific one.
					if thisHeight >= 100 and (bestX is missing value or thisX >= bestX) then
							set bestX to thisX
							set bestList to lst
							set bestPos to thisPos
							set bestSize to thisSize
						end if
					end try
				end repeat

				if bestList is not missing value then exit repeat

				my logStep("No real folder column found yet, waiting and retrying")
				delay 1
			end repeat

			if bestList is missing value then
				my logStep("--- full window dump (no candidate tall enough) ---")
				my dumpTree(frontWin, 0, 10)
				error "Could not find the active folder column. If an item is selected, Finder may be showing its preview/info instead of the folder list -- try deselecting first."
			end if

			set listPos to bestPos
			set listSize to bestSize
			set listBottom to (item 2 of listPos) + (item 2 of listSize)
			set listRight to (item 1 of listPos) + (item 1 of listSize)

			-- A popup menu may attach to the list/outline directly inside
			-- the scroll area (the actual receiving view), not the scroll
			-- area itself. Get bestList's *immediate* children only (not
			-- recursive, so this stays cheap even for a huge folder) to
			-- find that inner element as an extra menu-owner candidate.
			set innerOwners to {}
			repeat with kidsAttempt from 1 to 3
				try
					set innerKids to UI elements of bestList
					repeat with ik in innerKids
						set end of innerOwners to ik
						try
							my logStep("Inner owner candidate class: " & ((class of ik) as text))
						end try
					end repeat
				on error errKids number errKidsNum
					-- This used to be swallowed silently, which made a failed
					-- query look exactly like a column with no children.
					my logStep("Reading bestList's children failed (attempt " & kidsAttempt & "): " & errKidsNum & " " & errKids)
				end try
				if (count of innerOwners) > 0 then exit repeat
				delay 0.4
			end repeat

			-- A grouped column (or the Desktop folder) still opens a real
			-- popup on right-click, but its scroll area has no accessibility
			-- children, so no element exists to ask for "menu 1". Note it, so
			-- the routes below can lean on the ax-menu helper for those.
			set columnIsOpaque to ((count of innerOwners) = 0)
			-- Only column view has a browser element, and it's the only view
			-- where a selection gets in the way (list and icon view just deselect
			-- when you right-click empty space).
			set isColumnView to ((count of browserBoxes) > 0)
			if columnIsOpaque then
				my logStep("Column exposes no accessibility children (grouped, or the Desktop folder?)")
			end if

			-- A "click" route right-clicks empty space and then looks for the
			-- popup that opens. Each is {"click", x, y, ownerElement} --
			-- ownerElement is whatever element the resulting popup menu should
			-- be found on (checking the wrong element for a given click point
			-- is why detection was failing even when a real menu opened).
			--
			-- Route: empty space below the last row, at the column's own
			-- bottom edge. This is the proven one -- but it's only empty space
			-- if the folder has few enough rows; in a full column the click
			-- lands on the last visible row and opens that file's menu.
			set columnBottomRoute to {"click", (item 1 of listPos) + ((item 1 of listSize) / 2), listBottom - 10, bestList}

			-- Route: empty space to the right of the whole column browser,
			-- if the browser is wider than the columns it currently shows
			-- (covers folders whose column has no empty space of its own).
			set blankRightRoutes to {}
			repeat with bx in browserBoxes
				try
					set bPos to position of bx
					set bSize to size of bx
					set browserRight to (item 1 of bPos) + (item 1 of bSize)
					set gapWidth to browserRight - listRight
					if gapWidth > 40 then
						set end of blankRightRoutes to {"click", listRight + (gapWidth / 2), (item 2 of listPos) + 30, bx}
					end if
				end try
			end repeat

			-- Order matters: a right-click on a row selects it, which changes
			-- what every later route sees, so try the route that can't land on a
			-- row first. When the column hides its contents from accessibility we
			-- can't tell whether its bottom edge is a row or empty space, so that
			-- route goes last; otherwise it's the proven one and goes first.
			set routes to {}
			if columnIsOpaque then
				repeat with br in blankRightRoutes
					set end of routes to (contents of br)
				end repeat
				set end of routes to columnBottomRoute
			else
				set end of routes to columnBottomRoute
				repeat with br in blankRightRoutes
					set end of routes to (contents of br)
				end repeat
			end if

			set ctxMenu to missing value
			set importItem to missing value
			set scanDone to false
			-- What kind of menu turned up without an Import item decides
			-- which error to show if every route fails: a folder menu means
			-- the iPhone isn't reachable, an item menu means the click landed
			-- on a row because there was no empty space.
			set sawFolderMenuWithoutImport to false
			set sawItemMenu to false
			set sawMenuWithoutImport to false
			set helperReady to my axHelperReady()
			if not helperReady then
				my logStep("ax-menu helper is missing from the app (rebuild with build.sh) -- columns that hide their contents from accessibility won't work")
			end if

			repeat with route in routes
				set ctxMenu to missing value
				set noImportKind to ""
				set clickX to item 2 of route
				set clickY to item 3 of route
				set clickOwner to item 4 of route
				if helperReady then my runAxHelper("probe", clickX, clickY)
				my logStep("Right-clicking at {" & clickX & ", " & clickY & "}")

				do shell script "/usr/bin/osascript -l JavaScript " & quoted form of clickHelperPath & " " & (clickX as text) & " " & (clickY as text)
				delay 0.6

				-- The popup menu's actual owner in the accessibility tree
				-- isn't always the element we clicked (e.g. it may attach
				-- to whatever's inside a scroll area, not the scroll area
				-- itself), so try several plausible owners rather than
				-- just one.
				set ownersToTry to {clickOwner}
				repeat with io in innerOwners
					set end of ownersToTry to io
				end repeat
				repeat with bx2 in browserBoxes
					set end of ownersToTry to bx2
				end repeat
				set end of ownersToTry to frontWin

				-- For a column that hides its contents the tree can't
				-- work, and the helper polls for the menu itself, so a
				-- single quick look here is enough. Otherwise keep the
				-- proven retries in case the menu is slow to appear.
				set treeAttempts to 3
				if helperReady and columnIsOpaque then set treeAttempts to 1
				repeat with attemptNum from 1 to treeAttempts
					repeat with ownerCandidate in ownersToTry
						try
							set ctxMenu to menu 1 of ownerCandidate
							exit repeat
						end try
					end repeat
					if ctxMenu is not missing value then exit repeat
					if attemptNum < treeAttempts then delay 0.4
				end repeat

				-- Not reachable from the tree (a column that hides its
				-- contents): have the helper find the open popup by where
				-- it is on screen and click through it.
				if ctxMenu is missing value and helperReady then
					set helperResult to my runAxHelper("import-scan", clickX, clickY)
					if helperResult starts with "RESULT OK" then
						set scanDone to true
						exit repeat
					end if
					if helperResult starts with "RESULT NOSCAN" then
						-- It found the Import menu, so this IS the right
						-- menu; the problem is the device, and clicking
						-- somewhere else won't help.
						error "Could not find an iPhone with a Scan Documents option. Make sure your iPhone is nearby, unlocked, and on the same Wi-Fi/Bluetooth as this Mac."
					end if
					if helperResult starts with "RESULT NOIMPORT" then
						if helperResult contains "folder menu" then
							set noImportKind to "folder"
						else if helperResult contains "item menu" then
							set noImportKind to "item"
						else
							set noImportKind to "unknown"
						end if
					end if
				end if

				-- A menu turned up, but it may not be the one we want: if the
				-- click landed on a row it's that file's menu, which has no
				-- Import item. Check before committing to it.
				if ctxMenu is not missing value then
					set importItem to my findImportItem(ctxMenu)
					if importItem is not missing value then exit repeat
					set noImportKind to lastMenuKind
				end if

				-- Remember what kind of menu it was, for the error message if
				-- nothing works.
				if noImportKind is not "" then
					if noImportKind is "folder" then
						set sawFolderMenuWithoutImport to true
					else if noImportKind is "item" then
						set sawItemMenu to true
					else
						set sawMenuWithoutImport to true
					end if
				end if

				my logStep("That route didn't lead to an Import from iPhone menu, dismissing and trying the next one")
				my dismissMenu()
			end repeat

			if not scanDone and importItem is missing value then
				if sawFolderMenuWithoutImport then
					error "The folder's menu has no \"Import from iPhone...\" item. Make sure your iPhone is nearby, unlocked, and on the same Wi-Fi/Bluetooth as this Mac."
				end if
				-- A real folder menu (above) means the click did land in the
				-- folder; otherwise a selection in column view is the likeliest
				-- culprit, ahead of "no empty space", because Finder's preview
				-- column also opens a file's menu.
				if isColumnView and selectionAtStart > 0 then
					error "Something is selected in this folder. In column view Finder then adds a preview column on the right, and Fast Scan right-clicked in that instead of the folder. Command-click the selected item to deselect it, then try again."
				end if
				if sawItemMenu then
					error "There's no empty space at the bottom of this folder's window to right-click, so Finder opened the menu for a file instead of the folder. Make the Finder window larger so some blank space shows below the last item, then try again."
				end if
				if sawMenuWithoutImport then
					error "Could not find an \"Import from iPhone...\" menu item. Either your iPhone isn't nearby, unlocked, and on the same Wi-Fi/Bluetooth as this Mac, or there was no empty space at the bottom of the window to right-click, so Finder opened a file's menu instead (in that case, make the Finder window larger so some blank space shows below the last item)."
				end if
				error "Couldn't open a folder context menu at any of the places tried. This folder's column may have no empty space -- try resizing the Finder window wider, or scroll so there's a visible gap."
			end if

			if scanDone then
				my logStep("Scan Documents was clicked by the ax-menu helper")
			else
				my clickScanDocuments(importItem)
			end if
		end tell
	end tell

	my logStep("--- run end (success) ---")
on error errMsg number errNum
	my logStep("ERROR " & errNum & ": " & errMsg)
	display dialog "Fast Scan iPhone couldn't complete: " & errMsg buttons {"OK"} default button "OK" with title "Fast Scan iPhone - Error" with icon caution
end try
