// Recovers a transparent icon from two renders of the same SVG, one
// composited over white and one over black, then writes the whole .iconset
// from it.
//
// Quick Look (qlmanage -t) is the only SVG renderer available here that
// handles the scan beam's blur filter, but it always composites onto opaque
// white, which is how the icon ended up with white corners. Rendering the
// artwork over white AND over black gets around that: a pixel of true colour
// C and opacity a comes out as W = a*C + (1-a)*255 over white and K = a*C
// over black, so
//     a = 1 - (W - K) / 255        and        C = K / a
// exactly, anti-aliased edges included.
//
// Usage: icon-matte <over-white.png> <over-black.png> <out.iconset> <master.png>

import AppKit
import ImageIO

func fail(_ message: String) -> Never {
	FileHandle.standardError.write(Data((message + "\n").utf8))
	exit(1)
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

// 8-bit RGBA pixels of a PNG, decoded in sRGB. Both inputs are fully opaque,
// so premultiplied and straight alpha are the same thing here.
func pixels(of path: String) -> (width: Int, height: Int, data: [UInt8]) {
	guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
		let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("can't read \(path)") }
	let width = image.width
	let height = image.height
	var data = [UInt8](repeating: 0, count: width * height * 4)
	let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
		guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
			bytesPerRow: width * 4, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		return true
	}
	if !drawn { fail("can't decode \(path)") }
	return (width, height, data)
}

func writePNG(_ image: CGImage, to path: String) {
	guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else {
		fail("can't create \(path)")
	}
	CGImageDestinationAddImage(destination, image, nil)
	if !CGImageDestinationFinalize(destination) { fail("can't write \(path)") }
}

// Straight (non-premultiplied) RGBA bytes -> image.
func image(fromStraightRGBA rgba: [UInt8], size: Int) -> CGImage {
	guard let provider = CGDataProvider(data: Data(rgba) as CFData),
		let made = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4, space: srgb,
			bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil,
			shouldInterpolate: false, intent: .defaultIntent) else { fail("can't build the icon image") }
	return made
}

// Scales down with high-quality interpolation. Callers halve step by step
// (1024 -> 512 -> ...), which keeps small sizes crisper than one big jump.
func scaled(_ source: CGImage, to size: Int) -> CGImage {
	guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
		bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("can't create a \(size)px context") }
	context.interpolationQuality = .high
	context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
	guard let made = context.makeImage() else { fail("can't scale to \(size)px") }
	return made
}

let arguments = CommandLine.arguments
guard arguments.count == 5 else { fail("usage: icon-matte <over-white.png> <over-black.png> <out.iconset> <master.png>") }
let overWhite = pixels(of: arguments[1])
let overBlack = pixels(of: arguments[2])
guard overWhite.width == overBlack.width, overWhite.height == overBlack.height, overWhite.width == overWhite.height else {
	fail("the two renders must be the same square size")
}
let size = overWhite.width

// MARK: - Recover colour and opacity

var recovered = [UInt8](repeating: 0, count: size * size * 4)
for pixel in 0..<(size * size) {
	let p = pixel * 4
	// Average the three channels' differences to smooth out rounding.
	var difference = 0
	for channel in 0..<3 { difference += Int(overWhite.data[p + channel]) - Int(overBlack.data[p + channel]) }
	let alpha = max(0.0, min(1.0, 1.0 - Double(difference) / (3.0 * 255.0)))
	if alpha > 0 {
		for channel in 0..<3 {
			recovered[p + channel] = UInt8(max(0.0, min(255.0, (Double(overBlack.data[p + channel]) / alpha).rounded())))
		}
	}
	recovered[p + 3] = UInt8((alpha * 255.0).rounded())
}

// MARK: - Check: putting it back over white and black must reproduce the inputs

func worstError(over background: Double, against original: [UInt8]) -> Int {
	var worst = 0
	for pixel in 0..<(size * size) {
		let p = pixel * 4
		let alpha = Double(recovered[p + 3]) / 255.0
		for channel in 0..<3 {
			let composite = alpha * Double(recovered[p + channel]) + (1.0 - alpha) * background
			worst = max(worst, abs(Int(composite.rounded()) - Int(original[p + channel])))
		}
	}
	return worst
}

let errorOverWhite = worstError(over: 255, against: overWhite.data)
let errorOverBlack = worstError(over: 0, against: overBlack.data)
let corner = [0, (size - 1) * 4, (size * (size - 1)) * 4, (size * size - 1) * 4].map { recovered[$0 + 3] }
var partial = 0
for pixel in 0..<(size * size) where recovered[pixel * 4 + 3] > 0 && recovered[pixel * 4 + 3] < 255 { partial += 1 }
print("recovered \(size)x\(size): corner alpha \(corner), \(partial) anti-aliased edge pixels")
print("re-composited over white: worst error \(errorOverWhite)/255; over black: \(errorOverBlack)/255")
if errorOverWhite > 3 || errorOverBlack > 3 { fail("the recovered icon doesn't reproduce the renders; refusing to write it") }

// MARK: - Write the master and the iconset

var current = image(fromStraightRGBA: recovered, size: size)
writePNG(current, to: arguments[4])

let iconset = arguments[3]
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
// Each pixel size and the iconset file name(s) that use it.
let names: [Int: [String]] = [
	1024: ["icon_512x512@2x"],
	512: ["icon_512x512", "icon_256x256@2x"],
	256: ["icon_256x256", "icon_128x128@2x"],
	128: ["icon_128x128"],
	64: ["icon_32x32@2x"],
	32: ["icon_32x32", "icon_16x16@2x"],
	16: ["icon_16x16"],
]
guard size == 1024 else { fail("expected 1024px renders, got \(size)px") }
for pixelSize in [1024, 512, 256, 128, 64, 32, 16] {
	if pixelSize != 1024 { current = scaled(current, to: pixelSize) }
	for name in names[pixelSize] ?? [] { writePNG(current, to: "\(iconset)/\(name).png") }
}
print("wrote \(arguments[4]) and \(iconset)")
