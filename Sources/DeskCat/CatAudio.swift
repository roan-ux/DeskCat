import AVFoundation

/// Plays the cat's recorded sounds: one-shots (meows, box, toy) round-robin on a few mono
/// players so they can overlap, panned to where the cat is on screen, and a looping purr whose
/// level follows how hard the cat is purring. The engine is paused whenever everything is
/// quiet, so it costs nothing while idle.
@MainActor
final class CatAudio {
    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private let voices = (0..<4).map { _ in AVAudioPlayerNode() }
    private var nextVoice = 0
    private let purrPlayer = AVAudioPlayerNode()
    private var takes: [CatSound: [AVAudioPCMBuffer]] = [:]
    private var lastTake: [CatSound: Int] = [:]
    private var purrLoop: AVAudioPCMBuffer?
    private var purrLevel: Float = 0
    private var purrRunning = false
    private var busyUntil: CFTimeInterval = 0

    init() {
        let hw = engine.outputNode.outputFormat(forBus: 0).sampleRate
        format = AVAudioFormat(standardFormatWithSampleRate: hw > 0 ? hw : 48000, channels: 1)!
        for p in voices + [purrPlayer] {
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
        }
        let dir = Self.soundsDirectory
        for sound in CatSound.allCases {
            takes[sound] = (1...9).compactMap { load(dir?.appendingPathComponent("\(sound.prefix)-\($0).wav")) }
        }
        purrLoop = load(dir?.appendingPathComponent("purr-1.wav"))
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
        voice.volume = volume * sound.gain
        voice.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !voice.isPlaying { voice.play() }
        busyUntil = max(busyUntil, CACurrentMediaTime() + Double(buffer.frameLength) / format.sampleRate + 1)
    }

    /// Called every frame. `purring` 0...1; `intense` is a full purr (being petted), otherwise a
    /// softer one (sitting contentedly by you).
    func update(purring: Float, intense: Bool, pan: Float, volume: Float) {
        let want = purring * volume * (intense ? 0.9 : 0.5)
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
        if engine.isRunning && !purrRunning && CACurrentMediaTime() > busyUntil {
            engine.pause()
        }
    }

    /// Restarts the engine if it was paused, or stopped by an output change (e.g. headphones).
    @discardableResult
    private func ensureRunning() -> Bool {
        if engine.isRunning { return true }
        do { try engine.start(); return true } catch { return false }
    }
}
