// Posts a real Escape key press via CoreGraphics, to reliably dismiss an
// open menu (System Events' "key code 53" doesn't reliably reach menus
// opened via synthetic clicks).
// Usage: osascript -l JavaScript escape-helper.js
function run(argv) {
	ObjC.import('CoreGraphics')

	var down = $.CGEventCreateKeyboardEvent(null, 53, true)
	$.CGEventPost($.kCGHIDEventTap, down)

	delay(0.05)

	var up = $.CGEventCreateKeyboardEvent(null, 53, false)
	$.CGEventPost($.kCGHIDEventTap, up)

	return "escape sent"
}
