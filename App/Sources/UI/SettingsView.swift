import SwiftUI
import UniformTypeIdentifiers
import CoreAudioKit

struct SettingsView: View {
    @EnvironmentObject var emu: Emulator
    @ObservedObject var settings = Settings.shared
    @Environment(\.dismiss) private var dismiss

    private enum Importing { case firmware, bank, backup }
    @State private var importing: Importing?
    @State private var showURL = false
    @State private var urlText = ""
    @State private var confirmReset = false
    @State private var confirmUpdate: FirmwareRecord?
    @State private var exportURL: URL?
    @State private var showBluetooth = false
    @State private var renaming: FirmwareRecord?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Form {
                firmwareSection
                soundSection
                backupSection
                midiSection
                audioSection
                advancedSection
                aboutSection
            }
            .navigationTitle("FM-1")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
            .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                          allowedContentTypes: allowedTypes, allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .alert("Mettre à jour depuis le web", isPresented: $showURL) {
                TextField("https://…/firmware.fwsc", text: $urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Télécharger") {
                    let t = urlText
                    dismiss()
                    Task { await emu.download(from: t) }
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Adresse d'un fichier de mise à jour .fwsc (par exemple sur m-vave.com ou la page GitHub d'un firmware).")
            }
            .alert("Renommer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Nom", text: $newName)
                Button("OK") { if let r = renaming { emu.rename(r, to: newName) } }
                Button("Annuler", role: .cancel) {}
            }
            .confirmationDialog("Effacer la mémoire de ce firmware ?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Effacer et redémarrer", role: .destructive) { emu.factoryReset(); dismiss() }
            } message: {
                Text("Les presets, réglages et séquences enregistrés par ce firmware seront perdus : il redémarre dans son état d'usine.")
            }
            .confirmationDialog("Mettre à jour le firmware ?", isPresented: Binding(get: { confirmUpdate != nil }, set: { if !$0 { confirmUpdate = nil } }),
                                titleVisibility: .visible, presenting: confirmUpdate) { fw in
                Button("Installer \(fw.name)") { emu.boot(fw); dismiss() }
            } message: { fw in
                Text("\(fw.name) (\(fw.versionLabel)) remplace le firmware actuel, comme une mise à jour de la machine. Chaque firmware garde ses propres réglages.")
            }
            .sheet(isPresented: $showBluetooth) { BluetoothMIDIView().ignoresSafeArea() }
        }
    }

    // MARK: sections

    private var firmwareSection: some View {
        Section {
            if let fw = emu.current {
                LabeledContent("Firmware actuel", value: fw.name)
                LabeledContent("Identité", value: "\(fw.identity) · \(fw.versionLabel)")
            }
            ForEach(emu.firmwares) { fw in
                Button {
                    if fw.id != emu.current?.id { confirmUpdate = fw }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fw.name).foregroundStyle(.primary)
                            Text(fw.bundled ? "M-VAVE · \(fw.identity) · intégré" : "\(fw.identity)\(fw.source.map { " · " + $0 } ?? "")")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if fw.id == emu.current?.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .swipeActions {
                    if !fw.bundled {
                        Button("Supprimer", role: .destructive) { emu.remove(fw) }
                        Button("Renommer") { newName = fw.name; renaming = fw }
                    }
                }
            }
            Button { importing = .firmware } label: { Label("Mettre à jour depuis un fichier .fwsc…", systemImage: "square.and.arrow.down") }
            Button { urlText = ""; showURL = true } label: { Label("Mettre à jour depuis une adresse web…", systemImage: "globe") }
            if emu.current?.bundled != true {
                Button { emu.returnToStock(); dismiss() } label: { Label("Revenir au firmware d'origine V15", systemImage: "arrow.uturn.backward") }
            }
        } header: {
            Text("Firmware")
        } footer: {
            Text("Comme sur la machine, un firmware s'installe à partir d'un fichier de mise à jour .fwsc : celui de M-VAVE (m-vave.com, rubrique téléchargements), FM1 Open, ou un firmware de la communauté. Les fichiers .fwsc ouverts depuis Fichiers, AirDrop ou Mail arrivent aussi ici.")
        }
    }

    private var soundSection: some View {
        Section {
            Button { importing = .bank } label: { Label("Importer une banque DX7 (.syx)…", systemImage: "waveform") }
            Button(role: .destructive) { confirmReset = true } label: { Label("Effacer la mémoire de ce firmware…", systemImage: "trash") }
        } header: {
            Text("Sons")
        } footer: {
            Text("Une banque DX7 de 32 voix (SysEx) prend la place des voix 1 à 32, comme l'import de sons de M-VAVE. Tout ce que vous enregistrez avec SAVE sur le FM-1 est gardé d'un lancement à l'autre.")
        }
    }

    private var backupSection: some View {
        Section {
            if let url = exportURL {
                ShareLink(item: url) { Label("Partager « \(url.lastPathComponent) »", systemImage: "square.and.arrow.up") }
            } else {
                Button { exportURL = emu.makeBackupFile() } label: { Label("Préparer une sauvegarde (.fm1save)", systemImage: "externaldrive") }
            }
            Button { importing = .backup } label: { Label("Restaurer une sauvegarde…", systemImage: "clock.arrow.circlepath") }
        } header: {
            Text("Sauvegardes")
        } footer: {
            Text("Le format .fm1save est celui de l'émulateur web et du plug-in FM-1 : une sauvegarde passe de l'iPhone au navigateur ou au Mac, et inversement.")
        }
    }

    private var midiSection: some View {
        Section {
            Picker("Canal des notes reçues", selection: $settings.midiChannel) {
                Text("Automatique").tag(-1)
                Text("Tel qu'envoyé").tag(0)
                ForEach(1...16, id: \.self) { Text("Canal \($0)").tag($0) }
            }
            .onChange(of: settings.midiChannel) { _ in emu.applyMIDIChannel() }
            Button { showBluetooth = true } label: { Label("Claviers MIDI Bluetooth…", systemImage: "dot.radiowaves.left.and.right") }
            let names = emu.midi.sourceNames
            LabeledContent("Sources connectées", value: names.isEmpty ? "aucune" : names.joined(separator: ", "))
        } header: {
            Text("MIDI")
        } footer: {
            Text("Tous les claviers MIDI (USB, Bluetooth, réseau) jouent le FM-1 par sa prise MIDI IN, ainsi que les autres apps via le port virtuel « FM-1 ». En automatique, les notes vont sur le canal 2 pour le firmware de M-VAVE (actuellement canal \(emu.effectiveMIDIChannel == 0 ? "inchangé" : String(emu.effectiveMIDIChannel))).")
        }
    }

    private var audioSection: some View {
        Section {
            Picker("Tampon audio", selection: $settings.bufferFrames) {
                Text("512 images · 12 ms").tag(512)
                Text("1024 images · 23 ms").tag(1024)
                Text("2048 images · 46 ms").tag(2048)
                Text("4096 images · 93 ms").tag(4096)
            }
            .onChange(of: settings.bufferFrames) { _ in emu.applyBuffer() }
            Toggle("Son en arrière-plan", isOn: $settings.backgroundAudio)
            Toggle("Mélanger avec les autres apps", isOn: $settings.mixWithOthers)
                .onChange(of: settings.mixWithOthers) { _ in emu.applyMixing() }
            Toggle("Retour haptique", isOn: $settings.haptics)
        } header: {
            Text("Audio")
        } footer: {
            Text("Si le son craque (voyant rouge), augmentez le tampon. Un tampon plus court répond plus vite aux touches.")
        }
    }

    private var advancedSection: some View {
        Section {
            LabeledContent("Vitesse d'émulation", value: emu.stats.speed > 0 ? String(format: "%.2f× le temps réel", emu.stats.speed) : "–")
            LabeledContent("Coupures audio", value: "\(emu.stats.underruns)")
            LabeledContent("Temps émulé", value: String(format: "%.0f s", emu.stats.emulatedSeconds))
            Picker("Horloge du processeur", selection: $settings.mhz) {
                Text("240 MHz (d'origine)").tag(240)
                Text("320 MHz").tag(320)
                Text("160 MHz").tag(160)
            }
            Button { emu.restart(); dismiss() } label: { Label("Redémarrer la machine", systemImage: "power") }
        } header: {
            Text("Avancé")
        } footer: {
            Text("L'horloge s'applique au prochain redémarrage. 240 MHz est celle de la puce JieLi du FM-1 ; une autre valeur peut changer le comportement du firmware.")
        }
    }

    private var aboutSection: some View {
        Section {
            NavigationLink("Licences") { LicensesView() }
        } header: {
            Text("À propos")
        } footer: {
            Text("Émulation du matériel par fm1-emu de Joakim Eriksson (licence MIT). Firmware d'origine V15 © M-VAVE, distribué par M-VAVE sous licence Apache-2.0 dans le kit FM1 Open. M-VAVE et FM-1 sont des marques de leurs propriétaires ; cette application n'est pas affiliée à M-VAVE.")
        }
    }

    // MARK: importing

    private var allowedTypes: [UTType] {
        switch importing {
        case .firmware: return [UTType(importedAs: "com.m-vave.fwsc", conformingTo: .data), .data]
        case .bank: return [UTType(importedAs: "com.yamaha.dx7.syx", conformingTo: .data), .data]
        case .backup: return [UTType(importedAs: "com.fm1-emu.fm1save", conformingTo: .json), .json, .data]
        case nil: return [.data]
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        let kind = importing
        importing = nil
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            emu.message = "Impossible de lire « \(url.lastPathComponent) »."
            return
        }
        switch kind {
        case .firmware:
            dismiss()
            emu.update(with: data, name: url.lastPathComponent, source: url.lastPathComponent)
        case .bank:
            dismiss()
            emu.importBank(data)
        case .backup:
            dismiss()
            emu.restoreBackup(data)
        case nil:
            break
        }
    }
}

/// iOS's own Bluetooth MIDI pairing screen.
struct BluetoothMIDIView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = CABTMIDICentralViewController()
        let nav = UINavigationController(rootViewController: vc)
        vc.navigationItem.title = "MIDI Bluetooth"
        return nav
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}

struct LicensesView: View {
    var body: some View {
        List {
            NavigationLink("fm1-emu (MIT)") { LicenseText(file: "fm1-emu-LICENSE", ext: "txt") }
            NavigationLink("M-VAVE FM1 Open : firmware V15 (Apache-2.0) et tiers") {
                LicenseText(file: "M-VAVE-FM1-Open-THIRD_PARTY", ext: "md")
            }
        }
        .navigationTitle("Licences")
    }
}

struct LicenseText: View {
    let file: String
    let ext: String

    var body: some View {
        ScrollView {
            Text(text).font(.system(.footnote, design: .monospaced)).padding().textSelection(.enabled)
        }
        .navigationTitle(file)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var text: String {
        let url = Bundle.main.url(forResource: file, withExtension: ext, subdirectory: "Licenses")
            ?? Bundle.main.url(forResource: file, withExtension: ext)
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Texte introuvable."
    }
}
