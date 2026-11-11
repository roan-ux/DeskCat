import AppKit

/// Stickers: pictures of the cat cut out with a white sticker border, ready to paste into a chat.
/// The app keeps a sticker book with one sticker per thing the cat does (the latest time it did
/// it), filled in automatically as it goes about its day. Settings → Stickers shows the book;
/// click a sticker to copy it, or drag it out.
@MainActor
final class StickerBook: ObservableObject {
    static let shared = StickerBook()

    struct Sticker: Identifiable, Equatable {
        let id: String          // the activity, e.g. "sleep"
        let title: String       // e.g. "Asleep"
        let url: URL
        let image: NSImage
        let order: Int
    }

    @Published private(set) var stickers: [Sticker] = []

    let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DeskCat/Stickers", isDirectory: true)
    }()

    private init() { load() }

    /// Saves a sticker for an activity, replacing the one it had.
    func save(_ png: Data, act: Act) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(act.key).png")
        guard (try? png.write(to: url, options: .atomic)) != nil, let image = NSImage(data: png) else { return }
        let sticker = Sticker(id: act.key, title: act.label, url: url, image: image, order: act.order)
        stickers.removeAll { $0.id == act.key }
        stickers.append(sticker)
        stickers.sort { $0.order < $1.order }
    }

    private func load() {
        stickers = Act.all.compactMap { act in
            let url = folder.appendingPathComponent("\(act.key).png")
            guard let image = NSImage(contentsOf: url) else { return nil }
            return Sticker(id: act.key, title: act.label, url: url, image: image, order: act.order)
        }
    }

    static func copy(png: Data, file: URL?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        // Some chat apps (and Finder) take a file rather than image data.
        if let file { item.setString(file.absoluteString, forType: .fileURL) }
        pb.writeObjects([item])
    }

    func copy(_ sticker: Sticker) {
        guard let png = try? Data(contentsOf: sticker.url) else { return }
        Self.copy(png: png, file: sticker.url)
    }
}

extension Act {
    /// Every activity, in the order the sticker book shows them.
    static let all: [Act] = [.sit, .look, .groom, .yawn, .stretch, .loaf, .sleep, .wander, .watch, .approach,
                             .stalk, .swat, .pin, .petted, .startle, .held, .dizzy, .visit, .zoomies, .chase,
                             .climb, .trophy, .inBox, .leaving, .air, .land, .goHome]
    var key: String { String(describing: self) }
    var order: Int { Self.all.firstIndex(of: self) ?? 99 }

    /// How long into an activity the cat looks most like itself doing it (the pose has settled,
    /// or a quick move is at its peak). Nil: not worth a sticker on its own.
    var stickerMoment: CGFloat? {
        switch self {
        case .air: return 0.12
        case .startle, .pin: return 0.2
        case .swat: return 0.3
        case .land: return nil
        case .held, .dizzy, .yawn, .stretch: return 0.8
        case .sleep: return 2.5
        case .loaf: return 2
        case .inBox: return 3
        default: return 1.2
        }
    }
}

/// Draws the cat (with its box and toy when they're in the picture) into a sticker PNG.
enum StickerArt {
    /// Pixels per point. Stickers come out around 300 to 500 px across.
    static let resolution: CGFloat = 3

    @MainActor
    static func render(sim: CatSim, name: String) -> Data? {
        let s = sim.scale
        // The patch of screen the cat could cover, generously: a sticker gets trimmed to the cat after.
        let anchor = CatView.anchor(scale: s), size = CatView.size(scale: s)
        var region = CGRect(x: sim.pos.x - anchor.x, y: sim.pos.y - anchor.y, width: size.width, height: size.height)
            .insetBy(dx: -30 * s, dy: -30 * s)
        let showBox = sim.isHome && sim.boxShow.x > 0.5
        var boxFrame = CGRect.zero
        if showBox {
            let inset = BoxView.inset(scale: s)
            boxFrame = CGRect(origin: CGPoint(x: sim.box.x - inset.x, y: sim.box.y - inset.y), size: BoxView.size(scale: s))
            region = region.union(boxFrame)
        }
        let r = resolution
        let w = Int(region.width * r), h = Int(region.height * r)
        guard let ctx = bitmap(w, h) else { return nil }
        drawsGroundShadows = false
        defer { drawsGroundShadows = true }
        ctx.scaleBy(x: r, y: r)
        ctx.translateBy(x: -region.minX, y: -region.minY)     // world (screen) coordinates from here

        if showBox {
            let box = BoxView(frame: NSRect(origin: .zero, size: boxFrame.size))
            box.scale = s
            box.name = name
            box.show = 1
            if let rep = box.bitmapImageRepForCachingDisplay(in: box.bounds) {
                rep.size = boxFrame.size
                box.cacheDisplay(in: box.bounds, to: rep)
                if let img = rep.cgImage { ctx.draw(img, in: boxFrame) }
            }
        }
        let toyBehind = sim.toy.place == .box
        if toyBehind { drawToy(ctx, sim, region) }
        sim.draw(in: ctx)
        if !toyBehind { drawToy(ctx, sim, region) }

        guard let picture = ctx.makeImage(), let trimmed = trim(picture) else { return nil }
        guard let sticker = addBorder(trimmed) else { return nil }
        return NSBitmapImageRep(cgImage: sticker).representation(using: .png, properties: [:])
    }

    /// The toy, when it's in the picture (in the box, in the cat's mouth, or close by).
    private static func drawToy(_ ctx: CGContext, _ sim: CatSim, _ region: CGRect) {
        guard let kind = sim.toyKind else { return }
        let t = sim.toy
        if t.place == .box && !(sim.isHome && sim.boxShow.x > 0.5) { return }
        guard region.insetBy(dx: 20, dy: 20).contains(t.pos) else { return }
        ctx.saveGState()
        if t.place == .box {
            ctx.clip(to: CGRect(x: -100_000, y: sim.box.y + sim.boxRim, width: 200_000, height: 100_000))
        }
        ctx.translateBy(x: t.pos.x, y: t.pos.y)
        ctx.rotate(by: t.angle)
        ctx.scaleBy(x: t.facing * sim.scale, y: sim.scale)
        ToyArt.draw(kind, in: ctx)
        ctx.restoreGState()
    }

    private static func bitmap(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: max(w, 1), height: max(h, 1), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Crops to what was drawn (ignoring near-invisible pixels like the faint ground shadow's edge).
    private static func trim(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = bitmap(w, h), let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * ctx.bytesPerRow
            for x in 0..<w where px[row + x * 4 + 3] > 24 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // the bitmap's rows run top to bottom in memory, so y here is already image-space
        return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }

    /// A thick white die-cut border and a soft shadow, like a real sticker.
    private static func addBorder(_ image: CGImage) -> CGImage? {
        let border = 7 * resolution, pad = border + 6 * resolution
        let w = image.width + Int(pad * 2), h = image.height + Int(pad * 2)
        let rect = CGRect(x: pad, y: pad, width: CGFloat(image.width), height: CGFloat(image.height))

        // The cat's silhouette in white.
        guard let sctx = bitmap(image.width, image.height) else { return nil }
        let local = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        sctx.draw(image, in: local)
        sctx.setBlendMode(.sourceIn)
        sctx.setFillColor(CGColor(gray: 1, alpha: 1))
        sctx.fill(local)
        guard let silhouette = sctx.makeImage() else { return nil }

        // Stamp the silhouette in a ring to grow it into the border.
        guard let bctx = bitmap(w, h) else { return nil }
        let steps = 32
        for ring in [border * 0.5, border] {
            for i in 0..<steps {
                let a = CGFloat(i) / CGFloat(steps) * 2 * .pi
                bctx.draw(silhouette, in: rect.offsetBy(dx: cos(a) * ring, dy: sin(a) * ring))
            }
        }
        bctx.draw(silhouette, in: rect)
        guard let outline = bctx.makeImage() else { return nil }

        guard let out = bitmap(w, h) else { return nil }
        out.saveGState()
        out.setShadow(offset: CGSize(width: 0, height: -1.5 * resolution), blur: 4 * resolution,
                      color: CGColor(gray: 0, alpha: 0.28))
        out.draw(outline, in: CGRect(x: 0, y: 0, width: w, height: h))
        out.restoreGState()
        out.draw(image, in: rect)
        return out.makeImage()
    }
}
