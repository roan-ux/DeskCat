import AVFoundation

/// Plays the cat's recorded sounds. Meows are one-shots on two mono players (so they can
/// overlap), panned to where the cat is on screen. The purr is two looping recordings, a soft
/// one and a stronger one, crossfaded by how hard the cat is purring. The engine is paused
/// whenever the cat is quiet, so it costs nothing while idle.
@MainActor
final class CatAudio {
    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private let voices = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    private var nextVoice = 0
    private let purrSoft = AVAudioPlayerNode(), purrActive = AVAudioPlayerNode()
    private var takes: [CatSound: [AVAudioPCMBuffer]] = [:]
    private var lastTake: [CatSound: Int] = [:]
    private var softLoop: AVAudioPCMBuffer?, activeLoop: AVAudioPCMBuffer?
    private var softLevel: Float = 0, activeLevel: Float = 0
    private var purrRunning = false
    private var busyUntil: CFTimeInterval = 0

    init() {
        let hw = engine.outputNode.outputFormat(forBus: 0).sampleRate
        format = AVAudioFormat(standardFormatWithSampleRate: hw > 0 ? hw : 48000, channels: 1)!
        for p in voices + [purrSoft, purrActive] {
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
        }
        let dir = Self.soundsDirectory
        takes[.mew] = (1...5).compactMap { load(dir?.appendingPathComponent("mew-\($0).mp3"), peak: 0.6) }
        takes[.meow] = (1...4).compactMap { load(dir?.appendingPathComponent("meow-\($0).mp3"), peak: 0.7) }
        softLoop = load(dir?.appendingPathComponent("purr-soft.wav"), peak: 0.6)
        activeLoop = load(dir?.appendingPathComponent("purr-active.wav"), peak: 0.6)
        engine.prepare()
    }

    /// Inside the app: Contents/Resources/Sounds. Under `swift run`: the Sounds folder in the repo.
    private static var soundsDirectory: URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Sounds"),
           FileManager.default.fileExists(atPath: r.path) { return r }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sounds")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    /// Reads a recording, converts it to the engine's mono format and evens out its loudness.
    private func load(_ url: URL?, peak: Float) -> AVAudioPCMBuffer? {
        guard let url, let file = try? AVAudioFile(forReading: url),
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
        guard error == nil, out.frameLength > 0, let samples = out.floatChannelData?[0] else { return nil }
        let n = Int(out.frameLength)
        var m: Float = 0
        for i in 0..<n { m = max(m, abs(samples[i])) }
        if m > 0 { for i in 0..<n { samples[i] *= peak / m } }
        return out
    }

    /// What loaded, e.g. "mew 5, meow 4, purrs 2". Handy when a sound doesn't play.
    var loadedSummary: String {
        "mew \(takes[.mew]?.count ?? 0), meow \(takes[.meow]?.count ?? 0), purrs \([softLoop, activeLoop].compactMap { $0 }.count)"
    }

    /// `pan` is -1 (left of the screen) ... 1 (right); `volume` 0...1.
    func play(_ sound: CatSound, pan: Float, volume: Float) {
        guard let options = takes[sound], !options.isEmpty, ensureRunning() else { return }
        // a different take from last time
        var i = Int.random(in: 0..<options.count)
        if options.count > 1, i == lastTake[sound] { i = (i + 1) % options.count }
        lastTake[sound] = i
        let buffer = options[i]
        let voice = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        voice.pan = pan
        voice.volume = volume
        voice.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !voice.isPlaying { voice.play() }
        busyUntil = max(busyUntil, CACurrentMediaTime() + Double(buffer.frameLength) / format.sampleRate + 1)
    }

    /// Called every frame. `purring` 0...1; `intense` picks the stronger purr (being petted).
    func update(purring: Float, intense: Bool, pan: Float, volume: Float) {
        let wantSoft = intense ? 0 : purring * volume, wantActive = intense ? purring * volume : 0
        softLevel += (wantSoft - softLevel) * 0.08            // gentle crossfade over a few frames
        activeLevel += (wantActive - activeLevel) * 0.08
        let audible = softLevel > 0.002 || activeLevel > 0.002
        if (wantSoft > 0.01 || wantActive > 0.01) && !purrRunning, ensureRunning() {
            startLoop(purrSoft, softLoop)
            startLoop(purrActive, activeLoop)
            purrRunning = true
        }
        purrSoft.volume = softLevel; purrActive.volume = activeLevel
        purrSoft.pan = pan; purrActive.pan = pan
        if purrRunning && !audible && wantSoft < 0.001 && wantActive < 0.001 {
            purrSoft.stop(); purrActive.stop()
            purrRunning = false
        }
        if engine.isRunning && !purrRunning && CACurrentMediaTime() > busyUntil {
            engine.pause()
        }
    }

    private func startLoop(_ player: AVAudioPlayerNode, _ buffer: AVAudioPCMBuffer?) {
        guard let buffer else { return }
        player.volume = 0
        player.scheduleBuffer(buffer, at: nil, options: [.loops, .interrupts])
        player.play()
    }

    /// Restarts the engine if it was paused, or stopped by an output change (e.g. headphones).
    @discardableResult
    private func ensureRunning() -> Bool {
        if engine.isRunning { return true }
        do { try engine.start(); return true } catch { return false }
    }
}
