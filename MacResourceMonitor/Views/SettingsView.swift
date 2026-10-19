import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable private var launchAtLogin = LaunchAtLoginManager.shared
    @Bindable private var displayPreferences = MenuBarDisplayPreferences.shared
    @State private var contentHeight: CGFloat = 220

    var body: some View {
        Form {
            Section(String(localized: "settings.general")) {
                Toggle(String(localized: "menu.showNetworkSpeed"), isOn: $displayPreferences.showsNetworkSpeed)
                Toggle(String(localized: "settings.launchAtLogin"), isOn: launchBinding)
                    .help(String(localized: "settings.launchAtLogin.help"))

                if launchAtLogin.requiresApproval {
                    LabeledContent {
                        Button(String(localized: "settings.launchAtLogin.openLoginItems")) {
                            launchAtLogin.openSystemSettings()
                        }
                    } label: {
                        Text(String(localized: "settings.launchAtLogin.needsApproval"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let message = launchAtLogin.lastErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section { appIdentity }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollDisabled(true)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
            if height > 0 { contentHeight = ceil(height) }
        }
        .frame(width: 480, height: contentHeight)
        .fixedSize()
        .focusEffectDisabled()
        .background(SettingsWindowObserver())
        .onAppear { launchAtLogin.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
        .onExitCommand { SettingsWindowController.shared.close() }
    }

    private var appIdentity: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Mac Resource Monitor")
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button(String(localized: "menu.checkForUpdates")) { AppDelegate.shared?.checkForUpdates() }
            Button(String(localized: "settings.quit")) { AppDelegate.shared?.requestTermination() }
        }
    }

    private var launchBinding: Binding<Bool> {
        Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) })
    }
}
