import AppKit
import Security

/// Tokens for the integrations, in the login keychain rather than in Nook's preferences.
enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.nook.app",
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, _ account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var query = query(account)
        query[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(query as CFDictionary, nil)
    }
}

/// Review requests, mentions and CI results from GitHub notifications, through the gh CLI's own login.
final class GitHubMonitor {
    var onBanner: ((Banner) -> Void)?

    static let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: FileManager.default.isExecutableFile(atPath:))
    private var timer: Timer?
    private var seen: [String: String] = [:]
    private var primed = false

    func setEnabled(_ enabled: Bool) {
        if enabled, timer == nil, Self.gh != nil {
            // GitHub asks clients to poll notifications at most once a minute.
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.poll() }
            poll()
        } else if !enabled, timer != nil {
            timer?.invalidate()
            timer = nil
            seen.removeAll()
            primed = false
        }
    }

    private func poll() {
        guard let gh = Self.gh else { return }
        DispatchQueue.global().async { [weak self] in
            let output = PluginRunner.run(URL(fileURLWithPath: gh), arguments: ["api", "notifications"], limit: 1 << 20)
            let threads = output.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [[String: Any]]
            DispatchQueue.main.async { threads.map { self?.apply($0) } }
        }
    }

    private func apply(_ threads: [[String: Any]]) {
        var fresh: [[String: Any]] = []
        for thread in threads {
            guard let id = thread["id"] as? String, let updated = thread["updated_at"] as? String else { continue }
            if seen[id] != updated, thread["unread"] as? Bool == true { fresh.append(thread) }
            seen[id] = updated
        }
        defer { primed = true }
        guard primed, let latest = fresh.first, let banner = Self.banner(for: latest) else { return }
        onBanner?(banner)
    }

    static func banner(for thread: [String: Any]) -> Banner? {
        let subject = thread["subject"] as? [String: Any] ?? [:]
        guard let title = subject["title"] as? String else { return nil }
        let (symbol, label, tint): (String, String, NSColor) = switch thread["reason"] as? String {
        case "review_requested": ("eye.fill", "Review", .systemPurple)
        case "mention", "team_mention": ("at", "Mention", .systemBlue)
        case "assign": ("person.fill.checkmark", "Assigned", .systemBlue)
        case "ci_activity" where title.range(of: "fail", options: .caseInsensitive) != nil:
            ("xmark.octagon.fill", "CI failed", .systemRed)
        case "ci_activity": ("checkmark.circle.fill", "CI", .systemGreen)
        case "comment": ("text.bubble.fill", "Comment", .white)
        default: ("bell.fill", "GitHub", .white)
        }
        return Banner(symbol: symbol, title: String(title.prefix(60)), value: label, tint: tint, duration: 5,
                      showsTitle: true)
    }
}

/// Push alerts to the notch from anywhere: a server, a phone, cron. Subscribes to an ntfy topic.
final class NtfyMonitor {
    var onBanner: ((Banner) -> Void)?

    private var task: Task<Void, Never>?
    private var subscribed: String?

    static func isValidTopic(_ topic: String) -> Bool {
        topic.range(of: "^[-_A-Za-z0-9]{1,64}$", options: .regularExpression) != nil
    }

    func setEnabled(_ enabled: Bool) {
        let server = Pref.string(.ntfyServer).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let topic = Pref.string(.ntfyTopic)
        let url = URL(string: "\(server)/\(topic)/json")
        let valid = enabled && Self.isValidTopic(topic) && ["https", "http"].contains(url?.scheme)
        let token = valid ? Keychain.get("ntfy") : nil
        let key = valid ? "\(url?.absoluteString ?? "")|\(token ?? "")" : nil
        guard key != subscribed else { return }
        subscribed = key
        task?.cancel()
        guard valid, let url else { return }
        let deliver: (Banner) -> Void = { [weak self] banner in DispatchQueue.main.async { self?.onBanner?(banner) } }
        task = Task {
            var delay: UInt64 = 2
            while !Task.isCancelled {
                do {
                    var request = URLRequest(url: url, timeoutInterval: 120)
                    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    delay = 2
                    for try await line in bytes.lines {
                        guard let banner = Self.banner(from: line) else { continue }
                        deliver(banner)
                    }
                } catch {}
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 300)
            }
        }
    }

    /// One line of ntfy's JSON stream; keepalives and open events aren't messages.
    static func banner(from line: String) -> Banner? {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              json["event"] as? String == "message", let message = json["message"] as? String
        else { return nil }
        let urgent = (json["priority"] as? Int ?? 3) >= 4
        let text = (json["title"] as? String).map { "\($0): \(message)" } ?? message
        return Banner(symbol: urgent ? "exclamationmark.bubble.fill" : "bell.fill",
                      title: String(text.replacingOccurrences(of: "\n", with: " ").prefix(80)),
                      tint: urgent ? .systemRed : .systemTeal, duration: urgent ? 8 : 5, showsTitle: true, urgent: urgent)
    }
}

/// Chosen Home Assistant entities as tiles on the Widgets page; tap a light or switch to toggle it.
final class HomeAssistantMonitor {
    var onUpdate: (([PluginItem]) -> Void)?
    var onBanner: ((Banner) -> Void)?

    private var timer: Timer?
    private var states: [String: String] = [:]
    private var items: [String: PluginItem] = [:]
    private var server: (url: URL, token: String, entities: [String])?

    static let toggleable: Set<String> = ["light", "switch", "input_boolean", "fan"]

    static func entities(in text: String) -> [String] {
        text.split(whereSeparator: { ", \n".contains($0) }).map(String.init)
            .filter { $0.range(of: "^[a-z_]+\\.[a-z0-9_]+$", options: .regularExpression) != nil }
    }

    func setEnabled(_ enabled: Bool) {
        let entities = Self.entities(in: Pref.string(.homeAssistantEntities))
        let url = URL(string: Pref.string(.homeAssistantURL).trimmingCharacters(in: CharacterSet(charactersIn: "/ ")))
        guard enabled, let url, ["https", "http"].contains(url.scheme), !entities.isEmpty,
              let token = Keychain.get("homeAssistant")
        else {
            timer?.invalidate()
            timer = nil
            server = nil
            states.removeAll()
            items.removeAll()
            onUpdate?([])
            return
        }
        let changed = server?.url != url || server?.token != token || server?.entities != entities
        server = (url, token, entities)
        guard changed else { return }
        items = items.filter { entities.contains($0.key) }
        // shortcut: polls every 10 s; switch to the WebSocket API if instant updates matter.
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.poll() }
        }
        poll()
    }

    func toggle(_ entity: String) {
        guard let server, server.entities.contains(entity) else { return }
        var request = request(server, path: "api/services/homeassistant/toggle")
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["entity_id": entity])
        URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.poll() }
        }.resume()
    }

    private func request(_ server: (url: URL, token: String, entities: [String]), path: String) -> URLRequest {
        var request = URLRequest(url: server.url.appendingPathComponent(path), timeoutInterval: 8)
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func poll() {
        guard let server else { return }
        for entity in server.entities {
            URLSession.shared.dataTask(with: request(server, path: "api/states/\(entity)")) { [weak self] data, _, _ in
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                DispatchQueue.main.async { json.map { self?.apply(entity, $0) } }
            }.resume()
        }
    }

    private func apply(_ entity: String, _ json: [String: Any]) {
        guard server?.entities.contains(entity) == true else { return }
        let item = Self.item(entity: entity, json: json)
        let state = json["state"] as? String ?? ""
        if let previous = states[entity], previous != state,
           ["binary_sensor", "lock"].contains(entity.split(separator: ".").first) {
            onBanner?(Banner(symbol: item.symbol, title: item.title, value: item.value, tint: item.tint, duration: 5,
                             showsTitle: true))
        }
        states[entity] = state
        items[entity] = item
        onUpdate?(server?.entities.compactMap { items[$0] } ?? [])
    }

    static func item(entity: String, json: [String: Any]) -> PluginItem {
        let state = json["state"] as? String ?? "unknown"
        let attributes = json["attributes"] as? [String: Any] ?? [:]
        let domain = String(entity.split(separator: ".").first ?? "")
        let on = ["on", "open", "unlocked", "playing", "home", "heat", "cool"].contains(state)
        let symbol = switch domain {
        case "light": on ? "lightbulb.fill" : "lightbulb"
        case "switch", "input_boolean": "power"
        case "fan": "fan.fill"
        case "lock": state == "locked" ? "lock.fill" : "lock.open.fill"
        case "binary_sensor": on ? "sensor.fill" : "sensor"
        case "climate": "thermometer.medium"
        case "cover": state == "open" ? "blinds.horizontal.open" : "blinds.horizontal.closed"
        case "media_player": "hifispeaker.fill"
        case "person": "person.fill"
        case "sensor": "gauge.with.dots.needle.33percent"
        default: "house.fill"
        }
        let unit = attributes["unit_of_measurement"] as? String
        return PluginItem(id: "ha." + entity, title: String((attributes["friendly_name"] as? String ?? entity).prefix(40)),
                          value: String((unit.map { "\(state) \($0)" } ?? state.replacingOccurrences(of: "_", with: " ").capitalized).prefix(20)),
                          symbol: symbol, tint: on ? .systemYellow : .white,
                          entity: toggleable.contains(domain) ? entity : nil)
    }
}

/// Time-synced lyrics for what's playing, from LRCLIB (free, no account).
final class LyricsService {
    var onLyrics: (([LyricLine]?) -> Void)?
    private var track: String?

    func update(_ info: NowPlaying?) {
        guard Pref.bool(.showLyrics), let info, !info.title.isEmpty else {
            if track != nil { track = nil; onLyrics?(nil) }
            return
        }
        guard info.trackKey != track else { return }
        let key = info.trackKey
        track = key
        onLyrics?(nil)
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "track_name", value: info.title),
                                 URLQueryItem(name: "artist_name", value: info.artist)]
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue("Nook (https://github.com/tadeyemo32/nook)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let results = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]] ?? []
            let best = results.filter { $0["syncedLyrics"] is String }.min { a, b in
                abs((a["duration"] as? Double ?? 0) - info.duration) < abs((b["duration"] as? Double ?? 0) - info.duration)
            }
            let lines = (best?["syncedLyrics"] as? String).map(Self.parse)
            DispatchQueue.main.async {
                guard self?.track == key else { return }
                self?.onLyrics?(lines?.isEmpty == false ? lines : nil)
            }
        }.resume()
    }

    /// LRC: `[mm:ss.xx] words`, sometimes several timestamps on one line.
    static func parse(_ lrc: String) -> [LyricLine] {
        let stamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        var lines: [LyricLine] = []
        for raw in lrc.split(separator: "\n").map(String.init) {
            let range = NSRange(raw.startIndex..., in: raw)
            let matches = stamp.matches(in: raw, range: range)
            guard let last = matches.last, let end = Range(last.range, in: raw) else { continue }
            let text = raw[end.upperBound...].trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutes = Range(match.range(at: 1), in: raw).flatMap({ Double(raw[$0]) }),
                      let seconds = Range(match.range(at: 2), in: raw).flatMap({ Double(raw[$0]) }) else { continue }
                lines.append(LyricLine(time: minutes * 60 + seconds, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    static func line(in lyrics: [LyricLine], at time: Double) -> String? {
        lyrics.last { $0.time <= time }.map { $0.text.isEmpty ? "♪" : $0.text }
    }
}
