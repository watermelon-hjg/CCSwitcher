import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        // Apply saved language preference before any UI loads
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "auto"
        if lang != "auto" {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App starts as agent/accessory due to LSUIElement
    }

    /// Close the dev boxes' SSH forwards on the way out — an orphaned `ssh -N`
    /// would keep its local port bound and the next launch would have to move
    /// off it.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { SSHTunnelManager.shared.stopAll() }
    }
}

@main
struct CCSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var menuBarConfig = MenuBarConfig.shared
    @StateObject private var remoteHosts = RemoteHostsManager.shared
    @AppStorage("refreshInterval") private var refreshInterval: Double = 300
    @AppStorage("appLanguage") private var appLanguage = "auto"

    @State private var statusItemController = StatusItemController()
    @State private var didBootstrap = false

    var body: some Scene {
        // Hidden 1×1 window to keep SwiftUI's lifecycle alive so `Settings` scene
        // shows the native toolbar tabs even though the UI is AppKit-based.
        WindowGroup("CCSwitcherKeepalive") {
            HiddenWindowView()
                .onAppear {
                    guard !didBootstrap else { return }
                    didBootstrap = true
                    // Sparkle's SPUStandardUpdaterController(startingUpdater: true)
                    // schedules its own background update checks; no need to
                    // call checkForUpdates here.
                    _ = updateChecker
                    statusItemController.install(
                        appState: appState,
                        config: menuBarConfig,
                        locale: currentLocale
                    )
                    // Kick off background usage tracking immediately upon app start
                    Task {
                        await appState.refresh()
                        appState.startAutoRefresh(interval: refreshInterval)
                    }
                }
                .onChange(of: appLanguage) { _, _ in
                    statusItemController.updateLocale(currentLocale)
                }
        }
        .defaultSize(width: 20, height: 20)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(updateChecker)
                .environmentObject(menuBarConfig)
                .environmentObject(remoteHosts)
                .environment(\.locale, currentLocale)
        }
    }

    private var currentLocale: Locale {
        appLanguage == "auto" ? .autoupdatingCurrent : Locale(identifier: appLanguage)
    }
}
