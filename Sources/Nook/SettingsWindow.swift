import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Nook Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 640, height: 520))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", media = "Media", hud = "HUD", activities = "Live Activities"
    case island = "Island", agents = "Coding Agents", connectors = "Connectors", display = "Display"
    case lockScreen = "Lock Screen"
    case about = "About"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .media: return "play.fill"
        case .hud: return "speaker.wave.2.fill"
        case .activities: return "bolt.fill"
        case .island: return "capsule.fill"
        case .agents: return "chevron.left.forwardslash.chevron.right"
        case .connectors: return "puzzlepiece.extension.fill"
        case .display: return "display"
        case .lockScreen: return "lock.fill"
        case .about: return "info"
        }
    }

    var color: Color {
        switch self {
        case .general, .about: return .gray
        case .media: return .pink
        case .hud: return .blue
        case .activities: return .orange
        case .island: return Color(white: 0.15)
        case .agents: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .connectors: return .purple
        case .display: return .cyan
        case .lockScreen: return .indigo
        }
    }
}

private struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.gradient))
    }
}

struct SettingsView: View {
    @State private var page: SettingsPage = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { page in
                Label { Text(page.rawValue) } icon: { SettingsIcon(symbol: page.symbol, color: page.color) }
                    .tag(page)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            Form {
                switch page {
                case .general: GeneralSettings()
                case .media: MediaSettings()
                case .hud: HUDSettings()
                case .activities: ActivitySettings()
                case .island: IslandSettings()
                case .agents: AgentSettings()
                case .connectors: ConnectorsSettings()
                case .display: DisplaySettings()
                case .lockScreen: LockScreenSettings()
                case .about: AboutSettings()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(page.rawValue)
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage(Pref.expandOnHover.rawValue) private var expandOnHover = false
    @AppStorage(Pref.hoverDelay.rawValue) private var hoverDelay = 0.0
    @AppStorage(Pref.haptics.rawValue) private var haptics = true
    @AppStorage(Pref.swipeSeeks.rawValue) private var swipeSeeks = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Section {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
        }
        Section("Opening") {
            Toggle("Open the island on hover", isOn: $expandOnHover)
            LabeledContent("Hover delay") {
                Slider(value: $hoverDelay, in: 0...1, step: 0.1) { Text("Hover delay") }
                    .labelsHidden()
                Text(hoverDelay == 0 ? "None" : String(format: "%.1f s", hoverDelay)).monospacedDigit().frame(width: 44)
            }
            .disabled(!expandOnHover)
            Toggle("Haptic feedback on hover", isOn: $haptics)
        }
        Section {
            Picker("Swipe left / right", selection: $swipeSeeks) {
                Text("Next / previous track").tag(false)
                Text("Skip ±10 seconds").tag(true)
            }
        } header: {
            Text("Gestures")
        } footer: {
            Text("Two-finger swipes on the island. Swipe down opens it, swipe up closes it. Drop files on it to add them to the shelf.")
        }
    }
}

private struct MediaSettings: View {
    @AppStorage(Pref.liveWaveform.rawValue) private var liveWaveform = false
    @AppStorage(Pref.artworkTint.rawValue) private var artworkTint = true
    @AppStorage(Pref.dimArtworkOnPause.rawValue) private var dimOnPause = true

    var body: some View {
        Section {
            Toggle("Tint controls with the album colour", isOn: $artworkTint)
            Toggle("Dim the artwork when paused", isOn: $dimOnPause)
        }
        Section {
            Toggle("Live waveform", isOn: $liveWaveform)
        } footer: {
            Text("Moves the bars in time with the music by listening to the Mac's audio output. While it runs, macOS shows a purple recording dot in the menu bar. Nothing is recorded or stored.")
        }
    }
}

private struct HUDSettings: View {
    @AppStorage(Pref.replaceSystemHUD.rawValue) private var replace = true
    @AppStorage(Pref.hudShowsPercent.rawValue) private var percent = false

    var body: some View {
        Section {
            Toggle("Replace the system volume and brightness HUD", isOn: $replace)
            Toggle("Show a percentage instead of a bar", isOn: $percent)
        }
        Section {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                LabeledContent("Accessibility") {
                    if AXIsProcessTrusted() {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…", action: Self.requestAccess)
                    }
                }
            }
            Button("Reset Permission…", action: Self.resetAccess)
        } footer: {
            Text("Nook needs Accessibility to take over the volume and brightness keys. If it's switched on in System Settings but shows as not allowed here, the entry belongs to an older build: Reset Permission removes it and asks again.")
        }
    }

    private static func requestAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private static func resetAccess() {
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "dev.nook.app"]
        try? reset.run()
        reset.waitUntilExit()
        requestAccess()
    }
}

private struct ActivitySettings: View {
    @AppStorage(Pref.batteryAlerts.rawValue) private var battery = true
    @AppStorage(Pref.bluetoothActivity.rawValue) private var bluetooth = true
    @AppStorage(Pref.privacyIndicators.rawValue) private var privacy = true
    @AppStorage(Pref.downloadsActivity.rawValue) private var downloads = false
    @AppStorage(Pref.calendarAlerts.rawValue) private var calendarAlerts = false

    var body: some View {
        Section {
            Toggle("Charging, low battery and Low Power Mode", isOn: $battery)
            Toggle("AirPods and Bluetooth devices", isOn: $bluetooth)
            Toggle("Camera and microphone in use", isOn: $privacy)
            Toggle("Browser downloads", isOn: $downloads)
            Toggle("Upcoming calendar events", isOn: $calendarAlerts)
        } footer: {
            Text("Downloads asks for access to your Downloads folder. Calendar alerts need the calendar turned on under Island.")
        }
    }
}

private struct AgentSettings: View {
    @AppStorage(Pref.agentClaude.rawValue) private var claude = true
    @AppStorage(Pref.agentCodex.rawValue) private var codex = true
    @AppStorage(Pref.agentChips.rawValue) private var chips = true
    @AppStorage(Pref.agentChipStyle.rawValue) private var chipStyle = "used"
    @AppStorage(Pref.agentShowWhen.rawValue) private var showWhen = "active"
    @AppStorage(Pref.tabAgents.rawValue) private var agentsPage = true
    @AppStorage(Pref.agentShowModel.rawValue) private var showModel = true
    @AppStorage(Pref.agentShowPlan.rawValue) private var showPlan = true
    @AppStorage(Pref.agentShowResets.rawValue) private var showResets = true
    @AppStorage(Pref.agentShowContext.rawValue) private var showContext = true
    @AppStorage(Pref.agentShowCost.rawValue) private var showCost = false
    @AppStorage(Pref.agentShowLines.rawValue) private var showLines = false
    @AppStorage(Pref.agentAlertPermission.rawValue) private var permission = true
    @AppStorage(Pref.claudeDoneAlerts.rawValue) private var done = true
    @AppStorage(Pref.agentAlertWaiting.rawValue) private var waiting = true
    @AppStorage(Pref.agentAlertSubagent.rawValue) private var subagent = true
    @AppStorage(Pref.agentAlertCompact.rawValue) private var compact = false
    @AppStorage(Pref.agentAlertSession.rawValue) private var session = false
    @AppStorage(Pref.agentAlertOther.rawValue) private var other = true
    @AppStorage(Pref.agentAlertLimits.rawValue) private var limits = true
    @AppStorage(Pref.agentAlertContext.rawValue) private var context = true
    @State private var claudeConnected = AgentConnector.isConnected
    @State private var codexConnected = AgentConnector.isCodexConnected
    @State private var error: String?

    var body: some View {
        Section {
            agentRow(.claude, title: "Claude Code", connected: claudeConnected,
                     detail: "Alerts, plus usage limits and session details from its status line")
            Toggle("Show Claude's usage", isOn: $claude)
            if claudeConnected, AgentConnector.hasOwnStatusLine {
                Text("You have your own Claude Code status line, so Nook left it alone and can't show Claude's usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            agentRow(.codex, title: "Codex", connected: codexConnected,
                     detail: "Alerts. Usage is read from Codex's own logs, no connection needed")
            Toggle("Show Codex's usage", isOn: $codex)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Agents")
        } footer: {
            Text("Connecting adds hooks to ~/.claude/settings.json (and a status line) or ~/.codex/hooks.json, keeping a backup next to it. New sessions pick them up; Codex asks you to trust the hooks once. Only the alert type, message and project folder reach Nook, never your prompts. Codex logs are compressed once a session ends; reading those needs zstd (brew install zstd).")
        }

        Section {
            Picker("Show an agent", selection: $showWhen) {
                Text("While its CLI is open").tag("active")
                Text("Whenever its limits are known").tag("always")
            }
            Toggle("Usage beside the notch", isOn: $chips)
            Picker("Show usage as", selection: $chipStyle) {
                Text("Percent used").tag("used")
                Text("Percent left").tag("left")
                Text("Battery").tag("battery")
            }
            .disabled(!chips)
            Toggle("Agents page", isOn: $agentsPage)
        } header: {
            Text("In the island")
        } footer: {
            Text("An agent appears as soon as it starts and goes the moment you quit it. Each one gets its own logo and number, side by side, for its 5-hour limit; click it for the Agents page.")
        }

        Section("On the Agents page") {
            Toggle("Model and effort", isOn: $showModel)
            Toggle("Plan", isOn: $showPlan)
            Toggle("When each limit resets", isOn: $showResets)
            Toggle("Context window used", isOn: $showContext)
            Toggle("Session cost (Claude)", isOn: $showCost)
            Toggle("Lines added and removed (Claude)", isOn: $showLines)
        }

        Section {
            Toggle("Needs permission or has a question", isOn: $permission)
            Toggle("Finished a reply", isOn: $done)
            Toggle("Waiting for you", isOn: $waiting)
            Toggle("Subagent finished", isOn: $subagent)
            Toggle("Compacting context (Claude)", isOn: $compact)
            Toggle("Session started and ended", isOn: $session)
            Toggle("Other messages", isOn: $other)
            Toggle("Nearing a usage limit (80, 90 and 95%)", isOn: $limits)
            Toggle("Filling the context window (80 and 90%)", isOn: $context)
        } header: {
            Text("Alerts")
        } footer: {
            Text("Codex reports sessions starting, new prompts and finished replies; the rest come from Claude Code.")
        }
    }

    private func agentRow(_ agent: AgentUsage.Agent, title: String, connected: Bool, detail: String) -> some View {
        LabeledContent {
            Button(connected ? "Disconnect" : "Connect") { toggle(agent) }
        } label: {
            HStack(spacing: 10) {
                AgentLogo(agent: agent, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(connected ? "Connected" : detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func toggle(_ agent: AgentUsage.Agent) {
        do {
            switch agent {
            case .claude: try claudeConnected ? AgentConnector.disconnect() : AgentConnector.connect()
            case .codex: try codexConnected ? AgentConnector.disconnectCodex() : AgentConnector.connectCodex()
            }
            error = nil
        } catch {
            let file = agent == .claude ? "~/.claude/settings.json" : "~/.codex/hooks.json"
            self.error = "Couldn't update \(file): \(error.localizedDescription)"
        }
        claudeConnected = AgentConnector.isConnected
        codexConnected = AgentConnector.isCodexConnected
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "connectorsChanged")
    }
}

private struct ConnectorsSettings: View {
    @AppStorage(Pref.plugins.rawValue) private var pluginsOn = false
    @AppStorage(Pref.tabWidgets.rawValue) private var widgetsPage = false
    @State private var scripts = PluginRunner.scripts()

    var body: some View {
        Section {
            Toggle("Run plugin scripts", isOn: $pluginsOn)
            Toggle("Show the Widgets page", isOn: $widgetsPage)
            LabeledContent("Installed") {
                Text(scripts.isEmpty ? "None" : scripts.map(\.lastPathComponent).joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Button("Open Plugins Folder") { NSWorkspace.shared.open(PluginRunner.folder) }
                Button("Add Example") { addExample() }
            }
        } header: {
            Text("Plugins")
        } footer: {
            Text("A plugin is any executable script in the Plugins folder. It runs on the interval in its name (disk.5m.sh) and prints lines like title=…, value=…, symbol=…, progress=0.4 and alert=…. Widgets show on the Widgets page; alerts show in the notch.")
        }

        Section {
            Text(verbatim: "open -g \"nook://show?title=Build%20passed&symbol=checkmark.circle.fill&tint=green\"")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        } header: {
            Text("From any app or script")
        } footer: {
            Text("Also nook://progress?id=build&title=Building&progress=0.4 (and done=1), nook://timer?minutes=5, nook://open?tab=shelf. Add files to the shelf with open -a Nook file.pdf.")
        }
    }

    private func addExample() {
        let script = """
        #!/bin/sh
        # Example Nook plugin. Runs every 5 minutes (from its name) and prints key=value lines.
        # The data volume: on APFS, / is the small read-only system volume.
        used=$(df -k /System/Volumes/Data 2>/dev/null || df -k /)
        used=$(printf '%s\\n' "$used" | awk 'NR==2 { gsub("%", "", $5); print $5 }')
        echo "title=Disk"
        echo "value=$used% used"
        echo "symbol=internaldrive.fill"
        echo "progress=$(awk -v u="$used" 'BEGIN { printf "%.2f", u / 100 }')"
        if [ "$used" -ge 90 ]; then echo "tint=red"; echo "alert=Your disk is almost full"; fi

        """
        let url = PluginRunner.folder.appendingPathComponent("disk.5m.sh")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        scripts = PluginRunner.scripts()
        pluginsOn = true
        widgetsPage = true
    }
}

private struct IslandSettings: View {
    @AppStorage(Pref.showCalendar.rawValue) private var calendar = false
    @AppStorage(Pref.showWeather.rawValue) private var weather = false
    @AppStorage(Pref.tabShelf.rawValue) private var shelf = true
    @AppStorage(Pref.tabWidgets.rawValue) private var widgets = false
    @AppStorage(Pref.tabClipboard.rawValue) private var clipboard = false
    @AppStorage(Pref.clipboardHistory.rawValue) private var clipboardHistory = false
    @AppStorage(Pref.tabStats.rawValue) private var stats = false
    @AppStorage(Pref.tabAgents.rawValue) private var agents = true
    @AppStorage(Pref.tabTimer.rawValue) private var timer = false
    @AppStorage(Pref.tabMirror.rawValue) private var mirror = false

    var body: some View {
        Section {
            Toggle("Calendar next to now playing", isOn: $calendar)
            Toggle("Weather", isOn: $weather)
        } header: {
            Text("Home")
        } footer: {
            Text("macOS asks for calendar or location access when you turn these on. Weather comes from Open-Meteo.")
        }
        Section("Tabs") {
            Toggle("Shelf (drop files, AirDrop)", isOn: $shelf)
            Toggle("Widgets (plugins)", isOn: $widgets)
            Toggle("Clipboard history", isOn: $clipboard)
            Toggle("System stats", isOn: $stats)
            Toggle("Coding agents", isOn: $agents)
            Toggle("Timer", isOn: $timer)
            Toggle("Mirror (camera)", isOn: $mirror)
        }
        Section {
            Toggle("Keep clipboard history", isOn: $clipboardHistory)
        } footer: {
            Text("The last 25 text items, in memory only. Items password managers mark as secret are skipped.")
        }
    }
}

private struct DisplaySettings: View {
    @AppStorage(Pref.display.rawValue) private var display = "auto"
    @AppStorage(Pref.allDisplays.rawValue) private var allDisplays = false
    @AppStorage(Pref.simulatedNotch.rawValue) private var simulatedNotch = false
    @AppStorage(Pref.hideWhileGaming.rawValue) private var hideWhileGaming = false
    @AppStorage(Pref.notchWidthOffset.rawValue) private var widthOffset = 0.0
    @AppStorage(Pref.notchHeightOffset.rawValue) private var heightOffset = 0.0
    @AppStorage(Pref.outline.rawValue) private var outline = "none"
    @AppStorage(Pref.hideInFullscreen.rawValue) private var hideInFullscreen = false
    @AppStorage(Pref.hideFromCapture.rawValue) private var hideFromCapture = false

    var body: some View {
        Section {
            Picker("Show on", selection: $display) {
                Text("Built-in display (or main)").tag("auto")
                Text("Main display").tag("main")
                ForEach(NSScreen.screens, id: \.localizedName) { screen in
                    Text(screen.localizedName).tag(screen.localizedName)
                }
            }
            Toggle("Show on every display", isOn: $allDisplays)
            Toggle("Show the island when idle on displays without a notch", isOn: $simulatedNotch)
            Toggle("Hide when an app is fullscreen", isOn: $hideInFullscreen)
            Toggle("Hide while playing a game", isOn: $hideWhileGaming)
            Toggle("Hide from screenshots and screen recordings", isOn: $hideFromCapture)
        } footer: {
            Text("With every display on, each one gets its own island showing the same things; the one under the cursor opens. The lock-screen card stays on the display chosen above.")
        }
        Section("Shape") {
            LabeledContent("Width") {
                Slider(value: $widthOffset, in: -40...40, step: 1) { Text("Width") }.labelsHidden()
                Text("\(Int(widthOffset)) pt").monospacedDigit().frame(width: 44)
            }
            LabeledContent("Height") {
                Slider(value: $heightOffset, in: -8...8, step: 1) { Text("Height") }.labelsHidden()
                Text("\(Int(heightOffset)) pt").monospacedDigit().frame(width: 44)
            }
            Picker("Outline", selection: $outline) {
                Text("None").tag("none")
                Text("Contrast").tag("contrast")
                Text("Album colour").tag("color")
            }
            Button("Reset Size") {
                widthOffset = 0
                heightOffset = 0
            }
        }
    }
}

private struct LockScreenSettings: View {
    @AppStorage(Pref.showOnLockScreen.rawValue) private var show = true
    @AppStorage(Pref.lockScreenWidgets.rawValue) private var widgets = true
    @AppStorage(Pref.lockSounds.rawValue) private var sounds = false
    @AppStorage(Pref.lockScreenTop.rawValue) private var top = 0.28
    @AppStorage(Pref.lockHideWhenPaused.rawValue) private var hideWhenPaused = false
    @AppStorage(Pref.lockKeepAwake.rawValue) private var keepAwake = false

    var body: some View {
        Section {
            Toggle("Show the island and now playing on the lock screen", isOn: $show)
            Toggle("Battery, weather and timer widgets", isOn: $widgets).disabled(!show)
            Toggle("Hide now playing while paused", isOn: $hideWhenPaused).disabled(!show)
            Toggle("Keep the display on while music plays", isOn: $keepAwake).disabled(!show)
            Toggle("Play a sound on lock and unlock", isOn: $sounds)
        }
        Section {
            LabeledContent("From the top") {
                Slider(value: $top, in: 0.1...0.6, step: 0.01) { Text("From the top") }.labelsHidden()
                Text("\(Int((top * 100).rounded()))%").monospacedDigit().frame(width: 44)
            }
            Button("Reset Position") { top = 0.28 }
        } header: {
            Text("Position")
        } footer: {
            Text("How far down the screen the widgets and now-playing card start: by default just under the clock. Move it if it touches the clock or the password field on your display.")
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        let info = Bundle.main.infoDictionary
        Section {
            LabeledContent("Version", value: "\(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "0"))")
            LabeledContent("Add files from Terminal") {
                Text(verbatim: "open -a Nook file.pdf").font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
        }
    }
}
