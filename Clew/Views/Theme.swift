import SwiftUI

/// Graphite surfaces with pink accents, matching the app icon. Clew is always dark.
enum Theme {
    static let background = Color(red: 0.122, green: 0.122, blue: 0.129)   // #1F1F21
    static let surface = Color(red: 0.169, green: 0.169, blue: 0.180)      // #2B2B2E
    static let cardTop = Color(red: 0.91, green: 0.31, blue: 0.56)
    static let cardBottom = Color(red: 0.56, green: 0.08, blue: 0.31)
    // TARI (Ootle) card: violet, so it can't be mistaken for the XTM card at a glance.
    static let tariCardTop = Color(red: 0.55, green: 0.36, blue: 0.90)
    static let tariCardBottom = Color(red: 0.28, green: 0.12, blue: 0.56)
}

/// The window background: graphite with a faint pink glow from the top.
struct GraphiteBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Color.accentColor.opacity(0.10), .clear],
                           center: .top, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

/// Fades and blurs a screen in or out, used when Clew locks and unlocks.
struct BlurFade: ViewModifier {
    let amount: Double  // 0 = fully shown, 1 = gone
    func body(content: Content) -> some View {
        content
            .blur(radius: 14 * amount)
            .opacity(1 - amount)
            .scaleEffect(1 - 0.03 * amount)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(amount: 1), identity: BlurFade(amount: 0))
    }
}

/// The ball of thread from the app icon, drawn with Core Graphics so SwiftUI views and the
/// QR code renderer share one drawing.
enum YarnBall {
    static func draw(in ctx: CGContext, rect: CGRect, withThread: Bool = true) {
        let size = min(rect.width, rect.height)
        // The icon's ball sits in a 1024 canvas at (470, 540) with radius 235; scale that down.
        let scale = size / 600
        let center = CGPoint(x: rect.midX - 20 * scale, y: rect.midY + 20 * scale)
        let radius = 235 * scale
        let pink = CGColor(srgbRed: 1, green: 0.553, blue: 0.745, alpha: 1)

        if withThread {
            let thread = CGMutablePath()
            thread.move(to: CGPoint(x: center.x + 170 * scale, y: center.y - 160 * scale))
            thread.addCurve(to: CGPoint(x: center.x + 320 * scale, y: center.y - 240 * scale),
                            control1: CGPoint(x: center.x + 230 * scale, y: center.y - 240 * scale),
                            control2: CGPoint(x: center.x + 270 * scale, y: center.y - 180 * scale))
            ctx.addPath(thread)
            ctx.setStrokeColor(pink)
            ctx.setLineWidth(22 * scale)
            ctx.setLineCap(.round)
            ctx.strokePath()
        }

        let ball = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                            width: radius * 2, height: radius * 2), transform: nil)
        ctx.saveGState()
        ctx.addPath(ball)
        ctx.clip()
        let shade = CGGradient(colorsSpace: nil, colors: [
            CGColor(srgbRed: 1, green: 0.902, blue: 0.941, alpha: 1),
            CGColor(srgbRed: 1, green: 0.580, blue: 0.761, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(shade, startCenter: CGPoint(x: center.x - 80 * scale, y: center.y + 90 * scale),
                               startRadius: 0, endCenter: center, endRadius: radius,
                               options: .drawsAfterEndLocation)
        ctx.setStrokeColor(CGColor(srgbRed: 0.831, green: 0.184, blue: 0.471, alpha: 0.85))
        ctx.setLineWidth(16 * scale)
        for (angle, width, offset) in [(-0.55, 1.15, -40.0), (0.35, 1.0, 30.0), (1.2, 1.25, 0.0), (-1.3, 0.75, 60.0)] {
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: angle)
            let w = radius * 2 * width, h = radius * 0.95
            ctx.strokeEllipse(in: CGRect(x: -w / 2, y: -h / 2 + offset * scale, width: w, height: h))
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}

/// SwiftUI wrapper around the yarn ball drawing.
struct YarnBallView: View {
    var body: some View {
        Canvas { context, size in
            context.withCGContext { ctx in
                // SwiftUI's canvas has y pointing down; the drawing expects Core Graphics' y-up.
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
                YarnBall.draw(in: ctx, rect: CGRect(origin: .zero, size: size))
            }
        }
    }
}

/// Faint threads across the balance card, with a ball of yarn peeking in at the top right.
struct YarnPattern: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let thread = GraphicsContext.Shading.color(.white.opacity(0.10))
            for i in 0..<5 {
                let y = h * (0.25 + 0.16 * Double(i))
                let swing = h * (i.isMultiple(of: 2) ? 0.22 : -0.18)
                var path = Path()
                path.move(to: CGPoint(x: -20, y: y))
                path.addCurve(to: CGPoint(x: w + 20, y: y - swing * 0.5),
                              control1: CGPoint(x: w * 0.3, y: y + swing),
                              control2: CGPoint(x: w * 0.65, y: y - swing))
                context.stroke(path, with: thread, lineWidth: 1.2)
            }
            let ball = CGPoint(x: w * 0.92, y: h * 0.08)
            for (angle, stretch) in [(0.4, 1.0), (-0.5, 0.8), (1.3, 0.65)] {
                var ring = context
                ring.translateBy(x: ball.x, y: ball.y)
                ring.rotate(by: .radians(angle))
                let r = h * 0.75
                ring.stroke(Path(ellipseIn: CGRect(x: -r, y: -r * stretch, width: r * 2, height: r * 2 * stretch)),
                            with: .color(.white.opacity(0.09)), lineWidth: 1.4)
            }
        }
        .allowsHitTesting(false)
    }
}
