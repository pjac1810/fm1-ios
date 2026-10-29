import Foundation
import SwiftUI
import UIKit
import FM1Engine

/// The emulated FM-1: which firmware it runs, booting and updating it, its audio and MIDI,
/// and keeping the flash the firmware writes (presets, settings, sequences) between launches.
@MainActor
final class Emulator: ObservableObject {
    enum Status: Equatable {
        case off
        case updating(String)
        case running
        case failed(String)
    }

    struct Stats: Equatable {
        var speed: Float = 0
        var underruns: UInt64 = 0
        var emulatedSeconds: Double = 0
        var halted = false
        var midiActive = false
    }

    /// Something opened from outside (Files, AirDrop, Mail) waiting for the user's yes.
    enum Pending: Identifiable {
        case firmware(Data, String, String?)   // package, name, source
        case bank(Data, String)
        case backup(Data, String)
        var id: String {
            switch self {
            case .firmware(_, let n, _): return "fw-" + n
            case .bank(_, let n): return "syx-" + n
            case .backup(_, let n): return "save-" + n
            }
        }
    }

    @Published private(set) var current: FirmwareRecord?
    @Published private(set) var status: Status = .off
    @Published private(set) var stats = Stats()
    @Published private(set) var firmwares: [FirmwareRecord] = []
    @Published var message: String?
    @Published var pending: Pending?

    let library = FirmwareLibrary()
    let audio = AudioOutput()
    let midi = MIDIInput()
    let settings = Settings.shared

    private var timer: Timer?
    private var lastMidiCount: UInt64 = 0
    private var launched = false

    // MARK: life cycle

    func launch() {
        guard !launched else { return }
        launched = true
        firmwares = library.records
        let fw = settings.currentFirmware.flatMap { library.record(id: $0) } ?? library.bundled
        if let fw {
            boot(fw)
        } else {
            status = .failed("Le firmware d'origine manque dans l'application.")
        }
        audio.mixWithOthers = settings.mixWithOthers
        audio.start()
        midi.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func didEnterBackground() {
        if settings.backgroundAudio {
            fm1ios_request_save()
            keepSave()
        } else {
            fm1ios_stop()
            keepSave()
            audio.pause()
        }
    }

    func willEnterForeground() {
        audio.start()
        if status == .running { _ = fm1ios_start() }
    }

    func willTerminate() {
        fm1ios_stop()
        keepSave()
    }

    // MARK: booting / firmware updates

    /// Boot a firmware as the FM-1 does after an update or at power-on.
    @discardableResult
    func boot(_ fw: FirmwareRecord, bank: Data? = nil, freshStart: Bool = false) -> Bool {
        // the running firmware's last flash writes are kept first
        fm1ios_stop()
        keepSave()
        status = .updating(fw.name)
        guard let pkg = library.packageData(fw) else {
            status = .failed(FirmwareError.missingFile.localizedDescription)
            return false
        }
        if freshStart { library.deleteSave(for: fw) }
        let saved = library.loadSave(for: fw) ?? Data()
        let syx = bank ?? Data()
        let mhz = UInt32(max(60, min(480, settings.mhz)))
        let code: Int32 = pkg.withUnsafeBytes { p in
            saved.withUnsafeBytes { s in
                syx.withUnsafeBytes { b in
                    fm1ios_boot(p.bindMemory(to: UInt8.self).baseAddress, p.count,
                                s.count > 0 ? s.bindMemory(to: UInt8.self).baseAddress : nil, s.count,
                                b.count > 0 ? b.bindMemory(to: UInt8.self).baseAddress : nil, b.count, mhz)
                }
            }
        }
        switch code {
        case 0: break
        case 2: message = "La mémoire enregistrée de ce firmware n'a pas pu être relue : il démarre comme neuf."
        case 3: message = "Ce firmware a refusé la banque DX7 (fichier .syx de 32 voix attendu)."
        case 4: message = "Ce firmware n'accepte pas l'import de banques DX7 de cette façon."
        default:
            status = .failed(FirmwareError.notAPackage.localizedDescription)
            return false
        }
        current = fw
        settings.currentFirmware = fw.id
        applyMIDIChannel()
        fm1ios_set_buffer(UInt32(settings.bufferFrames))
        fm1ios_pot(UInt32(settings.pot))
        _ = fm1ios_start()
        status = .running
        stats = Stats()
        return true
    }

    /// Install a package (from a file or the web) and boot it: the FM-1's firmware update.
    func update(with data: Data, name: String, source: String?) {
        do {
            let fw = try library.install(data, suggestedName: name, source: source)
            firmwares = library.records
            boot(fw)
        } catch {
            message = error.localizedDescription
        }
    }

    func download(from text: String) async {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" || url.scheme == "http" else {
            message = "Adresse invalide."
            return
        }
        status = .updating("Téléchargement…")
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw FirmwareError.download("erreur HTTP \(http.statusCode)")
            }
            update(with: data, name: url.lastPathComponent, source: url.absoluteString)
        } catch {
            message = error.localizedDescription
        }
        if case .updating = status { status = current == nil ? .off : .running }
    }

    func returnToStock() {
        if let fw = library.bundled { boot(fw) }
    }

    func restart() {
        if let fw = current { boot(fw) }
    }

    /// Erase this firmware's saved flash and boot it as new (its factory state).
    func factoryReset() {
        if let fw = current { boot(fw, freshStart: true) }
    }

    func remove(_ fw: FirmwareRecord) {
        guard !fw.bundled else { return }
        let wasCurrent = fw.id == current?.id
        if wasCurrent { fm1ios_stop() }
        library.remove(fw)
        firmwares = library.records
        if wasCurrent { returnToStock() }
    }

    func rename(_ fw: FirmwareRecord, to name: String) {
        library.rename(fw, to: name)
        firmwares = library.records
        if fw.id == current?.id { current = library.record(id: fw.id) }
    }

    /// A DX7 32-voice bank (.syx) into the firmware's patch library, as M-VAVE's sound import does.
    func importBank(_ data: Data) {
        guard let fw = current else { return }
        boot(fw, bank: data)
    }

    // MARK: backups (.fm1save, the browser emulator's format)

    func makeBackupFile() -> URL? {
        guard let fw = current, let pkg = library.packageData(fw) else { return nil }
        fm1ios_request_save()
        fm1ios_stop()
        keepSave()
        _ = fm1ios_start()
        let sectors = library.loadSave(for: fw) ?? Data()
        guard let json = try? BackupFile.encode(record: fw, package: pkg, sectors: sectors) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let safe = fw.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe) \(stamp).fm1save")
        do {
            try json.write(to: url, options: .atomic)
            return url
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    func restoreBackup(_ data: Data) {
        do {
            let b = try BackupFile.decode(data)
            var fw = library.record(id: b.hash)
            if fw == nil, let pkg = b.package {
                fw = try library.install(pkg, suggestedName: b.name, source: "Sauvegarde")
                firmwares = library.records
            }
            guard let fw else {
                message = "Installez d'abord le firmware de cette sauvegarde, puis importez-la à nouveau."
                return
            }
            fm1ios_stop()
            keepSave()
            library.writeSave(b.sectors, for: fw)
            boot(fw)
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: files opened from outside the app

    func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            message = "Impossible de lire « \(url.lastPathComponent) »."
            return
        }
        let name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "syx": pending = .bank(data, name)
        case "fm1save", "json": pending = .backup(data, name)
        default:
            if FirmwareLibrary.identity(of: data) != nil {
                pending = .firmware(data, name, name)
            } else {
                message = FirmwareError.notAPackage.localizedDescription
            }
        }
    }

    func confirm(_ p: Pending) {
        pending = nil
        switch p {
        case .firmware(let d, let n, let s): update(with: d, name: n, source: s)
        case .bank(let d, _): importBank(d)
        case .backup(let d, _): restoreBackup(d)
        }
    }

    // MARK: settings that act on the machine

    func applyBuffer() { fm1ios_set_buffer(UInt32(settings.bufferFrames)) }

    func applyMixing() {
        audio.mixWithOthers = settings.mixWithOthers
        audio.reconfigure()
    }

    func applyMIDIChannel() {
        let c = settings.midiChannel
        if c < 0 {
            // M-VAVE's firmware takes its notes on channel 2 at its MIDI IN
            midi.forcedChannel = current?.isMVAVEStock == true ? 2 : 0
        } else {
            midi.forcedChannel = c
        }
    }

    var effectiveMIDIChannel: Int { midi.forcedChannel }

    // MARK: polling

    private func keepSave() {
        guard let fw = current else { return }
        var len = 0
        if let p = fm1ios_take_save(&len) {
            library.writeSave(Data(bytes: p, count: len), for: fw)
            fm1ios_free(p, len)
        }
    }

    private func poll() {
        keepSave()
        var s = Fm1Stats()
        fm1ios_stats(&s)
        let count = midi.messageCount
        let next = Stats(speed: s.speed, underruns: s.underruns, emulatedSeconds: Double(s.emu_ms) / 1000,
                         halted: s.halted != 0, midiActive: count != lastMidiCount)
        lastMidiCount = count
        if next != stats { stats = next }
        if s.halted != 0, status == .running {
            status = .failed("Le firmware s'est arrêté. Redémarrez la machine ou revenez au firmware d'origine.")
        }
    }
}
