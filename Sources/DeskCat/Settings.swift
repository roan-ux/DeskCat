import AppKit

/// Tiny UserDefaults wrapper: the cat's name, where the box was left, whether it roams, and sound.
enum Settings {
    static var name: String? {
        get { UserDefaults.standard.string(forKey: "catName") }
        set { UserDefaults.standard.set(newValue, forKey: "catName") }
    }

    static var boxOrigin: CGPoint? {
        get { UserDefaults.standard.string(forKey: "boxOrigin").map(NSPointFromString) }
        set { UserDefaults.standard.set(newValue.map { NSStringFromPoint($0) }, forKey: "boxOrigin") }
    }

    static var roamsOnItsOwn: Bool {
        get { UserDefaults.standard.object(forKey: "roamsOnItsOwn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "roamsOnItsOwn") }
    }

    static var soundOn: Bool {
        get { UserDefaults.standard.object(forKey: "soundOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundOn") }
    }

    /// 0...1
    static var soundVolume: Double {
        get { UserDefaults.standard.object(forKey: "soundVolume") as? Double ?? 0.6 }
        set { UserDefaults.standard.set(newValue, forKey: "soundVolume") }
    }
}
