import SwiftUI

@main
struct FM1App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var emu = Emulator()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(emu)
                .onAppear {
                    AppDelegate.emulator = emu
                    emu.launch()
                }
        }
        .onChange(of: phase) { p in
            switch p {
            case .background: emu.didEnterBackground()
            case .active: emu.willEnterForeground()
            default: break
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    static weak var emulator: Emulator?

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .landscape
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppDelegate.emulator?.willTerminate()
    }
}
