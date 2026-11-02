import AppKit
import AVFoundation
import CoreAudio

/// Plays the cat's recorded sounds: one-shots (meows, box, toy) round-robin on a few mono
/// voices so they can overlap, panned to where the cat is on screen, and a looping purr whose
/// level follows how hard the cat is purring. Each voice is player → varispeed (pitch drift)
/// → low-pass (muffling inside the box) → mixer. The engine is stopped whenever everything is
/// quiet, so it holds no audio output while idle.
///
/// A stopped engine can't simply be started again: its varispeed units come back silent, and
/// the output may have changed under it (sleep and wake, a different output device) without it
/// hearing about it. So whenever it's needed again after a stop, or after a wake, an output-device
/// change, a configuration change or a failed start, the whole engine is rebuilt (the loaded
/// sounds are kept; it takes a few milliseconds).
@MainActor
final class CatAudio {
    private var engine = AVAudioEngine()
    private let format: AVAudioFormat
    private struct Voice {
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitVarispeed()
        let muffle = AVAudioUnitEQ(numberOfBands: 1)
    }
    private var voices: [Voice] = []
    private var nextVoice = 0
    private var purrPlayer = AVAudioPlayerNode()
    private var purrMuffle = AVAudioUnitEQ(numberOfBands: 1)
    /// Set when the output may have changed; the next sound rebuilds the engine first.
    private var needsRebuild = false
    /// Set when the engine was stopped for being quiet. It's then rebuilt before it plays again:
    /// the varispeed (pitch) units stay silent after an engine stop/start, which used to leave
    /// every sound but the purr mute for good.
    private var stoppedAt: CFTimeInterval = 0
    private var configObserver: NSObjectProtocol?
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
        let dir = Self.soundsDirectory
        for sound in CatSound.allCases {
            takes[sound] = (1...9).compactMap { load(dir?.appendingPathComponent("\(sound.prefix)-\($0).wav")) }
        }
        purrLoop = load(dir?.appendingPathComponent("purr-1.wav"))
        buildGraph()
        watchForOutputChanges()
    }

    /// A fresh engine with its voices and purr wired up. The player→mixer connections use our own
    /// mono format; the mixer converts to whatever the output device wants at the time.
    private func buildGraph() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.stop()
        engine = AVAudioEngine()
        voices = (0..<4).map { _ in Voice() }
        purrPlayer = AVAudioPlayerNode()
        purrMuffle = AVAudioUnitEQ(numberOfBands: 1)
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
        engine.prepare()
        purrRunning = false
        needsRebuild = false
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsRebuild = true }
        }
    }

    /// Wakes and output-device switches can leave a stopped engine pointing at an output that's
    /// gone, without telling it. Flag a rebuild for the next sound.
    private func watchForOutputChanges() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsRebuild = true }
            }
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.needsRebuild = true }
        }
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
            stoppedAt = CACurrentMediaTime()
        }
    }

    /// Starts the engine for a sound, rebuilding it first if the output may have changed, and
    /// once more if starting fails, so a dead engine can't keep the cat silent.
    @discardableResult
    private func ensureRunning() -> Bool {
        if !engine.isRunning && stoppedAt > 0 { needsRebuild = true }
        if needsRebuild { buildGraph(); stoppedAt = 0 }
        if engine.isRunning { return true }
        if (try? engine.start()) != nil { return true }
        buildGraph()
        return (try? engine.start()) != nil
    }
}
