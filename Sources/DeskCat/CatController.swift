import AppKit
import QuartzCore

/// Owns the two windows (the box, and the cat above it) and runs the simulation once per
/// display frame. The pointer comes from `NSEvent.mouseLocation`, which needs no
/// Accessibility or Input Monitoring permission.
@MainActor
final class CatController: NSObject {
    let sim = CatSim()

    var menuProvider: (() -> NSMenu?)? {
        didSet {
            boxView.menuProvider = menuProvider
            catView.menuProvider = menuProvider
        }
    }

    var name: String {
        get { Settings.name ?? "kitty" }
        set {
            Settings.name = newValue
            boxView.name = newValue
        }
    }

    var isHome: Bool { sim.isHome }
    var statusLabel: String { sim.statusLabel }

    private let boxWindow: PetWindow
    private let boxView: BoxView
    private let catWindow: PetWindow
    private let catView: CatView
    private var displayLink: AnyObject?
    private var timer: Timer?
    private var lastTime: CFTimeInterval = 0
    private var dragOrigin = CGPoint.zero
    private var pressPoint = CGPoint.zero
    private var catDragging = false

    override init() {
        let scale = Look.current.size.scale
        boxView = BoxView(frame: NSRect(origin: .zero, size: BoxView.size(scale: scale)))
        boxWindow = PetWindow.make(size: BoxView.size(scale: scale))
        catView = CatView(frame: NSRect(origin: .zero, size: CatView.size(scale: scale)))
        catWindow = PetWindow.make(size: CatView.size(scale: scale))
        super.init()
        boxWindow.contentView = boxView
        catWindow.contentView = catView
        // The cat always floats just above its box.
        catWindow.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        catView.sim = sim
        boxView.name = name

        boxView.onDragStart = { [weak self] in self?.boxDragStart() }
        boxView.onDrag = { [weak self] delta in self?.boxDragged(by: delta) }
        boxView.onDragEnd = { [weak self] in self?.boxDragEnded() }
        catView.onPress = { [weak self] in self?.catPressed() }
        catView.onDrag = { [weak self] in self?.catDragged() }
        catView.onRelease = { [weak self] in self?.catReleased() }
    }

    func start() {
        applyLook()
        placeBox()
        updateWorld()
        sim.roams = Settings.roamsOnItsOwn
        sim.boot(pointer: NSEvent.mouseLocation)
        syncWindows()
        boxWindow.orderFrontRegardless()
        catWindow.orderFrontRegardless()
        lastTime = CACurrentMediaTime()
        startFrameClock()
    }

    // MARK: Commands

    func letOut() { sim.letOut() }
    func callHome() { sim.callHome() }

    /// Picks up the current `Look`: size, personality and colours. Safe to call any time.
    func applyLook() {
        let look = Look.current
        let scale = look.size.scale
        sim.scale = scale
        sim.playfulBase = look.personality.playfulness
        sim.roamDelay = look.personality.roamDelay
        boxView.scale = scale
        catWindow.setContentSize(CatView.size(scale: scale))
        boxWindow.setContentSize(BoxView.size(scale: scale))
        boxView.needsDisplay = true
        catView.needsDisplay = true
        syncWindows()
    }

    func resetBoxPosition() {
        guard let frame = NSScreen.main?.visibleFrame else { return }
        sim.box = CGPoint(x: frame.maxX - sim.boxW - 90, y: frame.minY)
        Settings.boxOrigin = sim.box
    }

    // MARK: Frame clock

    private func startFrameClock() {
        if #available(macOS 14.0, *) {
            // Display-synced: one simulation step per screen refresh, the smoothest option.
            let link = catView.displayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let t = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    @available(macOS 14.0, *)
    @objc private func frame(_ link: CADisplayLink) { tick() }

    @objc private func timerFired() { tick() }

    private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = now - lastTime
        // A dozing cat only needs ~20 fps for its breathing; save the battery.
        let resting = sim.sleeping && abs(sim.boxShow.x - sim.boxShow.target) < 0.001 && abs(sim.boxShow.v) < 0.001
        if resting && elapsed < 1.0 / 20.0 { return }
        lastTime = now
        updateWorld()
        sim.roams = Settings.roamsOnItsOwn
        let dt = CGFloat(min(elapsed, 1.0 / 20.0))
        sim.step(dt, pointer: NSEvent.mouseLocation)
        syncWindows()
    }

    /// The cat lives on the screen its box is on; the floor is just above the Dock.
    private func updateWorld() {
        let center = CGPoint(x: sim.box.x + sim.boxW / 2, y: sim.box.y + 40)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        sim.floorY = vf.minY
        sim.minX = vf.minX + 50
        sim.maxX = vf.maxX - 50
    }

    private func syncWindows() {
        // Whole-point window positions; the sub-point remainder is drawn, so motion stays smooth.
        let anchor = CatView.anchor(scale: sim.scale), inset = BoxView.inset(scale: sim.scale)
        let catOrigin = CGPoint(x: (sim.pos.x - anchor.x).rounded(), y: (sim.pos.y - anchor.y).rounded())
        if catWindow.frame.origin != catOrigin { catWindow.setFrameOrigin(catOrigin) }
        catView.needsDisplay = true

        let boxOrigin = CGPoint(x: (sim.box.x - inset.x).rounded(), y: (sim.box.y - inset.y).rounded())
        if boxWindow.frame.origin != boxOrigin { boxWindow.setFrameOrigin(boxOrigin) }
        boxView.show = sim.boxShow.x
        let visible = sim.boxShow.x > 0.02 || sim.boxShow.target > 0
        if visible != boxWindow.isVisible {
            if visible {
                boxWindow.orderFrontRegardless()
                catWindow.orderFrontRegardless()
            } else {
                boxWindow.orderOut(nil)
            }
        }
    }

    // MARK: Box dragging (only while the cat is home and the box is showing)

    private func boxDragStart() { dragOrigin = sim.box }

    private func boxDragged(by delta: CGVector) {
        guard sim.isHome else { return }
        sim.box = CGPoint(x: dragOrigin.x + delta.dx, y: max(sim.floorY, dragOrigin.y + delta.dy))
        updateWorld()
    }

    private func boxDragEnded() { Settings.boxOrigin = sim.box }

    private func placeBox() {
        if let saved = Settings.boxOrigin,
           NSScreen.screens.contains(where: { $0.visibleFrame.contains(CGPoint(x: saved.x + sim.boxW / 2, y: saved.y + 40)) }) {
            sim.box = saved
        } else {
            resetBoxPosition()
        }
    }

    // MARK: Picking the cat up

    private func catPressed() {
        pressPoint = NSEvent.mouseLocation
        catDragging = false
    }

    private func catDragged() {
        let m = NSEvent.mouseLocation
        if !catDragging && hypot(m.x - pressPoint.x, m.y - pressPoint.y) > 4 {
            catDragging = true
            sim.pickUp()
        }
    }

    private func catReleased() {
        if catDragging {
            sim.release()
        } else {
            sim.clickCat()
        }
        catDragging = false
    }
}
