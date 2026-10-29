import AVFoundation
import FM1Engine

/// The FM-1's line out: an AVAudioSourceNode that empties the emulator's audio ring
/// (fm1ios_pull, lock-free) at 44.1 kHz stereo; AVAudioEngine converts to the device's rate.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var observers: [NSObjectProtocol] = []
    private(set) var wanted = false
    var mixWithOthers = false

    func start() {
        wanted = true
        configureSession()
        if node == nil { build() }
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { print("FM-1 audio: \(error)") }
        }
    }

    func pause() {
        wanted = false
        engine.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Apply a change of the "mix with other apps" setting.
    func reconfigure() {
        guard wanted else { return }
        configureSession()
        if !engine.isRunning { try? engine.start() }
    }

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, options: mixWithOthers ? [.mixWithOthers] : [])
            try s.setPreferredSampleRate(44_100)
            try s.setPreferredIOBufferDuration(256.0 / 44_100.0)
            try s.setActive(true)
        } catch {
            print("FM-1 audio session: \(error)")
        }
    }

    private func build() {
        let rate = Double(fm1ios_sample_rate())
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        // the render block runs on the real-time audio thread: only fm1ios_pull (no lock, no allocation)
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            _ = fm1ios_pull(l, r, frameCount)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        node = source

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended, self.wanted { self.start() }
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.wanted else { return }
            self.engine.prepare()
            try? self.engine.start()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.wanted else { return }
            self.start()
        })
    }
}
