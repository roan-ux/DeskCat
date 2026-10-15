import AppKit

/// An sRGB colour that's easy to store, mix and convert.
struct RGB: Equatable {
    var r: CGFloat, g: CGFloat, b: CGFloat

    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
        self.r = r; self.g = g; self.b = b
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(CGFloat((v >> 16) & 0xff) / 255, CGFloat((v >> 8) & 0xff) / 255, CGFloat(v & 0xff) / 255)
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((clamp01(r) * 255).rounded()), Int((clamp01(g) * 255).rounded()), Int((clamp01(b) * 255).rounded()))
    }

    func mix(_ o: RGB, _ t: CGFloat) -> RGB { RGB(lerp(r, o.r, t), lerp(g, o.g, t), lerp(b, o.b, t)) }
    func cg(_ alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var luminance: CGFloat { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    static let black = RGB(0, 0, 0)
    static let white = RGB(1, 1, 1)
    static let ink = RGB(0.114, 0.114, 0.122)
}

struct Swatch {
    let name: String
    let color: RGB
}

enum CatSize: String, CaseIterable {
    case small, medium, large
    var scale: CGFloat {
        switch self {
        case .small: return 0.8
        case .medium: return 1
        case .large: return 1.3
        }
    }
    var title: String { rawValue.capitalized }
}

enum Personality: String, CaseIterable {
    case calm, normal, playful
    var title: String { rawValue.capitalized }
    /// How readily it plays with the pointer (0...1).
    var playfulness: CGFloat {
        switch self {
        case .calm: return 0.35
        case .normal: return 0.7
        case .playful: return 0.95
        }
    }
    /// Seconds before it leaves the box on its own.
    var roamDelay: ClosedRange<CGFloat> {
        switch self {
        case .calm: return 240...480
        case .normal: return 90...240
        case .playful: return 40...110
        }
    }
}

/// Everything you can customise about how the cat looks and acts. Saved in UserDefaults.
struct Look: Equatable {
    var coat: RGB
    var eyes: RGB
    var box: RGB
    var size: CatSize
    var personality: Personality

    static let coats = [
        Swatch(name: "Black", color: RGB(0.114, 0.114, 0.122)),
        Swatch(name: "Charcoal", color: RGB(0.36, 0.37, 0.40)),
        Swatch(name: "Ginger", color: RGB(0.88, 0.54, 0.24)),
        Swatch(name: "Cream", color: RGB(0.95, 0.89, 0.78)),
        Swatch(name: "White", color: RGB(0.97, 0.97, 0.96)),
    ]
    static let eyeColors = [
        Swatch(name: "White", color: RGB(1, 1, 1)),
        Swatch(name: "Gold", color: RGB(0.96, 0.78, 0.29)),
        Swatch(name: "Green", color: RGB(0.62, 0.83, 0.42)),
        Swatch(name: "Blue", color: RGB(0.55, 0.78, 0.94)),
    ]
    static let boxColors = [
        Swatch(name: "Yellow", color: RGB(0.96, 0.88, 0.36)),
        Swatch(name: "Kraft", color: RGB(0.79, 0.60, 0.38)),
        Swatch(name: "Pink", color: RGB(0.96, 0.65, 0.75)),
        Swatch(name: "Mint", color: RGB(0.65, 0.89, 0.77)),
        Swatch(name: "Sky", color: RGB(0.62, 0.79, 0.95)),
    ]

    static let standard = Look(coat: coats[0].color, eyes: eyeColors[0].color, box: boxColors[0].color,
                               size: .medium, personality: .normal)

    /// The live look. Setting it saves it and rebuilds the drawing colours.
    static var current = Look.load() {
        didSet {
            current.save()
            Palette.current = Palette(current)
        }
    }

    static func load() -> Look {
        let d = UserDefaults.standard
        var look = standard
        if let v = d.string(forKey: "coat").flatMap(RGB.init(hex:)) { look.coat = v }
        if let v = d.string(forKey: "eyes").flatMap(RGB.init(hex:)) { look.eyes = v }
        if let v = d.string(forKey: "boxColor").flatMap(RGB.init(hex:)) { look.box = v }
        if let v = d.string(forKey: "size").flatMap(CatSize.init(rawValue:)) { look.size = v }
        if let v = d.string(forKey: "personality").flatMap(Personality.init(rawValue:)) { look.personality = v }
        return look
    }

    func save() {
        let d = UserDefaults.standard
        d.set(coat.hex, forKey: "coat")
        d.set(eyes.hex, forKey: "eyes")
        d.set(box.hex, forKey: "boxColor")
        d.set(size.rawValue, forKey: "size")
        d.set(personality.rawValue, forKey: "personality")
    }
}

/// Drawing colours derived from the look, rebuilt only when the look changes.
struct Palette {
    static var current = Palette(Look.current)

    // cat
    let coat: CGColor
    let coatFar: CGColor        // far-side legs, a touch off the coat for depth
    let pawRim: CGColor         // rim around a paw held in front of the face
    let detail: CGColor         // toe lines, closed and happy eyes
    let sclera: CGColor
    let eyeRing: CGColor?       // outline so pale eyes still read on a pale coat
    let pupil: CGColor
    let mouth = RGB(1, 0.561, 0.639).cg()
    let heart = RGB(1, 0.42, 0.545).cg()
    let shadow = RGB.black.cg()
    let inkText = RGB.ink.ns
    // box
    let boxTop: CGColor
    let boxBottom: CGColor
    let boxFlap: CGColor
    let boxFlapDark: CGColor
    let boxShade: RGB
    let boxScratch: CGColor
    let boxCrease: CGColor
    let boxText: NSColor

    init(_ look: Look) {
        let c = look.coat
        let light = c.luminance > 0.55
        coat = c.cg()
        coatFar = (light ? c.mix(.black, 0.1) : c.mix(.white, 0.07)).cg()
        pawRim = (light ? c.mix(.black, 0.3) : c.mix(.white, 0.22)).cg()
        detail = light ? RGB.ink.cg(0.85) : RGB.white.cg()
        sclera = look.eyes.cg()
        eyeRing = abs(look.eyes.luminance - c.luminance) < 0.35 ? RGB.ink.cg(0.8) : nil
        pupil = RGB(0.07, 0.07, 0.08).cg()

        let b = look.box
        boxTop = b.mix(.white, 0.1).cg()
        boxBottom = b.mix(.black, 0.06).cg()
        boxFlap = b.mix(.black, 0.08).cg()
        boxFlapDark = b.mix(.black, 0.15).cg()
        boxShade = b.mix(.black, 0.7)
        boxScratch = b.mix(.black, 0.5).cg(0.32)
        boxCrease = b.mix(.black, 0.7).cg(0.28)
        boxText = b.luminance < 0.45 ? RGB.white.ns : RGB.ink.ns
    }
}
