import AppKit
import IOKit.pwr_mgt
import SwiftUI

private struct Island {
    let panel: NotchPanel
    let placement: IslandPlacement
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let panelSize = CGSize(width: 760, height: 300)
    private static let lockPanelSize = CGSize(width: 360, height: 230)

    private let model = IslandModel()
    private let settings = SettingsWindowController()

    private let media = MediaRouter()
    private let volume = VolumeMonitor()
    private let battery = BatteryMonitor()
    private let mediaKeys = MediaKeyTap()
    private let waveform = SystemAudioTap()
    private let bluetooth = BluetoothMonitor()
    private let privacy = PrivacyMonitor()
    private let clipboard = ClipboardMonitor()
    private let downloads = DownloadsMonitor()
    private let calendar = CalendarService()
    private let weather = WeatherService()
    private let stats = StatsMonitor()
    private let fullscreen = FullscreenMonitor()
    private let agents = AgentConnector()
    private let plugins = PluginRunner()
    private let tasks = AgentTaskRunner()
    private let github = GitHubMonitor()
    private let ntfy = NtfyMonitor()
    private let homeAssistant = HomeAssistantMonitor()
    private let lyrics = LyricsService()
    private let lockSpace = LockScreenSpace()

    private var islands: [Island] = []
    private var lockPanel: NotchPanel!
    private var isLocked = false
    private var statusItem: NSStatusItem!
    private var mouseTimer: Timer?
    private var hoverWork: DispatchWorkItem?
    private var hoveredDisplay: CGDirectDisplayID?
    private var awakeAssertion: IOPMAssertionID = 0
    private var mediaKeysEnabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.register()
        AgentConnector.upgradeIfNeeded()
        CLI.installWrapper()
        setUpPanel()
        setUpStatusItem()
        wireServices()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(prefsChanged), name: UserDefaults.didChangeNotification, object: nil)
        let lockCenter = DistributedNotificationCenter.default()
        lockCenter.addObserver(self, selector: #selector(screenLocked),
                               name: .init("com.apple.screenIsLocked"), object: nil,
                               suspensionBehavior: .deliverImmediately)
        lockCenter.addObserver(self, selector: #selector(screenUnlocked),
                               name: .init("com.apple.screenIsUnlocked"), object: nil,
                               suspensionBehavior: .deliverImmediately)
        applyPrefs()
        if CommandLine.arguments.contains("--preview-lock-screen") { setLocked(true) }

        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { model.addToShelf(files) }
        urls.filter { $0.scheme == "nook" }.forEach {
            URLCommands.handle($0, model: model, agents: agents, tasks: tasks)
        }
    }

    func joinNextMeeting() -> Bool {
        guard let url = model.nextMeeting?.meetingURL else { return false }
        return NSWorkspace.shared.open(url)
    }

    func setFocus(_ name: String?, quiet: Bool) {
        model.quiet = quiet
        model.show(Banner(symbol: name == nil ? "moon" : "moon.fill", title: name ?? "Focus",
                          value: name == nil ? "Off" : "On", tint: .systemIndigo, showsTitle: true, urgent: true))
    }

    private func setUpPanel() {
        let lockHosting = IslandHostingView(rootView: LockScreenView(model: model))
        lockHosting.onSwipe = { [weak self] direction in self?.handleSwipe(direction) }
        lockHosting.sizingOptions = []
        lockPanel = NotchPanel()
        lockPanel.ignoresMouseEvents = false
        lockPanel.contentView = lockHosting
        layout()
    }

    private func makeIsland(on display: CGDirectDisplayID) -> Island {
        let placement = IslandPlacement(displayID: display)
        let hosting = IslandHostingView(rootView: IslandView(model: model, placement: placement))
        hosting.onSwipe = { [weak self] direction in self?.handleSwipe(direction) }
        hosting.sizingOptions = []
        let panel = NotchPanel()
        panel.contentView = hosting
        panel.sharingType = Pref.bool(.hideFromCapture) ? .none : .readOnly
        return Island(panel: panel, placement: placement)
    }

    private func targetScreen() -> NSScreen? {
        let choice = Pref.string(.display)
        switch choice {
        case "main":
            return NSScreen.screens.first
        case "auto", "":
            return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
        default:
            return NSScreen.screens.first { $0.localizedName == choice }
                ?? NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
        }
    }

    private func targetScreens() -> [NSScreen] {
        guard let primary = targetScreen() else { return [] }
        guard Pref.bool(.allDisplays) else { return [primary] }
        return [primary] + NSScreen.screens.filter { $0 != primary }
    }

    private func layout() {
        let screens = targetScreens()
        let ids = screens.map(Self.displayID)

        var kept: [Island] = []
        for id in ids {
            kept.append(islands.first { $0.placement.displayID == id } ?? makeIsland(on: id))
        }
        for island in islands where !ids.contains(island.placement.displayID) {
            lockSpace?.remove(island.panel)
            island.panel.orderOut(nil)
        }
        islands = kept

        for (island, screen) in zip(islands, screens) {
            let placement = island.placement
            var notch: CGSize
            if screen.safeAreaInsets.top > 0,
               let left = screen.auxiliaryTopLeftArea,
               let right = screen.auxiliaryTopRightArea {
                if !placement.hasNotch { placement.hasNotch = true }
                notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
            } else {
                if placement.hasNotch { placement.hasNotch = false }
                notch = CGSize(width: 180, height: NSStatusBar.system.thickness)
            }
            notch.width += Pref.double(.notchWidthOffset)
            notch.height += Pref.double(.notchHeightOffset)
            if placement.notchSize != notch { placement.notchSize = notch }
            placement.screenFrame = screen.frame

            let size = Self.panelSize
            let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                               width: size.width, height: size.height)
            if island.panel.frame != frame { island.panel.setFrame(frame, display: true) }
            if !island.panel.isVisible {
                island.panel.orderFrontRegardless()
                if isLocked, Pref.bool(.showOnLockScreen) { lockSpace?.add(island.panel) }
            }
        }

        if !ids.contains(model.activeDisplay), let first = ids.first { model.activeDisplay = first }
        if let active = islands.first(where: { $0.placement.displayID == model.activeDisplay }),
           model.notchSize != active.placement.notchSize {
            model.notchSize = active.placement.notchSize
        }

        guard let screen = screens.first else { return }
        let card = Self.lockPanelSize
        let top = min(0.6, max(0.1, Pref.double(.lockScreenTop)))
        lockPanel.setFrame(
            NSRect(x: screen.frame.midX - card.width / 2,
                   y: screen.frame.maxY - (screen.frame.height * top).rounded() - card.height,
                   width: card.width, height: card.height),
            display: true)
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    @objc private func screensChanged() {
        layout()
    }

    @objc private func prefsChanged() {
        applyPrefs()
    }

    private func applyPrefs() {
        let column = Pref.bool(.showCalendar) || Pref.bool(.showReminders)
        if model.showsCalendar != column { model.showsCalendar = column }
        if model.showsAgentChips != Pref.bool(.agentChips) { model.showsAgentChips = Pref.bool(.agentChips) }
        let tabs = Tab.allCases.filter { $0.pref.map(Pref.bool) ?? true }
        if model.enabledTabs != tabs { model.enabledTabs = tabs }
        layout()
        let sharing: NSWindow.SharingType = Pref.bool(.hideFromCapture) ? .none : .readOnly
        islands.forEach { $0.panel.sharingType = sharing }
        lockPanel.sharingType = sharing

        let replaceHUD = Pref.bool(.replaceSystemHUD)
        if replaceHUD != mediaKeysEnabled {
            mediaKeysEnabled = replaceHUD
            if replaceHUD {
                mediaKeys.start(prompt: !Pref.bool(.accessibilityPrompted))
                Pref.set(true, .accessibilityPrompted)
            } else {
                mediaKeys.stop()
            }
        }
        updateWaveform()
        bluetooth.setEnabled(Pref.bool(.bluetoothActivity))
        privacy.setEnabled(Pref.bool(.privacyIndicators))
        clipboard.setEnabled(Pref.bool(.clipboardHistory))
        downloads.setEnabled(Pref.bool(.downloadsActivity))
        calendar.setEnabled(Pref.bool(.showCalendar) || Pref.bool(.calendarAlerts) || Pref.bool(.showReminders))
        weather.setEnabled(Pref.bool(.showWeather))
        fullscreen.setEnabled(fullscreen: Pref.bool(.hideInFullscreen), games: Pref.bool(.hideWhileGaming))
        agents.setEnabled(Pref.bool(.agentClaude) || Pref.bool(.agentCodex))
        plugins.setEnabled(Pref.bool(.plugins))
        github.setEnabled(Pref.bool(.githubAlerts))
        ntfy.setEnabled(Pref.bool(.ntfy))
        homeAssistant.setEnabled(Pref.bool(.homeAssistant))
        lyrics.update(model.nowPlaying)
        updateKeepAwake()
    }

    @objc private func screenLocked() { setLocked(true) }
    @objc private func screenUnlocked() { setLocked(false) }

    private func setLocked(_ locked: Bool) {
        if Pref.bool(.lockSounds), locked != isLocked {
            playSystemSound(locked ? "Pop" : "Tink")
        }
        model.locked = locked
        if !locked, isLocked {
            model.unlocking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.model.unlocking = false }
        }
        guard let lockSpace else {
            isLocked = locked
            return
        }
        isLocked = locked
        updateKeepAwake()
        if locked {
            guard Pref.bool(.showOnLockScreen) else { return }
            lockPanel.alphaValue = 1
            lockPanel.orderFrontRegardless()
            lockSpace.add(lockPanel)
            islands.forEach { lockSpace.add($0.panel) }
        } else {
            lockPanel.alphaValue = 0
            lockSpace.remove(lockPanel)
            lockPanel.orderOut(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, !isLocked else { return }
                islands.forEach { lockSpace.remove($0.panel) }
            }
        }
    }

    private func updateKeepAwake() {
        let wanted = isLocked && Pref.bool(.lockKeepAwake) && model.nowPlaying?.isPlaying == true
        if wanted, awakeAssertion == 0 {
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Nook is showing now playing on the lock screen" as CFString, &awakeAssertion)
            if status != kIOReturnSuccess { awakeAssertion = 0 }
        } else if !wanted, awakeAssertion != 0 {
            IOPMAssertionRelease(awakeAssertion)
            awakeAssertion = 0
        }
    }

    private func trackMouse() {
        let mouse = NSEvent.mouseLocation
        let hovered = islands.first { island in
            let size = model.size(on: island.placement)
            let frame = island.placement.screenFrame
            return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                          width: size.width, height: size.height)
                .insetBy(dx: -8, dy: -8)
                .contains(mouse)
        }?.placement.displayID
        guard hovered != hoveredDisplay else { return }

        hoveredDisplay = hovered
        if let hovered, hovered != model.activeDisplay {
            model.activeDisplay = hovered
            if let placement = islands.first(where: { $0.placement.displayID == hovered })?.placement {
                model.notchSize = placement.notchSize
            }
        }
        model.hovering = hovered != nil
        for island in islands { island.panel.ignoresMouseEvents = island.placement.displayID != hovered }
        hoverWork?.cancel()
        if hovered != nil {
            if Pref.bool(.haptics) {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            if Pref.bool(.expandOnHover) {
                let work = DispatchWorkItem { [weak self] in self?.model.expanded = true }
                hoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Pref.double(.hoverDelay), execute: work)
            }
        } else {
            model.expanded = false
        }
    }

    private func handleSwipe(_ direction: SwipeDirection) {
        switch direction {
        case .left, .right:
            if Pref.bool(.swipeSeeks), let info = model.nowPlaying, info.duration > 0 {
                let elapsed = info.elapsed(at: Date())
                model.send(.seek(elapsed + (direction == .left ? 10 : -10)))
            } else {
                model.send(direction == .left ? .next : .previous)
            }
        case .down: model.expanded = true
        case .up: model.expanded = false
        }
    }

    private func wireServices() {
        model.onMediaCommand = { [weak self] command in self?.media.send(command) }
        model.onOpenSettings = { [weak self] in
            self?.model.expanded = false
            self?.settings.show()
        }
        model.onTimerFinished = { playSystemSound("Glass") }

        media.onUpdate = { [weak self] info in
            self?.model.nowPlaying = info
            self?.lyrics.update(info)
            self?.updateWaveform()
            self?.updateKeepAwake()
        }
        media.onArtwork = { [weak self] image in self?.model.artwork = image }
        media.start()

        waveform.onLevels = { [weak self] levels in self?.model.audioLevels = levels }

        volume.onChange = { [weak self] level, muted in
            self?.model.showHUD(.volume(level: level, muted: muted))
        }
        volume.start()
        mediaKeys.onHUD = { [weak self] hud in self?.model.showHUD(hud) }

        battery.onChange = { [weak self] info in self?.model.updateBattery(info) }
        battery.onLowPowerModeChange = { [weak self] enabled in
            guard Pref.bool(.batteryAlerts) else { return }
            self?.model.show(Banner(symbol: "leaf.fill", title: "Low Power Mode",
                                    value: enabled ? "On" : "Off", tint: .systemYellow))
        }
        battery.start()

        bluetooth.onBanner = { [weak self] banner in self?.model.show(banner) }
        privacy.onChange = { [weak self] camera, mic in
            guard let model = self?.model else { return }
            if model.cameraInUse != camera { model.cameraInUse = camera }
            if model.micInUse != mic { model.micInUse = mic }
        }
        clipboard.onCopy = { [weak self] text in
            guard let model = self?.model else { return }
            model.clipboard.removeAll { $0 == text }
            model.clipboard.insert(text, at: 0)
            if model.clipboard.count > 25 { model.clipboard.removeLast(model.clipboard.count - 25) }
        }
        downloads.onUpdate = { [weak self] info in self?.model.download = info }
        downloads.onFinished = { [weak self] name in
            self?.model.show(Banner(symbol: "arrow.down.circle.fill", title: name, value: "Done", tint: .systemGreen))
        }
        calendar.onEvents = { [weak self] events in self?.model.events = events }
        calendar.onReminders = { [weak self] reminders in
            if self?.model.reminders != reminders { self?.model.reminders = reminders }
        }
        model.onCompleteReminder = { [weak self] id in self?.calendar.complete(id) }
        calendar.onBanner = { [weak self] banner in self?.model.show(banner) }
        weather.onWeather = { [weak self] info in self?.model.weather = info }

        stats.isVisible = { [weak self] in
            MainActor.assumeIsolated { self?.model.expanded == true && self?.model.tab == .stats }
        }
        stats.onUpdate = { [weak self] snapshot in self?.model.stats = snapshot }
        stats.start()

        fullscreen.displayIDs = { [weak self] in
            MainActor.assumeIsolated { self?.islands.map(\.placement.displayID) ?? [] }
        }
        fullscreen.onChange = { [weak self] displays in self?.model.hiddenDisplays = displays }

        agents.onBanner = { [weak self] banner in self?.model.show(banner) }
        agents.onAttention = { [weak self] activity in
            guard let model = self?.model else { return }
            if activity != nil || AgentUsage.Agent(rawValue: model.custom?.id ?? "") != nil { model.custom = activity }
        }
        agents.onUsage = { [weak self] usage in
            if self?.model.agents != usage { self?.model.agents = usage }
        }
        tasks.onChange = { [weak self] tasks in
            guard let model = self?.model else { return }
            let running = tasks.filter { $0.status == .running }.count
            if running > model.runningTasks.count, !model.expanded { model.tab = .agents }
            model.tasks = tasks
        }
        tasks.onBanner = { [weak self] banner in self?.model.show(banner) }
        agents.isHandedOff = { [weak self] session, cwd in self?.tasks.isHandedOff(session: session, cwd: cwd) ?? false }
        model.onTask = { [weak self] id, action in self?.tasks.perform(action, on: id) }
        tasks.resume()
        plugins.onUpdate = { [weak self] items in self?.model.widgets = items }
        github.onBanner = { [weak self] banner in self?.model.show(banner) }
        ntfy.onBanner = { [weak self] banner in self?.model.show(banner) }
        homeAssistant.onBanner = { [weak self] banner in self?.model.show(banner) }
        homeAssistant.onUpdate = { [weak self] items in
            if self?.model.homeWidgets != items { self?.model.homeWidgets = items }
        }
        model.onHomeToggle = { [weak self] entity in self?.homeAssistant.toggle(entity) }
        lyrics.onLyrics = { [weak self] lines in self?.model.lyrics = lines }
        plugins.onAlert = { [weak self] banner in self?.model.show(banner) }
    }

    private func updateWaveform() {
        waveform.setActive(model.nowPlaying?.isPlaying == true && Pref.bool(.liveWaveform))
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Nook")

        let menu = NSMenu()
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        menu.addItem(NSMenuItem(title: "Nook \(version) (\(build))", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Nook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        settings.show()
    }
}
