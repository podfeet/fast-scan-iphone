// Posts a real right-mouse-button click at the given screen point using
// CoreGraphics directly, bypassing System Events' click abstraction.
// Usage: osascript -l JavaScript click-helper.js <x> <y>
function run(argv) {
	ObjC.import('CoreGraphics')

	var x = parseFloat(argv[0])
	var y = parseFloat(argv[1])
	var point = $.CGPointMake(x, y)

	var down = $.CGEventCreateMouseEvent(null, $.kCGEventRightMouseDown, point, $.kCGMouseButtonRight)
	$.CGEventPost($.kCGHIDEventTap, down)

	delay(0.05)

	var up = $.CGEventCreateMouseEvent(null, $.kCGEventRightMouseUp, point, $.kCGMouseButtonRight)
	$.CGEventPost($.kCGHIDEventTap, up)

	return "posted right click at " + x + "," + y
}
