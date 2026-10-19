import AppKit
import SwiftUI

@main
struct MacResourceMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        UserDefaults.standard.register(defaults: [
            "NSAutoFillHeuristicControllerEnabled": false,
            AppPreferences.showNetworkSpeedKey: AppPreferences.showNetworkSpeedDefault
        ])
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .windowResizability(.contentSize)
        .commands {
            SettingsPresenterCommands()
        }
    }
}
