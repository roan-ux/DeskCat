import Foundation

// Cat sounds, synthesised in code like the cat itself is drawn in code: no recordings.
// A meow is a little voice: a buzzy source at the cat's pitch, shaped by three formant
// filters that follow the mouth as it opens ("m"), stretches ("ee") and rounds ("ow").
// Each one comes out slightly different. Everything is placed in stereo by where the cat
// is on screen (level, a fraction of a millisecond between the ears, and a few early
// reflections) so it doesn't sound flat or muffled.

enum CatSound: CaseIterable {
    case meow, mew, demand, trill, chatter, hiss
}

/// Small fast RNG that's safe to use on the audio thread (no locks, no allocation).
struct NoiseGen {
    private var state: UInt32
    init(seed: UInt32 = UInt32.random(in: 1...UInt32.max)) { state = seed }
    /// Uniform in -1...1.
    mutating func next() -> Float {
        state ^= state << 13; state ^= state >> 17; state ^= state << 5
        return Float(state) / Float(UInt32.max) * 2 - 1
    }
}

/// RBJ biquad, used as a band-pass (0 dB peak) or one-pole-ish low-pass.
struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    mutating func bandPass(_ f: Float, q: Float, sampleRate sr: Float) {
        let w = 2 * Float.pi * min(f, sr * 0.45) / sr, alpha = sin(w) / (2 * q), a0 = 1 + alpha
        b0 = alpha / a0; b1 = 0; b2 = -alpha / a0; a1 = -2 * cos(w) / a0; a2 = (1 - alpha) / a0
    }

    mutating func lowPass(_ f: Float, q: Float = 0.707, sampleRate sr: Float) {
        let w = 2 * Float.pi * min(f, sr * 0.45) / sr, alpha = sin(w) / (2 * q), a0 = 1 + alpha, c = cos(w)
        b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = b0; a1 = -2 * c / a0; a2 = (1 - alpha) / a0
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

private func sstep(_ x: Float) -> Float { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }
private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
private func jit(_ v: Float, _ amount: Float) -> Float { v * (1 + Float.random(in: -amount...amount)) }

enum SoundSynth {
    /// A mono, dry take of the sound.
    static func render(_ sound: CatSound, sampleRate sr: Float) -> [Float] {
        switch sound {
        case .meow:
            let s = jit(470, 0.08), p = jit(760, 0.08), e = jit(500, 0.1)
            return voice(dur: jit(0.7, 0.15), sr: sr, amp: 0.5,
                         f0: { u in u < 0.35 ? mix(s, p, sin(.pi / 2 * u / 0.35)) : mix(p, e, sstep((u - 0.35) / 0.65)) },
                         open: { u in sstep((u - 0.04) / 0.3) * (1 - 0.55 * sstep((u - 0.55) / 0.45)) },
                         round: { u in sstep((u - 0.45) / 0.55) })
        case .mew:      // short and rising at the end: a little question
            let s = jit(640, 0.08), p = jit(880, 0.06)
            return voice(dur: jit(0.32, 0.15), sr: sr, amp: 0.4,
                         f0: { u in u < 0.5 ? mix(s, p, sstep(u / 0.5)) : mix(p, p * 0.94, sstep((u - 0.5) / 0.5)) },
                         open: { u in sstep(u / 0.2) * (1 - 0.4 * sstep((u - 0.7) / 0.3)) },
                         round: { u in 0.2 * sstep((u - 0.5) / 0.5) })
        case .demand:   // long, insistent "maaa-ow"
            let s = jit(520, 0.06), p = jit(830, 0.06), e = jit(430, 0.08)
            return voice(dur: jit(1.1, 0.12), sr: sr, amp: 0.55,
                         f0: { u in u < 0.3 ? mix(s, p, sin(.pi / 2 * u / 0.3)) : mix(p, e, sstep((u - 0.3) / 0.7)) },
                         open: { u in sstep((u - 0.03) / 0.22) * (1 - 0.6 * sstep((u - 0.6) / 0.4)) },
                         round: { u in sstep((u - 0.4) / 0.6) })
        case .trill:    // "mrrrp": mostly closed mouth, rolled, rising
            let s = jit(390, 0.08), e = jit(620, 0.08)
            return voice(dur: jit(0.34, 0.15), sr: sr, amp: 0.42,
                         f0: { u in mix(s, e, sstep(u)) },
                         open: { u in 0.15 + 0.35 * sstep(u / 0.6) },
                         round: { _ in 0.35 },
                         roll: (rate: jit(27, 0.1), depth: 0.85), breath: 0.04)
        case .chatter:  // "ek-ek-ek" at something it can't reach
            var out: [Float] = []
            let clicks = Int.random(in: 5...8), f = jit(1050, 0.1)
            for _ in 0..<clicks {
                out += voice(dur: jit(0.05, 0.2), sr: sr, amp: 0.3,
                             f0: { u in f * (1 - 0.15 * u) }, open: { u in sin(.pi * u) }, round: { _ in 0 }, breath: 0.12)
                out += [Float](repeating: 0, count: Int(sr * jit(0.04, 0.3)))
            }
            return out
        case .hiss:
            return hiss(dur: jit(0.75, 0.15), sr: sr)
        }
    }

    /// Source -> mouth. `u` runs 0...1 across the sound.
    private static func voice(dur: Float, sr: Float, amp: Float,
                              f0: (Float) -> Float, open: (Float) -> Float, round: (Float) -> Float,
                              roll: (rate: Float, depth: Float)? = nil, breath: Float = 0.06) -> [Float] {
        let n = max(1, Int(dur * sr))
        var out = [Float](repeating: 0, count: n)
        var rng = NoiseGen()
        var f1 = Biquad(), f2 = Biquad(), f3 = Biquad(), tilt = Biquad()
        tilt.lowPass(5200, sampleRate: sr)
        var phase: Float = 0, wander: Float = 0, o: Float = 0
        let vibRate = Float.random(in: 4.5...6.5)
        for i in 0..<n {
            let u = Float(i) / Float(n), t = Float(i) / sr
            if i % 32 == 0 {
                o = open(u)
                let r = round(u)
                f1.bandPass(320 + 880 * o - 140 * r, q: 4.5, sampleRate: sr)
                f2.bandPass(1900 + 450 * o - 850 * r, q: 7, sampleRate: sr)
                f3.bandPass(3100 + 350 * o - 250 * r, q: 9, sampleRate: sr)
            }
            wander += (rng.next() - wander) * 0.003          // slow pitch wander, so it isn't robotic
            let vib = 1 + 0.012 * sin(2 * .pi * vibRate * t) * sstep(u / 0.4)
            let f = f0(u) * vib * (1 + 0.02 * wander)
            let dp = f / sr
            phase += dp
            if phase >= 1 { phase -= 1 }
            let saw = 2 * phase - 1 - polyBLEP(phase, dp)
            let x = tilt.process(-saw * 0.7 + rng.next() * breath)
            var y = f1.process(x) + 0.65 * f2.process(x) + 0.3 * f3.process(x) + 0.03 * x
            let attack = min(1, t / 0.035), release = min(1, (dur - t) / 0.07)
            y *= attack * release * (0.3 + 0.7 * o)
            if let roll { y *= 1 - roll.depth * 0.5 * (1 + sin(2 * .pi * roll.rate * t)) }
            out[i] = y
        }
        return normalized(out, to: amp)
    }

    private static func hiss(dur: Float, sr: Float) -> [Float] {
        let n = Int(dur * sr)
        var out = [Float](repeating: 0, count: n)
        var rng = NoiseGen()
        var hi = Biquad(), mid = Biquad()
        hi.bandPass(4200, q: 0.8, sampleRate: sr)
        mid.bandPass(2300, q: 1.2, sampleRate: sr)
        for i in 0..<n {
            let t = Float(i) / sr
            let x = rng.next()
            let spit: Float = t < 0.03 ? 1.8 : 1              // a sharp "kh" at the start
            let env = min(1, t / 0.012) * min(1, (dur - t) / 0.25) * (1 - 0.3 * t / dur)
            out[i] = (hi.process(x) + 0.6 * mid.process(x)) * env * spit
        }
        return normalized(out, to: 0.38)
    }

    private static func polyBLEP(_ t: Float, _ dt: Float) -> Float {
        if t < dt { let x = t / dt; return x + x - x * x - 1 }
        if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
        return 0
    }

    private static func normalized(_ v: [Float], to peak: Float) -> [Float] {
        let m = v.reduce(0) { max($0, abs($1)) }
        return m > 0 ? v.map { $0 * peak / m } : v
    }

    /// Places a mono take in stereo. `pan` is -1 (left) ... 1 (right).
    static func spatialize(_ mono: [Float], pan: Float, sampleRate sr: Float) -> (left: [Float], right: [Float]) {
        let p = min(max(pan, -1), 1)
        let angle = (p + 1) * .pi / 4
        let gl = cos(angle), gr = sin(angle)
        let itd = Int(abs(p) * 0.00045 * sr)               // the far ear hears it a touch later
        let tail = Int(0.03 * sr)
        let n = mono.count + tail
        var left = [Float](repeating: 0, count: n), right = [Float](repeating: 0, count: n)
        let dl = p > 0 ? itd : 0, dr = p < 0 ? itd : 0
        for i in 0..<mono.count {
            left[i + dl] += mono[i] * gl
            right[i + dr] += mono[i] * gr
        }
        // Early reflections at different times in each ear: this is what makes it sound like
        // it's in the room with you rather than inside the speaker.
        var soft = Biquad()
        soft.lowPass(4500, sampleRate: sr)
        let dull = mono.map { soft.process($0) }
        let taps: [(l: Float, r: Float, g: Float)] = [(0.0097, 0.0119, 0.2), (0.0143, 0.0168, 0.13), (0.0211, 0.0235, 0.08)]
        for tap in taps {
            let ol = Int(tap.l * sr), or = Int(tap.r * sr)
            for i in 0..<dull.count {
                if i + ol < n { left[i + ol] += dull[i] * tap.g * (0.6 + 0.4 * gl) }
                if i + or < n { right[i + or] += dull[i] * tap.g * (0.6 + 0.4 * gr) }
            }
        }
        return (left, right)
    }
}

/// The purr, rendered live on the audio thread. A purr is a rumble that pulses ~25 times a
/// second, slightly faster and louder breathing out than in. Two bands (a low rumble and a
/// throatier band around 400 Hz) so it's still audible on laptop speakers that can't play the
/// lowest part. Left and right share most of their noise but not all of it, which gives width.
final class PurrSynth {
    /// Set from the main thread; read on the audio thread.
    var targetLevel: Float = 0
    var targetPan: Float = 0
    var level: Float { lvl }

    private let sr: Float
    private var lvl: Float = 0, pan: Float = 0
    private var pulse: Float = 0, breath: Float = 0, cycle: Float = 2
    private var rng = NoiseGen(), rngL = NoiseGen(), rngR = NoiseGen()
    private var lowL = Biquad(), lowR = Biquad(), midL = Biquad(), midR = Biquad()

    init(sampleRate: Float) {
        sr = sampleRate
        lowL.bandPass(150, q: 1.1, sampleRate: sr); lowR.bandPass(150, q: 1.1, sampleRate: sr)
        midL.bandPass(420, q: 1.6, sampleRate: sr); midR.bandPass(420, q: 1.6, sampleRate: sr)
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let target = targetLevel, panTarget = targetPan
        if lvl < 0.0001 && target < 0.0001 {
            for i in 0..<frames { left[i] = 0; right[i] = 0 }
            return
        }
        for i in 0..<frames {
            lvl += (target - lvl) * 0.0006                 // ~35 ms fade
            pan += (panTarget - pan) * 0.0002
            breath += 1 / (sr * cycle)
            if breath >= 1 { breath -= 1; cycle = Float.random(in: 1.7...2.3) }
            let exhale = breath < 0.55
            let local = exhale ? breath / 0.55 : (breath - 0.55) / 0.45
            let rate: Float = exhale ? 26 : 22.5
            let breathEnv = (exhale ? 1 : 0.62) * (0.2 + 0.8 * sqrt(max(0, sin(.pi * local))))
            pulse += rate / sr
            if pulse >= 1 { pulse -= 1 }
            let c = 0.5 - 0.5 * cos(2 * .pi * pulse)
            let pulseEnv = c * c * sqrt(c)
            let common = rng.next()
            let nl = 0.75 * common + 0.25 * rngL.next(), nr = 0.75 * common + 0.25 * rngR.next()
            let l = lowL.process(nl) + 0.7 * midL.process(nl) + 0.015 * nl
            let r = lowR.process(nr) + 0.7 * midR.process(nr) + 0.015 * nr
            let angle = (pan + 1) * .pi / 4
            let g = lvl * pulseEnv * breathEnv * 3.2
            left[i] = l * g * cos(angle) * 1.414
            right[i] = r * g * sin(angle) * 1.414
        }
    }
}
