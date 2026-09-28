import AppKit
import SwiftUI

struct MacPlusPlusPublicSetupManager: View {
    var onChange: () -> Void = {}
    @AppStorage("org.macplusplus.setup.wifi") private var wifi = false
    @AppStorage("org.macplusplus.setup.wifi-nearby-scan") private var wifiNearbyScan = false
    @AppStorage("org.macplusplus.setup.bluetooth") private var bluetooth = false
    @AppStorage("org.macplusplus.setup.location") private var location = false
    @AppStorage("org.macplusplus.setup.notification-settings") private var notificationSettings = false
    @AppStorage("org.macplusplus.setup.screen-capture") private var screenCapture = false
    @AppStorage("org.macplusplus.setup.audio-visualization") private var audioVisualization = false
    @AppStorage("org.macplusplus.setup.accessibility") private var accessibility = false
    @AppStorage("org.macplusplus.setup.yabai") private var yabaiRawValue = MacPlusPlusYabaiLevel.off.rawValue

    private var selection: MacPlusPlusSetupSelection {
        MacPlusPlusSetupSelection(
            wifi: wifi,
            wifiNearbyScan: wifiNearbyScan,
            bluetooth: bluetooth,
            location: location,
            notificationSettings: notificationSettings,
            screenCapture: screenCapture,
            audioVisualization: audioVisualization,
            accessibility: accessibility,
            yabai: MacPlusPlusYabaiLevel(rawValue: yabaiRawValue) ?? .off
        )
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SET UP MAC++")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(.secondary)
                    Text("Choose your feature sets")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("These choices make a plan only. They do not install software, grant permissions, start services, or change startup security.")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                tierPicker

                capabilityToggle(
                    "Wi-Fi controls",
                    "Include Wi-Fi status and user-invoked controls. When this is off, those controls are omitted from the plan.",
                    disabledDetail: "Wi-Fi controls are omitted",
                    symbol: "wifi",
                    isOn: $wifi,
                    settingsURL: "x-apple.systempreferences:com.apple.wifi-settings-extension"
                )
                capabilityToggle(
                    "Nearby Wi-Fi scan",
                    "Include explicit nearby-network scans. macOS may require Location Services; saved passwords remain in macOS.",
                    disabledDetail: "nearby-network scans are omitted",
                    symbol: "wifi.circle",
                    isOn: $wifiNearbyScan,
                    settingsURL: "x-apple.systempreferences:com.apple.wifi-settings-extension"
                )
                .disabled(!wifi)
                capabilityToggle(
                    "Bluetooth devices",
                    "Show paired devices and offer connect/disconnect actions. macOS can ask for Bluetooth access when you first use the controls.",
                    disabledDetail: "Bluetooth status and device actions are omitted",
                    symbol: "dot.radiowaves.left.and.right",
                    isOn: $bluetooth,
                    settingsURL: "x-apple.systempreferences:com.apple.BluetoothSettings"
                )
                capabilityToggle(
                    "Location-aware features",
                    "Allow optional local weather and nearby-network features. Turn this off to keep location-based features out of the plan.",
                    disabledDetail: "location-based features are omitted",
                    symbol: "location",
                    isOn: $location,
                    settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices"
                )
                capabilityToggle(
                    "One-shot screen capture",
                    "Include explicit capture tools. No continuous screen recording is included; macOS asks when a capture tool is used.",
                    disabledDetail: "capture tools are omitted",
                    symbol: "viewfinder",
                    isOn: $screenCapture,
                    settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
                )
                capabilityToggle(
                    "Audio visualization",
                    "Include the separate generic audio helper. It analyzes audio locally and needs macOS audio-capture consent when started.",
                    disabledDetail: "the audio helper is omitted",
                    symbol: "waveform",
                    isOn: $audioVisualization,
                    settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_SystemAudioRecording"
                )
                capabilityToggle(
                    "Accessibility actions",
                    "Include chosen window and input actions. Without this set, Mac++ keeps its panels, Search, Wi-Fi, Bluetooth, wallpaper, and media controls.",
                    disabledDetail: "window and input actions are omitted",
                    symbol: "accessibility",
                    isOn: $accessibility,
                    settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
                )

                notificationCard
                yabaiCard
                planCard
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: wifi) { _, isEnabled in
            if !isEnabled {
                wifiNearbyScan = false
                UserDefaults.standard.removeObject(forKey: "cachedWiFiNetworks")
                UserDefaults.standard.removeObject(forKey: "lastKnownWiFiSSID")
            }
            onChange()
        }
        .onChange(of: wifiNearbyScan) { _, _ in onChange() }
        .onChange(of: location) { _, _ in onChange() }
        .onChange(of: yabaiRawValue) { _, _ in onChange() }
    }

    private var tierPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Choose a setup tier", systemImage: "square.stack.3d.up")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text("A tier is a preset for the plan. You can change individual feature sets below it.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(MacPlusPlusSetupTier.allCases) { tier in
                Button { apply(tier) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selection.installTier == tier.rawValue ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selection.installTier == tier.rawValue ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tier.title)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary)
                            Text(tier.detail)
                                .font(.system(size: 11, weight: .regular, design: .rounded))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(15)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private func apply(_ tier: MacPlusPlusSetupTier) {
        wifi = tier != .core
        wifiNearbyScan = false
        bluetooth = tier != .core
        location = false
        notificationSettings = false
        screenCapture = false
        audioVisualization = false
        accessibility = tier == .windowManagement || tier == .advanced
        switch tier {
        case .core, .systemControls:
            yabaiRawValue = MacPlusPlusYabaiLevel.off.rawValue
        case .windowManagement:
            yabaiRawValue = MacPlusPlusYabaiLevel.standard.rawValue
        case .advanced:
            yabaiRawValue = MacPlusPlusYabaiLevel.scriptingAddition.rawValue
        }
    }

    private func capabilityToggle(
        _ title: String,
        _ detail: String,
        disabledDetail: String,
        symbol: String,
        isOn: Binding<Bool>,
        settingsURL: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(title, isOn: isOn)
                        .toggleStyle(.switch)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(detail)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(isOn.wrappedValue ? "IN PLAN · disabled sets are omitted" : "OFF · \(disabledDetail)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
                }
            }
            Button("Open related System Settings") {
                guard let url = URL(string: settingsURL) else { return }
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.link)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.leading, 36)
        }
        .padding(15)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private var notificationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $notificationSettings) {
                Label("Notification settings shortcut", systemImage: "bell.badge")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .toggleStyle(.switch)
            Text("Mac++ does not read other apps’ notification contents, mirror them, or suppress native banners. macOS continues to deliver notifications either way.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if notificationSettings {
                Button("Open Notifications Settings") {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .medium, design: .rounded))
            } else {
                Text("OFF · the Mac++ shortcut is omitted; native macOS notifications are unchanged")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private var yabaiCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Window management", systemImage: "macwindow.on.rectangle")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text("Choose how much optional window automation to include. Mac++ never installs yabai or changes SIP from this page.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(MacPlusPlusYabaiLevel.allCases) { level in
                Button {
                    yabaiRawValue = level.rawValue
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: yabaiRawValue == level.rawValue ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(yabaiRawValue == level.rawValue ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(level.title)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary)
                            Text(yabaiDescription(for: level))
                                .font(.system(size: 11, weight: .regular, design: .rounded))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(yabaiRawValue == level.rawValue ? .isSelected : [])
            }
            if MacPlusPlusYabaiLevel(rawValue: yabaiRawValue) == .scriptingAddition {
                Label("Security tradeoff", systemImage: "exclamationmark.shield")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
                Text("The scripting addition needs a user-managed partial SIP change from Recovery. This reduces macOS protections and enables extra privileged window/space operations. Some yabai features remain unavailable without it. Keep SIP enabled unless you specifically need those features.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = URL(string: "https://github.com/asmvik/yabai/wiki/Installing-yabai-(latest-release)") {
                Link("Review yabai’s installation and SIP notes", destination: url)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
        }
        .padding(15)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private func yabaiDescription(for level: MacPlusPlusYabaiLevel) -> String {
        switch level {
        case .off:
            "No yabai service, rules, or Accessibility request."
        case .standard:
            "Install yabai separately and approve Accessibility. Recent compatible releases move windows with SIP enabled; scripting-addition features are omitted."
        case .scriptingAddition:
            "Adds yabai’s scripting addition. Requires a manual RecoveryOS security change and an explicit decision to accept the reduced protections."
        }
    }

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Install plan preview", systemImage: "checklist")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(selection.planSummary)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Selections are stored as Mac++ preferences. They do not trigger an installer or a macOS permission prompt.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(15)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }
}
