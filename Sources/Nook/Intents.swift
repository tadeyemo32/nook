import AppIntents
import AppKit

// Shortcuts actions. Each one sends the app the same nook:// link the CLI would, so values are checked
// in one place. scripts/bundle.sh extracts their metadata, since SwiftPM doesn't.

@MainActor private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

@MainActor private func send(_ command: String, _ query: [String: String?]) {
    appDelegate?.application(NSApp, open: [CLI.link(command, query)])
}

enum NookColor: String, AppEnum {
    case white, green, red, orange, yellow, blue, purple, pink

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Colour"
    static let caseDisplayRepresentations: [NookColor: DisplayRepresentation] = [
        .white: "White", .green: "Green", .red: "Red", .orange: "Orange", .yellow: "Yellow", .blue: "Blue",
        .purple: "Purple", .pink: "Pink",
    ]
}

enum NookPage: String, AppEnum {
    case home, shelf, widgets, clipboard, stats, agents, timer

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Page"
    static let caseDisplayRepresentations: [NookPage: DisplayRepresentation] = [
        .home: "Home", .shelf: "Shelf", .widgets: "Widgets", .clipboard: "Clipboard", .stats: "System Stats",
        .agents: "Agents", .timer: "Timer",
    ]
}

enum NookAgent: String, AppEnum {
    case claude, codex

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let caseDisplayRepresentations: [NookAgent: DisplayRepresentation] = [.claude: "Claude Code", .codex: "Codex"]
}

struct ShowAlertIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Alert in the Notch"
    static let description = IntentDescription("Shows a short alert in Nook's island.")

    @Parameter(title: "Title") var text: String
    @Parameter(title: "Value", description: "Shown on the right, like 12s or 80%.") var value: String?
    @Parameter(title: "SF Symbol", default: "bell.fill") var symbol: String
    @Parameter(title: "Colour", default: .white) var tint: NookColor
    @Parameter(title: "Seconds", default: 3) var duration: Double

    @MainActor func perform() async throws -> some IntentResult {
        send("show", ["title": text, "value": value, "symbol": symbol, "tint": tint.rawValue, "duration": String(duration)])
        return .result()
    }
}

struct SetProgressIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Progress in the Notch"
    static let description = IntentDescription("Shows or updates a progress ring. Finish it with Finish Progress.")

    @Parameter(title: "ID", default: "shortcut") var id: String
    @Parameter(title: "Title") var text: String
    @Parameter(title: "Progress", description: "From 0 to 1.", inclusiveRange: (0, 1)) var progress: Double
    @Parameter(title: "SF Symbol", default: "arrow.triangle.2.circlepath") var symbol: String

    @MainActor func perform() async throws -> some IntentResult {
        send("progress", ["id": id, "title": text, "progress": String(progress), "symbol": symbol])
        return .result()
    }
}

struct FinishProgressIntent: AppIntent {
    static let title: LocalizedStringResource = "Finish Progress in the Notch"

    @Parameter(title: "ID", default: "shortcut") var id: String
    @Parameter(title: "Title") var text: String?

    @MainActor func perform() async throws -> some IntentResult {
        send("progress", ["id": id, "done": "1", "title": text])
        return .result()
    }
}

struct StartTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Nook Timer"

    @Parameter(title: "Minutes", default: 25) var minutes: Double

    @MainActor func perform() async throws -> some IntentResult {
        send("timer", ["minutes": String(minutes)])
        return .result()
    }
}

struct OpenNookIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Nook"

    @Parameter(title: "Page", default: .home) var page: NookPage

    @MainActor func perform() async throws -> some IntentResult {
        send("open", ["tab": page.rawValue])
        return .result()
    }
}

struct RunAgentTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Agent Task in Background"
    static let description = IntentDescription(
        "Runs Claude Code or Codex in a folder in the background. Nook shows it in the notch and says when it's done.")

    @Parameter(title: "Agent", default: .claude) var agent: NookAgent
    @Parameter(title: "Task") var task: String
    @Parameter(title: "Folder", description: "The project folder, like ~/dev/app.") var folder: String

    @MainActor func perform() async throws -> some IntentResult {
        let cwd = NSString(string: folder).expandingTildeInPath
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isFolder), isFolder.boolValue else {
            throw CLI.Failure("There's no folder at \(folder).")
        }
        let path = AgentTaskRequest.defaultPath
        guard let executable = AgentTaskRequest.find(agent.rawValue, in: path) else {
            throw CLI.Failure("Couldn't find \(agent.rawValue). Install it, or run nook run from a terminal.")
        }
        let id = try AgentTaskRequest(agent: AgentUsage.Agent(rawValue: agent.rawValue) ?? .claude, prompt: task,
                                      cwd: cwd, executable: executable, path: path).write()
        send("task", ["id": id])
        return .result()
    }
}

struct JoinMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Join Next Meeting"
    static let description = IntentDescription(
        "Opens the call link of the meeting that's on now or starts within 10 minutes. Needs Nook's calendar on.")

    @MainActor func perform() async throws -> some IntentResult {
        guard appDelegate?.joinNextMeeting() == true else { throw CLI.Failure("No meeting with a call link is starting.") }
        return .result()
    }
}

struct NookFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Nook"
    static let description: IntentDescription? = "Shows the Focus in the notch and can keep Nook quiet while it's on."

    @Parameter(title: "Name", description: "Shown in the notch when the Focus turns on, like Work.") var name: String?
    @Parameter(title: "Only urgent alerts", default: true) var quiet: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name ?? "Set a name")", subtitle: quiet ? "Only urgent alerts" : "All alerts")
    }

    // shortcut: assumes the system calls this again with an empty filter when the Focus ends; untested on macOS 14.
    @MainActor func perform() async throws -> some IntentResult {
        appDelegate?.setFocus(name, quiet: name != nil && quiet)
        return .result()
    }
}

struct NookShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: JoinMeetingIntent(), phrases: ["Join my next meeting with \(.applicationName)"],
                    shortTitle: "Join Next Meeting", systemImageName: "video.fill")
        AppShortcut(intent: StartTimerIntent(), phrases: ["Start a \(.applicationName) timer"],
                    shortTitle: "Start Timer", systemImageName: "timer")
        AppShortcut(intent: OpenNookIntent(), phrases: ["Open \(.applicationName)", "Open \(.applicationName) \(\.$page)"],
                    shortTitle: "Open Nook", systemImageName: "capsule.fill")
    }
}
