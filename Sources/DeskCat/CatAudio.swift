import AVFoundation

/// Plays the cat's sounds: one-shots (meows, trills, hisses) on two player nodes so they can
/// overlap, and the purr as a live source. A touch of small-room reverb on top. The engine is
/// paused whenever the cat is quiet, so it costs nothing while idle.
@MainActor
final class CatAudio {
    private let engine = AVAudioEngine()
    private let players = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    private var nextPlayer = 0
    private let bus = AVAudioMixerNode()
    private let reverb = AVAudioUnitReverb()
    private let format: AVAudioFormat
    private let purr: PurrSynth
    private let purrNode: AVAudioSourceNode
    private var busyUntil: CFTimeInterval = 0

    init() {
        let hw = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sr = hw > 0 ? hw : 48000
        format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let synth = PurrSynth(sampleRate: Float(sr))
        purr = synth
        purrNode = AVAudioSourceNode(format: format) { _, _, frameCount, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            synth.render(left: l, right: r, frames: Int(frameCount))
            return noErr
        }
        engine.attach(bus)
        engine.attach(reverb)
        engine.attach(purrNode)
        for p in players {
            engine.attach(p)
            engine.connect(p, to: bus, format: format)
        }
        engine.connect(purrNode, to: bus, format: format)
        engine.connect(bus, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        reverb.loadFactoryPreset(.smallRoom)
        reverb.wetDryMix = 12
        engine.prepare()
    }

    /// `pan` is -1 (left of the screen) ... 1 (right); `volume` 0...1.
    func play(_ sound: CatSound, pan: Float, volume: Float) {
        let sr = Float(format.sampleRate)
        let take = SoundSynth.spatialize(SoundSynth.render(sound, sampleRate: sr), pan: pan, sampleRate: sr)
        let n = take.left.count
        guard n > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let l = buffer.floatChannelData?[0], let r = buffer.floatChannelData?[1] else { return }
        buffer.frameLength = AVAudioFrameCount(n)
        take.left.withUnsafeBufferPointer { l.update(from: $0.baseAddress!, count: n) }
        take.right.withUnsafeBufferPointer { r.update(from: $0.baseAddress!, count: n) }
        guard ensureRunning() else { return }
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.volume = volume
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
        busyUntil = max(busyUntil, CACurrentMediaTime() + Double(n) / format.sampleRate + 1.5)
    }

    /// Called every frame with how hard the cat is purring (0...1).
    func update(purring: Float, pan: Float, volume: Float) {
        purr.targetLevel = purring * volume
        purr.targetPan = pan
        if purring > 0.02 {
            ensureRunning()
        } else if engine.isRunning && purr.level < 0.0005 && CACurrentMediaTime() > busyUntil {
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
