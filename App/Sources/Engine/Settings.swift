import Foundation

/// The app's preferences (UserDefaults). The FM-1's own settings live in its emulated flash.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    /// frames kept ready ahead of the audio device
    @Published var bufferFrames: Int { didSet { d.set(bufferFrames, forKey: "bufferFrames") } }
    /// -1 auto (channel 2 for M-VAVE's firmware, unchanged otherwise), 0 unchanged, 1...16 forced
    @Published var midiChannel: Int { didSet { d.set(midiChannel, forKey: "midiChannel") } }
    @Published var backgroundAudio: Bool { didSet { d.set(backgroundAudio, forKey: "backgroundAudio") } }
    @Published var mixWithOthers: Bool { didSet { d.set(mixWithOthers, forKey: "mixWithOthers") } }
    @Published var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    /// the emulated CPU clock (240 MHz as on the chip)
    @Published var mhz: Int { didSet { d.set(mhz, forKey: "mhz") } }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "bufferFrames": 1024,
            "pot": 900,
            "midiChannel": -1,
            "backgroundAudio": true,
            "mixWithOthers": false,
            "haptics": true,
            "mhz": 240,
        ])
        bufferFrames = d.integer(forKey: "bufferFrames")
        midiChannel = d.integer(forKey: "midiChannel")
        backgroundAudio = d.bool(forKey: "backgroundAudio")
        mixWithOthers = d.bool(forKey: "mixWithOthers")
        haptics = d.bool(forKey: "haptics")
        mhz = d.integer(forKey: "mhz")
    }

    /// the MASTER pot, 0..1023 (a real pot: it stays where it was left)
    var pot: Int {
        get { d.integer(forKey: "pot") }
        set { d.set(newValue, forKey: "pot") }
    }

    /// the firmware booted last (its package hash)
    var currentFirmware: String? {
        get { d.string(forKey: "currentFirmware") }
        set { d.set(newValue, forKey: "currentFirmware") }
    }
}
