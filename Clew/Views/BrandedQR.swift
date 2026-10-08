import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// QR code with round dots, soft corner markers and the yarn ball in the middle.
///
/// Uses the highest error correction level (H, recovers up to ~30% damage) so the logo, which
/// covers about 5% of the code, never stops it scanning.
enum BrandedQR {
    static func image(for text: String, size: CGFloat = 640) -> NSImage? {
        guard !text.isEmpty, let modules = modules(for: text) else { return nil }
        let n = modules.count
        let quiet = 3                                      // white margin, in modules
        let unit = size / CGFloat(n + quiet * 2)
        guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        let ink = CGColor(srgbRed: 0.118, green: 0.122, blue: 0.137, alpha: 1)   // graphite
        let pink = CGColor(srgbRed: 0.800, green: 0.180, blue: 0.455, alpha: 1)
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // Module (row, column) → rectangle, with row 0 at the top.
        func rect(_ row: Int, _ col: Int, span: Int = 1) -> CGRect {
            CGRect(x: CGFloat(quiet + col) * unit, y: size - CGFloat(quiet + row + span) * unit,
                   width: CGFloat(span) * unit, height: CGFloat(span) * unit)
        }

        let finders = [(0, 0), (0, n - 7), (n - 7, 0)]
        func inFinder(_ r: Int, _ c: Int) -> Bool {
            finders.contains { r >= $0.0 && r < $0.0 + 7 && c >= $0.1 && c < $0.1 + 7 }
        }
        var logo = Int((Double(n) * 0.22).rounded())
        if logo % 2 == 0 { logo += 1 }
        let logoStart = (n - logo) / 2
        func inLogo(_ r: Int, _ c: Int) -> Bool {
            (logoStart..<logoStart + logo).contains(r) && (logoStart..<logoStart + logo).contains(c)
        }

        // Data dots.
        ctx.setFillColor(ink)
        for r in 0..<n {
            for c in 0..<n where modules[r][c] && !inFinder(r, c) && !inLogo(r, c) {
                ctx.fillEllipse(in: rect(r, c).insetBy(dx: unit * 0.06, dy: unit * 0.06))
            }
        }

        // Corner markers: a rounded ring with a pink rounded centre.
        for (r, c) in finders {
            let outer = rect(r, c, span: 7)
            ctx.addPath(CGPath(roundedRect: outer.insetBy(dx: unit / 2, dy: unit / 2),
                               cornerWidth: unit * 1.8, cornerHeight: unit * 1.8, transform: nil))
            ctx.setStrokeColor(ink)
            ctx.setLineWidth(unit)
            ctx.strokePath()
            ctx.addPath(CGPath(roundedRect: rect(r + 2, c + 2, span: 3), cornerWidth: unit,
                               cornerHeight: unit, transform: nil))
            ctx.setFillColor(pink)
            ctx.fillPath()
        }

        // The yarn ball on a white tile in the middle.
        let tile = rect(logoStart, logoStart, span: logo)
        YarnBall.draw(in: ctx, rect: tile.insetBy(dx: unit * 0.4, dy: unit * 0.4), withThread: false)

        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }

    /// The QR grid as rows of on/off modules, without the generator's margin.
    private static func modules(for text: String) -> [[Bool]]? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 255, count: w * h)
        guard let gray = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        gray.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let dark = { (x: Int, y: Int) in pixels[y * w + x] < 128 }

        // Trim the white margin the generator adds.
        let rows = (0..<h).filter { y in (0..<w).contains { dark($0, y) } }
        let cols = (0..<w).filter { x in (0..<h).contains { dark(x, $0) } }
        guard let top = rows.first, let bottom = rows.last, let left = cols.first, let right = cols.last,
              bottom - top == right - left else { return nil }
        return (top...bottom).map { y in (left...right).map { x in dark(x, y) } }
    }
}
