import CoreGraphics

// The cat's body, physics and behaviour. Everything is in screen coordinates (points, y up).
// This file is a direct port of the logic in `playground.html`, so the browser preview and the
// Mac app behave the same. Keep the two in step when changing either.

// MARK: - Rig

/// One pose of the skeleton, in cat-local units: facing right, origin on the ground under the body.
/// h = hips, c = chest (centre + radius), k = head centre, ff/fb = front/back foot.
struct Pose {
    var hx, hy, hr, cx, cy, cr, kx, ky, ffx, ffy, fbx, fby: CGFloat

    static let stand  = Pose(hx: -20, hy: 27, hr: 14, cx: 16, cy: 29, cr: 15, kx: 33, ky: 50, ffx: 18, ffy: 0, fbx: -21, fby: 0)
    static let sit    = Pose(hx: -11, hy: 15, hr: 17, cx: 5, cy: 36, cr: 14, kx: 10, ky: 63, ffx: 10, ffy: 0, fbx: 3, fby: 0)
    static let crouch = Pose(hx: -21, hy: 23, hr: 14, cx: 15, cy: 15, cr: 14, kx: 33, ky: 22, ffx: 24, ffy: 0, fbx: -17, fby: 0)
    static let lie    = Pose(hx: -16, hy: 13, hr: 14, cx: 13, cy: 13, cr: 14, kx: 31, ky: 27, ffx: 30, ffy: 1, fbx: -6, fby: 1)
    static let bow    = Pose(hx: -20, hy: 31, hr: 14, cx: 17, cy: 12, cr: 13, kx: 37, ky: 16, ffx: 44, ffy: 0, fbx: -22, fby: 0)
    static let leap   = Pose(hx: -22, hy: 30, hr: 14, cx: 18, cy: 33, cr: 15, kx: 35, ky: 51, ffx: 40, ffy: 13, fbx: -44, fby: 15)
    static let held   = Pose(hx: -1, hy: -50, hr: 13, cx: 2, cy: -22, cr: 14, kx: 3, ky: 5, ffx: 6, ffy: -46, fbx: 0, fby: -74)

    func blended(toward o: Pose, by t: CGFloat) -> Pose {
        Pose(hx: lerp(hx, o.hx, t), hy: lerp(hy, o.hy, t), hr: lerp(hr, o.hr, t),
             cx: lerp(cx, o.cx, t), cy: lerp(cy, o.cy, t), cr: lerp(cr, o.cr, t),
             kx: lerp(kx, o.kx, t), ky: lerp(ky, o.ky, t),
             ffx: lerp(ffx, o.ffx, t), ffy: lerp(ffy, o.ffy, t), fbx: lerp(fbx, o.fbx, t), fby: lerp(fby, o.fby, t))
    }
}

enum PoseName { case stand, sit, crouch, lie, bow, leap }

enum LegID: CaseIterable {
    case nf, ff, nb, fb   // near/far, front/back
    var front: Bool { self == .nf || self == .ff }
    var near: Bool { self == .nf || self == .nb }
    /// Walk gait (lateral sequence): near-back, near-front, far-back, far-front.
    var gaitOffset: CGFloat {
        switch self {
        case .nb: return 0
        case .nf: return 0.25
        case .fb: return 0.5
        case .ff: return 0.75
        }
    }
}

struct Leg { var anchor: CGPoint; var knee: CGPoint; var foot: CGPoint }

struct Skeleton {
    var p: Pose
    var legs: [LegID: Leg]
    var shoulder: CGPoint
}

/// Two-bone IK. The joint bends backwards, like a cat's wrist and hock.
func solveIK(_ a: CGPoint, _ b: CGPoint, _ l1: CGFloat, _ l2: CGFloat) -> CGPoint {
    let dx = b.x - a.x, dy = b.y - a.y
    let d = max(hypot(dx, dy), 0.001)
    if d >= l1 + l2 - 0.01 {
        return CGPoint(x: a.x + dx * l1 / (l1 + l2), y: a.y + dy * l1 / (l1 + l2))
    }
    let ux = dx / d, uy = dy / d
    let along = (l1 * l1 - l2 * l2 + d * d) / (2 * d)
    let h = sqrt(max(0, l1 * l1 - along * along))
    let nx = -uy, ny = ux
    let s: CGFloat = nx > 0 ? -1 : 1
    return CGPoint(x: a.x + ux * along + nx * h * s, y: a.y + uy * along + ny * h * s)
}

// MARK: - Behaviour types

enum Act {
    case inBox, leaving, air, land, pin, sit, look, groom, yawn, stretch, loaf, sleep
    case wander, watch, approach, stalk, swat, petted, startle, goHome, held
    case dizzy, visit, zoomies, chase, climb, trophy

    var label: String {
        switch self {
        case .inBox: return "In the box"
        case .leaving: return "Jumping out"
        case .air: return "In the air"
        case .land: return "Landing"
        case .pin: return "Got it!"
        case .sit: return "Sitting"
        case .look: return "Looking around"
        case .groom: return "Grooming"
        case .yawn: return "Yawning"
        case .stretch: return "Stretching"
        case .loaf: return "Loafing"
        case .sleep: return "Asleep"
        case .wander: return "Exploring"
        case .watch: return "Watching your pointer"
        case .approach: return "Creeping closer"
        case .stalk: return "Stalking"
        case .swat: return "Batting at it"
        case .petted: return "Being petted"
        case .startle: return "Startled!"
        case .goHome: return "Heading home"
        case .held: return "Picked up"
        case .dizzy: return "Dizzy!"
        case .visit: return "Coming to say hi"
        case .zoomies: return "Zoomies!"
        case .chase: return "Chasing the toy"
        case .climb: return "Climbing after it"
        case .trophy: return "Got the toy!"
        }
    }
}

enum Landing { case land, pin, box }

/// What the paws are up to while the cat dangles from the pointer.
enum HeldGesture { case limp, reach, paddle, tuck, reachDown, scramble }

/// Scratch state for the current activity.
struct ActData {
    var dur: CGFloat = 0
    var next: CGFloat = 0
    var lookX: CGFloat = 0
    var lookY: CGFloat = 0
    var x: CGFloat = 0
    var tiltSign: CGFloat = 1
    var wiggle: CGFloat = 0
    var ready = false
    var wait: CGFloat = 0
    var left = 0
    var bored: CGFloat = 90
    var fromBox = false
    var landY: CGFloat = 0
    var then: Landing = .land
    var peek = Spring(1, f: 3, z: 0.55)
    var peekValue: CGFloat = 1
    var stir: CGFloat = 0
    var prep: CGFloat = 0
}

struct Swat { var t: CGFloat = 0; var target: CGPoint; var jumps: Int }

struct Heart { var x: CGFloat; var y: CGFloat; var age: CGFloat }

struct Perception {
    var head: CGPoint
    var dH: CGFloat
    var idle: CGFloat
    var moving: Bool
    var near: Bool
    var startle: Bool
}

// MARK: - Simulation

final class CatSim {
    static let gravity: CGFloat = 2400
    static let tailCount = 10

    /// Overall size (Settings → Size). Cat-local units are multiplied by this on the way to the screen.
    var scale: CGFloat = 1
    var boxW: CGFloat { 120 * scale }
    var boxRim: CGFloat { 90 * scale }
    var tailSegment: CGFloat { 6.2 * scale }
    /// How readily it plays (Settings → Personality); playfulness drifts back to this after play.
    var playfulBase: CGFloat = 0.7

    // World, set by the controller each frame
    var floorY: CGFloat = 0
    var minX: CGFloat = 0
    var maxX: CGFloat = 1000
    var maxY: CGFloat = 1000
    var box = CGPoint.zero                       // bottom-left of the box body
    var boxShow = Spring(1, f: 4.2, z: 0.42)
    var roams = true
    /// Seconds before the cat leaves the box on its own.
    var roamDelay: ClosedRange<CGFloat> = 90...240

    // Pointer
    var ptrX: CGFloat = 0, ptrY: CGFloat = 0
    var ptrVX: CGFloat = 0, ptrVY: CGFloat = 0
    var ptrSpeed: CGFloat = 0
    var ptrLastMove: CGFloat = 0
    /// How far the pointer has turned while moving fast, in radians (signed, slowly forgotten).
    /// Several quick circles in a row make the cat dizzy.
    var spin: CGFloat = 0
    private var ptrHeading: CGFloat?

    // Body
    var pos = CGPoint.zero
    var velX: CGFloat = 0, velY: CGFloat = 0
    var air = false, held = false
    var gait: CGFloat = 0, speed: CGFloat = 0, breath: CGFloat = 0, time: CGFloat = 0
    var sit = Spring(1, f: 3, z: 0.8), crouch = Spring(0, f: 3.2, z: 0.75), lie = Spring(0, f: 1.6, z: 0.9)
    var bow = Spring(0, f: 2.2, z: 0.7), leap = Spring(0, f: 5, z: 0.7), hold = Spring(0, f: 4, z: 0.6)
    var squash = Spring(1, f: 4.5, z: 0.32), lean = Spring(0, f: 4, z: 0.6)
    var facing = Spring(1, f: 5, z: 0.85), headFacing = Spring(1, f: 7, z: 0.8), swing = Spring(0, f: 1.4, z: 0.12)
    var tilt = Spring(0, f: 3, z: 0.45), pitch = Spring(0, f: 4, z: 0.7)
    var gx = Spring(0, f: 9, z: 0.85), gy = Spring(0, f: 9, z: 0.85)
    var open = Spring(1, f: 14, z: 1), dil = Spring(0.3, f: 4, z: 0.9), happy = Spring(0, f: 5, z: 0.9), yawn = Spring(0, f: 3, z: 0.8)
    var earL = Spring(0, f: 6, z: 0.35), earR = Spring(0, f: 6, z: 0.35)
    var paw = Spring(0, f: 8, z: 0.55), pawX = Spring(30, f: 11, z: 0.45), pawY = Spring(30, f: 11, z: 0.45), rim = Spring(0, f: 5, z: 0.7)
    var groom = Spring(0, f: 3, z: 0.8), wiggle = Spring(0, f: 4, z: 0.8), purr = Spring(0, f: 3, z: 1)
    var tailBase = Spring(-1.0, f: 2.2, z: 0.6), tailCurl = Spring(0.36, f: 2, z: 0.6), tailAmp = Spring(0.1, f: 2, z: 0.8)
    var tailFreq: CGFloat = 1.6
    var tailPuff = Spring(1, f: 5, z: 0.5)
    /// 0...1, drives the swirly eyes and the stars circling the head.
    var dizzy = Spring(0, f: 2.5, z: 0.9)
    /// While held, the hips and back legs lag behind the scruff like a loose pendulum (world x, sideways)
    /// and stretch down when lifted fast. Low damping so they keep swinging after the pointer stops.
    var dangle = Spring(0, f: 1.5, z: 0.16), stretch = Spring(0, f: 2.2, z: 0.25)
    /// While held it keeps doing things with its paws: reaching, paddling the air, curling up.
    /// Front/back paw offsets (cat-local), how curled the body is, and how hard the legs paddle.
    var heldFX = Spring(0, f: 3.5, z: 0.55), heldFY = Spring(0, f: 3.5, z: 0.55)
    var heldBX = Spring(0, f: 3, z: 0.6), heldBY = Spring(0, f: 3, z: 0.6)
    var curl = Spring(0, f: 2, z: 0.6), paddle = Spring(0, f: 3, z: 0.8)
    var paddlePhase: CGFloat = 0, paddleRate: CGFloat = 6
    /// 0 side view, 1 the front-facing climbing figure (drawn separately: left paws left, right paws right).
    var climbView = Spring(0, f: 7, z: 0.9)
    /// Progress through one climbing stroke, 0...1: hold, gather the back legs, push up, re-hook the front paws.
    var climbPhase: CGFloat = 0
    /// Which front paw re-hooks first this stroke (they take turns leading).
    var climbLead: CGFloat = 1
    /// How far one stroke lifts the cat, in cat units (about how far the back feet can gather up).
    static let climbStroke: CGFloat = 22
    /// Thin rims on limbs that cross in front of the body (held, climbing). Off until it's decided on.
    static var limbRims = false
    /// 0...1, how far the paw nearest the toy reaches for it while climbing; -1/1 which side.
    var climbReach = Spring(0, f: 6, z: 0.6)
    var climbReachSide: CGFloat = 1
    private var heldGesture = HeldGesture.limp, heldNext: CGFloat = 0
    var tailPhase: CGFloat = 0
    var tail: [CGPoint] = []
    var blinkAt: CGFloat = 0, blinkT: CGFloat = -1
    var sleeping = false
    /// World y below which the body is hidden (inside the box).
    var boxClip: CGFloat?

    // Brain
    var act: Act = .inBox
    var t: CGFloat = 0
    var d = ActData()
    var interest: CGFloat = 0, playful: CGFloat = 0.7, outSince: CGFloat = 0
    var petTime: CGFloat = 0, lastPet: CGFloat = -9, noticed = false
    var duckUntil: CGFloat = 0, happyUntil: CGFloat = 0
    var swat: Swat?
    var hearts: [Heart] = []
    var zzz: CGFloat = 0
    var dizzyUntil: CGFloat = -10

    // Toy
    var toyKind: ToyKind? {
        didSet { if toyKind != oldValue { toy = ToyState(); placeToyInBox() } }
    }
    var toy = ToyState()
    /// Drains while it plays, refills slowly; when low it stops batting a toy that's lying still.
    var playEnergy: CGFloat = 1
    private var lastToyPlay: CGFloat = -10, lastToyHit: CGFloat = -10, nextLeap: CGFloat = 0
    var toyRadius: CGFloat { (toyKind?.radius ?? 12) * scale }
    var toyInBox: Bool { toyKind != nil && toy.place == .box }
    var toySpeed: CGFloat { hypot(toy.vx, toy.vy) }
    var toyResting: Bool { toy.place == .free && toySpeed < 15 && toy.pos.y - toyRadius - floorY < 2 }
    /// Being waved about or flying: impossible to ignore.
    var toyExciting: Bool {
        toyKind != nil && ((toy.place == .held && ptrSpeed > 40) || (toy.place == .free && toySpeed > 60))
    }
    /// Sounds to play this frame; the controller drains it.
    var sounds: [CatSound] = []
    private var lastVocal: CGFloat = -10
    /// Every 5 to 10 minutes it comes over to the pointer to say hi, even from the box.
    var visitAt: CGFloat = 0
    private var visitPending = false

    var isHome: Bool { act == .inBox || act == .leaving }

    /// True while something on screen moves quickly enough to need 60 fps. Otherwise (sitting,
    /// loafing, waiting in the box) breathing and tail sway look the same at 30 fps, and the app
    /// drops the frame rate to save power.
    var needsSmoothMotion: Bool {
        if held || air || swat != nil || time < dizzyUntil || speed > 3 || hearts.count > 0 { return true }
        if abs(boxShow.x - boxShow.target) > 0.002 || abs(boxShow.v) > 0.01 { return true }
        if act == .inBox && abs(d.peek.x - d.peek.target) > 0.01 { return true }
        if ptrSpeed > 30 && hypot(ptrX - pos.x, ptrY - pos.y) < 320 * scale { return true }   // watching or being petted
        if toyKind != nil && (toy.place == .held || toy.place == .carried || (toy.place == .free && !toyResting)) { return true }
        switch act {
        case .leaving, .land, .pin, .startle, .stretch, .yawn, .stalk, .swat, .petted,
             .wander, .approach, .goHome, .visit, .zoomies, .dizzy, .chase, .climb, .trophy:
            return true
        default:
            return false
        }
    }
    private var committed: Bool {
        if swat != nil { return true }
        switch act {
        case .leaving, .air, .held, .startle, .land, .pin, .dizzy, .climb: return true
        default: return false
        }
    }

    // MARK: Setup

    func boot(pointer: CGPoint) {
        ptrX = pointer.x; ptrY = pointer.y
        go(.inBox, ActData(next: CGFloat.random(in: roamDelay) * 0.5))
        visitAt = rnd(300, 600)
        d.peek = Spring(0.95, f: 3, z: 0.55)
        placeInBox(0.95)
        initTail()
    }

    // MARK: Skeleton

    func skeleton() -> Skeleton {
        let ws: [(Pose, CGFloat)] = [(.sit, clamp01(sit.x)), (.crouch, clamp01(crouch.x)), (.lie, clamp01(lie.x)),
                                     (.bow, clamp01(bow.x)), (.leap, clamp01(leap.x)), (.held, clamp01(hold.x))]
        var p = Pose.stand
        for (pose, w) in ws { p = p.blended(toward: pose, by: w) }
        // held by the scruff: the lower body swings and stretches behind it instead of moving as one piece
        let hw = clamp01(hold.x)
        if hw > 0.001 {
            let fs: CGFloat = facing.x >= 0 ? 1 : -1
            let sway = dangle.x / scale * fs * hw, drop = stretch.x * hw
            p.cx += sway * 0.3; p.cy -= drop * 0.3
            p.hx += sway; p.hy -= drop
            p.ffx += sway * 0.55; p.ffy -= drop * 0.4
            p.fbx += sway * 1.35 + sin(time * 2.1) * 1.5 * hw; p.fby -= drop * 1.3
            // curling up: hips come forward and up under the chest, so the spine bends
            let c = curl.x * hw
            p.hx += c * 10; p.hy += c * 12; p.cx += c * 3; p.ky -= c * 3
        }
        // breathing, butt wiggle
        let br = sin(breath)
        p.cr *= 1 + 0.03 * br; p.cy += 0.6 * br; p.ky += 0.5 * br
        p.hx += sin(time * 15) * 2.4 * wiggle.x
        // walk: body bob + planted feet
        let moving = clamp01(speed / 90) * (1 - clamp01(sit.x)) * (1 - clamp01(lie.x)) * (1 - clamp01(leap.x)) * (1 - clamp01(hold.x))
        let stride = 14 + 10 * clamp01(speed / 260)
        let bob = moving * 1.6 * cos(gait * .pi * 4)
        p.hy += bob; p.cy += bob; p.ky += bob * 0.6
        var feet: [LegID: CGPoint] = [:]
        for leg in LegID.allCases {
            var x = (leg.front ? p.ffx : p.fbx) + (leg.near ? 3 : -3)
            var y = leg.front ? p.ffy : p.fby
            if moving > 0 {
                let ph = (gait + leg.gaitOffset).truncatingRemainder(dividingBy: 1)
                var dx: CGFloat, lift: CGFloat = 0
                if ph < 0.6 {
                    dx = lerp(stride / 2, -stride / 2, ph / 0.6)
                } else {
                    let u = (ph - 0.6) / 0.4
                    dx = lerp(-stride / 2, stride / 2, smoothstep(u))
                    lift = sin(.pi * u) * 6
                }
                x += dx * moving; y += lift * moving
            }
            feet[leg] = CGPoint(x: x, y: y)
        }
        if hw > 0.001 {
            // living paws while held; near and far legs paddle out of step
            for leg in LegID.allCases {
                guard var f = feet[leg] else { continue }
                let ph = paddlePhase + (leg.near ? 0 : .pi) + (leg.front ? 0 : .pi / 2)
                let amp = paddle.x * (leg.front ? 7 : 5)
                let spread: CGFloat = leg.near ? 1 : -1
                if leg.front {
                    f.x += (heldFX.x + spread * 2 + amp * sin(ph)) * hw
                    f.y += (heldFY.x + spread * 3 * clamp01(heldFY.x / 20) + amp * cos(ph)) * hw
                } else {
                    f.x += (heldBX.x + amp * sin(ph)) * hw
                    f.y += (heldBY.x + amp * cos(ph)) * hw
                }
                feet[leg] = f
            }
        }
        let shoulder = CGPoint(x: p.cx + 2, y: p.cy - p.cr * 0.45)
        let hipJoint = CGPoint(x: p.hx + 2, y: p.hy - p.hr * 0.35)
        // paws hooked over the box rim
        let rimY = boxClip.map { ($0 - pos.y) / scale } ?? 0
        let r = clamp01(rim.x)
        if r > 0, let nf = feet[.nf], let ff = feet[.ff] {
            feet[.nf] = CGPoint(x: lerp(nf.x, p.cx + 14, r), y: lerp(nf.y, rimY + 2, r))
            feet[.ff] = CGPoint(x: lerp(ff.x, p.cx - 8, r), y: lerp(ff.y, rimY + 2, r))
        }
        // grooming / swatting paw
        let g = clamp01(groom.x), pw = clamp01(paw.x)
        if g > 0, let nf = feet[.nf] { feet[.nf] = CGPoint(x: lerp(nf.x, p.kx + 4, g), y: lerp(nf.y, p.ky - 14, g)) }
        if pw > 0, let nf = feet[.nf] { feet[.nf] = CGPoint(x: lerp(nf.x, pawX.x, pw), y: lerp(nf.y, pawY.x, pw)) }
        var legs: [LegID: Leg] = [:]
        for leg in LegID.allCases {
            let a = leg.front ? shoulder : hipJoint
            let l1: CGFloat = leg.front ? 13 : 14, l2: CGFloat = leg.front ? 14 : 15
            var f = feet[leg] ?? a
            let dist = hypot(f.x - a.x, f.y - a.y), maxLen = l1 + l2
            if dist > maxLen { f = CGPoint(x: a.x + (f.x - a.x) * maxLen / dist, y: a.y + (f.y - a.y) * maxLen / dist) }
            legs[leg] = Leg(anchor: a, knee: solveIK(a, f, l1, l2), foot: f)
        }
        return Skeleton(p: p, legs: legs, shoulder: shoulder)
    }

    /// Facing spring -> x scale. Passes quickly through a narrow minimum instead of going paper-thin.
    func turnScale(_ f: CGFloat, _ minimum: CGFloat) -> CGFloat {
        (f >= 0 ? 1 : -1) * (minimum + (1 - minimum) * min(1, abs(f)))
    }

    /// Cat-local point -> world (applies facing, squash and lean around the root).
    func toWorld(_ lx: CGFloat, _ ly: CGFloat) -> CGPoint {
        let sy = squash.x, sx = 1 + (1 - sy) * 0.7, f = turnScale(facing.x, 0.35)
        let x = lx * f * sx * scale, y = ly * sy * scale
        let a = lean.x + swing.x, c = cos(a), s = sin(a)
        let purrShake = purr.x * sin(time * 90) * 0.35
        return CGPoint(x: pos.x + x * c - y * s + purrShake, y: pos.y + x * s + y * c)
    }

    func toLocal(_ wx: CGFloat, _ wy: CGFloat) -> CGPoint {
        CGPoint(x: (wx - pos.x) / (turnScale(facing.x, 0.35) * scale), y: (wy - pos.y) / scale)
    }

    func headWorld() -> CGPoint {
        let s = skeleton()
        return toWorld(s.p.kx, s.p.ky)
    }

    // MARK: Tail

    private func tailRoot(_ sk: Skeleton) -> CGPoint {
        let side = toWorld(sk.p.hx - sk.p.hr * 0.8, sk.p.hy + sk.p.hr * 0.2)
        let front = CGPoint(x: pos.x, y: pos.y - 60 * scale)       // climbing: hangs from the middle
        let k = smoothstep(clamp01(climbView.x))
        return CGPoint(x: lerp(side.x, front.x, k), y: lerp(side.y, front.y, k))
    }

    func initTail() {
        let r = tailRoot(skeleton())
        let f = sgn(facing.x) == 0 ? 1 : sgn(facing.x)
        tail = (0..<Self.tailCount).map { i in CGPoint(x: r.x - CGFloat(i) * tailSegment * f, y: r.y + CGFloat(i) * 2) }
    }

    /// A chain that chases a mood-driven shape, so it lags behind the body and settles on its own.
    private func stepTail(_ dt: CGFloat, _ sk: Skeleton) {
        if tail.count != Self.tailCount { initTail() }
        let root = tailRoot(sk)
        tailPhase += dt * tailFreq * .pi * 2
        let f = sgn(facing.x) == 0 ? 1 : sgn(facing.x)
        var ang = tailBase.x, x = root.x, y = root.y
        tail[0] = root
        for i in 1..<Self.tailCount {
            let u = CGFloat(i) / CGFloat(Self.tailCount)
            ang += tailCurl.x * u + tailAmp.x * u * sin(tailPhase - CGFloat(i) * 0.55) * 1.4
            let tx = x - cos(ang) * f * tailSegment, ty = y + sin(ang) * tailSegment
            var p = tail[i]
            let k = 1 - exp(-dt * lerp(26, 9, u))
            p.x += (tx - p.x) * k; p.y += (ty - p.y) * k
            let prev = tail[i - 1]
            let ddx = p.x - prev.x, ddy = p.y - prev.y, dd = max(hypot(ddx, ddy), 1)
            p = CGPoint(x: prev.x + ddx / dd * tailSegment, y: prev.y + ddy / dd * tailSegment)
            if boxClip == nil && !held { p.y = max(p.y, floorY + 3.5 * scale) }   // rests on the floor
            tail[i] = p
            x = p.x; y = p.y
        }
    }

    // MARK: Frame

    func step(_ dt: CGFloat, pointer raw: CGPoint) {
        time += dt
        trackPointer(raw, dt)
        think(dt)
        speed = air ? 0 : abs(velX)
        gait += speed * dt * 0.6 / (14 + 10 * clamp01(speed / 260))
        breath += dt * (sleeping ? 1.6 : 2.6)
        if blinkT >= 0 {
            blinkT += dt
            if blinkT > 0.16 { blinkT = -1 }
        }
        stepSprings(dt)
        boxShow.step(dt)
        if !isHome && !held { pos.x = clamp(pos.x, minX, maxX) }
        stepTail(dt, skeleton())
        stepToy(dt)
        for i in hearts.indices {
            hearts[i].age += dt
            hearts[i].y += 22 * dt
            hearts[i].x += sin(hearts[i].age * 6 + hearts[i].y) * 0.25
        }
        hearts.removeAll { $0.age >= 1.4 }
    }

    private func stepSprings(_ dt: CGFloat) {
        sit.step(dt); crouch.step(dt); lie.step(dt); bow.step(dt); leap.step(dt); hold.step(dt)
        squash.step(dt); lean.step(dt); facing.step(dt); headFacing.step(dt); swing.step(dt)
        tilt.step(dt); pitch.step(dt); gx.step(dt); gy.step(dt)
        open.step(dt); dil.step(dt); happy.step(dt); yawn.step(dt); earL.step(dt); earR.step(dt)
        paw.step(dt); pawX.step(dt); pawY.step(dt); rim.step(dt)
        groom.step(dt); wiggle.step(dt); purr.step(dt)
        tailBase.step(dt); tailCurl.step(dt); tailAmp.step(dt); tailPuff.step(dt)
        dizzy.step(dt); dangle.step(dt); stretch.step(dt); climbView.step(dt); climbReach.step(dt)
        heldFX.step(dt); heldFY.step(dt); heldBX.step(dt); heldBY.step(dt); curl.step(dt); paddle.step(dt)
    }

    private func trackPointer(_ raw: CGPoint, _ dt: CGFloat) {
        let dx = raw.x - ptrX, dy = raw.y - ptrY
        if abs(dx) + abs(dy) > 0.5 { ptrLastMove = time }
        if dt > 0 {
            let k = min(1, dt * 14)
            ptrVX += (dx / dt - ptrVX) * k
            ptrVY += (dy / dt - ptrVY) * k
        }
        ptrX = raw.x; ptrY = raw.y
        ptrSpeed = hypot(ptrVX, ptrVY)
        // Add up how much the pointer's heading turns while it moves fast. Circling adds up,
        // back-and-forth cancels out. Slow loops never get far because it's forgotten at ~35%/s.
        if ptrSpeed > 600 {
            let h = atan2(ptrVY, ptrVX)
            if let last = ptrHeading {
                var dh = h - last
                if dh > .pi { dh -= 2 * .pi } else if dh < -.pi { dh += 2 * .pi }
                spin += dh
            }
            ptrHeading = h
        } else {
            ptrHeading = nil
        }
        spin -= spin * min(1, dt * 0.35)
    }

    // MARK: Helpers

    private func go(_ a: Act, _ data: ActData = ActData()) {
        act = a; t = 0; d = data
        if a != .inBox { sleeping = a == .sleep }
    }

    private func pose(_ name: PoseName) {
        sit.target = name == .sit ? 1 : 0
        crouch.target = name == .crouch ? 1 : 0
        lie.target = name == .lie ? 1 : 0
        bow.target = name == .bow ? 1 : 0
        leap.target = name == .leap ? 1 : 0
        hold.target = 0
    }

    private func faceTo(_ x: CGFloat, _ minimum: CGFloat = 6) {
        let dx = x - pos.x
        if abs(dx) > minimum { facing.target = sgn(dx) }
    }

    private func lookAt(_ wx: CGFloat, _ wy: CGFloat) {
        let h = headWorld(), dx = wx - h.x, dy = wy - h.y
        let dist = max(hypot(dx, dy), 1), r = min(1, dist / 110)
        gx.target = dx / dist * r; gy.target = dy / dist * r
        pitch.target = clamp(atan2(dy, abs(dx)) * 0.35, -0.3, 0.45)
        if abs(dx) > 12 { headFacing.target = sgn(dx) }
    }

    private func lookForward() {
        gx.target = 0.25 * sgn(facing.target); gy.target = -0.05; pitch.target = 0
        headFacing.target = sgn(facing.target)
    }

    private enum Mood { case relaxed, walk, happy, hunt, alert, scared, sleep, box }

    /// Tail shape per mood: (base angle, curl, sway, sway speed, puff).
    /// Angles are measured from straight back (0); up is positive, down negative. Curl bends each
    /// segment a little more, so a drooping base with positive curl makes the relaxed "J" shape.
    private func mood(_ m: Mood) {
        let v: (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
        switch m {
        case .relaxed: v = (-1.0, 0.36, 0.1, 1.2, 1)
        case .walk: v = (0.15, 0.3, 0.12, 2.2, 1)
        case .happy: v = (1.2, 0.14, 0.08, 1.6, 1)
        case .hunt: v = (-0.3, 0.05, 0.07, 7, 1)
        case .alert: v = (-0.15, 0.3, 0.05, 3, 1)
        case .scared: v = (1.0, 0.25, 0.04, 2, 1.9)
        case .sleep: v = (-1.35, -0.42, 0, 1, 1)
        case .box: v = (-0.6, 0.35, 0.1, 1.4, 1)
        }
        tailBase.target = v.0; tailCurl.target = v.1; tailAmp.target = v.2; tailFreq = v.3; tailPuff.target = v.4
    }

    @discardableResult
    private func moveToward(_ x: CGFloat, _ maxSpeed: CGFloat, _ dt: CGFloat, _ stopAt: CGFloat = 4) -> Bool {
        let dx = x - pos.x
        let want = clamp(dx * 3, -maxSpeed, maxSpeed) * (abs(dx) < stopAt ? 0 : 1)
        let accel = 700 * dt
        velX += clamp(want - velX, -accel, accel)
        pos.x += velX * dt
        if abs(velX) > 8 { facing.target = sgn(velX) }
        return abs(dx) < stopAt + 1 && abs(velX) < 15
    }

    private func brake(_ dt: CGFloat) {
        let a = 900 * dt
        velX -= clamp(velX, -a, a)
        pos.x += velX * dt
    }

    /// Ballistic jump to (tx, ty) peaking `apex` above the higher end.
    private func launch(_ tx: CGFloat, _ ty: CGFloat, _ apex: CGFloat, _ then: Landing) {
        let g = Self.gravity, top = max(pos.y, ty) + apex
        let up = sqrt(2 * g * (top - pos.y)), tUp = up / g, tDown = sqrt(2 * (top - ty) / g)
        velX = (tx - pos.x) / (tUp + tDown); velY = up; air = true
        squash.v += 6; squash.x = 1.18
        if abs(tx - pos.x) > 4 { facing.target = sgn(tx - pos.x) }
        go(.air, ActData(landY: ty, then: then))
    }

    /// Queues a sound, with probability `p`. Vocal sounds keep a few seconds apart so it isn't chatty.
    private func say(_ sound: CatSound, _ p: CGFloat = 1) {
        guard chance(p), time - lastVocal > 3, sounds.count < 4 else { return }
        lastVocal = time
        sounds.append(sound)
    }

    private func emitHeart() {
        let h = headWorld()
        hearts.append(Heart(x: h.x + rnd(-12, 12) * scale, y: h.y + 26 * scale, age: 0))
        if hearts.count > 8 { hearts.removeFirst() }
    }

    private func blinkMaybe() {
        if time > blinkAt {
            blinkT = 0
            blinkAt = time + rnd(2.2, 6) * (chance(0.2) ? 0.15 : 1)
        }
    }

    private func earTwitch() {
        if chance(0.5) { earL.v += rnd(10, 16) } else { earR.v += rnd(10, 16) }
    }

    private func startSwat(_ target: CGPoint, jumps: Int = 1) {
        swat = Swat(target: target, jumps: jumps)
    }

    private func updateSwat(_ dt: CGFloat) {
        guard var s = swat else { return }
        s.t += dt
        let sh = skeleton().shoulder
        if s.t < 0.14 {            // wind up: paw cocked beside the face
            paw.target = 1; pawX.target = sh.x + 8; pawY.target = sh.y + 24
            earL.target = -0.15; earR.target = -0.15
        } else if s.t < 0.32 {     // strike towards the pointer
            let l = toLocal(s.target.x, s.target.y)
            let ang = clamp(atan2(l.y - sh.y, max(4, l.x - sh.x)), -0.6, air ? 1.2 : 0.9)
            pawX.target = sh.x + cos(ang) * 30; pawY.target = sh.y + sin(ang) * 30
        } else {
            paw.target = 0; earL.target = 0; earR.target = 0
        }
        swat = s.t > 0.55 ? nil : s
    }

    // MARK: Perception and decisions

    private func perceive(_ dt: CGFloat) -> Perception {
        let h = headWorld()
        let dH = hypot(ptrX - h.x, ptrY - h.y)
        let idle = time - ptrLastMove, moving = idle < 0.25
        let near = dH < 260
        if near && moving && ptrSpeed > 25 && ptrSpeed < 2400 {
            interest = min(1, interest + dt * (1.4 - dH / 260))
        } else {
            interest = max(0, interest - dt * 0.3)
        }
        let petting = dH < 30 * scale && ptrSpeed > 12 && ptrSpeed < 650 && !air && !held && toy.place != .held
        petTime = petting ? petTime + dt : max(0, petTime - dt * 2)
        if petting { lastPet = time }
        if !moving || !near { noticed = false }
        let startle = dH < 150 && ptrSpeed > 2600 && !(toyKind != nil && toy.place == .held)   // waving a toy isn't scary
        return Perception(head: h, dH: dH, idle: idle, moving: moving, near: near, startle: startle)
    }

    private func pick<T>(_ opts: [(T, CGFloat)]) -> T {
        let total = opts.reduce(0) { $0 + max(0, $1.1) }
        var r = CGFloat.random(in: 0..<max(total, 0.0001))
        for (a, w) in opts {
            r -= max(0, w)
            if r <= 0 { return a }
        }
        return opts[0].0
    }

    private func decideOut(_ per: Perception) -> Act {
        if time < dizzyUntil { return .dizzy }
        if visitPending { return .visit }
        if toyKind != nil && toy.place == .carried { return playEnergy < 0.35 ? .goHome : .trophy }
        if toyKind != nil && (toy.place == .free || toy.place == .held) {
            let playing = time - lastToyPlay < 3 && playEnergy > 0.15
            if toyExciting || toy.place == .held || playing { return .chase }
            if toyResting && playEnergy > 0.4 && chance(0.2) { return .chase }   // notices it lying there
        }
        let lowPtr = ptrY - floorY < 110
        if interest > 0.35 && per.near {
            if per.dH < 78 * scale { return pick([(.swat, 45), (.watch, 35), (.groom, 8 * (1 - playful)), (.sit, 10)]) }
            if lowPtr && abs(ptrX - pos.x) < 420 { return pick([(.stalk, 40 * playful), (.watch, 35), (.approach, 15), (.sit, 10)]) }
            return pick([(.watch, 55), (.approach, abs(ptrX - pos.x) > 140 ? 25 : 0), (.look, 12)])
        }
        if time - outSince > d.bored || (per.idle > 40 && chance(0.4)) {
            return per.idle > 40 && chance(0.4) ? .loaf : .goHome
        }
        return pick([(.sit, 22), (.look, 18), (.wander, 26), (.groom, 12), (.yawn, 7), (.stretch, 7),
                     (.loaf, per.idle > 15 ? 18 : 10), (.zoomies, 4 * playful)])
    }

    private func enter(_ a: Act) {
        var n = ActData(bored: d.bored)
        switch a {
        case .sit: n.dur = rnd(2, 5)
        case .look: n.dur = rnd(2.5, 5); n.next = 0
        case .groom: n.dur = rnd(2.5, 4.5)
        case .yawn: n.dur = 1.9
        case .stretch: n.dur = 1.8
        case .loaf: n.dur = rnd(6, 12); n.ready = chance(0.3)   // ready: drifts off into a nap
        case .wander: n.x = clamp(pos.x + rnd(150, 420) * (chance(0.5) ? 1 : -1), minX, maxX)
        case .watch: n.dur = rnd(1.4, 3.2); n.tiltSign = chance(0.5) ? 1 : -1
        case .approach: n.dur = 4
        case .stalk: n.dur = 7
        case .visit:
            n.dur = rnd(4, 8); n.tiltSign = chance(0.5) ? 1 : -1
            visitPending = false; visitAt = time + rnd(300, 600)
        case .chase: n.dur = rnd(20, 35)
        case .climb: n.dur = rnd(10, 14); n.x = 0; n.landY = 0; climbPhase = 0
        case .trophy:
            let side: CGFloat = chance(0.5) ? 1 : -1
            n.x = clamp(pos.x + side * rnd(150, 350) * scale, minX, maxX); n.dur = rnd(1.2, 2.2)
        case .zoomies:
            var side: CGFloat = chance(0.5) ? 1 : -1
            if (side > 0 ? maxX - pos.x : pos.x - minX) < 250 { side = -side }
            n.x = clamp(pos.x + side * rnd(300, 600), minX, maxX)
            n.left = chance(0.5) ? 1 : 0
        case .swat:
            faceTo(ptrX)
            let jumps = chance(0.35) ? 2 : 1
            startSwat(CGPoint(x: ptrX, y: ptrY), jumps: jumps)
            n.left = jumps - 1
        default: break
        }
        go(a, n)
    }

    /// Expressions relax back to neutral every frame unless the current activity holds them.
    private func relax(_ per: Perception) {
        yawn.target = 0; groom.target = 0; wiggle.target = 0; purr.target = 0
        happy.target = time < happyUntil ? 1 : 0
        tilt.target = 0; earL.target = 0; earR.target = 0; rim.target = 0
        dizzy.target = time < dizzyUntil ? 1 : 0
        dangle.target = 0; stretch.target = 0; climbView.target = 0; climbReach.target = 0
        heldFX.target = 0; heldFY.target = 0; heldBX.target = 0; heldBY.target = 0; curl.target = 0; paddle.target = 0
        if swat == nil { paw.target = 0 }
        open.target = sleeping ? 0 : 1
        dil.target = 0.25 + 0.4 * clamp01((220 - per.dH) / 200) * (per.near ? 1 : 0)
    }

    // MARK: Brain

    private func think(_ dt: CGFloat) {
        let per = perceive(dt)
        let a = act
        t += dt
        relax(per)
        playful += (playfulBase - playful) * min(1, dt * 0.03)
        blinkMaybe()
        if !sleeping && time.truncatingRemainder(dividingBy: 7) < dt && chance(0.5) { earTwitch() }

        // Spun round in fast circles: dizzy, wherever it is (even dangling from the pointer).
        if abs(spin) > 25 && per.dH < 520 * scale && !sleeping && time > dizzyUntil + 2 {
            spin = 0
            dizzyUntil = time + rnd(3.5, 5)
            say(.mew, 0.7)      // "mew?"
            if !isHome && !committed { swat = nil; paw.target = 0; wiggle.target = 0; enter(.dizzy); return }
        }

        // Interrupts
        if !isHome && !committed && a != .sleep {
            if per.startle { startle(); return }
            if petTime > 0.25 && a != .petted {
                say(.mew, 0.5)
                go(.petted, ActData(bored: d.bored))
            } else if per.near && per.moving && !noticed && [.sit, .look, .wander, .groom, .loaf, .yawn, .stretch].contains(a) {
                noticed = true
                if chance(0.35 + 0.55 * playful) { earL.v += 8; earR.v += 8; enter(.watch) }
            }
        }

        playEnergy = min(1, playEnergy + dt / 240)
        // A toy being waved about or thrown: out of the box, awake, after it.
        if toyExciting && !held && act != .chase && !committed {
            if act == .inBox {
                if time >= dizzyUntil && chance(dt * 3) { letOut() }
            } else if act == .sleep {
                if hypot(toy.pos.x - pos.x, toy.pos.y - pos.y) < 500 * scale && chance(dt * 1.5) { sleeping = false; enter(.chase) }
            } else if !isHome {
                enter(.chase)
            }
        }
        if [.sit, .look, .wander].contains(act) && chance(dt / 150) { say(chance(0.7) ? .meow : .mew) }
        if !isHome && !committed && time > visitAt && [.sit, .look, .wander, .groom, .loaf, .yawn, .stretch].contains(act) {
            enter(.visit)
        }

        switch act {
        case .inBox: inBox(dt, per)
        case .leaving: leaving(dt)
        case .air: inAir(dt)
        case .land:
            pose(.stand); brake(dt); lean.target = 0
            if t > 0.35 { enter(decideOut(per)) }
        case .pin:
            pose(.crouch); brake(dt); paw.target = 1; pawX.target = 34; pawY.target = 2
            mood(.hunt)
            let fs: CGFloat = facing.target >= 0 ? 1 : -1
            let caught = toyKind != nil && toy.place == .free && abs(toy.pos.x - (pos.x + fs * 30 * scale)) < 45 * scale
                && toy.pos.y - toyRadius - floorY < 20 * scale
            if caught {
                // pinned under the paws
                toy.vx = 0; toy.spin = 0; toy.pos.x += (pos.x + fs * 32 * scale - toy.pos.x) * 0.3
                lookAt(toy.pos.x, toy.pos.y)
            } else {
                lookAt(ptrX, ptrY)
            }
            if t > 0.6 {
                paw.target = 0; playful = max(0.2, playful - 0.1)
                if caught {
                    // Caught the toy: keep playing with it, or if that's enough, take it home.
                    playEnergy = max(0, playEnergy - 0.035)      // every pounce tires it a little
                    if playEnergy < 0.3 { snatchToy(); go(.goHome) } else { enter(.chase) }
                } else {
                    enter(chance(0.5) ? .sit : .watch)
                }
            }
        case .sit:
            pose(.sit); brake(dt); mood(.relaxed); idleLook(per)
            if t > d.dur { enter(decideOut(per)) }
        case .look:
            pose(.sit); brake(dt); mood(.relaxed)
            if t > d.next { d.next = t + rnd(0.7, 1.8); d.lookX = pos.x + rnd(-300, 300); d.lookY = floorY + rnd(0, 260) }
            lookAt(d.lookX, d.lookY)
            if t > d.dur { enter(decideOut(per)) }
        case .groom:
            pose(.sit); brake(dt); mood(.relaxed)
            groom.target = t > 0.3 && t < d.dur - 0.3 ? 1 : 0
            pitch.target = -0.35 + sin(t * 9) * 0.06; gx.target = 0.2; gy.target = -0.4
            open.target = 0.35; headFacing.target = sgn(facing.target)
            if t > d.dur { enter(decideOut(per)) }
        case .yawn:
            pose(.sit); brake(dt); mood(.relaxed)
            yawn.target = t > 0.2 && t < 1.3 ? 1 : 0
            open.target = yawn.target > 0 ? 0.08 : 1
            pitch.target = yawn.target * 0.35; earL.target = yawn.target * 0.35; earR.target = yawn.target * 0.35
            if t > d.dur { enter(chance(0.4) ? .stretch : decideOut(per)) }
        case .stretch:
            pose(t < 1.3 ? .bow : .stand); brake(dt); mood(.happy)
            open.target = t < 1.3 ? 0.3 : 1
            if t > d.dur { enter(decideOut(per)) }
        case .loaf:
            pose(.lie); brake(dt); mood(.relaxed); open.target = t > 2 ? 0.45 : 1; idleLook(per, 0.4)
            if (per.idle > 25 || d.ready) && t > 4 { go(.sleep, ActData(dur: rnd(20, 50), bored: d.bored)) }
            else if t > d.dur { enter(decideOut(per)) }
        case .sleep: sleepTick(dt, per)
        case .wander:
            pose(.stand); mood(.walk); lookForward()
            if moveToward(d.x, 75, dt) { enter(chance(0.6) ? .sit : .look) }
        case .watch: watch(dt, per)
        case .approach:
            pose(.stand); mood(.alert); lookAt(ptrX, ptrY)
            if moveToward(ptrX - sgn(ptrX - pos.x) * 100, 80, dt, 10) || t > d.dur { enter(.watch) }
        case .stalk: stalk(dt, per)
        case .swat:
            pose(.sit); brake(dt); mood(.hunt); lookAt(ptrX, ptrY); faceTo(ptrX)
            dil.target = 1
            if swat == nil {
                if d.left > 0 { d.left -= 1; startSwat(CGPoint(x: ptrX, y: ptrY)) }
                else { enter(per.dH < 90 && chance(0.5) ? .watch : .sit) }
            }
        case .petted:
            pose(.sit); brake(dt); mood(.happy)
            happy.target = 1; purr.target = 1; earL.target = 0.25; earR.target = 0.25
            lookAt(ptrX, ptrY)
            if t.truncatingRemainder(dividingBy: 0.7) < dt { emitHeart() }
            if petTime < 0.05 && time - lastPet > 0.7 { enter(chance(0.5) ? .sit : .groom) }
            else if t > 5 && chance(dt * 0.25) { enter(.swat) }
        case .startle:
            earL.target = 0.9; earR.target = 0.9; mood(.scared); dil.target = 1
            if !air {
                brake(dt); pose(.crouch)
                if t > 1.1 { enter(chance(0.4) ? .goHome : .watch) }
            } else {
                stepAir(dt)
            }
        case .goHome: goHome(dt)
        case .held: heldTick(dt)
        case .dizzy: dizzyTick(dt)
        case .chase: chase(dt)
        case .climb: climb(dt)
        case .trophy: trophy(dt)
        case .visit: visit(dt, per)
        case .zoomies:
            pose(.stand); mood(.happy); lookForward(); earL.target = -0.2; earR.target = -0.2
            if moveToward(d.x, 340, dt, 12) {
                if d.left > 0 {
                    d.left -= 1
                    d.x = clamp(pos.x - sgn(facing.target) * rnd(250, 450), minX, maxX)
                } else {
                    enter(.sit)
                }
            }
        }
        updateSwat(dt)
    }

    private func leaving(_ dt: CGFloat) {
        pose(.sit); rim.target = 0
        if t < 0.24 {
            squash.target = 0.8     // anticipation: sink into the box before the jump
            d.peekValue = lerp(1, 0.7, t / 0.24)
            placeInBox(d.peekValue)
        } else {
            squash.target = 1; boxClip = nil
            let side: CGFloat = box.x + boxW + 70 < maxX ? 1 : -1
            outSince = time
            let bored = rnd(90, 240)
            // clear the rim comfortably, then drop to the floor beside the box
            launch(box.x + boxW / 2 + side * (boxW / 2 + 55 * scale), floorY,
                   box.y + boxRim + 40 * scale - max(pos.y, floorY), .land)
            d.bored = bored; d.fromBox = true
        }
    }

    private func inAir(_ dt: CGFloat) {
        pose(.leap)
        velY -= Self.gravity * dt
        pos.x += velX * dt; pos.y += velY * dt
        squash.target = 1 + clamp(abs(velY) / 2600, 0, 0.22)
        lean.target = clamp(velY / 1800, -0.35, 0.35) * (sgn(facing.target) == 0 ? 1 : sgn(facing.target))
        // stay hidden by the box front while climbing out of it or dropping into it
        let rimY = box.y + boxRim
        let overBox = abs(pos.x - (box.x + boxW / 2)) < boxW / 2 + 10
        let hidden = overBox && ((d.fromBox && pos.y < rimY) || (d.then == .box && velY < 0 && pos.y < rimY + 40 * scale))
        boxClip = hidden ? rimY : nil
        if d.fromBox && velY < 0 && !toyInBox { boxShow.target = 0 }   // tuck the box away once the cat is out (unless the toy's in it)
        if toyKind != nil && toy.place == .free && time - lastToyHit > 0.4 {
            let h = headWorld()
            if hypot(toy.pos.x - h.x, toy.pos.y - h.y) < 30 * scale + toyRadius {
                let fs: CGFloat = facing.target >= 0 ? 1 : -1
                toy.vx = velX * 0.7 + fs * rnd(120, 260) * scale; toy.vy = max(toy.vy, 0) + rnd(220, 420)
                toy.spin = rnd(-12, 12); lastToyHit = time
            }
        }
        if d.then == .box && velY < 0 && pos.y <= d.landY { landInBox(); return }
        if pos.y <= floorY && velY < 0 {
            pos.y = floorY; air = false; velY = 0
            squash.x = 0.7; squash.v = 0; squash.target = 1; lean.target = 0; leap.target = 0
            if d.then == .pin { pose(.crouch); go(.pin, ActData(bored: d.bored)) }
            else { go(.land, ActData(bored: d.bored)) }
        }
    }

    private func stepAir(_ dt: CGFloat) {
        velY -= Self.gravity * dt
        pos.x += velX * dt; pos.y += velY * dt
        if pos.y <= floorY { pos.y = floorY; velY = 0; air = false; squash.x = 0.75; leap.target = 0 }
    }

    private func startle() {
        swat = nil; paw.target = 0
        let away: CGFloat = sgn(pos.x - ptrX) == 0 ? 1 : sgn(pos.x - ptrX)
        velX = away * 220; velY = 520; air = true; squash.x = 1.25; leap.target = 0.6
        facing.target = -away; tailPuff.target = 1.9
        go(.startle, ActData(bored: d.bored))
    }

    private func idleLook(_ per: Perception, _ amount: CGFloat = 1) {
        if per.near && per.moving && interest > 0.2 {
            lookAt(ptrX, ptrY)
        } else if t.truncatingRemainder(dividingBy: 2.2) < 0.02 {
            gx.target = rnd(-0.6, 0.6) * amount; gy.target = rnd(-0.3, 0.4) * amount; pitch.target = rnd(-0.1, 0.2)
        }
    }

    private func watch(_ dt: CGFloat, _ per: Perception) {
        let low = ptrY - floorY < 60
        pose(low && playful > 0.5 ? .crouch : .sit); crouch.target *= 0.6
        brake(dt); mood(.hunt); lookAt(ptrX, ptrY); faceTo(ptrX, 30)
        dil.target = 0.85
        // head tilt when the pointer pauses: the classic curious cat
        tilt.target = per.idle > 0.35 && per.idle < 3 && per.dH < 260 ? 0.32 * d.tiltSign : 0
        if t > d.dur {
            if !per.near || interest < 0.1 { enter(chance(0.5) ? .sit : .groom) }
            else { enter(decideOut(per)) }
        }
    }

    private func stalk(_ dt: CGFloat, _ per: Perception) {
        let dx = ptrX - pos.x
        pose(.crouch); mood(.hunt); lookAt(ptrX, ptrY); dil.target = 1
        earL.target = -0.1; earR.target = -0.1
        if abs(dx) > 130 && !d.ready {
            moveToward(ptrX - sgn(dx) * 120, 38, dt, 6); d.wiggle = 0
        } else {
            brake(dt); faceTo(ptrX); d.ready = true
            d.wiggle += dt; wiggle.target = d.wiggle > 0.3 ? 1 : 0
            if d.wait == 0 { d.wait = rnd(0.9, 1.4) }
            if d.wiggle > d.wait {
                wiggle.target = 0; squash.x = 0.82; earL.target = 0; earR.target = 0
                let tx = clamp(ptrX, minX, maxX), ty = max(floorY, ptrY - 22)
                launch(tx - sgn(dx) * 10, floorY, max(25, ty - floorY + 10), .pin)
                playful = max(0.25, playful - 0.08)
                return
            }
        }
        if ptrSpeed > 900 || t > d.dur || !per.near { wiggle.target = 0; enter(.watch) }
    }

    private func sleepTick(_ dt: CGFloat, _ per: Perception) {
        pose(.lie); brake(dt); mood(.sleep); sleeping = true
        open.target = 0; gx.target = 0; gy.target = 0; pitch.target = -0.12
        zzz += dt
        if per.near && per.moving {
            d.stir += dt
            if d.stir > 0.05 && d.stir - dt <= 0.05 { earTwitch() }
            if d.stir > 1.2 { sleeping = false; open.target = 1; enter(.yawn); return }
        } else {
            d.stir = max(0, d.stir - dt * 0.5)
        }
        // a nap, not hibernation: wakes up by itself and stretches
        if d.dur > 0 && t > d.dur { sleeping = false; open.target = 1; say(.mew, 0.3); enter(chance(0.6) ? .stretch : .yawn) }
    }

    private func goHome(_ dt: CGFloat) {
        boxShow.target = 1
        // Tidies up: fetches its toy and carries it home in its mouth.
        if toyKind != nil && toyResting && toy.pos.x > minX - 20 && toy.pos.x < maxX + 20 {
            pose(.stand); mood(.walk); lookAt(toy.pos.x, toy.pos.y)
            let side: CGFloat = sgn(toy.pos.x - pos.x) == 0 ? 1 : sgn(toy.pos.x - pos.x)
            if moveToward(toy.pos.x - side * 20 * scale, 130, dt, 6) {
                faceTo(toy.pos.x, 1); toy.place = .carried; t = 0
            }
            return
        }
        let cx = box.x + boxW / 2, onFloor = box.y - floorY < 10
        let side: CGFloat = sgn(pos.x - cx) == 0 ? 1 : sgn(pos.x - cx)
        let spot = onFloor ? cx + side * (boxW / 2 + 34 * scale) : cx + side * 30 * scale
        pose(.stand); mood(.walk); lookForward()
        if t < 0.5 { brake(dt); lookAt(cx, box.y + boxRim); return }
        if moveToward(spot, 120, dt, 5) {
            faceTo(cx, 1)
            d.prep += dt; squash.target = 0.8; pose(.crouch); crouch.target = 0.5
            if d.prep > 0.22 { squash.target = 1; launch(cx, box.y + boxRim - 30 * scale, 34, .box) }
        }
    }

    private func landInBox() {
        air = false; velX = 0; velY = 0; leap.target = 0; lean.target = 0
        facing.target = sgn(facing.target) == 0 ? 1 : sgn(facing.target)
        squash.x = 0.8; squash.target = 1
        pose(.sit); sit.snap(1); crouch.snap(0); leap.snap(0)
        if toy.place == .carried { placeToyInBox() }     // drops it in the box
        var n = ActData(next: time + CGFloat.random(in: roamDelay))
        n.peek = Spring(0, f: 3, z: 0.55)
        n.peek.target = 1
        go(.inBox, n)
    }

    func placeInBox(_ peek: CGFloat) {
        let rimY = box.y + boxRim
        pos.x = box.x + boxW / 2
        pos.y = rimY + (lerp(-98, -40, clamp01(peek)) + max(0, peek - 1) * 60) * scale
        boxClip = rimY
    }

    private func inBox(_ dt: CGFloat, _ per: Perception) {
        pose(.sit); mood(.box); boxShow.target = 1
        let sleepy = per.idle > 40
        sleeping = sleepy && !per.near
        var peek: CGFloat = sleepy ? 0.62 : 0.95
        if per.near && per.moving && per.dH < 230 { peek = 1.12 }
        if per.startle || (ptrSpeed > 2400 && per.dH < 170 && toy.place != .held) { duckUntil = time + 1.3 }
        if swat != nil { peek = 1.25 }                 // rise up to bat over the rim
        if time < duckUntil { peek = 0 }
        let dizzyNow = time < dizzyUntil
        if dizzyNow { peek = 0.88 + sin(time * 2.2) * 0.07 }   // sways woozily at the rim
        d.peek.target = peek
        d.peek.step(dt)
        placeInBox(d.peek.x)
        rim.target = d.peek.x > 0.85 && !sleepy ? 1 : 0
        open.target = sleeping ? 0 : 1
        if dizzyNow {
            // swirly eyes do the looking
        } else if (per.near && interest > 0.15) || per.dH < 160 {
            lookAt(ptrX, ptrY)
            faceTo(ptrX, 30 * scale)     // turn the whole body, not just the head
        } else if t.truncatingRemainder(dividingBy: 2.6) < dt {
            gx.target = rnd(-0.7, 0.7); gy.target = rnd(-0.2, 0.4); headFacing.target = chance(0.5) ? 1 : -1
        }
        tilt.target = per.idle > 0.4 && per.idle < 3 && per.dH < 200 ? 0.28 : 0
        if dizzyNow {
            lean.target = sin(time * 2.6) * 0.09
            tilt.target = sin(time * 3.3) * 0.3; pitch.target = cos(time * 3.3) * 0.12
            earL.target = 0.45; earR.target = 0.2
        } else {
            lean.target = 0
        }
        // petting in the box
        if petTime > 0.25 {
            if petTime - dt <= 0.25 { say(.mew, 0.4) }
            happy.target = 1; purr.target = 1
            if t.truncatingRemainder(dividingBy: 0.7) < dt { emitHeart() }
        }
        // batting from the box
        let facingPtr = abs(ptrX - pos.x) < 12 * scale || (sgn(ptrX - pos.x) == sgn(facing.x) && abs(facing.x) > 0.8)
        if swat == nil && !dizzyNow && facingPtr && per.dH < 75 * scale && per.dH > 30 * scale && per.moving && ptrSpeed < 1500 && d.peek.x > 0.9 && chance(dt * 1.6) {
            startSwat(CGPoint(x: ptrX, y: ptrY))
        }
        if swat != nil { rim.target = 0 }
        if roams && (time > d.next || time > visitAt) && !sleepy && petTime == 0 && !dizzyNow {
            if time > visitAt { visitPending = true }
            letOut()
        }
    }

    private func dizzyTick(_ dt: CGFloat) {
        mood(.relaxed); tailAmp.target = 0.02
        if time < dizzyUntil {
            // stagger a few wobbly steps, then plop down and sway
            let fs: CGFloat = facing.target >= 0 ? 1 : -1
            if t < 1.6 {
                pose(.stand)
                velX = fs * 32 * scale * (0.5 + 0.5 * sin(t * 3)); pos.x += velX * dt
            } else {
                pose(.sit); brake(dt)
            }
            lean.target = sin(t * 2.4) * 0.13
            tilt.target = sin(t * 3.3) * 0.3; pitch.target = cos(t * 3.3) * 0.12
            earL.target = 0.45; earR.target = 0.2
            headFacing.target = fs
        } else {
            // shake it off
            if d.wait == 0 { d.wait = t }
            let k = t - d.wait, fade = max(0, 1 - k / 0.6)
            pose(.sit); brake(dt); lean.target = 0
            tilt.target = sin(k * 34) * 0.32 * fade
            earL.target = sin(k * 34) * 0.4 * fade; earR.target = -sin(k * 34) * 0.4 * fade
            if k > 0.75 { enter(chance(0.5) ? .groom : .sit) }
        }
    }

    /// Trots over to the pointer with its tail up, sits by it and looks up. Follows once or twice if it moves off.
    private func visit(_ dt: CGFloat, _ per: Perception) {
        let tx = clamp(ptrX, minX, maxX)
        let side: CGFloat = sgn(tx - pos.x) == 0 ? 1 : sgn(tx - pos.x)
        mood(.happy); lookAt(ptrX, ptrY)
        if !d.ready {
            pose(.stand)
            if moveToward(tx - side * 55 * scale, 120, dt, 8) {
                d.ready = true; d.wait = 0; faceTo(ptrX, 1); emitHeart()
                say(chance(0.45) ? .meow : .mew)
            }
            if t > 25 { enter(.sit) }
        } else {
            pose(.sit); brake(dt); faceTo(ptrX, 10)
            happy.target = 0; tilt.target = 0.22 * d.tiltSign; purr.target = 0.45
            d.wait += dt
            if chance(dt * 0.4) { emitHeart() }
            if abs(tx - pos.x) > 160 * scale && d.left < 2 { d.ready = false; d.left += 1 }
            else if d.wait > d.dur { enter(decideOut(per)) }
        }
    }

    // MARK: Toy

    private func placeToyInBox() {
        toy.place = .box; toy.vx = 0; toy.vy = 0; toy.spin = 0; toy.angle = -0.3; toy.facing = 1
        toy.pos = CGPoint(x: box.x + 32 * scale, y: box.y + boxRim + toyRadius * 0.15)
    }

    private func stepToy(_ dt: CGFloat) {
        guard let kind = toyKind else { return }
        let r = toyRadius
        switch toy.place {
        case .box:
            placeToyInBox()
        case .held:
            toy.pos = CGPoint(x: ptrX - toy.grab.dx, y: ptrY - toy.grab.dy)
            toy.vx = ptrVX; toy.vy = ptrVY; toy.spin = 0
            toy.angle += (clamp(-ptrVX * 0.0005, -0.6, 0.6) - toy.angle) * min(1, dt * 8)   // swings as you wave it
            if abs(ptrVX) > 60 { toy.facing = sgn(ptrVX) }
        case .carried:
            let sk = skeleton()
            toy.pos = toWorld(sk.p.kx + 16, sk.p.ky - 13)
            toy.vx = 0; toy.vy = 0; toy.angle = 0.15; toy.facing = facing.x >= 0 ? 1 : -1
        case .free:
            toy.vy -= 1900 * dt
            toy.pos.x += toy.vx * dt; toy.pos.y += toy.vy * dt
            toy.angle += toy.spin * dt
            // dropped into the box
            let rimY = box.y + boxRim
            if boxShow.x > 0.5 && toy.vy < 0 && toy.pos.x > box.x + 12 * scale && toy.pos.x < box.x + boxW - 12 * scale
                && toy.pos.y < rimY + r && toy.pos.y > rimY - 25 * scale {
                placeToyInBox(); return
            }
            if toy.pos.y - r <= floorY {
                toy.pos.y = floorY + r
                if toy.vy < -120 { toy.vy = -toy.vy * 0.42; toy.spin *= 0.7 } else { toy.vy = 0 }
                toy.vx *= exp(-dt * (kind.rolls ? 1.6 : 4.5))
                if abs(toy.vx) < 4 { toy.vx = 0 }
                if kind.rolls {
                    toy.spin = -toy.vx / r
                } else {           // slides, and settles the right way up
                    toy.spin *= exp(-dt * 8)
                    let a = atan2(sin(toy.angle), cos(toy.angle))
                    toy.angle = a - a * min(1, dt * 6)
                }
            }
            let lo = minX - 40 * scale, hi = maxX + 40 * scale
            if toy.pos.x < lo { toy.pos.x = lo; toy.vx = abs(toy.vx) * 0.5 }
            if toy.pos.x > hi { toy.pos.x = hi; toy.vx = -abs(toy.vx) * 0.5 }
            if toy.pos.y + r > maxY { toy.pos.y = maxY - r; toy.vy = -abs(toy.vy) * 0.4 }
            if abs(toy.vx) > 30 { toy.facing = sgn(toy.vx) }
        }
    }

    /// Pointer pressed on the toy. Returns false if there's nothing to pick up.
    func grabToy() -> Bool {
        guard toyKind != nil else { return false }
        if toy.place == .box && boxShow.x < 0.5 { return false }
        toy.grab = CGVector(dx: ptrX - toy.pos.x, dy: ptrY - toy.pos.y)
        toy.place = .held      // also takes it out of the cat's mouth
        return true
    }

    /// Let go of the toy: it flies off with the pointer's speed, or drops into the box if it's over it.
    func throwToy() {
        guard toy.place == .held else { return }
        let rimY = box.y + boxRim
        let overBox = toy.pos.x > box.x && toy.pos.x < box.x + boxW && toy.pos.y > rimY - 20 * scale && toy.pos.y < rimY + 70 * scale
        if overBox && hypot(ptrVX, ptrVY) < 300 && boxShow.x > 0.5 { placeToyInBox(); return }
        toy.place = .free
        toy.vx = clamp(ptrVX, -2600, 2600) * 0.9
        toy.vy = clamp(ptrVY, -1500, 2600) * 0.9
        toy.spin = -toy.vx / max(toyRadius, 1) * 0.4 + rnd(-3, 3)
    }

    /// Takes the toy in its mouth, from your pointer or off the floor.
    private func snatchToy() {
        toy.place = .carried; toy.vx = 0; toy.vy = 0
        happyUntil = time + 0.8
        lastToyPlay = time
    }

    /// Trots off with the toy in its mouth, sits with it, then drops it to play again
    /// or, if it's tired, takes it home.
    private func trophy(_ dt: CGFloat) {
        guard toy.place == .carried else { enter(decideOut(perceiveQuiet())); return }
        mood(.happy); lastToyPlay = time
        if !d.ready {
            pose(.stand); lookForward()
            if moveToward(d.x, 150, dt, 8) || t > 6 { d.ready = true; d.wait = 0 }
        } else {
            pose(.sit); brake(dt); idleLookForward()
            d.wait += dt
            if d.wait > d.dur {
                if playEnergy < 0.35 { go(.goHome) }
                else { toy.place = .free; toy.vx = 0; toy.vy = 0; enter(.chase) }
            }
        }
    }

    private func perceiveQuiet() -> Perception {
        Perception(head: headWorld(), dH: hypot(ptrX - headWorld().x, ptrY - headWorld().y), idle: time - ptrLastMove,
                   moving: time - ptrLastMove < 0.25, near: false, startle: false)
    }

    private func idleLookForward() {
        gx.target = 0.3 * sgn(facing.target); gy.target = 0; pitch.target = 0.05; headFacing.target = sgn(facing.target)
    }

    private func batToy() {
        let fs: CGFloat = facing.target >= 0 ? 1 : -1
        let dir: CGFloat = sgn(toy.pos.x - pos.x) == 0 ? fs : sgn(toy.pos.x - pos.x)
        startSwat(toy.pos)
        toy.place = .free
        toy.vx = dir * rnd(260, 520) * scale; toy.vy = rnd(140, 380); toy.spin = rnd(-14, 14)
        lastToyHit = time
        playEnergy = max(0, playEnergy - 0.025)
    }

    /// Runs after the toy, leads it while it flies, leaps at it, bats it about, pounces on it.
    private func chase(_ dt: CGFloat) {
        guard toyKind != nil, toy.place == .free || toy.place == .held else { enter(.sit); return }
        let r = toyRadius, fs: CGFloat = facing.target >= 0 ? 1 : -1
        mood(.hunt); lookAt(toy.pos.x, toy.pos.y); dil.target = 1
        lastToyPlay = time
        playEnergy = max(0, playEnergy - dt / 50)
        let height = toy.pos.y - r - floorY
        var tx = toy.pos.x
        if toy.place == .free && height > 4 {          // where it'll come down
            let g: CGFloat = 1900
            let tFall = (toy.vy + sqrt(max(0, toy.vy * toy.vy + 2 * g * height))) / g
            tx = toy.pos.x + toy.vx * min(tFall, 1.2)
        }
        tx = clamp(tx, minX, maxX)
        let dx = tx - pos.x, side: CGFloat = sgn(dx) == 0 ? fs : sgn(dx)
        if d.wait > 0 {                                  // just batted it: watch it go
            d.wait -= dt; pose(.crouch); crouch.target = 0.5; brake(dt); faceTo(toy.pos.x, 10)
            return
        }
        let reach = 240 * scale, near = abs(toy.pos.x - pos.x)
        if height > 25 * scale && height < reach && near < 150 * scale && time > nextLeap {
            nextLeap = time + rnd(0.7, 1.3)
            startSwat(toy.pos)
            launch(clamp(toy.pos.x - side * 14 * scale, minX, maxX), floorY, height + 20 * scale, .land)
            return
        }
        if height >= reach && toy.place == .held && near < 110 * scale { enter(.climb); return }
        if height <= 25 * scale && near < 30 * scale + r {
            if toy.place == .free {
                if chance(0.4) && toySpeed < 200 && time > nextLeap {
                    nextLeap = time + 0.8
                    launch(toy.pos.x, floorY, 26 * scale, .pin)          // pounce
                } else {
                    batToy(); d.wait = rnd(0.5, 1.1)
                }
                return
            } else {                                                      // dangled in front of its nose
                if swat == nil && chance(dt * 2) { startSwat(toy.pos) }
                let h = headWorld()
                if hypot(toy.pos.x - h.x, toy.pos.y - h.y) < 34 * scale + r {
                    d.wiggle += dt
                    if d.wiggle > 0.5 && chance(dt * 2.5) { snatchToy(); enter(.trophy); return }
                }
            }
        }
        let fast = near > 200 * scale
        pose(fast ? .stand : .crouch)
        if !fast { crouch.target = 0.35 }
        let arrived = moveToward(tx - side * (14 * scale + r), fast ? 320 : 170, dt, 6)
        // Tired of it: picks it up and takes it home.
        if arrived && toyResting && (playEnergy < 0.25 || t > d.dur) { snatchToy(); go(.goHome) }
        else if t > d.dur + 10 { enter(.sit) }
    }

    /// The toy is held out of reach: claws its way up the screen after it, then lets go and drops.
    private func climb(_ dt: CGFloat) {
        pose(.stand); hold.target = 1; climbView.target = 1
        mood(.hunt); tailBase.target = -1.45; tailCurl.target = 0.1; tailAmp.target = 0.06
        earL.target = 0.1; earR.target = 0.1; dil.target = 1
        gx.target = clamp((toy.pos.x - pos.x) / (160 * scale), -0.6, 0.6); gy.target = 0.8   // looking up at it
        lastToyPlay = time
        // Climbs until its paws are at the toy (they reach ~30 above the head), up to 60% of the screen.
        let maxH = max(0, (maxY - floorY) * 0.6)
        let want = clamp(toy.pos.y - floorY - 74 * scale - 25 * scale, 0, maxH)
        // Climbs in strokes, about two a second: the body only rises during the push, so it holds,
        // gathers, surges up, re-hooks, rather than scrabbling. d.landY is the height of finished strokes.
        let stroke = Self.climbStroke * scale
        let moreToGo = toy.place == .held && t < d.dur && want > d.landY + 4 * scale
        if moreToGo || climbPhase > 0 {
            climbPhase += dt / 0.5
            if climbPhase >= 1 { climbPhase = 0; d.landY += stroke; climbLead = -climbLead }
        }
        if !moreToGo && climbPhase == 0 && want < d.landY - stroke * 1.5 {
            d.landY = max(0, d.landY - 60 * scale * dt)     // toy lowered: slides down a bit
        }
        d.x = d.landY + smoothstep(clamp01((climbPhase - 0.35) / 0.25)) * stroke
        pos.x += clamp(toy.pos.x - pos.x, -45 * dt, 45 * dt)
        pos.y = floorY + d.x + 74 * scale * clamp01(hold.x)     // feet stay on the wall as it turns upright
        // At the top: reach for it with the nearer paw, then grab it in its mouth.
        let paws = CGPoint(x: pos.x, y: pos.y + 22 * scale)
        let gap = hypot(toy.pos.x - paws.x, toy.pos.y - paws.y)
        climbReachSide = toy.pos.x >= pos.x ? 1 : -1
        climbReach.target = gap < 80 * scale ? 1 : 0
        if toy.place == .held && gap < 32 * scale + toyRadius {
            d.wiggle += dt
            if d.wiggle > 0.45 && chance(dt * 3) {
                snatchToy()
                climbView.target = 0; hold.target = 0
                pos.y = floorY + d.x
                air = true; velY = 80; velX = 0
                go(.air, ActData(then: .land))
                return
            }
        }
        if toy.place != .held || t > d.dur || abs(toy.pos.x - pos.x) > 220 * scale {
            hold.target = 0; paddle.target = 0; climbView.target = 0
            pos.y = floorY + d.x
            air = true; velY = 60
            velX = toy.place == .free ? clamp((toy.pos.x - pos.x) * 1.2, -350, 350) : 0
            go(.air, ActData(then: .land))
        }
    }

    private func heldTick(_ dt: CGFloat) {
        pose(.stand); hold.target = 1; sit.target = 0
        earL.target = 0.5; earR.target = 0.5; mood(.scared); tailPuff.target = 1
        tailBase.target = -1.45; tailCurl.target = 0.08   // hangs down
        open.target = 1; dil.target = 1

        // Every second or two it changes what it's doing; being whisked around or lowered
        // near the floor takes priority.
        let nearFloor = ptrY - floorY < 130 * scale
        if ptrSpeed > 1100 {
            if heldGesture != .scramble { heldGesture = .scramble; heldNext = time + 0.8 }
        } else if nearFloor && heldGesture != .reachDown && heldGesture != .scramble {
            heldGesture = .reachDown; heldNext = time + rnd(1.5, 3)
        } else if time > heldNext {
            heldGesture = nearFloor ? .reachDown : pickHeld()
            heldNext = time + rnd(1.0, 2.6)
        }
        let fs: CGFloat = facing.x >= 0 ? 1 : -1
        switch heldGesture {
        case .limp:
            paddleRate = 2
            lookAt(ptrX + fs * 40, ptrY - 80)
        case .reach:      // paws up and forward, as if reaching for your arm
            heldFX.target = 16; heldFY.target = 24; heldBX.target = 6; heldBY.target = 4
            curl.target = 0.2; paddle.target = 0.15; paddleRate = 4
            earL.target = 0.1; earR.target = 0.1
            lookAt(ptrX + fs * 60, ptrY + 10)
        case .paddle:     // air-walking
            heldFX.target = 8; heldFY.target = 6; heldBX.target = 4; heldBY.target = 6
            curl.target = 0.1; paddle.target = 1; paddleRate = 7
            lookAt(ptrX + fs * 50, ptrY - 120)
        case .tuck:       // curls up, paws tucked to the chest, tail curled under
            heldFX.target = 10; heldFY.target = 14; heldBX.target = 14; heldBY.target = 18
            curl.target = 1; paddle.target = 0; paddleRate = 2
            tailCurl.target = 0.32; earL.target = 0.25; earR.target = 0.25
            lookAt(ptrX + fs * 30, ptrY - 40)
        case .reachDown:  // close to the floor: stretches all four legs down to land
            heldFX.target = 6; heldFY.target = -10; heldBX.target = 2; heldBY.target = -12
            curl.target = -0.2; paddle.target = 0.35; paddleRate = 5
            earL.target = 0; earR.target = 0
            lookAt(ptrX + fs * 20, floorY)
        case .scramble:   // whisked about: paddling hard, ears back
            heldFX.target = 10; heldFY.target = 8; heldBX.target = 4; heldBY.target = 8
            curl.target = 0.3; paddle.target = 1.3; paddleRate = 11
            earL.target = 0.8; earR.target = 0.8
            lookAt(ptrX + fs * 40, ptrY - 80)
        }
        paddlePhase += dt * paddleRate
        swing.target = clamp(-ptrVX / 2200, -0.5, 0.5)
        dangle.target = clamp(-ptrVX * 0.018, -26, 26) * scale
        stretch.target = clamp(ptrVY * 0.01, -6, 12)
        pos = CGPoint(x: ptrX, y: ptrY - 8 * scale)
        boxShow.target = 1
    }

    private func pickHeld() -> HeldGesture {
        let opts: [(HeldGesture, CGFloat)] = [(.limp, 25), (.reach, 22), (.paddle, 18), (.tuck, 15)]
        let others = opts.filter { $0.0 != heldGesture }
        var r = CGFloat.random(in: 0..<others.reduce(0) { $0 + $1.1 })
        for (g, w) in others { r -= w; if r <= 0 { return g } }
        return .limp
    }

    // MARK: Commands from the app

    func letOut() {
        guard act == .inBox else { return }
        rim.target = 0; swat = nil; paw.target = 0; happy.target = 0; purr.target = 0
        go(.leaving, ActData(peekValue: d.peek.x))
    }

    func callHome() {
        if isHome || act == .goHome || act == .air || act == .held { return }
        sleeping = false
        go(.goHome)
    }

    func clickCat() {
        if act == .inBox { letOut(); return }
        if committed { return }
        if act == .sleep { sleeping = false; enter(.yawn); return }
        emitHeart()
        happyUntil = time + 0.6
    }

    func pickUp() {
        if act == .leaving { return }
        boxClip = nil; rim.snap(0); air = false; held = true; sleeping = false
        if toy.place == .carried { toy.place = .free; toy.vy = 0 }
        swat = nil; paw.target = 0; happy.target = 0; purr.target = 0
        facing.target = sgn(facing.x) == 0 ? 1 : sgn(facing.x)
        heldGesture = chance(0.5) ? .reach : .paddle; heldNext = time + rnd(0.8, 1.6)   // first reaction to being lifted
        if chance(0.5) { lastVocal = -10; say(.meow) }
        go(.held)
    }

    func release() {
        held = false; hold.target = 0; swing.target = 0; earL.target = 0; earR.target = 0
        let overBox = ptrX > box.x - 10 && ptrX < box.x + boxW + 10 && ptrY > box.y && ptrY < box.y + boxRim + 120
        air = true
        if overBox {
            velX = 0; velY = 0
            go(.air, ActData(landY: box.y + boxRim - 30 * scale, then: .box))
        } else {
            velX = clamp(ptrVX * 0.5, -500, 500); velY = clamp(ptrVY * 0.3, -200, 400)
            boxShow.target = toyInBox ? 1 : 0
            outSince = time
            go(.air, ActData(bored: rnd(90, 240), then: .land))
            d.landY = floorY
        }
    }

    var statusLabel: String {
        if act == .inBox && time < dizzyUntil { return "Dizzy in the box" }
        if act == .inBox && sleeping { return "Dozing in the box" }
        if act == .inBox && happy.target > 0 { return "Being petted" }
        return act.label
    }
}
