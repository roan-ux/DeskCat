import AppKit

/// The toy's own little window, centred on the toy. Press to pick it up, drag, let go to throw.
/// While it's in the box it's clipped at the rim, like the cat.
final class ToyView: NSView {
    static func size(scale: CGFloat) -> NSSize { NSSize(width: 130 * scale, height: 130 * scale) }

    weak var sim: CatSim?
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func mouseUp(with event: NSEvent) { onRelease?() }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let sim, let kind = sim.toyKind,
              let origin = window?.frame.origin else { return }
        ctx.clear(bounds)
        let t = sim.toy, s = sim.scale
        ctx.saveGState()
        ctx.translateBy(x: -origin.x, y: -origin.y)      // world coordinates from here
        if t.place == .free {                            // contact shadow, fading with height
            let k = clamp01(1 - max(0, t.pos.y - sim.toyRadius - sim.floorY) / 160)
            drawGroundShadow(ctx, center: CGPoint(x: t.pos.x, y: sim.floorY + 1), rx: sim.toyRadius * 1.1 * (0.6 + 0.4 * k), ry: 3 * s, alpha: 0.22 * k)
        }
        if t.place == .box {
            ctx.setAlpha(clamp01((sim.boxShow.x - 0.5) * 3))
            ctx.clip(to: CGRect(x: -100_000, y: sim.box.y + sim.boxRim, width: 200_000, height: 100_000))
        }
        ctx.translateBy(x: t.pos.x, y: t.pos.y)
        ctx.rotate(by: t.angle)
        ctx.scaleBy(x: t.facing * s, y: s)
        ToyArt.draw(kind, in: ctx)
        ctx.restoreGState()
    }
}
