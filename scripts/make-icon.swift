// Draws the Clew app icon (a ball of thread) and writes the macOS icon set. Clew Testnet's is
// orange instead of pink, like its testnet badge.
// Usage: swift scripts/make-icon.swift Clew/Assets.xcassets/AppIcon.appiconset
//        swift scripts/make-icon.swift Clew/Assets.xcassets/AppIconTestnet.appiconset testnet
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let testnet = CommandLine.arguments.dropFirst(2).first == "testnet"
// thread, ball highlight, ball shade, wraps, outline
let palette: (UInt32, UInt32, UInt32, UInt32, UInt32) = testnet
    ? (0xFFC069, 0xFFF1D6, 0xFFB547, 0xC9741A, 0x7A4310)
    : (0xFF8DBE, 0xFFE6F0, 0xFF94C2, 0xD42F78, 0x7A1242)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(size: Int) -> Data {
    let s = CGFloat(size) / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)

    // Tile with the standard macOS margin and a soft shadow.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.3))
    ctx.addPath(tile); ctx.setFillColor(color(0x3A3C41)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    let background = CGGradient(colorsSpace: nil, colors: [color(0x63666E), color(0x232528)] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
    ctx.restoreGState()

    // Thread trailing off the ball.
    let thread = CGMutablePath()
    thread.move(to: CGPoint(x: 640, y: 380))
    thread.addCurve(to: CGPoint(x: 790, y: 300), control1: CGPoint(x: 700, y: 300), control2: CGPoint(x: 740, y: 360))
    thread.addCurve(to: CGPoint(x: 760, y: 200), control1: CGPoint(x: 840, y: 240), control2: CGPoint(x: 800, y: 190))
    ctx.addPath(thread)
    ctx.setStrokeColor(color(palette.0)); ctx.setLineWidth(22); ctx.setLineCap(.round)
    ctx.strokePath()

    // The ball.
    let center = CGPoint(x: 470, y: 540), radius: CGFloat = 235
    let ball = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                        width: radius * 2, height: radius * 2), transform: nil)
    ctx.saveGState()
    ctx.addPath(ball); ctx.clip()
    let shade = CGGradient(colorsSpace: nil, colors: [color(palette.1), color(palette.2)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(shade, startCenter: CGPoint(x: center.x - 80, y: center.y + 90), startRadius: 0,
                           endCenter: center, endRadius: radius, options: .drawsAfterEndLocation)

    // Wraps of thread around the ball.
    ctx.setStrokeColor(color(palette.3, 0.85)); ctx.setLineWidth(16)
    for (angle, width, offset) in [(-0.55, 1.15, -40.0), (0.35, 1.0, 30.0), (1.2, 1.25, 0.0), (-1.3, 0.75, 60.0)] {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        let w = radius * 2 * width, h = radius * 0.95
        ctx.strokeEllipse(in: CGRect(x: -w / 2, y: -h / 2 + offset, width: w, height: h))
        ctx.restoreGState()
    }
    ctx.restoreGState()
    ctx.addPath(ball); ctx.setStrokeColor(color(palette.4, 0.4)); ctx.setLineWidth(6); ctx.strokePath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try drawIcon(size: points * scale).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
print("Wrote icon set to \(output.path)")
