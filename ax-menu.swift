// Drives Finder's already-open context menu straight through the
// Accessibility API. scan-from-iphone.applescript can't always reach that
// menu by walking down from the window through System Events: when a column
// is grouped ("Use Groups") or is the Desktop folder, the column's scroll
// area exposes no children at all, so there's no element to ask for
// "menu 1 of ...". The popup is still a real on-screen window though, and
// hit-testing a screen position finds it however the tree is (or isn't)
// wired up.
//
// Usage:
//   ax-menu import-scan <x> <y>   In the context menu open at screen point
//                                 x,y, choose Import from iPhone > Scan
//                                 Documents
//   ax-menu probe <x> <y>         Describe the accessibility element at x,y
//   ax-menu selftest              Check the item-picking logic (touches no UI)
//
// Everything is logged to stdout; the last line is always "RESULT ...".

import ApplicationServices
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

func say(_ message: String) {
	print(message)
}

func finish(_ result: String) -> Never {
	print("RESULT " + result)
	exit(0)
}

// MARK: - Accessibility helpers

let systemWide = AXUIElementCreateSystemWide()
// A busy Finder shouldn't be able to stall the whole scan for the default
// six seconds per query.
_ = AXUIElementSetMessagingTimeout(systemWide, 2.0)

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
	var value: CFTypeRef?
	guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
	return value
}

func string(_ element: AXUIElement, _ name: String) -> String {
	return attribute(element, name) as? String ?? ""
}

func children(of element: AXUIElement) -> [AXUIElement] {
	return attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func elementValue(_ value: CFTypeRef?) -> AXUIElement? {
	guard let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
	return (value as! AXUIElement)
}

func parent(of element: AXUIElement) -> AXUIElement? {
	return elementValue(attribute(element, kAXParentAttribute))
}

func pid(of element: AXUIElement) -> pid_t {
	var pid: pid_t = 0
	AXUIElementGetPid(element, &pid)
	return pid
}

// A menu item's visible text normally lives in AXTitle; fall back to
// AXDescription in case a menu vends it that way instead.
func label(of element: AXUIElement) -> String {
	for name in [kAXTitleAttribute, kAXDescriptionAttribute] {
		let text = string(element, name)
		if !text.isEmpty { return text }
	}
	return ""
}

func isEnabled(_ element: AXUIElement) -> Bool {
	return (attribute(element, kAXEnabledAttribute) as? NSNumber)?.boolValue ?? true
}

func describe(_ element: AXUIElement) -> String {
	let owner = pid(of: element)
	let app = NSRunningApplication(processIdentifier: owner)?.localizedName ?? "pid \(owner)"
	return "\(string(element, kAXRoleAttribute)) \"\(label(of: element))\" [\(app)]"
}

func element(atX x: Double, y: Double) -> AXUIElement? {
	var hit: AXUIElement?
	guard AXUIElementCopyElementAtPosition(systemWide, Float(x), Float(y), &hit) == .success else { return nil }
	return hit
}

// The menu that `element` is, or sits inside. A menu item's parent is its
// menu, so a couple of levels is plenty.
func enclosingMenu(of element: AXUIElement) -> AXUIElement? {
	var current: AXUIElement? = element
	for _ in 0..<3 {
		guard let candidate = current else { return nil }
		if string(candidate, kAXRoleAttribute) == kAXMenuRole { return candidate }
		current = parent(of: candidate)
	}
	return nil
}

func cancel(_ menu: AXUIElement) {
	_ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
}

// MARK: - Finding the open menu

// Screen offsets from the click to sample, nearest first. A context menu's
// top-left corner lands on the click unless it would run off the screen, in
// which case macOS slides it up and/or over to fit -- so rather than assume
// where it went, look on both sides of the click and above and below it.
func sampleOffsets() -> [(dx: Double, dy: Double)] {
	var offsets: [(dx: Double, dy: Double)] = []
	var step = 14.0
	while step <= 560 {
		for dx in [40.0, -40.0, 130.0] {
			offsets.append((dx, step))
			offsets.append((dx, -step))
		}
		step += 26
	}
	return offsets
}

func menuByHitTest(x: Double, y: Double, finder: pid_t) -> AXUIElement? {
	for offset in sampleOffsets() {
		guard let hit = element(atX: x + offset.dx, y: y + offset.dy),
			pid(of: hit) == finder,
			let menu = enclosingMenu(of: hit) else { continue }
		return menu
	}
	return nil
}

// Two cheaper ways to spot the menu if the hit test somehow misses it.
func menuByFocus(_ finderApp: AXUIElement) -> AXUIElement? {
	guard let focused = elementValue(attribute(finderApp, kAXFocusedUIElementAttribute)) else { return nil }
	return enclosingMenu(of: focused)
}

func menuByAppChildren(_ finderApp: AXUIElement) -> AXUIElement? {
	return children(of: finderApp).first { string($0, kAXRoleAttribute) == kAXMenuRole }
}

func waitForMenu(x: Double, y: Double, finder: pid_t) -> AXUIElement? {
	let finderApp = AXUIElementCreateApplication(finder)
	for pass in 1...5 {
		if let menu = menuByHitTest(x: x, y: y, finder: finder) {
			say("  found the menu by hit test (pass \(pass))")
			return menu
		}
		if let menu = menuByFocus(finderApp) {
			say("  found the menu via Finder's focused element (pass \(pass))")
			return menu
		}
		if let menu = menuByAppChildren(finderApp) {
			say("  found the menu among Finder's direct children (pass \(pass))")
			return menu
		}
		Thread.sleep(forTimeInterval: 0.3)
	}
	return nil
}

// When no menu turns up, say what IS at a few spots around the click, so the
// log shows whether the hit test sees the popup at all.
func reportSurroundings(x: Double, y: Double) {
	say("  nothing menu-like near the click; what's around it:")
	for offset in [(0.0, 0.0), (40.0, 14.0), (40.0, 120.0), (-40.0, 14.0), (40.0, -120.0)] {
		if let hit = element(atX: x + offset.0, y: y + offset.1) {
			say("    at (\(Int(x + offset.0)), \(Int(y + offset.1))): \(describe(hit))")
		} else {
			say("    at (\(Int(x + offset.0)), \(Int(y + offset.1))): no accessibility element")
		}
	}
}

// MARK: - Choosing the menu items

struct MenuItem {
	let element: AXUIElement
	let title: String
	let enabled: Bool
}

func menuItems(_ menu: AXUIElement) -> [MenuItem] {
	return children(of: menu).map { MenuItem(element: $0, title: label(of: $0), enabled: isEnabled($0)) }
}

func summary(_ items: [MenuItem]) -> String {
	return items.map { ($0.title.isEmpty ? "-" : $0.title) + ($0.enabled ? "" : " (disabled)") }.joined(separator: ", ")
}

// The import submenu is a flat list: a disabled header row naming each
// device, then that device's Take Photo / Scan Documents / Add Sketch rows,
// then a separator. Take the Scan Documents row that follows the first
// header mentioning "iPhone", and give up if another device's header turns
// up first -- so it structurally can't land on an iPad's entry.
func scanDocumentsIndex(titles: [String], enabled: [Bool]) -> Int? {
	var inIPhoneSection = false
	for (index, title) in titles.enumerated() {
		if !inIPhoneSection {
			if title.contains("iPhone") { inIPhoneSection = true }
		} else {
			if !enabled[index] && !title.isEmpty { return nil }
			if title == "Scan Documents" { return index }
		}
	}
	return nil
}

func importScan(x: Double, y: Double) -> Never {
	guard AXIsProcessTrusted() else {
		finish("FAIL this process has no Accessibility access (grant it to FastScan)")
	}
	guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier else {
		finish("FAIL Finder isn't running")
	}

	guard let menu = waitForMenu(x: x, y: y, finder: finder) else {
		reportSurroundings(x: x, y: y)
		finish("NOMENU")
	}
	let items = menuItems(menu)
	say("  menu items: " + summary(items))

	guard let importItem = items.first(where: { $0.title.hasPrefix("Import from iPhone") && $0.enabled }) else {
		cancel(menu)
		// Say which kind of menu this was, because the fix differs. A
		// folder's own menu always has "New Folder" (a file's or folder's
		// item menu never does), so a folder menu with no Import item means
		// the iPhone isn't reachable, while an item menu means the click
		// landed on a row because there was no empty space to click.
		if items.isEmpty { finish("NOIMPORT unknown menu") }
		finish(items.contains { $0.title == "New Folder" } ? "NOIMPORT folder menu" : "NOIMPORT item menu")
	}
	say("  pressing \"\(importItem.title)\"")
	guard AXUIElementPerformAction(importItem.element, kAXPressAction as CFString) == .success else {
		cancel(menu)
		finish("FAIL couldn't press \"\(importItem.title)\"")
	}

	// The device list can take a moment to fill in, so keep looking until
	// the iPhone's Scan Documents row shows up.
	var submenuItems: [MenuItem] = []
	var scanIndex: Int?
	for _ in 1...12 {
		Thread.sleep(forTimeInterval: 0.25)
		guard let submenu = children(of: importItem.element).first(where: { string($0, kAXRoleAttribute) == kAXMenuRole }) else { continue }
		submenuItems = menuItems(submenu)
		scanIndex = scanDocumentsIndex(titles: submenuItems.map { $0.title }, enabled: submenuItems.map { $0.enabled })
		if scanIndex != nil { break }
	}
	say("  import submenu items: " + (submenuItems.isEmpty ? "(none appeared)" : summary(submenuItems)))

	guard let index = scanIndex else {
		cancel(menu)
		finish("NOSCAN")
	}
	say("  pressing \"Scan Documents\" (item \(index + 1) of the submenu)")
	let pressed = AXUIElementPerformAction(submenuItems[index].element, kAXPressAction as CFString)
	switch pressed {
	case .success:
		finish("OK")
	case .cannotComplete:
		// Choosing the item hands off to Continuity Camera, so Finder may
		// not answer the press before our timeout even though it worked.
		finish("OK the press timed out, but Finder likely dispatched it")
	default:
		cancel(menu)
		finish("FAIL pressing Scan Documents returned AXError \(pressed.rawValue)")
	}
}

func probe(x: Double, y: Double) -> Never {
	guard AXIsProcessTrusted() else {
		finish("FAIL this process has no Accessibility access (grant it to FastScan)")
	}
	guard var current = element(atX: x, y: y) else {
		finish("NONE nothing at (\(Int(x)), \(Int(y)))")
	}
	var chain = [describe(current)]
	for _ in 0..<5 {
		guard let next = parent(of: current) else { break }
		chain.append(describe(next))
		current = next
	}
	say("  under (\(Int(x)), \(Int(y))): " + chain.joined(separator: "  <-  "))
	finish("OK")
}

// MARK: - Self test (pure logic, touches no UI)

func selfTest() -> Never {
	var failures = 0
	func check(_ name: String, _ titles: [String], _ enabled: [Bool], expecting expected: Int?) {
		let got = scanDocumentsIndex(titles: titles, enabled: enabled)
		if got != expected {
			failures += 1
			say("FAIL \(name): expected \(String(describing: expected)), got \(String(describing: got))")
		} else {
			say("ok   \(name)")
		}
	}

	let device = ["Take Photo", "Scan Documents", "Add Sketch"]
	let deviceEnabled = [true, true, true]
	let iPhone = ["Al iPhone 17 Pro"] + device
	let iPad = ["Al M4 iPad Pro"] + device
	let headerEnabled = [false] + deviceEnabled

	check("iPhone listed first, then iPad",
		iPhone + [""] + iPad, headerEnabled + [false] + headerEnabled, expecting: 2)
	check("iPad listed first, then iPhone",
		iPad + [""] + iPhone, headerEnabled + [false] + headerEnabled, expecting: 7)
	check("iPhone only", iPhone, headerEnabled, expecting: 2)
	check("iPad only", iPad, headerEnabled, expecting: nil)
	check("iPhone header but no Scan Documents", ["Al iPhone 17 Pro", "Take Photo", "Add Sketch"], [false, true, true], expecting: nil)
	check("another device's header comes before the Scan row",
		["Al iPhone 17 Pro", "Take Photo", "Al M4 iPad Pro", "Scan Documents"], [false, true, false, true], expecting: nil)
	check("empty submenu", [], [], expecting: nil)

	finish(failures == 0 ? "OK selftest passed" : "FAIL \(failures) selftest check(s) failed")
}

// MARK: - Entry point

func coordinate(_ text: String) -> Double? {
	return Double(text.replacingOccurrences(of: ",", with: "."))
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
	finish("FAIL usage: ax-menu import-scan|probe <x> <y>  |  ax-menu selftest")
}

switch arguments[1] {
case "selftest":
	selfTest()
case "import-scan", "probe":
	guard arguments.count >= 4, let x = coordinate(arguments[2]), let y = coordinate(arguments[3]) else {
		finish("FAIL \(arguments[1]) needs numeric x and y")
	}
	if arguments[1] == "probe" { probe(x: x, y: y) }
	importScan(x: x, y: y)
default:
	finish("FAIL unknown command \"\(arguments[1])\"")
}
