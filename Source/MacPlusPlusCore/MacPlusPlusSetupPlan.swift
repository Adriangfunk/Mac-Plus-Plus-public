import Foundation

enum MacPlusPlusSetupTier: String, CaseIterable, Identifiable {
    case core
    case systemControls = "system-controls"
    case windowManagement = "window-management"
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .core: "Core"
        case .systemControls: "System controls"
        case .windowManagement: "Window management"
        case .advanced: "Advanced"
        }
    }

    var detail: String {
        switch self {
        case .core: "Shell and Search, with optional permissions and helpers left out."
        case .systemControls: "Add Wi-Fi and Bluetooth controls; choose other permissions separately."
        case .windowManagement: "Add standard yabai and Accessibility actions while SIP stays enabled."
        case .advanced: "Select yabai’s scripting addition for a manual RecoveryOS security decision."
        }
    }
}

enum MacPlusPlusYabaiLevel: String, CaseIterable, Identifiable, Codable {
    case off
    case standard
    case scriptingAddition

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "No yabai"
        case .standard: "yabai · SIP stays enabled"
        case .scriptingAddition: "yabai · scripting addition"
        }
    }
}

struct MacPlusPlusSetupSelection: Equatable, Codable {
    var wifi = false
    var wifiNearbyScan = false
    var bluetooth = false
    var location = false
    var notificationSettings = false
    var screenCapture = false
    var audioVisualization = false
    var accessibility = false
    var yabai: MacPlusPlusYabaiLevel = .off

    var selectedCapabilities: [String] {
        var values = ["shell", "search"]
        if wifi { values.append("wifi") }
        if wifi && wifiNearbyScan { values.append("wifi-nearby-scan") }
        if bluetooth { values.append("bluetooth") }
        if location { values.append("location") }
        if notificationSettings { values.append("notification-settings") }
        if screenCapture { values.append("screen-capture") }
        if audioVisualization { values.append("audio-visualization") }
        if accessibility { values.append("accessibility") }
        if yabai != .off { values.append("yabai") }
        if yabai == .scriptingAddition { values.append("yabai-scripting-addition") }
        return values
    }

    var installTier: String {
        if yabai == .scriptingAddition { return "advanced" }
        if yabai == .standard || accessibility { return "window-management" }
        if wifi || bluetooth || location || screenCapture || audioVisualization {
            return "system-controls"
        }
        return "core"
    }

    var planSummary: String {
        var lines = [
            "Mac++ setup plan · \(installTier)",
            "Included: \(selectedCapabilities.joined(separator: ", "))",
            "Notifications: native macOS only; Mac++ never reads contents or suppresses banners."
        ]
        if wifi {
            lines.append("Wi-Fi: status and user-started controls are included.")
            if wifiNearbyScan {
                lines.append("Nearby Wi-Fi scans are included and may require Location Services.")
            } else {
                lines.append("Nearby Wi-Fi scans are omitted.")
            }
        } else {
            lines.append("Wi-Fi status, scans, and controls are omitted.")
        }
        if bluetooth {
            lines.append("Bluetooth: device controls may request Bluetooth access when first used.")
        } else {
            lines.append("Bluetooth status and device controls are omitted.")
        }
        if location {
            lines.append("Location-aware features are included; macOS controls the privacy grant.")
        } else {
            lines.append("Location-aware features are omitted.")
        }
        if notificationSettings {
            lines.append("Notification settings shortcut: included; native macOS delivery is unchanged.")
        } else {
            lines.append("Notification settings shortcut: omitted; native macOS delivery is unchanged.")
        }
        if screenCapture {
            lines.append("Screen capture: one-shot tools only; macOS asks when a capture is requested.")
        } else {
            lines.append("Screen capture tools are omitted.")
        }
        if audioVisualization {
            lines.append("Audio: optional local visualizer; macOS audio-capture consent is required when started.")
        } else {
            lines.append("Audio visualization helper is omitted.")
        }
        if accessibility {
            lines.append("Accessibility actions are included; macOS may request Accessibility or Input Monitoring access when used.")
        } else {
            lines.append("Accessibility window and input actions are omitted.")
        }
        switch yabai {
        case .off:
            lines.append("Window management: macOS defaults; no yabai service or rules.")
        case .standard:
            lines.append("Window management: yabai with Accessibility permission; SIP remains enabled and scripting-addition features stay off.")
        case .scriptingAddition:
            lines.append("Advanced window management: yabai scripting addition requires a user-managed partial SIP change from Recovery. Mac++ will not change SIP or configure sudoers.")
        }
        return lines.joined(separator: "\n")
    }
}
