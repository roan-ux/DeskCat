import AppKit
import QuartzCore

/// Owns the two windows (the box, and the cat above it) and runs the simulation once per
/// display frame. The pointer comes from `NSEvent.mouseLocation`, which needs no
/// Accessibility or Input Monitoring permission.
@MainActor
final class CatController: NSObject {
    let sim = CatSim()
    private let audio = CatAudio()

    var menuProvider: (() -> NSMenu?)? {
        didSet {
            boxView.menuProvider = menuProvider
            catView.menuProvider = menuProvider
            toyView.menuProvider = menuProvider
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
    private let toyWindow: PetWindow
    private let toyView: ToyView
    /// What the toy window last drew, so a toy lying still isn't redrawn every frame.
    private var toyDrawn: [CGFloat] = []
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
        toyView = ToyView(frame: NSRect(origin: .zero, size: ToyView.size(scale: scale)))
        toyWindow = PetWindow.make(size: ToyView.size(scale: scale))
        super.init()
        toyWindow.contentView = toyView
        toyWindow.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)   // above the cat: it carries it
        toyView.sim = sim
        toyView.onPress = { [weak self] in self?.toyPressed() }
        toyView.onRelease = { [weak self] in self?.toyReleased() }
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
        if sim.toyKind != nil { toyWindow.orderFrontRegardless() }
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
        toyWindow.setContentSize(ToyView.size(scale: scale))
        toyView.needsDisplay = true
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
            // Display-synced, but capped (see frameRate): the display may refresh at 120 Hz.
            let link = catView.displayLink(target: self, selector: #selector(frame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 60, preferred: 30)
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

    /// Frames per second the cat needs right now. Each frame costs a redraw here and a composite
    /// in WindowServer, so only draw as often as the motion needs.
    private var frameRate: Double {
        if !catWindow.occlusionState.contains(.visible) { return 4 }   // displays asleep, screen locked
        if sim.needsSmoothMotion { return 60 }
        return sim.sleeping ? 15 : 30
    }
    private var currentRate: Double = 30

    private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = now - lastTime
        let rate = frameRate
        if rate != currentRate {
            currentRate = rate
            if #available(macOS 14.0, *), let link = displayLink as? CADisplayLink {
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 60, preferred: Float(rate))
            }
        }
        // The display link may still fire faster than asked (it snaps to what the display supports).
        if elapsed < 1.0 / rate - 0.002 { return }
        lastTime = now
        updateWorld()
        sim.roams = Settings.roamsOnItsOwn
        let toy = Settings.toy
        if sim.toyKind != toy { sim.toyKind = toy }
        let dt = CGFloat(min(elapsed, 1.0 / 12.0))
        sim.step(dt, pointer: NSEvent.mouseLocation)
        syncWindows()
        playSounds()
    }

    /// Plays what the cat said this frame, panned to where it is on its screen.
    private func playSounds() {
        let on = Settings.soundOn, volume = Float(Settings.soundVolume)
        let head = sim.headWorld()
        let screen = NSScreen.screens.first { $0.frame.contains(head) } ?? NSScreen.main
        var pan: Float = 0
        if let f = screen?.frame { pan = Float(max(-1, min(1, (head.x - f.midX) / (f.width / 2)))) * 0.85 }
        if on && volume > 0 {
            for sound in sim.sounds { audio.play(sound, pan: pan, volume: volume) }
        }
        sim.sounds.removeAll()
        audio.update(purring: on ? Float(max(0, min(1, sim.purr.x))) : 0, intense: sim.purr.target > 0.8, pan: pan, volume: volume)
    }

    /// The cat lives on the screen its box is on; the floor is just above the Dock.
    private func updateWorld() {
        let center = CGPoint(x: sim.box.x + sim.boxW / 2, y: sim.box.y + 40)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        sim.floorY = vf.minY
        sim.minX = vf.minX + 50
        sim.maxX = vf.maxX - 50
        sim.maxY = vf.maxY
    }

    private func syncWindows() {
        // Whole-point window positions; the sub-point remainder is drawn, so motion stays smooth.
        let anchor = CatView.anchor(scale: sim.scale), inset = BoxView.inset(scale: sim.scale)
        let catOrigin = CGPoint(x: (sim.pos.x - anchor.x).rounded(), y: (sim.pos.y - anchor.y).rounded())
        if catWindow.frame.origin != catOrigin { catWindow.setFrameOrigin(catOrigin) }
        catView.needsDisplay = true

        syncToyWindow()

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

    private func syncToyWindow() {
        guard sim.toyKind != nil else {
            if toyWindow.isVisible { toyWindow.orderOut(nil) }
            return
        }
        let size = ToyView.size(scale: sim.scale), t = sim.toy
        let origin = CGPoint(x: (t.pos.x - size.width / 2).rounded(), y: (t.pos.y - size.height / 2).rounded())
        if toyWindow.frame.origin != origin { toyWindow.setFrameOrigin(origin) }
        if !toyWindow.isVisible { toyWindow.orderFrontRegardless() }
        let place: CGFloat = t.place == .box ? 0 : t.place == .held ? 1 : t.place == .free ? 2 : 3
        let state = [t.pos.x, t.pos.y, t.angle, t.facing, place, (sim.boxShow.x * 100).rounded(), CGFloat(sim.toyKind?.radius ?? 0)]
        if state != toyDrawn {
            toyDrawn = state
            toyView.needsDisplay = true
        }
    }

    // MARK: The toy: press to pick it up, let go to throw

    private func toyPressed() {
        if !sim.grabToy() { return }
    }

    private func toyReleased() { sim.throwToy() }

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
