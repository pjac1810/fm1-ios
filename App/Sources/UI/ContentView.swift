import SwiftUI

struct ContentView: View {
    @EnvironmentObject var emu: Emulator
    @ObservedObject var settings = Settings.shared
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color(red: 0x18 / 255, green: 0x19 / 255, blue: 0x1b / 255).ignoresSafeArea()
            HStack(spacing: 0) {
                PanelView(haptics: settings.haptics)
                    .ignoresSafeArea(edges: .vertical)
                sideBar
            }
            if case .updating(let what) = emu.status {
                updatingOverlay(what)
            }
            if case .failed(let why) = emu.status {
                failedOverlay(why)
            }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(emu)
        }
        .alert("FM-1", isPresented: Binding(get: { emu.message != nil }, set: { if !$0 { emu.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(emu.message ?? "")
        }
        .confirmationDialog(pendingTitle, isPresented: Binding(get: { emu.pending != nil }, set: { if !$0 { emu.pending = nil } }),
                            titleVisibility: .visible, presenting: emu.pending) { p in
            Button(pendingAction(p)) { emu.confirm(p) }
            Button("Annuler", role: .cancel) { emu.pending = nil }
        } message: { p in
            Text(pendingMessage(p))
        }
        .onOpenURL { emu.open($0) }
    }

    private var sideBar: some View {
        VStack(spacing: 18) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title2)
            }
            .accessibilityLabel("Réglages et firmware")
            SpeedLight(stats: emu.stats)
            Image(systemName: "pianokeys")
                .foregroundStyle(emu.stats.midiActive ? Color.green : Color.gray.opacity(0.5))
                .accessibilityLabel("Activité MIDI")
            Spacer()
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.top, 14)
        .frame(width: 52)
    }

    private func updatingOverlay(_ what: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Mise à jour du firmware").font(.headline)
            Text(what).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func failedOverlay(_ why: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
            Text(why).multilineTextAlignment(.center)
            HStack {
                Button("Redémarrer") { emu.restart() }
                Button("Firmware d'origine") { emu.returnToStock() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var pendingTitle: String {
        switch emu.pending {
        case .firmware: return "Mettre à jour le firmware ?"
        case .bank: return "Importer une banque DX7 ?"
        case .backup: return "Restaurer une sauvegarde ?"
        case nil: return ""
        }
    }

    private func pendingAction(_ p: Emulator.Pending) -> String {
        switch p {
        case .firmware: return "Installer et redémarrer"
        case .bank: return "Importer les 32 voix"
        case .backup: return "Restaurer"
        }
    }

    private func pendingMessage(_ p: Emulator.Pending) -> String {
        switch p {
        case .firmware(let data, let name, _):
            let id = FirmwareLibrary.identity(of: data) ?? "?"
            return "\(name) (\(id)). Les réglages enregistrés du firmware actuel sont conservés ; chaque firmware garde les siens."
        case .bank(_, let name):
            return "\(name) remplacera les 32 premières voix de la bibliothèque du firmware actuel."
        case .backup(_, let name):
            return "\(name) remplacera la mémoire enregistrée de son firmware."
        }
    }
}

/// Green: the emulation keeps up with ease; orange: just; red: the sound drops out.
struct SpeedLight: View {
    let stats: Emulator.Stats

    var body: some View {
        VStack(spacing: 2) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(stats.speed > 0 ? String(format: "%.1f×", stats.speed) : "–")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .accessibilityLabel("Vitesse d'émulation")
    }

    private var color: Color {
        if stats.speed == 0 { return .gray }
        if stats.speed < 1.0 { return .red }
        if stats.speed < 1.2 { return .orange }
        return .green
    }
}
