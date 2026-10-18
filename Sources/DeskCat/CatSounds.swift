// Everything the cat (and its box and toy) can sound like. The sounds are short recordings in
// `Sounds/` (see Sounds/CREDITS.md), named `<prefix>-<n>.wav`; each play picks one of the takes
// at random. Purring is separate and continuous (see CatAudio).
enum CatSound: CaseIterable {
    // the cat's voice
    case meow, chirp, wake
    // the box and the floor
    case boxIn, boxSettle, boxOut, land
    // toys
    case squeak, plush, bell, toyLand

    /// File name prefix in Sounds/.
    var prefix: String {
        switch self {
        case .meow: return "meow"
        case .chirp: return "chirp"
        case .wake: return "wake"
        case .boxIn: return "box-in"
        case .boxSettle: return "box-settle"
        case .boxOut: return "box-out"
        case .land, .toyLand: return "land"
        case .squeak: return "squeak"
        case .plush: return "plush"
        case .bell: return "bell"
        }
    }

    /// Mix level relative to the user's volume. The files are already level-matched; this keeps
    /// the voice in front and the foley in the background.
    var gain: Float {
        switch self {
        case .meow, .chirp: return 1
        case .wake: return 0.9
        case .boxIn: return 0.8
        case .boxSettle, .boxOut: return 0.7
        case .land: return 0.55
        case .squeak, .plush: return 0.7
        case .bell: return 0.55
        case .toyLand: return 0.35
        }
    }

    /// Vocal sounds are rationed so the cat isn't chatty; foley isn't.
    var isVocal: Bool { self == .meow || self == .chirp || self == .wake }
}
