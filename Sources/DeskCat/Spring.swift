import CoreGraphics

/// Damped spring. Everything that moves eases toward a target through one of these, which gives
/// the motion its follow-through and settle. `f` is how fast (Hz), `z` how bouncy:
/// 1 settles without overshoot, ~0.3 wobbles.
struct Spring {
    var x: CGFloat
    var v: CGFloat = 0
    var target: CGFloat
    var f: CGFloat
    var z: CGFloat

    init(_ x: CGFloat, f: CGFloat, z: CGFloat) {
        self.x = x
        self.target = x
        self.f = f
        self.z = z
    }

    mutating func step(_ dt: CGFloat) {
        let w = 2 * .pi * f, k = w * w, c = 2 * z * w
        // Small fixed substeps keep stiff springs stable even when a frame arrives late.
        let n = max(1, Int((dt * 240).rounded(.up)))
        let h = dt / CGFloat(n)
        for _ in 0..<n {
            v += (k * (target - x) - c * v) * h
            x += v * h
        }
    }

    mutating func snap(_ value: CGFloat) {
        x = value
        target = value
        v = 0
    }
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }
func clamp01(_ v: CGFloat) -> CGFloat { clamp(v, 0, 1) }
func rnd(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b) }
func chance(_ p: CGFloat) -> Bool { CGFloat.random(in: 0..<1) < p }
func smoothstep(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }
func sgn(_ v: CGFloat) -> CGFloat { v > 0 ? 1 : (v < 0 ? -1 : 0) }
