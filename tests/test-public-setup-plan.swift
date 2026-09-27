import Foundation

@main
struct MacPlusPlusPublicSetupPlanTests {
    static func main() {
        let core = MacPlusPlusSetupSelection()
        precondition(core.selectedCapabilities == ["shell", "search"], "Core must opt in to no optional capabilities")
        precondition(core.yabai == .off, "Core must leave yabai off")
        precondition(core.installTier == "core", "Empty optional selection should remain Core")

        let wifi = MacPlusPlusSetupSelection(wifi: true)
        precondition(wifi.selectedCapabilities.contains("wifi"), "Wi-Fi control selection should be represented")
        precondition(!wifi.selectedCapabilities.contains("wifi-nearby-scan"), "Nearby scanning must remain separately opt-in")
        precondition(wifi.planSummary.contains("Nearby Wi-Fi scans are omitted."), "Plan should explain omitted Wi-Fi scanning")

        let scan = MacPlusPlusSetupSelection(wifi: true, wifiNearbyScan: true, location: true)
        precondition(scan.selectedCapabilities.contains("wifi-nearby-scan"), "Nearby scan selection should be represented")
        precondition(scan.selectedCapabilities.contains("location"), "Nearby scanning can include its selected location requirement")

        let notifications = MacPlusPlusSetupSelection(notificationSettings: true)
        precondition(notifications.planSummary.contains("native macOS delivery is unchanged"), "Notification selection should explain delivery")
        precondition(notifications.planSummary.contains("never reads contents"), "Notification selection should explain privacy behavior")

        let standard = MacPlusPlusSetupSelection(yabai: .standard)
        precondition(standard.installTier == "window-management", "Standard yabai should select the window-management tier")
        precondition(standard.planSummary.contains("SIP remains enabled"), "Standard yabai must explain SIP state")

        let advanced = MacPlusPlusSetupSelection(yabai: .scriptingAddition)
        precondition(advanced.installTier == "advanced", "Scripting addition must require the advanced tier")
        precondition(advanced.planSummary.contains("partial SIP change from Recovery"), "Advanced tier should explain the SIP tradeoff")
        precondition(advanced.planSummary.contains("Mac++ will not change SIP"), "Mac++ must never change SIP")

        print("Mac++ public setup plan: PASS")
    }
}
