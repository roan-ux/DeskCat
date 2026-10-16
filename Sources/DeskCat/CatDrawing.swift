import AppKit

/// Soft contact shadow: a few stacked translucent ellipses, a cheap blur.
func drawGroundShadow(_ ctx: CGContext, center: CGPoint, rx: CGFloat, ry: CGFloat, alpha: CGFloat) {
    guard alpha > 0.005 else { return }
    ctx.saveGState()
    ctx.setFillColor(Palette.current.shadow)
    ctx.setAlpha(alpha * 0.32)
    for i in 0..<4 {
        let k = 1 + CGFloat(i) * 0.22
        ctx.fillEllipse(in: CGRect(x: center.x - rx * k, y: center.y - ry * k, width: rx * k * 2, height: ry * k * 2))
    }
    ctx.restoreGState()
}

/// Draws the cat in world (screen) coordinates. The caller translates the context so the
/// window's origin sits at its own (0, 0). Port of the drawing code in `playground.html`.
extension CatSim {
    func draw(in ctx: CGContext) {
        if climbView.x > 0.5 { drawClimbing(ctx); return }
        let sk = skeleton(), p = sk.p, pal = Palette.current, s = scale
        if boxClip == nil && !held {     // shadow shrinks and fades as it leaves the ground
            let k = clamp01(1 - max(0, pos.y - floorY) / 220)
            drawGroundShadow(ctx, center: CGPoint(x: pos.x, y: floorY + 1), rx: 36 * s * (0.6 + 0.4 * k), ry: 4 * s, alpha: 0.2 * k)
        }
        ctx.saveGState()
        if let clipY = boxClip {
            ctx.clip(to: CGRect(x: -100_000, y: clipY, width: 200_000, height: 100_000))
        }
        drawTail(ctx)
        drawLeg(ctx, sk.legs[.fb], pal.coatFar)
        drawLeg(ctx, sk.legs[.ff], pal.coatFar)
        let hip = toWorld(p.hx, p.hy), chest = toWorld(p.cx, p.cy)
        let sy = squash.x, sx = 1 + (1 - sy) * 0.7, vol = sqrt(sx * sy) * s
        let back = lerp(-1.5, 2.5, clamp01(crouch.x)), belly = lerp(-2, -4, clamp01(lie.x))
        bean(ctx, hip, p.hr * vol, chest, p.cr * vol, back: back, belly: belly)
        line(ctx, chest, toWorld(p.kx, p.ky), 17 * s, pal.coat)   // neck
        let heldRim = hold.x > 0.5 ? pal.pawRim : nil   // dangling legs cross the body: a thin rim keeps them readable
        drawLeg(ctx, sk.legs[.nb], pal.coat, outline: heldRim)
        let pawUp = max(paw.x, groom.x) > 0.3
        if !pawUp && (boxClip == nil || rim.x < 0.5) { drawLeg(ctx, sk.legs[.nf], pal.coat, outline: heldRim) }
        drawHead(ctx, sk)
        // A paw in front of the face gets a faint rim so it still reads against the head.
        if pawUp { drawLeg(ctx, sk.legs[.nf], pal.coat, outline: pal.pawRim) }
        ctx.restoreGState()

        // Paws hooked over the rim sit in front of the box, so they're drawn unclipped.
        if boxClip != nil && rim.x >= 0.5 {
            for id in [LegID.ff, .nf] {
                guard let leg = sk.legs[id] else { continue }
                let f = toWorld(leg.foot.x, leg.foot.y)
                ctx.setFillColor(pal.coat)
                ctx.fillEllipse(in: CGRect(x: f.x - 6.5 * s, y: f.y - 5 * s, width: 13 * s, height: 10 * s))
                ctx.setStrokeColor(pal.detail)
                ctx.setLineWidth(1.3 * s)
                ctx.setLineCap(.round)
                for dx: CGFloat in [-2.2, 2.2] {
                    ctx.move(to: CGPoint(x: f.x + dx * s, y: f.y - 4.5 * s))
                    ctx.addLine(to: CGPoint(x: f.x + dx * s, y: f.y - 1.8 * s))
                }
                ctx.strokePath()
            }
        }
        if sleeping { drawZzz(ctx, sk) }
        if dizzy.x > 0.03 { drawStars(ctx, sk) }
        for h in hearts { drawHeart(ctx, h) }
    }

    /// Climbing the screen after the toy, seen from the front: left paws on the left, right paws on
    /// the right, reaching up in turn while the back feet push, tail hanging down the middle.
    private func drawClimbing(_ ctx: CGContext) {
        let pal = Palette.current, s = scale
        // Where we are in the stroke: g gathers the back legs, r is the push, then the front paws re-hook.
        let u = climbPhase, L = Self.climbStroke
        let g = smoothstep(clamp01(u / 0.35)), r = smoothstep(clamp01((u - 0.35) / 0.25))
        let squeeze = g - r                       // 1 when bunched up, 0 when stretched out
        // shadow on the floor far below, small and faint
        let k = clamp01(1 - max(0, pos.y - 74 * s - floorY) / 220)
        drawGroundShadow(ctx, center: CGPoint(x: pos.x, y: floorY + 1), rx: 26 * s * (0.6 + 0.4 * k), ry: 3.5 * s, alpha: 0.18 * k)
        drawTail(ctx)
        ctx.saveGState()
        ctx.translateBy(x: pos.x, y: pos.y)
        ctx.rotate(by: sin(time * 1.3) * 0.03 + squeeze * 0.02 * climbLead + lean.x)   // a slight sway into each stroke
        ctx.scaleBy(x: s, y: s)
        let bob: CGFloat = 0
        func limb(_ a: CGPoint, _ b: CGPoint, out: CGFloat, _ color: CGColor, upper: CGFloat, lower: CGFloat) {
            // the joint bows outwards, like elbows and knees seen from the front
            let m = CGPoint(x: (a.x + b.x) / 2 + out, y: (a.y + b.y) / 2)
            line(ctx, a, m, upper, color)
            line(ctx, m, b, lower, color)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: b.x - 5.4, y: b.y - 4.6, width: 10.8, height: 9.2))
        }
        let hips = CGPoint(x: 0, y: climbHipY), chest = CGPoint(x: 0, y: -22 + 2 * squeeze)
        // back legs: both gather up under the body, then push together (feet stay put while it rises)
        func backLegs() {
            for side: CGFloat in [-1, 1] {
                // tucks up partway (feet stay below the hips), knees out to the sides
                let foot = CGPoint(x: side * (16 + 2 * squeeze), y: -70 + 14 * squeeze * (side == climbLead ? 1 : 0.9))
                limb(CGPoint(x: side * 8, y: hips.y - 2), foot, out: side * (6 + 5 * squeeze), pal.coat, upper: 11, lower: 8)
            }
        }
        backLegs()
        bean(ctx, hips, 14, chest, 15, back: 0, belly: 0)
        // front legs: hold while it pushes (so they bend as the body rises past them), then re-hook
        // higher one after the other. At the top, the paw on the toy's side stretches for it.
        let reach = clamp01(climbReach.x)
        for side: CGFloat in [-1, 1] {
            let order: CGFloat = side == climbLead ? 0 : 1
            let hook = smoothstep(clamp01((u - 0.62 - 0.1 * order) / 0.2))
            let low = r - hook                       // 1 right after the push: paw down by the chest
            // hooked above the head; after the push they're down by its cheeks, still holding on
            var paw = CGPoint(x: side * (27 - 2 * low), y: 30 + L * (hook - r))
            if side == climbReachSide && reach > 0 {
                let up = CGPoint(x: side * 25, y: 42 + sin(time * 14) * 3)
                paw = CGPoint(x: lerp(paw.x, up.x, reach), y: lerp(paw.y, up.y, reach))
            }
            limb(CGPoint(x: side * 11, y: chest.y + 2 + bob), paw, out: side * (6 + 3 * low), pal.coat, upper: 10, lower: 8)
        }
        // head, face on, looking up at the toy
        ctx.translateBy(x: 0, y: 6 - 1.5 * squeeze)
        ctx.rotate(by: tilt.x * 0.5)
        ear(ctx, CGPoint(x: -23, y: 8), CGPoint(x: -8, y: 18), CGPoint(x: -19, y: 34), earL.x * 0.9)
        ear(ctx, CGPoint(x: 8, y: 18), CGPoint(x: 23, y: 8), CGPoint(x: 19, y: 34), -earR.x * 0.9)
        ctx.setFillColor(pal.coat)
        headPath(ctx, 25, 21)
        ctx.fillPath()
        eye(ctx, -9, 3, 8, gx.x, gy.x)
        eye(ctx, 9, 3, 8, gx.x, gy.x)
        ctx.restoreGState()
        for h in hearts { drawHeart(ctx, h) }
    }

    // MARK: Parts

    private func line(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, _ w: CGFloat, _ color: CGColor) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
    }

    private func fillCircle(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    /// Smooth bean between the hip and chest circles.
    private func bean(_ ctx: CGContext, _ a: CGPoint, _ ra: CGFloat, _ b: CGPoint, _ rb: CGFloat, back: CGFloat, belly: CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y, d = max(hypot(dx, dy), 1)
        let nx = -dy / d, ny = dx / d
        let mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2, mr = (ra + rb) / 2
        let coat = Palette.current.coat
        ctx.setFillColor(coat)
        ctx.move(to: CGPoint(x: a.x + nx * ra, y: a.y + ny * ra))
        ctx.addQuadCurve(to: CGPoint(x: b.x + nx * rb, y: b.y + ny * rb),
                         control: CGPoint(x: mx + nx * (mr + back), y: my + ny * (mr + back)))
        ctx.addLine(to: CGPoint(x: b.x - nx * rb, y: b.y - ny * rb))
        ctx.addQuadCurve(to: CGPoint(x: a.x - nx * ra, y: a.y - ny * ra),
                         control: CGPoint(x: mx - nx * (mr + belly), y: my - ny * (mr + belly)))
        ctx.closePath()
        ctx.fillPath()
        fillCircle(ctx, a, ra, coat)
        fillCircle(ctx, b, rb, coat)
    }

    private func drawLeg(_ ctx: CGContext, _ leg: Leg?, _ color: CGColor, outline: CGColor? = nil) {
        guard let leg else { return }
        let a = toWorld(leg.anchor.x, leg.anchor.y), k = toWorld(leg.knee.x, leg.knee.y), f = toWorld(leg.foot.x, leg.foot.y)
        let dir: CGFloat = facing.x >= 0 ? 1 : -1, s = scale
        let fx = f.x + 1.5 * dir * s, fy = f.y + s
        if let outline {
            line(ctx, k, f, 10 * s, outline)
            ctx.setFillColor(outline)
            ctx.fillEllipse(in: CGRect(x: fx - 6.6 * s, y: fy - 5.6 * s, width: 13.2 * s, height: 11.2 * s))
        }
        line(ctx, a, k, 9.5 * s, color)
        line(ctx, k, f, 7.5 * s, color)
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: fx - 5.2 * s, y: fy - 4.2 * s, width: 10.4 * s, height: 8.4 * s))
    }

    private func drawTail(_ ctx: CGContext) {
        let n = tail.count, puff = tailPuff.x
        guard n > 1 else { return }
        for i in 0..<(n - 1) {
            // a thicker base that flares into the body, so the tail looks like it grows out of it
            let flare: CGFloat = i == 0 ? 1.5 : (i == 1 ? 1.15 : 1)
            line(ctx, tail[i], tail[i + 1], lerp(7.5, 4.6, CGFloat(i) / CGFloat(n - 1)) * flare * puff * scale, Palette.current.coat)
        }
    }

    /// Rounded head: a superellipse, slightly wider and flatter at the cheeks.
    private func headPath(_ ctx: CGContext, _ a: CGFloat, _ b: CGFloat) {
        for i in 0...40 {
            let th = CGFloat(i) / 40 * .pi * 2, c = cos(th), s = sin(th)
            let x = a * sgn(c) * pow(abs(c), 2 / 2.5) * (s < 0 ? 1.04 : 1)
            let y = b * sgn(s) * pow(abs(s), 2 / 2.5) * (s < 0 ? 0.92 : 1)
            if i == 0 { ctx.move(to: CGPoint(x: x, y: y)) } else { ctx.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.closePath()
    }

    private func ear(_ ctx: CGContext, _ b1: CGPoint, _ b2: CGPoint, _ tip: CGPoint, _ rot: CGFloat) {
        let mx = (b1.x + b2.x) / 2, my = (b1.y + b2.y) / 2
        ctx.saveGState()
        ctx.translateBy(x: mx, y: my)
        ctx.rotate(by: rot)
        ctx.translateBy(x: -mx, y: -my)
        ctx.setFillColor(Palette.current.coat)
        ctx.move(to: b1)
        ctx.addQuadCurve(to: tip, control: CGPoint(x: lerp(b1.x, tip.x, 0.5) - 2.5, y: lerp(b1.y, tip.y, 0.5) + 1))
        ctx.addQuadCurve(to: b2, control: CGPoint(x: lerp(b2.x, tip.x, 0.5) + 1.5, y: lerp(b2.y, tip.y, 0.5) + 2))
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    private var blinkAmount: CGFloat {
        blinkT < 0 ? 1 : 1 - sin(.pi * clamp01(blinkT / 0.16))
    }

    private func eye(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ gzx: CGFloat, _ gzy: CGFloat) {
        let pal = Palette.current
        let openness = clamp01(open.x * blinkAmount)
        ctx.setStrokeColor(pal.detail)
        ctx.setLineCap(.round)
        ctx.setLineWidth(2.2)
        if dizzy.x > 0.4 {                   // @ @
            ctx.setFillColor(pal.sclera)
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            ctx.setStrokeColor(pal.pupil)
            ctx.setLineWidth(1.6)
            let spinAngle = time * 7
            for i in 0...36 {
                let u = CGFloat(i) / 36, th = u * .pi * 5 + spinAngle, rr = r * 0.85 * u
                let pt = CGPoint(x: x + cos(th) * rr, y: y + sin(th) * rr)
                if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
            }
            ctx.strokePath()
            return
        }
        if clamp01(happy.x) > 0.5 {          // ^ ^
            ctx.move(to: CGPoint(x: x - r * 0.8, y: y - r * 0.15))
            ctx.addQuadCurve(to: CGPoint(x: x + r * 0.8, y: y - r * 0.15), control: CGPoint(x: x, y: y + r * 0.8))
            ctx.strokePath()
            return
        }
        if openness < 0.1 {                  // closed, relaxed
            ctx.move(to: CGPoint(x: x - r * 0.8, y: y))
            ctx.addQuadCurve(to: CGPoint(x: x + r * 0.8, y: y), control: CGPoint(x: x, y: y - r * 0.55))
            ctx.strokePath()
            return
        }
        let eyeRect = CGRect(x: x - r, y: y - r * (1 - openness) * 0.35 - r * openness, width: r * 2, height: r * 2 * openness)
        if let ring = pal.eyeRing {
            ctx.setStrokeColor(ring)
            ctx.setLineWidth(1.4)
            ctx.strokeEllipse(in: eyeRect)
        }
        ctx.saveGState()
        ctx.setFillColor(pal.sclera)
        ctx.fillEllipse(in: eyeRect)
        ctx.addEllipse(in: eyeRect)
        ctx.clip()
        let px = x + gzx * r * 0.42, py = y + gzy * r * 0.34
        let w = r * (0.34 + 0.62 * clamp01(dil.x)), h = r * 1.5
        ctx.setFillColor(pal.pupil)
        ctx.move(to: CGPoint(x: px, y: py + h / 2))
        ctx.addQuadCurve(to: CGPoint(x: px, y: py - h / 2), control: CGPoint(x: px + w * 1.05, y: py))
        ctx.addQuadCurve(to: CGPoint(x: px, y: py + h / 2), control: CGPoint(x: px - w * 1.05, y: py))
        ctx.fillPath()
        fillCircle(ctx, CGPoint(x: px + w * 0.28, y: py + r * 0.3), r * 0.17, RGB.white.cg())
        ctx.restoreGState()
    }

    private func drawHead(_ ctx: CGContext, _ sk: Skeleton) {
        let p = sk.p, c = toWorld(p.kx, p.ky)
        let hf = headFacing.x, sy = 1 + (squash.x - 1) * 0.35
        let a = tilt.x * 0.9 + pitch.x
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: lean.x + swing.x * 0.5)
        ctx.scaleBy(x: turnScale(hf, 0.6) * scale, y: sy * scale)
        ctx.rotate(by: a)
        // ears rotate outward/back when flattened
        ear(ctx, CGPoint(x: -22, y: 8), CGPoint(x: -7, y: 18), CGPoint(x: -18, y: 34), earL.x * 0.9)
        ear(ctx, CGPoint(x: 6, y: 18), CGPoint(x: 21, y: 9), CGPoint(x: 19, y: 34), -earR.x * 0.9)
        ctx.setFillColor(Palette.current.coat)
        headPath(ctx, 25, 21)
        ctx.fillPath()
        // gaze in head space (undo the head's own flip and tilt)
        let flip: CGFloat = hf >= 0 ? 1 : -1
        let gzx = gx.x * flip, gzy = gy.x
        let rx = gzx * cos(a) + gzy * sin(a), ry = -gzx * sin(a) + gzy * cos(a)
        eye(ctx, -6.5, 2, 8, rx, ry)
        eye(ctx, 12.5, 2, 8, rx, ry)
        if yawn.x > 0.05 {
            let yv = clamp01(yawn.x)
            ctx.setFillColor(Palette.current.mouth)
            ctx.fillEllipse(in: CGRect(x: 4 - 4 * yv, y: -10 - 6.5 * yv, width: 8 * yv, height: 13 * yv))
        }
        ctx.restoreGState()
    }

    private func drawZzz(_ ctx: CGContext, _ sk: Skeleton) {
        let h = toWorld(sk.p.kx, sk.p.ky)
        let dir: CGFloat = facing.x >= 0 ? 1 : -1
        for i in 0..<3 {
            let u = (zzz * 0.45 + CGFloat(i) / 3).truncatingRemainder(dividingBy: 1)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10 + u * 8, weight: .bold),
                .foregroundColor: Palette.current.inkText,
            ]
            ctx.saveGState()
            ctx.setAlpha(sin(.pi * u) * 0.85)
            ("z" as NSString).draw(at: CGPoint(x: h.x + (18 + u * 22) * dir * scale, y: h.y + (22 + u * 34) * scale), withAttributes: attrs)
            ctx.restoreGState()
        }
    }

    /// Little stars orbiting above the head; the ones on the far side of the loop are smaller and dimmer.
    private func drawStars(_ ctx: CGContext, _ sk: Skeleton) {
        let h = toWorld(sk.p.kx, sk.p.ky), s = scale, k = clamp01(dizzy.x)
        let cx = h.x, cy = h.y + 30 * s
        for i in 0..<3 {
            let a = time * 4 + CGFloat(i) * .pi * 2 / 3
            let depth = (sin(a) + 1) / 2          // 0 far, 1 near
            let c = CGPoint(x: cx + cos(a) * 26 * s, y: cy - sin(a) * 6 * s)
            let r = (3.2 + 2 * depth) * s * k
            ctx.saveGState()
            ctx.setAlpha(k * (0.55 + 0.45 * depth))
            ctx.setFillColor(Palette.current.star)
            for j in 0..<10 {
                let th = CGFloat(j) * .pi / 5 + .pi / 2 + time * 3, rr = j % 2 == 0 ? r : r * 0.45
                let pt = CGPoint(x: c.x + cos(th) * rr, y: c.y + sin(th) * rr)
                if j == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
            }
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    private func drawHeart(_ ctx: CGContext, _ h: Heart) {
        let a = 7 + h.age * 4, d = a / CGFloat(2).squareRoot(), r = a / 2
        ctx.saveGState()
        ctx.setAlpha(max(0, 1 - h.age / 1.4))
        ctx.setFillColor(Palette.current.heart)
        ctx.addLines(between: [CGPoint(x: h.x, y: h.y + d), CGPoint(x: h.x + d, y: h.y),
                               CGPoint(x: h.x, y: h.y - d), CGPoint(x: h.x - d, y: h.y)])
        ctx.closePath()
        ctx.fillPath()
        fillCircle(ctx, CGPoint(x: h.x - d / 2, y: h.y + d / 2), r, Palette.current.heart)
        fillCircle(ctx, CGPoint(x: h.x + d / 2, y: h.y + d / 2), r, Palette.current.heart)
        ctx.restoreGState()
    }
}
