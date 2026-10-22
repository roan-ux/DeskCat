import AVFoundation

/// Plays the cat's recorded sounds: one-shots (meows, box, toy) round-robin on a few mono
/// voices so they can overlap, panned to where the cat is on screen, and a looping purr whose
/// level follows how hard the cat is purring. Each voice is player → varispeed (pitch drift)
/// → low-pass (muffling inside the box) → mixer. The engine is stopped whenever everything is
/// quiet, so it holds no audio output while idle.
@MainActor
final class CatAudio {
    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private struct Voice {
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitVarispeed()
        let muffle = AVAudioUnitEQ(numberOfBands: 1)
    }
    private let voices = (0..<4).map { _ in Voice() }
    private var nextVoice = 0
    private let purrPlayer = AVAudioPlayerNode()
    private let purrMuffle = AVAudioUnitEQ(numberOfBands: 1)
    /// The purr dips under the cat's voice until then.
    private var duckUntil: CFTimeInterval = 0
    private var takes: [CatSound: [AVAudioPCMBuffer]] = [:]
    private var lastTake: [CatSound: Int] = [:]
    private var purrLoop: AVAudioPCMBuffer?
    private var purrLevel: Float = 0
    private var purrRunning = false
    private var busyUntil: CFTimeInterval = 0

    init() {
        let hw = engine.outputNode.outputFormat(forBus: 0).sampleRate
        format = AVAudioFormat(standardFormatWithSampleRate: hw > 0 ? hw : 48000, channels: 1)!
        for v in voices {
            for node in [v.player, v.pitch, v.muffle] as [AVAudioNode] { engine.attach(node) }
            Self.setUpMuffle(v.muffle)
            engine.connect(v.player, to: v.pitch, format: format)
            engine.connect(v.pitch, to: v.muffle, format: format)
            engine.connect(v.muffle, to: engine.mainMixerNode, format: format)
        }
        engine.attach(purrPlayer); engine.attach(purrMuffle)
        Self.setUpMuffle(purrMuffle)
        engine.connect(purrPlayer, to: purrMuffle, format: format)
        engine.connect(purrMuffle, to: engine.mainMixerNode, format: format)
        let dir = Self.soundsDirectory
        for sound in CatSound.allCases {
            takes[sound] = (1...9).compactMap { load(dir?.appendingPathComponent("\(sound.prefix)-\($0).wav")) }
        }
        purrLoop = load(dir?.appendingPathComponent("purr-1.wav"))
        engine.prepare()
    }

    /// A low-pass that's bypassed unless the sound comes from inside the box.
    private static func setUpMuffle(_ eq: AVAudioUnitEQ) {
        let band = eq.bands[0]
        band.filterType = .lowPass
        band.frequency = 1800
        band.bandwidth = 0.7
        band.bypass = false
        eq.bypass = true
    }

    /// Inside the app: Contents/Resources/Sounds. Under `swift run`: the Sounds folder in the repo.
    private static var soundsDirectory: URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Sounds"),
           FileManager.default.fileExists(atPath: r.path) { return r }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sounds")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    /// Reads a recording and converts it to the engine's mono format. The files are already
    /// trimmed and level-matched, so levels are left alone.
    private func load(_ url: URL?) -> AVAudioPCMBuffer? {
        guard let url, FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: source)) != nil,
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return nil }
        let ratio = format.sampleRate / file.processingFormat.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return source
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    /// What loaded, e.g. "meow 3, chirp 1, ..., purr 1". Handy when a sound doesn't play.
    var loadedSummary: String {
        CatSound.allCases.map { "\($0) \(takes[$0]?.count ?? 0)" }.joined(separator: ", ") + ", purr \(purrLoop == nil ? 0 : 1)"
    }

    /// `pan` is -1 (left of the screen) ... 1 (right); `volume` 0...1 (the user's setting).
    func play(_ event: SoundEvent, pan: Float, volume: Float) {
        let sound = event.sound
        guard let options = takes[sound], !options.isEmpty, ensureRunning() else { return }
        // a different take from last time
        var i = Int.random(in: 0..<options.count)
        if options.count > 1, i == lastTake[sound] { i = (i + 1) % options.count }
        lastTake[sound] = i
        let buffer = options[i]
        let voice = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        // mix offset, ±1 dB of randomness, softer for gentler impacts, quieter through the box
        var db = sound.gainDB + Float.random(in: -1...1) + 20 * log10(0.35 + 0.65 * max(0, min(1, event.level)))
        if event.muffled { db -= 4 }
        voice.player.pan = pan
        voice.player.volume = volume * pow(10, db / 20)
        let v = sound.pitchVariation
        voice.pitch.rate = 1 + Float.random(in: -v...v)
        voice.muffle.bypass = !event.muffled
        voice.player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !voice.player.isPlaying { voice.player.play() }
        let length = Double(buffer.frameLength) / format.sampleRate / Double(voice.pitch.rate)
        if sound.isVocal { duckUntil = CACurrentMediaTime() + length }
        busyUntil = max(busyUntil, CACurrentMediaTime() + length + 1)
    }

    /// Called every frame. `purring` 0...1; `intense` is a full purr (being petted), otherwise a
    /// softer one (sitting contentedly by you). `muffled` while the cat is in its box.
    func update(purring: Float, intense: Bool, muffled: Bool, pan: Float, volume: Float) {
        var want = purring * volume * (intense ? 0.8 : 0.5)
        if CACurrentMediaTime() < duckUntil { want *= 0.5 }   // let the meow through
        if muffled { want *= 0.65 }
        purrMuffle.bypass = !muffled
        purrLevel += (want - purrLevel) * 0.08            // eases in and out over a few frames
        if want > 0.01 && !purrRunning, let loop = purrLoop, ensureRunning() {
            purrPlayer.volume = 0
            purrPlayer.scheduleBuffer(loop, at: nil, options: [.loops, .interrupts])
            purrPlayer.play()
            purrRunning = true
        }
        purrPlayer.volume = purrLevel
        purrPlayer.pan = pan
        if purrRunning && purrLevel < 0.002 && want < 0.001 {
            purrPlayer.stop()
            purrRunning = false
        }
        // Stop (not just pause) once everything is quiet: a paused engine keeps the speakers open,
        // which can hiss on some outputs and keeps the Mac from idle-sleeping. It restarts in a
        // few milliseconds when the next sound plays.
        if engine.isRunning && !purrRunning && CACurrentMediaTime() > busyUntil {
            engine.stop()
        }
    }

    /// Restarts the engine if it was paused, or stopped by an output change (e.g. headphones).
    @discardableResult
    private func ensureRunning() -> Bool {
        if engine.isRunning { return true }
        do { try engine.start(); return true } catch { return false }
    }
}
