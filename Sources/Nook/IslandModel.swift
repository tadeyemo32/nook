import AppKit
import Observation

enum IslandMode: Equatable { case idle, compact, hud, expanded }

enum HUD: Equatable {
    case volume(level: Float, muted: Bool)
    case brightness(level: Float)
}

enum MediaCommand: Equatable {
    case playPause, next, previous, toggleShuffle, toggleRepeat
    case seek(Double)
}

struct BatteryInfo: Equatable {
    var level: Double
    var isCharging: Bool
    var isPluggedIn: Bool
    var minutesRemaining: Int?
}

struct Banner: Equatable {
    var symbol: String
    var title: String
    var value: String? = nil
    var tint: NSColor = .white
    var duration: TimeInterval = 3
    var showsTitle = false
    var agent: AgentUsage.Agent? = nil
    /// Still shows while a Focus has asked Nook to stay quiet.
    var urgent = false

    var displaysTitle: Bool { showsTitle || value == nil }
}

struct CustomActivity: Equatable {
    var id: String
    var symbol: String
    var title: String
    var progress: Double?
    var tint: NSColor = .white
    var badge: String? = nil
    var agent: AgentUsage.Agent? = nil
}

struct DownloadInfo: Equatable {
    var name: String
    var progress: Double?
}

struct TimerState: Equatable {
    var total: TimeInterval
    var endDate: Date?
    var pausedRemaining: TimeInterval?

    func remaining(at date: Date) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        return max(0, endDate?.timeIntervalSince(date) ?? 0)
    }
}

struct CalendarItem: Equatable, Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var color: NSColor
    var meetingURL: URL? = nil
}

struct ReminderItem: Equatable, Identifiable {
    var id: String
    var title: String
    var due: Date?
    var color: NSColor
}

struct LyricLine: Equatable {
    var time: Double
    var text: String
}

struct WeatherInfo: Equatable {
    var temperature: Double
    var high: Double
    var low: Double
    var symbol: String
    var unit: String
}

struct SystemStats: Equatable {
    var cpu: Double
    var gpu: Double?
    var memoryUsed: Double
    var memoryTotal: Double
    var networkIn: Double
    var networkOut: Double
    var diskFree: Double
    var diskTotal: Double
}

enum Tab: String, CaseIterable, Identifiable {
    case home, shelf, widgets, clipboard, stats, agents, timer, mirror
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .shelf: return "tray.fill"
        case .widgets: return "square.grid.2x2.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .stats: return "gauge.with.dots.needle.67percent"
        case .agents: return "chevron.left.forwardslash.chevron.right"
        case .timer: return "timer"
        case .mirror: return "person.crop.square.fill"
        }
    }

    var pref: Pref? {
        switch self {
        case .home: return nil
        case .shelf: return .tabShelf
        case .widgets: return .tabWidgets
        case .clipboard: return .tabClipboard
        case .stats: return .tabStats
        case .agents: return .tabAgents
        case .timer: return .tabTimer
        case .mirror: return .tabMirror
        }
    }
}

enum Activity: Equatable { case banner, lock, custom, task, timer, download, nowPlaying, privacy }

@Observable
final class IslandPlacement {
    let displayID: CGDirectDisplayID
    var notchSize = CGSize(width: 185, height: 32)
    var hasNotch = true
    @ObservationIgnored var screenFrame: NSRect = .zero

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }
}

@Observable
final class IslandModel {
    var hiddenDisplays: Set<CGDirectDisplayID> = []
    var activeDisplay: CGDirectDisplayID = 0
    var notchSize = CGSize(width: 185, height: 32)

    var hovering = false
    var expanded = false
    var locked = false
    var unlocking = false
    var tab: Tab = .home
    var hud: HUD?

    var nowPlaying: NowPlaying?
    var artwork: NSImage? {
        didSet { artworkColor = artwork.flatMap(Self.averageColor) }
    }
    private(set) var artworkColor: NSColor?
    var audioLevels: [Float]?

    var battery: BatteryInfo?
    var banner: Banner?
    var custom: CustomActivity?
    var timer: TimerState?
    var download: DownloadInfo?
    var cameraInUse = false
    var micInUse = false

    var events: [CalendarItem] = []
    var weather: WeatherInfo?
    var shelf: [URL] = (UserDefaults.standard.stringArray(forKey: Pref.shelfItems.rawValue) ?? [])
        .map(URL.init(fileURLWithPath:))
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    var clipboard: [String] = []
    var stats: SystemStats?
    var agents: [AgentUsage] = []
    var tasks: [AgentTask] = []
    var widgets: [PluginItem] = []
    var homeWidgets: [PluginItem] = []
    var reminders: [ReminderItem] = []
    var lyrics: [LyricLine]?
    /// Set by Nook's Focus filter: only urgent banners show.
    var quiet = false

    var runningTasks: [AgentTask] { tasks.filter { $0.status == .running } }

    /// The meeting to join: one with a call link that's on now or starts within 10 minutes.
    var nextMeeting: CalendarItem? {
        let now = Date()
        return events.first { $0.meetingURL != nil && !$0.isAllDay && $0.end > now && $0.start.timeIntervalSince(now) < 600 }
    }

    private(set) var expandOnHover = UserDefaults.standard.bool(forKey: Pref.expandOnHover.rawValue)

    @ObservationIgnored var onMediaCommand: ((MediaCommand) -> Void)?
    @ObservationIgnored var onTimerFinished: (() -> Void)?
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    @ObservationIgnored var onTask: ((String, TaskAction) -> Void)?
    @ObservationIgnored var onCompleteReminder: ((String) -> Void)?
    @ObservationIgnored var onHomeToggle: ((String) -> Void)?
    @ObservationIgnored private var hudWork: DispatchWorkItem?
    @ObservationIgnored private var bannerWork: DispatchWorkItem?
    @ObservationIgnored private var timerWork: DispatchWorkItem?

    var activity: Activity? {
        if banner != nil { return .banner }
        if locked || unlocking { return .lock }
        if custom != nil { return .custom }
        if !runningTasks.isEmpty { return .task }
        if timer != nil { return .timer }
        if download != nil { return .download }
        if nowPlaying?.isPlaying == true { return .nowPlaying }
        if cameraInUse || micInUse { return .privacy }
        return nil
    }

    var mode: IslandMode { mode(on: activeDisplay) }

    func mode(on display: CGDirectDisplayID) -> IslandMode {
        if expanded, display == activeDisplay { return .expanded }
        if hud != nil { return .hud }
        if activity != nil { return .compact }
        return .idle
    }

    var showsCalendar = false
    var enabledTabs: [Tab] = [.home]
    var visibleTabs: [Tab] { enabledTabs.filter { $0 != .agents || !agents.isEmpty || !tasks.isEmpty } }

    var taskTitle: String {
        let running = runningTasks
        return running.count == 1 ? running[0].project : "\(running.count) tasks"
    }
    var showsAgentChips = true

    func size(on placement: IslandPlacement) -> CGSize {
        let active = placement.displayID == activeDisplay
        return size(for: mode(on: placement.displayID), notch: placement.notchSize,
                    lifted: active && hovering && !expanded)
    }

    func size(for mode: IslandMode, notch n: CGSize, lifted: Bool = false) -> CGSize {
        let lift: CGSize = lifted ? CGSize(width: 12, height: 2) : .zero
        switch mode {
        case .idle: return CGSize(width: n.width + lift.width, height: n.height + lift.height)
        case .compact: return CGSize(width: n.width + 2 * compactSideWidth + lift.width, height: n.height + lift.height)
        case .hud: return CGSize(width: n.width + 2 * 66, height: n.height)
        case .expanded:
            let calendar: CGFloat = tab == .home && showsCalendar ? 196 : 0
            let left = visibleTabs.count > 1 ? 28 * CGFloat(visibleTabs.count) : 0
            let right = (showsAgentChips ? 60 * CGFloat(agents.count) : 0) + (weather != nil ? 52 : 0)
            let header = n.width + 2 * (18 + max(left, right))
            return CGSize(width: max(n.width + 270 + calendar, 448 + calendar, header), height: n.height + 162)
        }
    }

    var compactSideWidth: CGFloat {
        switch activity {
        case .banner:
            guard let banner else { return 40 }
            let leading = 34 + (banner.displaysTitle ? 6 + Self.textWidth(banner.title) : 0)
            let trailing = 14 + Self.textWidth(banner.value ?? "")
            return min(190, max(44, max(leading, trailing)))
        case .lock: return 36
        case .custom:
            guard let custom else { return 40 }
            return min(190, max(60, 42 + Self.textWidth(custom.title)))
        case .task: return min(190, max(60, 42 + Self.textWidth(taskTitle)))
        case .timer: return 62
        case .download: return 54
        case .nowPlaying: return 40
        case .privacy: return 36
        case nil: return 0
        }
    }

    func setExpandOnHover(_ value: Bool) {
        expandOnHover = value
        Pref.set(value, .expandOnHover)
    }

    func send(_ command: MediaCommand) {
        onMediaCommand?(command)
    }

    func showHUD(_ newHUD: HUD) {
        hud = newHUD
        hudWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hud = nil }
        hudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    func show(_ newBanner: Banner) {
        guard !quiet || newBanner.urgent else { return }
        banner = newBanner
        bannerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.banner = nil }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + newBanner.duration, execute: work)
    }

    func updateBattery(_ info: BatteryInfo?) {
        let previous = battery
        battery = info
        guard let info else { return }
        let percent = "\(Int((info.level * 100).rounded()))%"

        if info.isPluggedIn, !(previous?.isPluggedIn ?? true) {
            show(Banner(symbol: "bolt.fill", title: "Charging", value: percent, tint: .systemGreen))
        } else if Pref.bool(.batteryAlerts), !info.isPluggedIn, let previous {
            for threshold in [0.2, 0.1] where info.level <= threshold && previous.level > threshold {
                show(Banner(symbol: threshold > 0.1 ? "battery.25" : "battery.0",
                            title: "Low Battery", value: percent, tint: .systemRed, duration: 5, urgent: true))
            }
        }
    }

    func addToShelf(_ urls: [URL]) {
        let new = urls.filter { !shelf.contains($0) }
        guard !new.isEmpty else { return }
        shelf.append(contentsOf: new)
        saveShelf()
        show(Banner(symbol: "tray.and.arrow.down.fill", title: "Added to Shelf",
                    value: new.count > 1 ? "\(new.count) files" : "Added", tint: .systemBlue, duration: 1.5))
    }

    func removeFromShelf(_ url: URL) {
        shelf.removeAll { $0 == url }
        saveShelf()
    }

    func clearShelf() {
        shelf.removeAll()
        saveShelf()
    }

    private func saveShelf() {
        Pref.set(shelf.map(\.path), .shelfItems)
    }

    func startTimer(_ seconds: TimeInterval) {
        timer = TimerState(total: seconds, endDate: Date().addingTimeInterval(seconds))
        scheduleTimer(seconds)
    }

    func toggleTimerPause() {
        guard var state = timer else { return }
        if let paused = state.pausedRemaining {
            state.pausedRemaining = nil
            state.endDate = Date().addingTimeInterval(paused)
            scheduleTimer(paused)
        } else {
            state.pausedRemaining = state.remaining(at: Date())
            state.endDate = nil
            timerWork?.cancel()
        }
        timer = state
    }

    func cancelTimer() {
        timerWork?.cancel()
        timer = nil
    }

    private func scheduleTimer(_ seconds: TimeInterval) {
        timerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.timer = nil
            self?.show(Banner(symbol: "timer", title: "Timer", value: "Done", tint: .systemOrange, duration: 6, urgent: true))
            self?.onTimerFinished?()
        }
        timerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width)
    }

    private static func averageColor(of image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        var buckets = [(weight: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat)](repeating: (0, 0, 0, 0), count: 12)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let color = NSColor(red: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                                blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
            let s = color.saturationComponent, v = color.brightnessComponent
            guard s > 0.25, v > 0.2 else { continue }
            let bucket = min(11, Int(color.hueComponent * 12))
            let weight = s * v
            buckets[bucket].weight += weight
            buckets[bucket].r += color.redComponent * weight
            buckets[bucket].g += color.greenComponent * weight
            buckets[bucket].b += color.blueComponent * weight
        }
        guard let best = buckets.max(by: { $0.weight < $1.weight }), best.weight > 2 else { return .white }
        let color = NSColor(red: best.r / best.weight, green: best.g / best.weight, blue: best.b / best.weight, alpha: 1)
        return NSColor(hue: color.hueComponent, saturation: min(1, color.saturationComponent * 1.1),
                       brightness: max(0.8, color.brightnessComponent), alpha: 1)
    }
}
