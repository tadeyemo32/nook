import Foundation

enum Pref: String {
    case expandOnHover, hoverDelay, haptics
    case liveWaveform, artworkTint, dimArtworkOnPause, swipeSeeks
    case replaceSystemHUD, hudShowsPercent, accessibilityPrompted
    case batteryAlerts, bluetoothActivity, privacyIndicators, downloadsActivity, calendarAlerts
    case showCalendar, showWeather, tabShelf, tabClipboard, tabStats, tabTimer, tabMirror, tabWidgets, tabAgents
    case clipboardHistory
    case display, allDisplays, simulatedNotch, notchWidthOffset, notchHeightOffset, outline
    case hideInFullscreen, hideWhileGaming, hideFromCapture
    case showOnLockScreen, lockScreenWidgets, lockSounds, lockScreenTop, lockHideWhenPaused, lockKeepAwake
    case claudeDoneAlerts, plugins
    case agentClaude, agentCodex, agentChips, agentChipStyle, agentShowWhen
    case agentShowModel, agentShowContext, agentShowCost, agentShowLines, agentShowPlan, agentShowResets
    case agentAlertPermission, agentAlertWaiting, agentAlertSubagent, agentAlertCompact, agentAlertSession
    case agentAlertOther, agentAlertLimits, agentAlertContext
    case shelfItems

    static func register() {
        UserDefaults.standard.register(defaults: [
            Pref.hoverDelay.rawValue: 0.0,
            Pref.haptics.rawValue: true,
            Pref.artworkTint.rawValue: true,
            Pref.dimArtworkOnPause.rawValue: true,
            Pref.replaceSystemHUD.rawValue: true,
            Pref.batteryAlerts.rawValue: true,
            Pref.bluetoothActivity.rawValue: true,
            Pref.privacyIndicators.rawValue: true,
            Pref.tabShelf.rawValue: true,
            Pref.tabAgents.rawValue: true,
            Pref.display.rawValue: "auto",
            Pref.outline.rawValue: "none",
            Pref.showOnLockScreen.rawValue: true,
            Pref.claudeDoneAlerts.rawValue: true,
            Pref.lockScreenWidgets.rawValue: true,
            Pref.lockScreenTop.rawValue: 0.28,
            Pref.agentClaude.rawValue: true,
            Pref.agentCodex.rawValue: true,
            Pref.agentChips.rawValue: true,
            Pref.agentChipStyle.rawValue: "used",
            Pref.agentShowWhen.rawValue: "active",
            Pref.agentShowModel.rawValue: true,
            Pref.agentShowContext.rawValue: true,
            Pref.agentShowPlan.rawValue: true,
            Pref.agentShowResets.rawValue: true,
            Pref.agentAlertPermission.rawValue: true,
            Pref.agentAlertWaiting.rawValue: true,
            Pref.agentAlertSubagent.rawValue: true,
            Pref.agentAlertOther.rawValue: true,
            Pref.agentAlertLimits.rawValue: true,
            Pref.agentAlertContext.rawValue: true,
        ])
    }

    static func bool(_ key: Pref) -> Bool { UserDefaults.standard.bool(forKey: key.rawValue) }
    static func double(_ key: Pref) -> Double { UserDefaults.standard.double(forKey: key.rawValue) }
    static func string(_ key: Pref) -> String { UserDefaults.standard.string(forKey: key.rawValue) ?? "" }
    static func set(_ value: Any?, _ key: Pref) { UserDefaults.standard.set(value, forKey: key.rawValue) }
}
