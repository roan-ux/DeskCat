// Everything the cat (and its box and toy) can sound like. The sounds are short recordings in
// `Sounds/` (see Sounds/CREDITS.md), named `<prefix>-<n>.wav`; each play picks one of the takes
// at random. Purring is separate and continuous (see CatAudio).
//
// How the sound is put together, borrowing from game audio practice:
// - Every file is matched to the same perceived loudness (-20 LUFS, ITU-R BS.1770), so nothing
//   is quiet or loud just because of how it was recorded.
// - On top of that, a small mix offset per sound (`gainDB`) keeps the voice in front and the
//   foley a little behind it. The offsets stay within a few dB so it still sounds even.
// - Each play varies a little in pitch and level, so the same take never repeats exactly.
// - Impacts get louder the harder they hit; sounds from inside the box are muffled; the purr
//   dips while the cat meows.
enum CatSound: CaseIterable {
    // the cat's voice
    case meow, chirp, wake
    // seeing stars (and birdies)
    case dizzy
    // the box, the floor, the screen it climbs
    case boxIn, boxOut, land, claw
    // toys
    case squeak, plush, bell, toyLand

    /// File name prefix in Sounds/.
    var prefix: String {
        switch self {
        case .meow: return "meow"
        case .chirp: return "chirp"
        case .wake: return "wake"
        case .dizzy: return "dizzy"
        case .boxIn: return "box-in"
        case .boxOut: return "box-out"
        case .land, .toyLand: return "land"
        case .claw: return "claw"
        case .squeak: return "squeak"
        case .plush: return "plush"
        case .bell: return "bell"
        }
    }

    /// Mix offset in dB, relative to the voice.
    var gainDB: Float {
        switch self {
        case .meow, .chirp: return 0
        case .wake: return -1
        case .dizzy: return -4                        // bright tweets, so they sit back a little
        case .boxIn, .boxOut, .land: return -3
        case .claw: return -5                         // a light scrabble under everything else
        case .squeak, .plush: return -2
        case .bell: return -3
        case .toyLand: return -6
        }
    }

    /// How far each play may drift in pitch (and speed), e.g. 0.05 = ±5%.
    var pitchVariation: Float {
        switch self {
        case .meow, .chirp, .wake: return 0.035      // a cat's voice drifts a little, not a lot
        case .bell: return 0.02
        case .dizzy: return 0.04
        default: return 0.07                          // foley and squeaks can vary more
        }
    }

    /// Vocal sounds are rationed so the cat isn't chatty; foley isn't.
    var isVocal: Bool { self == .meow || self == .chirp || self == .wake }
}

/// One sound to play this frame.
struct SoundEvent {
    var sound: CatSound
    /// 0...1: how hard it was (impacts get quieter when softer).
    var level: Float = 1
    /// Coming from inside the box: quieter and duller.
    var muffled = false
}
