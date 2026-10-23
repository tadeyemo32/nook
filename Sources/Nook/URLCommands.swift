import AppKit

enum URLCommands {
    static func handle(_ url: URL, model: IslandModel, agents: AgentConnector, tasks: AgentTaskRunner) {
        guard url.scheme == "nook", let command = url.host else { return }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first })

        switch command {
        case "show":
            guard let title = text(query["title"]) else { return }
            model.show(Banner(symbol: symbol(query["symbol"], default: "bell.fill"), title: title,
                              value: text(query["value"], limit: 20), tint: tint(query["tint"]),
                              duration: min(30, max(1, Double(query["duration"] ?? "") ?? 3)), showsTitle: true))
        case "progress":
            let id = text(query["id"], limit: 40) ?? "default"
            let progress = Double(query["progress"] ?? "").map { min(1, max(0, $0)) }
            if query["done"] == "1" || progress == 1 {
                let title = text(query["title"]) ?? model.custom?.title ?? "Done"
                if model.custom?.id == id { model.custom = nil }
                model.show(Banner(symbol: "checkmark.circle.fill", title: title, tint: .systemGreen, showsTitle: true))
            } else {
                model.custom = CustomActivity(
                    id: id, symbol: symbol(query["symbol"], default: model.custom?.symbol ?? "arrow.triangle.2.circlepath"),
                    title: text(query["title"]) ?? model.custom?.title ?? "Working", progress: progress)
            }
        case "clear":
            if query["id"] == nil || model.custom?.id == query["id"] { model.custom = nil }
        case "timer":
            let seconds = (Double(query["minutes"] ?? "") ?? 0) * 60 + (Double(query["seconds"] ?? "") ?? 0)
            if seconds > 0 { model.startTimer(min(seconds, 24 * 3600)) }
        case "open":
            if let tab = query["tab"].flatMap(Tab.init(rawValue:)), tab != .mirror, model.enabledTabs.contains(tab) {
                model.tab = tab
            }
            model.expanded = true
        case "close":
            model.expanded = false
        case "settings":
            model.onOpenSettings?()
        case "claude":
            agents.handle(query)
        case "task":
            tasks.start(id: query["id"] ?? "")
        default:
            break
        }
    }

    private static func text(_ value: String?, limit: Int = 60) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(limit))
    }

    private static func symbol(_ name: String?, default fallback: String) -> String {
        guard let name, name.count <= 60, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        else { return fallback }
        return name
    }

    private static func tint(_ name: String?) -> NSColor {
        switch name?.lowercased() {
        case "green": return .systemGreen
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "blue": return .systemBlue
        case "purple": return .systemPurple
        case "pink": return .systemPink
        default: return .white
        }
    }
}
