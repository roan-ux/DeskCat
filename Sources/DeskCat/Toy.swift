import AppKit

/// The cat's toy. One at a time, picked from the menu or Settings. It lives in the box with the
/// cat; drag it out to tease the cat, throw it and the cat goes after it.
enum ToyKind: String, CaseIterable {
    case shark, miniShark, mouse, bird, plushCat

    var title: String {
        switch self {
        case .shark: return "Plush shark"
        case .miniShark: return "Little shark"
        case .mouse: return "Mouse"
        case .bird: return "Bird"
        case .plushCat: return "Plush cat"
        }
    }

    /// Collision radius in base (medium-size) units; the drawing is about twice this wide.
    var radius: CGFloat {
        switch self {
        case .shark: return 21
        case .miniShark: return 14
        case .mouse: return 12
        case .bird: return 12
        case .plushCat: return 16
        }
    }

    /// What it sounds like when it's grabbed, batted or caught.
    var sound: CatSound {
        switch self {
        case .mouse, .miniShark: return .squeak
        case .shark, .plushCat: return .plush
        case .bird: return .bell
        }
    }

    /// Round toys roll along the floor; flat ones slide.
    var rolls: Bool { self == .bird || self == .plushCat }
}

enum ToyPlace { case box, held, free, carried }

struct ToyState {
    var pos = CGPoint.zero
    var vx: CGFloat = 0, vy: CGFloat = 0
    var angle: CGFloat = 0, spin: CGFloat = 0
    var place = ToyPlace.box
    /// Pointer offset while you hold it, so it doesn't jump to the pointer.
    var grab = CGVector.zero
    var facing: CGFloat = 1
}

// MARK: - Drawing

/// Draws a toy centred on (0, 0), facing right, in base units (the caller scales and rotates).
enum ToyArt {
    private static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }

    static func draw(_ kind: ToyKind, in ctx: CGContext) {
        switch kind {
        case .shark: shark(ctx, top: rgb(0x6F8FA9), fin: rgb(0x5A7790), size: 1)
        case .miniShark: shark(ctx, top: rgb(0x8CC6EA), fin: rgb(0x6FADD6), size: 0.66)
        case .mouse: mouse(ctx)
        case .bird: bird(ctx)
        case .plushCat: plushCat(ctx)
        }
    }

    private static func shape(_ ctx: CGContext, _ fill: CGColor, _ stroke: CGColor? = nil, _ build: (CGMutablePath) -> Void) {
        let path = CGMutablePath()
        build(path)
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
        if let stroke {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(1.2)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
    }

    private static func dot(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: CGColor) {
        ctx.setFillColor(c)
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    private static func line(_ ctx: CGContext, _ pts: [CGPoint], _ c: CGColor, _ w: CGFloat) {
        ctx.setStrokeColor(c)
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addLines(between: pts)
        ctx.strokePath()
    }

    /// A soft plush shark: chubby body, white belly, stubby fins, a little smile.
    private static func shark(_ ctx: CGContext, top: CGColor, fin: CGColor, size k: CGFloat) {
        ctx.saveGState()
        ctx.scaleBy(x: k, y: k)
        let edge = rgb(0x2F3E4C, 0.55), belly = rgb(0xF4F1EA)
        // tail fin
        shape(ctx, fin, edge) { p in
            p.move(to: CGPoint(x: -18, y: 0))
            p.addQuadCurve(to: CGPoint(x: -31, y: 12), control: CGPoint(x: -24, y: 3))
            p.addQuadCurve(to: CGPoint(x: -27, y: 0), control: CGPoint(x: -26, y: 6))
            p.addQuadCurve(to: CGPoint(x: -30, y: -10), control: CGPoint(x: -26, y: -5))
            p.addQuadCurve(to: CGPoint(x: -18, y: -2), control: CGPoint(x: -23, y: -3))
            p.closeSubpath()
        }
        // dorsal fin
        shape(ctx, fin, edge) { p in
            p.move(to: CGPoint(x: -4, y: 9))
            p.addQuadCurve(to: CGPoint(x: 1, y: 19), control: CGPoint(x: -3, y: 16))
            p.addQuadCurve(to: CGPoint(x: 8, y: 9), control: CGPoint(x: 6, y: 13))
            p.closeSubpath()
        }
        // body
        shape(ctx, top, edge) { p in
            p.move(to: CGPoint(x: 24, y: 1))
            p.addCurve(to: CGPoint(x: -20, y: 2), control1: CGPoint(x: 20, y: 14), control2: CGPoint(x: -8, y: 13))
            p.addCurve(to: CGPoint(x: 24, y: 1), control1: CGPoint(x: -8, y: -12), control2: CGPoint(x: 20, y: -12))
            p.closeSubpath()
        }
        // belly
        shape(ctx, belly) { p in
            p.move(to: CGPoint(x: 22, y: -2))
            p.addCurve(to: CGPoint(x: -14, y: -3), control1: CGPoint(x: 14, y: -11), control2: CGPoint(x: -6, y: -10))
            p.addCurve(to: CGPoint(x: 22, y: -2), control1: CGPoint(x: -2, y: -3), control2: CGPoint(x: 14, y: -1))
            p.closeSubpath()
        }
        // pectoral fin
        shape(ctx, fin, edge) { p in
            p.move(to: CGPoint(x: 4, y: -3))
            p.addQuadCurve(to: CGPoint(x: -3, y: -12), control: CGPoint(x: 0, y: -10))
            p.addQuadCurve(to: CGPoint(x: 9, y: -4), control: CGPoint(x: 6, y: -7))
            p.closeSubpath()
        }
        dot(ctx, 14, 3, 1.9, rgb(0x1E2328))
        dot(ctx, 14.6, 3.7, 0.6, rgb(0xFFFFFF))
        line(ctx, [CGPoint(x: 17, y: -3), CGPoint(x: 19.5, y: -4.2), CGPoint(x: 22, y: -3)], rgb(0x1E2328, 0.8), 1)
        for gx: CGFloat in [7, 9.5] { line(ctx, [CGPoint(x: gx, y: 4), CGPoint(x: gx - 1, y: 0)], edge, 0.9) }
        dot(ctx, 17, -1, 1.8, rgb(0xF59AA8, 0.6))   // blush
        ctx.restoreGState()
    }

    /// A felt mouse: teardrop body, big pink ears, string tail.
    private static func mouse(_ ctx: CGContext) {
        let body = rgb(0x9C9AA3), edge = rgb(0x4A4850, 0.55), pink = rgb(0xF4A3B4)
        line(ctx, [CGPoint(x: -11, y: -2), CGPoint(x: -17, y: 2), CGPoint(x: -22, y: -3), CGPoint(x: -26, y: 1)], rgb(0xD98C9C), 1.6)
        shape(ctx, body, edge) { p in
            p.move(to: CGPoint(x: 14, y: -3))
            p.addCurve(to: CGPoint(x: -12, y: -5), control1: CGPoint(x: 8, y: 12), control2: CGPoint(x: -14, y: 10))
            p.addQuadCurve(to: CGPoint(x: 14, y: -3), control: CGPoint(x: 0, y: -8))
            p.closeSubpath()
        }
        dot(ctx, 3, 8, 5, body)
        dot(ctx, 3, 8, 3.2, pink)
        dot(ctx, 14.5, -2.5, 1.8, pink)
        dot(ctx, 8.5, 1.5, 1.4, rgb(0x1E2328))
        for dy: CGFloat in [-1, 1] {
            line(ctx, [CGPoint(x: 13, y: -2), CGPoint(x: 19, y: -2 + dy * 2.5)], rgb(0x4A4850, 0.5), 0.6)
        }
    }

    /// A round feather-toy bird: yellow body, orange beak, bright tail feathers.
    private static func bird(_ ctx: CGContext) {
        let edge = rgb(0x6B4E12, 0.5)
        for (i, c) in [rgb(0xE5484D), rgb(0x3E8EDE), rgb(0x46B36B)].enumerated() {
            let a = CGFloat(i - 1) * 0.35
            ctx.saveGState()
            ctx.translateBy(x: -8, y: 1)
            ctx.rotate(by: .pi + a)
            shape(ctx, c) { p in p.addEllipse(in: CGRect(x: 0, y: -2.6, width: 15, height: 5.2)) }
            ctx.restoreGState()
        }
        shape(ctx, rgb(0xF6C945), edge) { p in p.addEllipse(in: CGRect(x: -11, y: -10, width: 22, height: 20)) }
        shape(ctx, rgb(0xFFE9A6)) { p in p.addEllipse(in: CGRect(x: -6, y: -9, width: 14, height: 9)) }
        shape(ctx, rgb(0xE9A92F), edge) { p in
            p.move(to: CGPoint(x: -6, y: 2))
            p.addQuadCurve(to: CGPoint(x: 5, y: 0), control: CGPoint(x: 0, y: 7))
            p.addQuadCurve(to: CGPoint(x: -6, y: 2), control: CGPoint(x: -1, y: -2))
            p.closeSubpath()
        }
        shape(ctx, rgb(0xF08A24), edge) { p in
            p.move(to: CGPoint(x: 10, y: 3)); p.addLine(to: CGPoint(x: 16, y: 1)); p.addLine(to: CGPoint(x: 10, y: -1)); p.closeSubpath()
        }
        dot(ctx, 5.5, 4, 1.6, rgb(0x1E2328))
        dot(ctx, 6, 4.6, 0.5, rgb(0xFFFFFF))
    }

    /// A small orange plush cat with stitched eyes and stripes.
    private static func plushCat(_ ctx: CGContext) {
        let fur = rgb(0xF2A04E), edge = rgb(0x7A4A18, 0.55), stripe = rgb(0xD97E2B)
        line(ctx, [CGPoint(x: -10, y: -6), CGPoint(x: -17, y: -2), CGPoint(x: -18, y: 6)], fur, 4.5)
        shape(ctx, fur, edge) { p in p.addEllipse(in: CGRect(x: -13, y: -12, width: 22, height: 16)) }
        for x: CGFloat in [-7, -2] { line(ctx, [CGPoint(x: x, y: 3), CGPoint(x: x + 1, y: -2)], stripe, 1.6) }
        dot(ctx, -8, -12, 3, fur); dot(ctx, 4, -12, 3, fur)
        // head with ears
        shape(ctx, fur, edge) { p in
            p.move(to: CGPoint(x: 0, y: 8)); p.addLine(to: CGPoint(x: 1, y: 19)); p.addLine(to: CGPoint(x: 7, y: 12))
            p.addLine(to: CGPoint(x: 12, y: 12)); p.addLine(to: CGPoint(x: 17, y: 19)); p.addLine(to: CGPoint(x: 19, y: 8))
            p.addCurve(to: CGPoint(x: 0, y: 8), control1: CGPoint(x: 20, y: -4), control2: CGPoint(x: -1, y: -4))
            p.closeSubpath()
        }
        dot(ctx, 3, 15, 1.5, rgb(0xF6B8C2)); dot(ctx, 16, 15, 1.5, rgb(0xF6B8C2))
        for ex: CGFloat in [5.5, 13] {
            line(ctx, [CGPoint(x: ex - 2, y: 7), CGPoint(x: ex, y: 5.6), CGPoint(x: ex + 2, y: 7)], rgb(0x3A2410), 1.1)
        }
        dot(ctx, 9.3, 3.5, 1.1, rgb(0xE07A8C))
        line(ctx, [CGPoint(x: 6, y: 13), CGPoint(x: 7, y: 10)], stripe, 1.3)
        line(ctx, [CGPoint(x: 12.5, y: 13), CGPoint(x: 11.5, y: 10)], stripe, 1.3)
    }
}
