import AppKit

enum MediaSource: String {
    case spotify = "Spotify"
    case music = "Music"
    case system = "System"

    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music: return "com.apple.Music"
        case .system: return ""
        }
    }
}

enum RepeatMode: Equatable { case off, one, all }

struct NowPlaying: Equatable {
    var source: MediaSource
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var position: Double
    var duration: Double
    var fetchedAt: Date
    var artworkURL: URL?
    var shuffle: Bool? = nil
    var repeatMode: RepeatMode? = nil
    var appBundleID: String? = nil

    var trackKey: String { "\(source.rawValue)|\(title)|\(artist)|\(album)" }

    func elapsed(at date: Date) -> Double {
        guard isPlaying else { return position }
        return min(duration, position + date.timeIntervalSince(fetchedAt))
    }
}

final class MediaController {
    var onUpdate: ((NowPlaying?) -> Void)?
    var onArtwork: ((NSImage?) -> Void)?
    var isSuspended = false

    private let queue = DispatchQueue(label: "nook.media")
    private var compiled: [String: NSAppleScript] = [:]
    private var timer: Timer?
    private var current: NowPlaying?
    private var lastTrackKey = ""

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func poll() {
        guard !isSuspended else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let sources = [MediaSource.spotify, .music].filter { running.contains($0.bundleID) }

        queue.async { [weak self] in
            guard let self else { return }
            let candidates = sources.compactMap { self.query($0) }
            let pick = candidates.first(where: \.isPlaying) ?? candidates.first
            DispatchQueue.main.async { self.apply(pick) }
        }
    }

    func send(_ command: MediaCommand) {
        guard let source = current?.source else { return }
        let verb: String
        switch command {
        case .playPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        case let .seek(seconds): verb = "set player position to \(max(0, seconds))"
        case .toggleShuffle:
            verb = source == .music ? "set shuffle enabled to not shuffle enabled" : "set shuffling to not shuffling"
        case .toggleRepeat where source == .music:
            verb = """
            if song repeat is off then
                set song repeat to all
            else if song repeat is all then
                set song repeat to one
            else
                set song repeat to off
            end if
            """
        case .toggleRepeat:
            verb = "set repeating to not repeating"
        }
        let script = "tell application \"\(source.rawValue)\"\n\(verb)\nend tell"
        let cacheable: Bool
        if case .seek = command { cacheable = false } else { cacheable = true }
        queue.async { [weak self] in
            _ = self?.run(script, cache: cacheable)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.poll() }
        }
    }

    private func apply(_ info: NowPlaying?) {
        current = info
        onUpdate?(info)

        let key = info?.trackKey ?? ""
        guard key != lastTrackKey else { return }
        lastTrackKey = key
        guard let info else {
            onArtwork?(nil)
            return
        }
        loadArtwork(for: info)
    }

    private func loadArtwork(for info: NowPlaying) {
        switch info.source {
        case .system:
            onArtwork?(nil)
        case .spotify:
            guard let url = info.artworkURL else { onArtwork?(nil); return }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                let image = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async { self?.onArtwork?(image) }
            }.resume()
        case .music:
            queue.async { [weak self] in
                let script = """
                try
                    tell application "Music" to return data of artwork 1 of current track
                end try
                """
                let image = self?.run(script).flatMap { NSImage(data: $0.data) }
                DispatchQueue.main.async { self?.onArtwork?(image) }
            }
        }
    }

    private func query(_ source: MediaSource) -> NowPlaying? {
        let script: String
        switch source {
        case .system:
            return nil
        case .spotify:
            script = """
            try
                tell application "Spotify"
                    set t to current track
                    return (player state as string) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (player position as string) & linefeed & ((duration of t) / 1000 as string) & linefeed & (artwork url of t) & linefeed & (shuffling as string) & linefeed & (repeating as string)
                end tell
            end try
            return ""
            """
        case .music:
            script = """
            try
                tell application "Music"
                    if player state is stopped then return ""
                    set t to current track
                    return (player state as string) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (player position as string) & linefeed & (duration of t as string) & linefeed & "" & linefeed & (shuffle enabled as string) & linefeed & (song repeat as string)
                end tell
            end try
            return ""
            """
        }

        guard let output = run(script)?.stringValue, !output.isEmpty else { return nil }
        let fields = output.components(separatedBy: "\n")
        guard fields.count >= 6 else { return nil }

        return NowPlaying(
            source: source,
            title: fields[1],
            artist: fields[2],
            album: fields[3],
            isPlaying: fields[0] == "playing",
            position: Self.number(fields[4]),
            duration: Self.number(fields[5]),
            fetchedAt: Date(),
            artworkURL: fields.count > 6 ? URL(string: fields[6]).flatMap { $0.scheme == "https" ? $0 : nil } : nil,
            shuffle: fields.count > 7 ? fields[7] == "true" : nil,
            repeatMode: fields.count > 8 ? Self.repeatMode(fields[8]) : nil,
            appBundleID: source.bundleID
        )
    }

    private static func repeatMode(_ text: String) -> RepeatMode {
        switch text {
        case "one": return .one
        case "all", "true": return .all
        default: return .off
        }
    }

    private static func number(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func run(_ source: String, cache: Bool = true) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else { return nil }
            if cache { compiled[source] = fresh }
            script = fresh
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}
