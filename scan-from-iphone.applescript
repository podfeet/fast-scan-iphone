-- Fast Scan iPhone
-- Right-clicks empty space in the active Finder column-view folder,
-- opens "Import from iPhone or iPad", and clicks "Scan Documents" under
-- whichever entry's name contains "iPhone" -- never iPad, never Take
-- Photo/Add Sketch. Logs progress to scan-log.txt for troubleshooting.

global targetLists
global targetParents
global browserBoxes
global reportLines
global outPath

on collectLists(el, parentEl, depth, maxDepth)
	tell application "System Events"
		if depth > maxDepth then return
		set isList to false
		try
			-- A column with "Use Groups" enabled renders as an outline
			-- (grouped/hierarchical), not a flat list -- treat both the
			-- same way since either can be a real folder column.
			if (class of el) is list or (class of el) is «class outl» then
				set end of targetLists to el
				set end of targetParents to parentEl
				set isList to true
			end if
		end try
		try
			if (class of el) is «class broW» then
				set end of browserBoxes to el
			end if
		end try
		-- Don't recurse into a list's own rows -- for a folder with many
		-- items, walking every row forces Finder's NSTableView to fully
		-- materialize a view for each one (not just the visible ones),
		-- which is what was causing multi-second-plus stalls on folders
		-- like Applications. We only need the list's own bounds, never
		-- its row contents, during this search.
		if not isList and depth < maxDepth then
			try
				set kids to UI elements of el
				repeat with k in kids
					my collectLists(k, el, depth + 1, maxDepth)
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
	set end of reportLines to msg
	try
		my writeTextToFile(my joinList(reportLines, linefeed), outPath)
	end try
end logStep

set targetLists to {}
set targetParents to {}
set browserBoxes to {}
set outPath to "/Users/allison/htdocs/fast-scan-iphone/scan-log.txt"
set reportLines to {}
my logStep("--- run start ---")

try
	tell application "Finder" to activate
	delay 0.3
	my logStep("Finder activated")

	tell application "System Events"
		tell process "Finder"
			set frontWin to window 1
			my logStep("Got front window")

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
			set bestParent to missing value
			set bestPos to missing value
			set bestSize to missing value
			repeat with searchAttempt from 1 to 3
				my logStep("Starting search, attempt " & searchAttempt)
				set targetLists to {}
				set targetParents to {}
				set browserBoxes to {}

				my collectLists(searchRoot, searchRoot, 0, 6)
				my logStep("Fast search done, found: " & (count of targetLists))

				if (count of targetLists) = 0 then
					my logStep("Fast search found nothing, falling back to full window search")
					set targetLists to {}
					set targetParents to {}
					set browserBoxes to {}
					my collectLists(frontWin, frontWin, 0, 8)
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
						my logStep("  list " & idx & ": pos={" & thisX & "," & (item 2 of thisPos) & "} size={" & (item 1 of thisSize) & "," & thisHeight & "}")
						if thisHeight >= 100 and (bestX is missing value or thisX > bestX) then
							set bestX to thisX
							set bestList to lst
							set bestParent to item idx of targetParents
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

			-- Use the enclosing scroll area's viewport size (its immediate
			-- parent during the search) rather than the list's own size --
			-- a list with more rows than fit on screen reports its full
			-- scrollable content height (we saw 3229px for a ~330px-tall
			-- visible column), which would put our click point way off
			-- screen.
			set viewPos to bestPos
			set viewSize to bestSize
			try
				set viewPos to position of bestParent
				set viewSize to size of bestParent
				my logStep("Using parent viewport pos={" & (item 1 of viewPos) & "," & (item 2 of viewPos) & "} size={" & (item 1 of viewSize) & "," & (item 2 of viewSize) & "} instead of list's own size")
			on error errV
				my logStep("Could not get parent viewport, using list's own size: " & errV)
			end try

			set listPos to viewPos
			set listSize to viewSize
			set listBottom to (item 2 of listPos) + (item 2 of listSize)
			set listRight to (item 1 of listPos) + (item 1 of listSize)

			-- Candidate 1: empty space below the last row, at the column's own bottom edge.
			-- Each candidate is {x, y, ownerElement} -- ownerElement is whatever
			-- element the resulting popup menu should be found on (checking
			-- the wrong element for a given click point is why detection was
			-- failing even when a real menu opened).
			set candidatePoints to {{(item 1 of listPos) + ((item 1 of listSize) / 2), listBottom - 10, bestList}}

			-- Candidate 2: empty space to the right of the whole column browser,
			-- if the browser is wider than the columns it currently shows
			-- (covers folders whose column has no empty space of its own).
			repeat with bx in browserBoxes
				try
					set bPos to position of bx
					set bSize to size of bx
					set browserRight to (item 1 of bPos) + (item 1 of bSize)
					set gapWidth to browserRight - listRight
					if gapWidth > 40 then
						set end of candidatePoints to {listRight + (gapWidth / 2), (item 2 of listPos) + 30, bx}
					end if
				end try
			end repeat

			set ctxMenu to missing value
			repeat with pt in candidatePoints
				set clickX to item 1 of pt
				set clickY to item 2 of pt
				set clickOwner to item 3 of pt
				my logStep("Right-clicking at {" & clickX & ", " & clickY & "}")

				do shell script "/usr/bin/osascript -l JavaScript " & quoted form of "/Users/allison/htdocs/fast-scan-iphone/click-helper.js" & " " & (clickX as text) & " " & (clickY as text)
				delay 0.6

				repeat with attemptNum from 1 to 3
					try
						set ctxMenu to menu 1 of clickOwner
						exit repeat
					on error
						delay 0.4
					end try
				end repeat

				if ctxMenu is not missing value then exit repeat

				my logStep("No menu at that point after retries, dismissing and trying next candidate")
				try
					do shell script "/usr/bin/osascript -l JavaScript " & quoted form of "/Users/allison/htdocs/fast-scan-iphone/escape-helper.js"
				end try
				delay 0.3
			end repeat

			if ctxMenu is missing value then
				error "Right-click didn't open a menu at any candidate point. This folder's column may have no empty space -- try resizing the Finder window wider, or scroll so there's a visible gap."
			end if
			my logStep("Context menu opened")

			set importItem to menu item "Import from iPhone or iPad" of ctxMenu
			click importItem
			delay 0.6
			my logStep("Opened Import from iPhone or iPad submenu")

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
	end tell

	my logStep("--- run end (success) ---")
on error errMsg number errNum
	my logStep("ERROR " & errNum & ": " & errMsg)
	display dialog "Fast Scan iPhone couldn't complete: " & errMsg buttons {"OK"} default button "OK" with title "Fast Scan iPhone - Error" with icon caution
end try
