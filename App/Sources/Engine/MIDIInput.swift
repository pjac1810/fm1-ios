import CoreMIDI
import Foundation
import FM1Engine

/// The FM-1's MIDI IN: every MIDI source of the phone (USB, Bluetooth, network, other apps) and
/// a virtual destination "FM-1" that other apps can play, all forwarded as MIDI 1.0 bytes into
/// the emulated MIDI IN jack, where the firmware reads them with its own driver.
final class MIDIInput {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var destination = MIDIEndpointRef()
    private var connected = Set<MIDIEndpointRef>()
    private let lock = NSLock()
    private var channel = 0          // 0: as sent, 1...16: channel messages moved to it
    private var messages: UInt64 = 0

    /// Move channel messages to this channel (1...16), or leave them (0).
    var forcedChannel: Int {
        get { lock.lock(); defer { lock.unlock() }; return channel }
        set { lock.lock(); channel = max(0, min(16, newValue)); lock.unlock() }
    }

    /// Messages received so far (for the activity light).
    var messageCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return messages
    }

    /// The names of the sources listened to.
    var sourceNames: [String] {
        (0..<MIDIGetNumberOfSources()).compactMap { i -> String? in
            var name: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(MIDIGetSource(i), kMIDIPropertyDisplayName, &name) == noErr,
                  let n = name?.takeRetainedValue() else { return nil }
            return n as String
        }
    }

    func start() {
        guard client == 0 else { return }
        MIDIClientCreateWithBlock("FM-1" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectSources() }
            }
        }
        MIDIInputPortCreateWithProtocol(client, "FM-1 MIDI IN" as CFString, ._1_0, &port) { [weak self] list, _ in
            self?.receive(list)
        }
        MIDIDestinationCreateWithProtocol(client, "FM-1" as CFString, ._1_0, &destination) { [weak self] list, _ in
            self?.receive(list)
        }
        connectSources()
    }

    func connectSources() {
        guard port != 0 else { return }
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            if !connected.contains(src), MIDIPortConnectSource(port, src, nil) == noErr {
                connected.insert(src)
            }
        }
    }

    // MARK: Universal MIDI Packets -> MIDI 1.0 bytes

    private func receive(_ list: UnsafePointer<MIDIEventList>) {
        let forced = forcedChannel
        var bytes: [UInt8] = []
        var count: UInt64 = 0
        let n = Int(list.pointee.numPackets)
        guard n > 0, let first = MemoryLayout<MIDIEventList>.offset(of: \MIDIEventList.packet),
              let wordsAt = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words) else { return }
        var packet = (UnsafeRawPointer(list) + first).assumingMemoryBound(to: MIDIEventPacket.self)
        for k in 0..<n {
            let wc = Int(packet.pointee.wordCount)
            let words = (UnsafeRawPointer(packet) + wordsAt).assumingMemoryBound(to: UInt32.self)
            var i = 0
            while i < wc {
                let w = words[i]
                let type = Int(w >> 28)
                let size = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4][type]
                switch type {
                case 0x1: // system common / real time
                    let st = UInt8((w >> 16) & 0xff)
                    bytes.append(st)
                    switch st {
                    case 0xf1, 0xf3: bytes.append(UInt8((w >> 8) & 0x7f))
                    case 0xf2: bytes.append(UInt8((w >> 8) & 0x7f)); bytes.append(UInt8(w & 0x7f))
                    default: break
                    }
                case 0x2: // MIDI 1.0 channel voice
                    var st = UInt8((w >> 16) & 0xff)
                    if forced > 0 { st = (st & 0xf0) | UInt8(forced - 1) }
                    bytes.append(st)
                    bytes.append(UInt8((w >> 8) & 0x7f))
                    if st & 0xf0 != 0xc0 && st & 0xf0 != 0xd0 { bytes.append(UInt8(w & 0x7f)) }
                    count += 1
                case 0x3 where i + 1 < wc: // 7-bit system exclusive, up to 6 bytes a packet
                    let status = (w >> 20) & 0xf
                    let num = Int((w >> 16) & 0xf)
                    let w2 = words[i + 1]
                    let data: [UInt8] = [UInt8((w >> 8) & 0x7f), UInt8(w & 0x7f),
                                         UInt8((w2 >> 24) & 0x7f), UInt8((w2 >> 16) & 0x7f),
                                         UInt8((w2 >> 8) & 0x7f), UInt8(w2 & 0x7f)]
                    if status == 0 || status == 1 { bytes.append(0xf0) }
                    bytes.append(contentsOf: data.prefix(min(num, 6)))
                    if status == 0 || status == 3 { bytes.append(0xf7) }
                default:
                    break
                }
                i += size
            }
            if k + 1 < n { packet = UnsafePointer(MIDIEventPacketNext(packet)) }
        }
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { fm1ios_midi($0.baseAddress, $0.count) }
        lock.lock(); messages &+= max(count, 1); lock.unlock()
    }
}
