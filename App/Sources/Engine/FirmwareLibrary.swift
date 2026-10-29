import Foundation
import CryptoKit
import FM1Engine

/// A firmware update package (.fwsc) the app can boot, as the FM-1 itself can be flashed with.
struct FirmwareRecord: Codable, Identifiable, Hashable {
    /// SHA-256 of the package (hex): each exact package keeps its own saved flash
    var id: String
    /// what the user sees
    var name: String
    /// the identity written in the package's header ("FM-1_015" for M-VAVE's V15)
    var identity: String
    var fileName: String
    var bundled: Bool
    var added: Date
    /// where it came from (a file name or a web address)
    var source: String?

    /// M-VAVE's own (closed-source) firmware: identities FM-1_0NN.
    var isMVAVEStock: Bool {
        identity.range(of: #"^FM-1_0\d\d$"#, options: .regularExpression) != nil
    }

    /// "V15" for FM-1_015, else the identity.
    var versionLabel: String {
        if isMVAVEStock, let n = Int(identity.suffix(3)) { return "V\(n)" }
        return identity
    }
}

enum FirmwareError: LocalizedError {
    case notAPackage
    case missingFile
    case download(String)

    var errorDescription: String? {
        switch self {
        case .notAPackage: return "Ce fichier n'est pas un firmware FM-1 (.fwsc)."
        case .missingFile: return "Le fichier du firmware est introuvable."
        case .download(let why): return "Téléchargement impossible : \(why)"
        }
    }
}

/// The packages (the bundled M-VAVE V15 and those the user installed) and, per package, the
/// flash the firmware saved (its presets, settings, sequences), kept in Application Support.
final class FirmwareLibrary {
    static let bundledFileName = "FM-1_015.fwsc"

    private(set) var records: [FirmwareRecord] = []
    private let fm = FileManager.default
    private let root: URL
    private var packagesDir: URL { root.appendingPathComponent("Firmware", isDirectory: true) }
    private var savesDir: URL { root.appendingPathComponent("Saves", isDirectory: true) }
    private var indexURL: URL { root.appendingPathComponent("library.json") }

    init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("FM1", isDirectory: true)
        for d in [root, packagesDir, savesDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        load()
    }

    // MARK: the index

    private func load() {
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([FirmwareRecord].self, from: data) {
            records = list.filter { !$0.bundled }
        }
        if let bundled = makeBundledRecord() {
            records.insert(bundled, at: 0)
        }
    }

    private func store() {
        let list = records.filter { !$0.bundled }
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    static func bundledURL() -> URL? {
        Bundle.main.url(forResource: "FM-1_015", withExtension: "fwsc", subdirectory: "Firmware")
            ?? Bundle.main.url(forResource: "FM-1_015", withExtension: "fwsc")
    }

    private func makeBundledRecord() -> FirmwareRecord? {
        guard let url = Self.bundledURL(), let data = try? Data(contentsOf: url) else { return nil }
        return FirmwareRecord(id: Self.sha256(data), name: "M-VAVE FM-1 V15 (firmware d'origine)",
                              identity: Self.identity(of: data) ?? "FM-1_015", fileName: Self.bundledFileName,
                              bundled: true, added: Date(timeIntervalSince1970: 0), source: "M-VAVE")
    }

    var bundled: FirmwareRecord? { records.first { $0.bundled } }

    func record(id: String) -> FirmwareRecord? { records.first { $0.id == id } }

    // MARK: packages

    func packageData(_ r: FirmwareRecord) -> Data? {
        if r.bundled { return Self.bundledURL().flatMap { try? Data(contentsOf: $0) } }
        return try? Data(contentsOf: packagesDir.appendingPathComponent(r.fileName))
    }

    /// Add a package (or find it if it is already there). Throws when the bytes are no package.
    @discardableResult
    func install(_ data: Data, suggestedName: String, source: String?) throws -> FirmwareRecord {
        guard let identity = Self.identity(of: data) else { throw FirmwareError.notAPackage }
        let hash = Self.sha256(data)
        if let existing = record(id: hash) { return existing }
        let file = hash + ".fwsc"
        try data.write(to: packagesDir.appendingPathComponent(file), options: .atomic)
        var name = (suggestedName as NSString).deletingPathExtension
        if name.isEmpty { name = identity }
        let r = FirmwareRecord(id: hash, name: name, identity: identity, fileName: file, bundled: false,
                               added: Date(), source: source)
        records.append(r)
        store()
        return r
    }

    func rename(_ r: FirmwareRecord, to name: String) {
        guard let i = records.firstIndex(where: { $0.id == r.id }), !r.bundled else { return }
        records[i].name = name
        store()
    }

    func remove(_ r: FirmwareRecord) {
        guard !r.bundled else { return }
        try? fm.removeItem(at: packagesDir.appendingPathComponent(r.fileName))
        deleteSave(for: r)
        records.removeAll { $0.id == r.id }
        store()
    }

    // MARK: saved flash

    private func saveURL(_ r: FirmwareRecord) -> URL { savesDir.appendingPathComponent(r.id + ".sectors") }

    func loadSave(for r: FirmwareRecord) -> Data? {
        guard let d = try? Data(contentsOf: saveURL(r)), !d.isEmpty else { return nil }
        return d
    }

    func writeSave(_ data: Data, for r: FirmwareRecord) {
        try? data.write(to: saveURL(r), options: .atomic)
    }

    func deleteSave(for r: FirmwareRecord) {
        try? fm.removeItem(at: saveURL(r))
    }

    // MARK: helpers

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The package's identity, or nil when the bytes are no FM-1 update package.
    static func identity(of data: Data) -> String? {
        var out = [CChar](repeating: 0, count: 64)
        let cap = out.count
        let n: Int32 = data.withUnsafeBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return fm1ios_package_identity(p, raw.count, &out, cap)
        }
        guard n >= 0 else { return nil }
        return String(cString: out)
    }
}

// MARK: - .fm1save backups (the browser emulator's format, so saves move between them)

struct BackupFile {
    static let format = "fm1-emulator-save"
    static let sector = 4096

    /// JSON: the package (base64) and the flash sectors it saved.
    static func encode(record: FirmwareRecord, package: Data, sectors: Data) throws -> Data {
        var list: [[String: Any]] = []
        let rec = 4 + sector
        var o = 0
        while o + rec <= sectors.count {
            let at = sectors.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let bytes = sectors.subdata(in: o + 4..<o + rec)
            list.append(["at": Int(UInt32(littleEndian: at)), "data": bytes.base64EncodedString()])
            o += rec
        }
        let json: [String: Any] = [
            "format": format, "version": 1, "hash": record.id, "name": record.name,
            "package": package.base64EncodedString(), "sectors": list,
        ]
        return try JSONSerialization.data(withJSONObject: json, options: [])
    }

    struct Decoded {
        var hash: String
        var name: String
        var package: Data?
        /// restore records (u32 LE offset + 4096 bytes)
        var sectors: Data
    }

    static func decode(_ data: Data) throws -> Decoded {
        struct Bad: LocalizedError { var errorDescription: String? { "Cette sauvegarde n'est pas lisible." } }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["format"] as? String == format, obj["version"] as? Int == 1,
              let hash = obj["hash"] as? String, hash.count == 64,
              let name = obj["name"] as? String,
              let list = obj["sectors"] as? [[String: Any]], list.count <= 256 else { throw Bad() }
        var package: Data?
        if let p = obj["package"] as? String {
            guard let d = Data(base64Encoded: p), FirmwareLibrary.sha256(d) == hash else { throw Bad() }
            package = d
        }
        var out = Data()
        var seen = Set<Int>()
        for s in list {
            guard let at = s["at"] as? Int, at >= 0, at < 1 << 20, at % sector == 0, !seen.contains(at),
                  let b = s["data"] as? String, let bytes = Data(base64Encoded: b), bytes.count == sector else { throw Bad() }
            seen.insert(at)
            var le = UInt32(at).littleEndian
            out.append(Data(bytes: &le, count: 4))
            out.append(bytes)
        }
        return Decoded(hash: hash, name: name, package: package, sectors: out)
    }
}
