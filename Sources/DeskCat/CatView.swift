import AppKit

/// Draws the cat. The window follows the cat around; the simulation works in screen
/// coordinates, so drawing just shifts by the window's origin.
final class CatView: NSView {
    static func size(scale: CGFloat) -> NSSize { NSSize(width: 300 * scale, height: 330 * scale) }
    /// Where the cat's root sits inside the view: the ground under its body, or the scruff while
    /// it's held or climbing. There's room below for the body and tail to hang from the scruff.
    static func anchor(scale: CGFloat) -> CGPoint { CGPoint(x: 150 * scale, y: 155 * scale) }

    weak var sim: CatSim?
    var onPress: (() -> Void)?
    var onDrag: (() -> Void)?
    var onRelease: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func mouseDragged(with event: NSEvent) { onDrag?() }
    override func mouseUp(with event: NSEvent) { onRelease?() }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let sim, let origin = window?.frame.origin else { return }
        ctx.clear(bounds)
        ctx.saveGState()
        ctx.translateBy(x: -origin.x, y: -origin.y)
        sim.draw(in: ctx)
        ctx.restoreGState()
    }
}
