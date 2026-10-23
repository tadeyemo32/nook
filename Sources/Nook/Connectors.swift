import AppKit

enum NookSupport {
    static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nook", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

struct AgentUsage: Equatable, Identifiable {
    enum Agent: String, CaseIterable, Codable {
        case claude, codex, cursor, gemini
    }

    struct Window: Equatable {
        var name: String
        var used: Double
        var resets: Date
    }

    var agent: Agent
    var windows: [Window] = []
    var model: String?
    var effort: String?
    var context: Double?
    var cost: Double?
    var linesAdded: Int?
    var linesRemoved: Int?
    var project: String?
    var plan: String?

    var id: Agent { agent }
    var busiest: Window? { windows.max { $0.used < $1.used } }

    func contextBanner(warned: inout Set<String>) -> Banner? {
        guard let context else { return nil }
        if context < 70 { [80, 90].forEach { warned.remove("\(agent)-context-\($0)") } }
        for threshold in [90.0, 80] where context >= threshold {
            guard warned.insert("\(agent)-context-\(Int(threshold))").inserted else { return nil }
            return Banner(symbol: "square.stack.3d.up.fill", title: "Context", value: "\(Int(context))%",
                          tint: threshold >= 90 ? .systemRed : .systemOrange, duration: 5,
                          showsTitle: true, agent: agent)
        }
        return nil
    }

    func limitBanner(warned: inout Set<String>) -> Banner? {
        for window in windows {
            for threshold in [95.0, 90, 80] where window.used >= threshold {
                let key = "\(agent)-\(window.name)-\(Int(threshold))-\(Int(window.resets.timeIntervalSince1970))"
                guard warned.insert(key).inserted else { break }
                return Banner(symbol: "gauge.with.dots.needle.67percent", title: "\(window.name) limit",
                              value: "\(Int(window.used))%", tint: threshold >= 90 ? .systemRed : .systemOrange,
                              duration: 6, showsTitle: true, agent: agent)
            }
        }
        return nil
    }
}

extension AgentUsage.Agent {
    var name: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini"
        }
    }

    var appIcon: NSImage? { Self.icons[self] }

    var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "terminal.fill"
        case .cursor: return "cursorarrow.rays"
        case .gemini: return "sparkle"
        }
    }

    var tint: NSColor {
        switch self {
        case .claude: return NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        case .gemini: return NSColor(red: 0.3, green: 0.55, blue: 1, alpha: 1)
        default: return .white
        }
    }

    private static let icons: [Self: NSImage] = Dictionary(uniqueKeysWithValues: allCases.compactMap { agent in
        let ids = switch agent {
        case .claude: ["com.anthropic.claudefordesktop"]
        case .codex: ["com.openai.codex", "com.openai.chat"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .gemini: [String]()
        }
        return ids.lazy.compactMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:)).first
            .map { (agent, NSWorkspace.shared.icon(forFile: $0.path)) }
    })
}

final class AgentConnector {
    var onBanner: ((Banner) -> Void)?
    var onAttention: ((CustomActivity?) -> Void)?
    var onUsage: (([AgentUsage]) -> Void)?
    /// Whether a session just handed its work to a Nook background task, so its Stop isn't "Done".
    var isHandedOff: ((String?, String?) -> Bool)?

    private static let marker = "Nook/claude-"
    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
    private static var codexHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
    }
    private static var cursorHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/hooks.json")
    }
    private static var geminiSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/settings.json")
    }
    private static var hookScript: URL { NookSupport.folder.appendingPathComponent("claude-hook.sh") }
    private static var statusScript: URL { NookSupport.folder.appendingPathComponent("claude-statusline.sh") }
    static var statusFile: URL { NookSupport.folder.appendingPathComponent("claude-status.json") }
    static var hookKey: String {
        if let key = UserDefaults.standard.string(forKey: "agentHookKey") { return key }
        let key = UUID().uuidString
        UserDefaults.standard.set(key, forKey: "agentHookKey")
        return key
    }

    /// (key in the agent's config, the Claude-style event name Nook's hook script is called with)
    typealias Events = [(key: String, event: String)]
    static let claudeEvents: Events = ["Notification", "Stop", "StopFailure", "SubagentStop", "UserPromptSubmit",
                                       "PreCompact", "SessionStart", "SessionEnd"].map { ($0, $0) }
    static let codexEvents: Events = ["Stop", "UserPromptSubmit", "SessionStart"].map { ($0, $0) }
    static let geminiEvents: Events = [("SessionStart", "SessionStart"), ("SessionEnd", "SessionEnd"),
                                       ("BeforeAgent", "UserPromptSubmit"), ("AfterAgent", "Stop"),
                                       ("Notification", "Notification"), ("PreCompress", "PreCompact")]
    /// Only hooks that just observe: Cursor blocks a gated action (like a shell command) on unexpected output.
    static let cursorEvents: Events = [("sessionStart", "SessionStart"), ("sessionEnd", "SessionEnd"),
                                       ("stop", "Stop"), ("subagentStop", "SubagentStop"),
                                       ("preCompact", "PreCompact")]

    private var timer: Timer?
    private var attention: (agent: AgentUsage.Agent, session: String?)?
    private var sessions: [String: (agent: AgentUsage.Agent, last: Date, working: Bool)] = [:]
    private var warned: Set<String> = []
    private let codex = CodexUsageReader()
    private var ended: [AgentUsage.Agent: Date] = [:]
    static let idleTimeout: TimeInterval = 5 * 60
    private var watchers: [String: DispatchSourceProcess] = [:]

    static var isConnected: Bool { isInstalled(in: settingsURL) }
    static var isCodexConnected: Bool { isInstalled(in: codexHooksURL) }

    static func isConnected(_ agent: AgentUsage.Agent) -> Bool {
        switch agent {
        case .claude: return isConnected
        case .codex: return isCodexConnected
        case .cursor: return isInstalled(in: cursorHooksURL)
        case .gemini: return isInstalled(in: geminiSettingsURL)
        }
    }

    static func connect(_ agent: AgentUsage.Agent) throws {
        switch agent {
        case .claude: try connect()
        case .codex: try connectCodex()
        case .cursor:
            try writeScripts()
            try writeSettings(connectedCursor(try readSettings(cursorHooksURL), hookScript: hookScript.path),
                              to: cursorHooksURL)
        case .gemini:
            try writeScripts()
            try writeSettings(connected(try readSettings(geminiSettingsURL), hookScript: hookScript.path,
                                        statusScript: nil, events: geminiEvents, agent: "gemini"),
                              to: geminiSettingsURL)
        }
    }

    static func disconnect(_ agent: AgentUsage.Agent) throws {
        switch agent {
        case .claude: try disconnect()
        case .codex: try disconnectCodex()
        case .cursor: try writeSettings(disconnectedHooks(try readSettings(cursorHooksURL)), to: cursorHooksURL)
        case .gemini: try writeSettings(disconnectedHooks(try readSettings(geminiSettingsURL)), to: geminiSettingsURL)
        }
    }

    private static func isInstalled(in url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(marker + "hook.sh")
    }

    static var hasOwnStatusLine: Bool {
        guard let settings = try? readSettings(settingsURL), let status = settings["statusLine"] as? [String: Any]
        else { return false }
        return !((status["command"] as? String) ?? "").contains(marker)
    }

    static func connect() throws {
        try writeScripts()
        try writeSettings(connected(try readSettings(settingsURL), hookScript: hookScript.path,
                                    statusScript: statusScript.path), to: settingsURL)
    }

    static func disconnect() throws {
        try writeSettings(disconnected(try readSettings(settingsURL)), to: settingsURL)
        try? FileManager.default.removeItem(at: statusFile)
    }

    static func connectCodex() throws {
        try writeScripts()
        try writeSettings(connected(try readSettings(codexHooksURL), hookScript: hookScript.path, statusScript: nil,
                                    events: codexEvents, agent: "codex"), to: codexHooksURL)
    }

    static func disconnectCodex() throws {
        try writeSettings(disconnected(try readSettings(codexHooksURL)), to: codexHooksURL)
    }

    private static let skillMarker = "Installed by Nook (nook-skill)"

    private static func skillURL(_ agent: AgentUsage.Agent) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(agent == .codex ? ".codex/skills/nook/SKILL.md" : ".claude/skills/nook/SKILL.md")
    }

    static func isSkillInstalled(_ agent: AgentUsage.Agent) -> Bool {
        ((try? String(contentsOf: skillURL(agent), encoding: .utf8)) ?? "").contains(skillMarker)
    }

    /// The /nook skill: the agent hands the task to `nook run`, and Nook runs it in the background.
    static func installSkill(_ agent: AgentUsage.Agent) throws {
        let command = "\"$HOME/Library/Application Support/Nook/bin/nook\" run --agent \(agent.rawValue)"
        let task = agent == .codex ? "Hand the user's task to Nook instead of doing it here." : """
        Hand this task to Nook instead of doing it here:

        $ARGUMENTS
        """
        let steps = agent == .codex ? """
        1. Write the task as a complete, self-contained brief: the background run starts fresh and won't see \
        this conversation, so include the goal, the files involved and what done looks like.
        2. From the project folder, run (quote the brief for the shell):

           \(command) -- '<brief>'

           It writes to ~/Library/Application Support/Nook and opens Nook, which Codex's sandbox blocks, so \
        run it with escalated permissions from the start: the user approves once and can allow it for good.
        """ : """
        1. If nothing is written above, the task is what the user just asked for.
        2. From the project folder, run (quote the task for the shell):

           \(command) --resume ${CLAUDE_SESSION_ID} -- '<task>'

           The background session continues this conversation, so a short task is enough.
        """
        let skill = """
        ---
        name: nook
        description: Hand a task to Nook so it runs in the background and the user can close this terminal. Nook shows \(agent.name)'s logo in the Mac's notch while it works and Done when it finishes. Use when the user types /nook <task>, or asks to run something in the background, hand it to Nook, or wants to close the terminal while you work.
        argument-hint: <task>
        ---
        <!-- \(skillMarker). Settings → Coding Agents in Nook removes it. -->

        \(task)

        \(steps)
        3. Tell the user in one line that Nook is running it and they can close the terminal: the notch shows \
        Done when it finishes, and Nook's Agents page can reopen the session. Don't start on the task yourself.

        """
        let url = skillURL(agent)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try skill.write(to: url, atomically: true, encoding: .utf8)
    }

    static func removeSkill(_ agent: AgentUsage.Agent) throws {
        guard isSkillInstalled(agent) else { return }
        try FileManager.default.removeItem(at: skillURL(agent).deletingLastPathComponent())
    }

    static func upgradeIfNeeded() {
        if AgentUsage.Agent.allCases.contains(where: isConnected) { try? writeScripts() }
        for agent in AgentTaskRequest.agents where isSkillInstalled(agent) { try? installSkill(agent) }
        guard isConnected, let hooks = (try? readSettings(settingsURL))?["hooks"] as? [String: Any],
              claudeEvents.contains(where: { event in
                  !((hooks[event.key] as? [[String: Any]]) ?? []).contains(where: isOurs)
              })
        else { return }
        try? connect()
    }

    static func connected(_ settings: [String: Any], hookScript: String, statusScript: String?,
                          events: Events = claudeEvents, agent: String? = nil) -> [String: Any] {
        var settings = disconnectedHooks(settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (key, event) in events {
            var entries = hooks[key] as? [[String: Any]] ?? []
            let command = "\"\(hookScript)\" \(event)" + (agent.map { " \($0)" } ?? "")
            entries.append(["hooks": [["type": "command", "command": command]]])
            hooks[key] = entries
        }
        settings["hooks"] = hooks
        if let statusScript, settings["statusLine"] == nil {
            settings["statusLine"] = ["type": "command", "command": "\"\(statusScript)\"", "padding": 0]
        }
        return settings
    }

    /// Cursor's hooks.json has no matcher groups: each event lists commands directly.
    static func connectedCursor(_ settings: [String: Any], hookScript: String) -> [String: Any] {
        var settings = disconnectedHooks(settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (key, event) in cursorEvents {
            hooks[key] = (hooks[key] as? [[String: Any]] ?? []) + [["command": "\"\(hookScript)\" \(event) cursor"]]
        }
        settings["hooks"] = hooks
        settings["version"] = settings["version"] ?? 1
        return settings
    }

    static func disconnected(_ settings: [String: Any]) -> [String: Any] {
        var settings = disconnectedHooks(settings)
        if let status = settings["statusLine"] as? [String: Any],
           ((status["command"] as? String) ?? "").contains(marker) {
            settings["statusLine"] = nil
        }
        return settings
    }

    static func disconnectedHooks(_ settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        ((entry["hooks"] as? [[String: Any]] ?? []) + [entry]).contains { ($0["command"] as? String ?? "").contains(marker) }
    }

    private static func readSettings(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    private static func writeSettings(_ settings: [String: Any], to settingsURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.appendingPathExtension("nook-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    private static func writeScripts() throws {
        let hook = """
        #!/bin/sh
        # Installed by Nook. Forwards a Claude Code or Codex hook event ($1; $2 is the agent,
        # claude by default) to Nook. Only the fields Nook shows are sent, base64url-encoded:
        # never prompts or transcripts.
        input=$(cat)
        # Background tasks Nook runs itself report when they finish.
        [ -n "${NOOK_TASK:-}" ] && exit 0
        # Gemini CLI and Cursor read a hook's output as JSON.
        case "${2:-claude}" in cursor|gemini) printf '{}' ;; esac
        field() { printf '%s' "$input" | plutil -extract "$1" raw -o - - 2>/dev/null | tr -d '\\n' | head -c 300 | base64 | tr '+/' '-_' | tr -d '\\n='; }
        first() { for key in "$@"; do value=$(field "$key"); [ -n "$value" ] && { printf '%s' "$value"; return; }; done; }
        # Up past the shells that ran us to the agent itself, so Nook can tell when it quits.
        pid=$PPID
        while [ "${pid:-0}" -gt 1 ]; do
          case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
            *sh) pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') ;;
            *) break ;;
          esac
        done
        # A reply can end with work still going: background tasks, scheduled prompts, or a question.
        # Only counts and a yes/no reach Nook, never the message itself.
        running=$(printf '%s' "$input" | plutil -extract background_tasks json -o - - 2>/dev/null | grep -oE '"status":"(running|pending)"' | wc -l | tr -d ' ')
        crons=$(printf '%s' "$input" | plutil -extract session_crons json -o - - 2>/dev/null | grep -o '"schedule"' | wc -l | tr -d ' ')
        last=$(for key in last_assistant_message prompt_response; do printf '%s' "$input" | plutil -extract "$key" raw -o - - 2>/dev/null && break; done | tr -d ' \t\n*_)"' | tail -c 1)
        asks=0; [ "$last" = "?" ] && asks=1
        open -g "nook://claude?key=\(hookKey)&agent=${2:-claude}&event=$1&pid=${pid:-0}&type=$(field notification_type)&message=$(field message)&cwd=$(first cwd workspace_roots.0)&session=$(first session_id conversation_id)&status=$(field status)&error=$(field error)&running=${running:-0}&crons=${crons:-0}&asks=$asks"

        """
        let status = """
        #!/bin/sh
        # Installed by Nook. Saves Claude Code's status (usage limits) for Nook to read,
        # and prints a short status line.
        dir="$HOME/Library/Application Support/Nook"
        input=$(cat)
        printf '%s' "$input" > "$dir/claude-status.json.tmp" && mv "$dir/claude-status.json.tmp" "$dir/claude-status.json"
        get() { printf '%s' "$input" | plutil -extract "$1" raw -o - - 2>/dev/null | tr -d '\\n'; }
        line=$(get model.display_name)
        ctx=$(get context_window.used_percentage); [ -n "$ctx" ] && line="$line · context ${ctx%.*}%"
        five=$(get rate_limits.five_hour.used_percentage); [ -n "$five" ] && line="$line · 5h ${five%.*}%"
        printf '%s' "$line"

        """
        for (url, text) in [(hookScript, hook), (statusScript, status)] {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    func handle(_ query: [String: String]) {
        guard query["key"] == Self.hookKey else { return }
        func decoded(_ key: String) -> String? {
            guard var text = query[key], !text.isEmpty else { return nil }
            text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            text += String(repeating: "=", count: (4 - text.count % 4) % 4)
            return Data(base64Encoded: text).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.prefix(120)) }
        }
        let agent = AgentUsage.Agent(rawValue: query["agent"] ?? "") ?? .claude
        let project = decoded("cwd").map { URL(fileURLWithPath: $0).lastPathComponent } ?? agent.name
        let session = decoded("session")
        let state = Self.stopState(query, status: decoded("status"))
        trackSession(agent, session, event: query["event"], pid: pid_t(query["pid"] ?? "") ?? 0,
                     stillWorking: state != .done && state != .failed && state != .aborted)
        func banner(_ symbol: String, _ value: String, _ tint: NSColor, _ pref: Pref, duration: TimeInterval = 3) {
            guard Pref.bool(pref) else { return }
            onBanner?(Banner(symbol: symbol, title: project, value: value, tint: tint, duration: duration,
                             showsTitle: true, agent: agent))
        }

        switch query["event"] {
        case "Notification":
            switch decoded("type") {
            case "permission_prompt", "worker_permission_prompt", "workflow_permission_prompt", "ToolPermission":
                needsYou(agent, session, project, "Permission")
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                needsYou(agent, session, project, "Question")
            case "idle_prompt":
                banner("ellipsis.bubble.fill", "Waiting", .systemBlue, .agentAlertWaiting, duration: 4)
            case "agent_completed":
                guard Pref.bool(.agentAlertSubagent) else { break }
                let outcome = decoded("message")
                let failed = outcome?.range(of: "failed", options: .caseInsensitive) != nil
                onBanner?(Banner(symbol: failed ? "exclamationmark.triangle.fill" : "person.2.fill",
                                 title: outcome ?? "Agent done", tint: failed ? .systemRed : .systemTeal,
                                 duration: 5, showsTitle: true, agent: agent))
            case "auth_success":
                break
            default:
                if Pref.bool(.agentAlertOther), let message = decoded("message") {
                    onBanner?(Banner(symbol: "sparkle", title: message, tint: agent.tint, duration: 5,
                                     showsTitle: true, agent: agent))
                }
            }
        case "Stop":
            clearAttention(agent, session)
            guard isHandedOff?(session, decoded("cwd")) != true else { break }
            switch state {
            case .failed: banner("xmark.octagon.fill", "Failed", .systemRed, .claudeDoneAlerts)
            case .aborted: break
            case .running(let count): banner("ellipsis.circle.fill", "\(count) running", .systemBlue, .claudeDoneAlerts)
            case .scheduled: banner("clock.fill", "Scheduled", .systemIndigo, .claudeDoneAlerts)
            case .question: banner("questionmark.bubble.fill", "Question", .systemOrange, .agentAlertWaiting, duration: 4)
            case .done: banner("checkmark.circle.fill", "Done", .systemGreen, .claudeDoneAlerts)
            }
        case "StopFailure":
            clearAttention(agent, session)
            let error = decoded("error").map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
            banner("xmark.octagon.fill", String((error ?? "Failed").prefix(20)), .systemRed, .claudeDoneAlerts, duration: 5)
        case "SubagentStop":
            banner("person.2.fill", "Subagent done", .systemTeal, .agentAlertSubagent)
        case "PreCompact":
            banner("arrow.down.right.and.arrow.up.left", "Compacting", .systemPurple, .agentAlertCompact)
        case "SessionStart":
            banner("play.circle.fill", "Started", .systemBlue, .agentAlertSession)
        case "SessionEnd":
            clearAttention(agent, session)
            banner("stop.circle.fill", "Ended", .systemGray, .agentAlertSession)
        case "UserPromptSubmit":
            clearAttention(agent, session)
        default:
            break
        }
    }

    enum StopState: Equatable { case done, failed, aborted, running(Int), scheduled, question }

    /// What a Stop really means: an agent ends a reply even while background tasks run, prompts are
    /// scheduled to come back, or it has asked the user something.
    static func stopState(_ query: [String: String], status: String?) -> StopState {
        if status == "error" { return .failed }
        if status == "aborted" { return .aborted }
        if let running = Int(query["running"] ?? ""), running > 0 { return .running(running) }
        if (Int(query["crons"] ?? "") ?? 0) > 0 { return .scheduled }
        if query["asks"] == "1" { return .question }
        return .done
    }

    private func needsYou(_ agent: AgentUsage.Agent, _ session: String?, _ project: String, _ reason: String) {
        guard Pref.bool(.agentAlertPermission) else { return }
        attention = (agent, session)
        onAttention?(CustomActivity(id: agent.rawValue, symbol: "hand.raised.fill", title: project,
                                    progress: nil, tint: .systemOrange, badge: "exclamationmark", agent: agent))
        onBanner?(Banner(symbol: "hand.raised.fill", title: project, value: reason, tint: .systemOrange,
                         duration: 4, showsTitle: true, agent: agent, urgent: true))
        playSystemSound("Tink")
    }

    private func clearAttention(_ agent: AgentUsage.Agent, _ session: String?) {
        guard let attention, attention.agent == agent,
              attention.session == nil || session == nil || attention.session == session
        else { return }
        self.attention = nil
        onAttention?(nil)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.readUsage() }
            }
            readUsage()
        } else if timer != nil {
            timer?.invalidate()
            timer = nil
            onUsage?([])
        }
    }

    private func readUsage() {
        let claude = Pref.bool(.agentClaude) ? Self.claudeUsage() : nil
        let shown = claude.flatMap { isActive(.claude, written: $0.written) ? $0.usage : nil }
        guard Pref.bool(.agentCodex) else { return publish([shown].compactMap { $0 }) }
        codex.read { [weak self] codex in
            guard let self else { return }
            let active = codex.flatMap { self.isActive(.codex, written: $0.written) ? $0.usage : nil }
            publish([shown, active].compactMap { $0 })
        }
    }

    private func trackSession(_ agent: AgentUsage.Agent, _ session: String?, event: String?, pid: pid_t,
                              stillWorking: Bool = false) {
        let key = "\(agent.rawValue)/\(session ?? "")"
        switch event {
        case "SessionEnd":
            return endSession(key, agent: agent)
        case "UserPromptSubmit":
            sessions[key] = (agent, Date(), true)
        case "Stop":
            sessions[key] = (agent, Date(), stillWorking)
        default:
            sessions[key] = (agent, Date(), sessions[key]?.working ?? false)
        }
        watchExit(key, agent: agent, pid: pid)
        if timer != nil { readUsage() }
    }

    func isActive(_ agent: AgentUsage.Agent, written: Date?, now: Date = Date()) -> Bool {
        guard Pref.string(.agentShowWhen) != "always" else { return true }
        if sessions.contains(where: { $0.value.agent == agent && watchers[$0.key] != nil }) { return true }
        let heard = sessions.values.filter { $0.agent == agent }
        if heard.contains(where: { $0.working && now.timeIntervalSince($0.last) < 3600 }) { return true }
        let logged = written.flatMap { $0 > (ended[agent] ?? .distantPast) ? $0 : nil }
        let last = (heard.map(\.last) + [logged].compactMap { $0 }).max()
        return last.map { now.timeIntervalSince($0) < Self.idleTimeout } ?? false
    }

    private func watchExit(_ key: String, agent: AgentUsage.Agent, pid: pid_t) {
        guard pid > 1, watchers[key] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            endSession(key, agent: agent)
        }
        source.resume()
        watchers[key] = source
    }

    private func endSession(_ key: String, agent: AgentUsage.Agent) {
        watchers[key]?.cancel()
        watchers[key] = nil
        sessions[key] = nil
        if !sessions.values.contains(where: { $0.agent == agent }) { ended[agent] = Date() }
        if timer != nil { readUsage() }
    }

    private func publish(_ usage: [AgentUsage]) {
        onUsage?(usage)
        for agent in usage {
            if Pref.bool(.agentAlertLimits) { agent.limitBanner(warned: &warned).map { onBanner?($0) } }
            if Pref.bool(.agentAlertContext) { agent.contextBanner(warned: &warned).map { onBanner?($0) } }
        }
    }

    static func claudeUsage(now: Date = Date()) -> (usage: AgentUsage, written: Date?)? {
        guard let data = try? Data(contentsOf: statusFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        func value<T>(_ path: String...) -> T? {
            var node: Any? = json
            for key in path { node = (node as? [String: Any])?[key] }
            return node as? T
        }
        func window(_ key: String, _ name: String) -> AgentUsage.Window? {
            guard let used: Double = value("rate_limits", key, "used_percentage"),
                  let resets: Double = value("rate_limits", key, "resets_at"),
                  Date(timeIntervalSince1970: resets) > now
            else { return nil }
            return AgentUsage.Window(name: name, used: used, resets: Date(timeIntervalSince1970: resets))
        }

        var usage = AgentUsage(agent: .claude,
                               windows: [window("five_hour", "5-hour"), window("seven_day", "Weekly")].compactMap { $0 })
        let modified = (try? statusFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, now.timeIntervalSince(modified) < 600 {
            usage.model = value("model", "display_name")
            usage.effort = value("effort", "level")
            usage.context = value("context_window", "used_percentage")
            usage.cost = value("cost", "total_cost_usd")
            usage.linesAdded = value("cost", "total_lines_added")
            usage.linesRemoved = value("cost", "total_lines_removed")
            usage.project = (value("cwd") as String?).map { URL(fileURLWithPath: $0).lastPathComponent }
        } else if usage.windows.isEmpty {
            return nil
        }
        return (usage, modified)
    }
}

final class CodexUsageReader {
    private let queue = DispatchQueue(label: "nook.codex")
    private var cache: (url: URL, modified: Date, limits: String?, turn: String?)?

    private static let sessions = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")
    private static let zstd = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        .first(where: FileManager.default.isExecutableFile(atPath:))

    func read(_ completion: @escaping ((usage: AgentUsage, written: Date)?) -> Void) {
        queue.async { [self] in
            let usage = latest()
            DispatchQueue.main.async { completion(usage) }
        }
    }

    private func latest() -> (usage: AgentUsage, written: Date)? {
        guard let (url, modified) = Self.newestLog() else { return nil }
        if cache?.url != url || cache?.modified != modified {
            let text = Self.contents(of: url)
            cache = (url, modified, text.flatMap { Self.lastLine(containing: "\"rate_limits\"", in: $0) },
                     text.flatMap { Self.lastLine(containing: "\"type\":\"turn_context\"", in: $0) })
        }
        return cache?.limits
            .flatMap { Self.usage(limitsLine: $0, turnLine: cache?.turn, loggedAt: modified) }
            .map { ($0, modified) }
    }

    private static func newestLog() -> (URL, Date)? {
        let calendar = Calendar.current
        let logs = (0..<8).flatMap { daysAgo -> [URL] in
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) else { return [] }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            return (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        return logs
            .filter { $0.lastPathComponent.hasPrefix("rollout-") }
            .compactMap { url in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate.map { (url, $0) }
            }
            .max { $0.1 < $1.1 }
    }

    private static func contents(of url: URL) -> String? {
        guard url.pathExtension == "zst" else { return try? String(contentsOf: url, encoding: .utf8) }
        guard let zstd else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-dcq", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    static func lastLine(containing needle: String, in text: String) -> String? {
        guard let hit = text.range(of: needle, options: .backwards) else { return nil }
        let start = text[..<hit.lowerBound].lastIndex(of: "\n").map(text.index(after:)) ?? text.startIndex
        let end = text[hit.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        return String(text[start..<end])
    }

    static func usage(limitsLine: String, turnLine: String?, loggedAt: Date, now: Date = Date()) -> AgentUsage? {
        func payload(_ line: String?) -> [String: Any]? {
            line.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["payload"]
                as? [String: Any]
        }
        guard let event = payload(limitsLine), let limits = event["rate_limits"] as? [String: Any] else { return nil }
        let windows = ["primary", "secondary"].compactMap { key -> AgentUsage.Window? in
            guard let window = limits[key] as? [String: Any], let used = window["used_percent"] as? Double else { return nil }
            let resets = (window["resets_at"] as? Double).map(Date.init(timeIntervalSince1970:))
                ?? (window["resets_in_seconds"] as? Double).map(loggedAt.addingTimeInterval)
            guard let resets, resets > now else { return nil }
            return AgentUsage.Window(name: windowName(minutes: window["window_minutes"] as? Double), used: used,
                                     resets: resets)
        }
        var usage = AgentUsage(agent: .codex, windows: windows,
                               plan: (limits["plan_type"] as? String).map(planName))
        guard now.timeIntervalSince(loggedAt) < 600 else { return windows.isEmpty ? nil : usage }

        if let info = event["info"] as? [String: Any],
           let tokens = (info["last_token_usage"] as? [String: Any])?["total_tokens"] as? Double,
           let size = info["model_context_window"] as? Double, size > 0 {
            usage.context = min(100, tokens / size * 100)
        }
        if let turn = payload(turnLine) {
            usage.model = turn["model"] as? String
            usage.effort = turn["effort"] as? String
            usage.project = (turn["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        return usage
    }

    static func windowName(minutes: Double?) -> String {
        guard let minutes, minutes > 0 else { return "Limit" }
        switch Int(minutes) {
        case 300: return "5-hour"
        case 10080: return "Weekly"
        case let m where m % 1440 == 0: return "\(m / 1440)-day"
        case let m: return "\(max(1, m / 60))-hour"
        }
    }

    private static func planName(_ raw: String) -> String {
        ["prolite": "Pro Lite", "pro": "Pro", "plus": "Plus", "team": "Team", "business": "Business",
         "enterprise": "Enterprise", "edu": "Edu", "free": "Free"][raw] ?? raw.capitalized
    }
}

struct PluginItem: Equatable, Identifiable {
    var id: String
    var title: String
    var value: String?
    var symbol: String
    var tint: NSColor
    var progress: Double?
    var url: URL?
    /// A Home Assistant entity that a tap toggles.
    var entity: String? = nil
}

final class PluginRunner {
    var onUpdate: (([PluginItem]) -> Void)?
    var onAlert: ((Banner) -> Void)?

    static var folder: URL {
        let url = NookSupport.folder.appendingPathComponent("Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var timer: Timer?
    private var lastRun: [String: Date] = [:]
    private var running: Set<String> = []
    private var items: [String: PluginItem] = [:]
    private var lastAlert: [String: String] = [:]
    private let queue = DispatchQueue(label: "nook.plugins", attributes: .concurrent)

    func setEnabled(_ enabled: Bool) {
        if enabled, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
            timer?.fire()
        } else if !enabled, timer != nil {
            timer?.invalidate()
            timer = nil
            items.removeAll()
            onUpdate?([])
        }
    }

    func refreshAll() {
        lastRun.removeAll()
        tick()
    }

    static func scripts() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                        options: .skipsHiddenFiles)) ?? [])
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func tick() {
        let scripts = Self.scripts()
        let names = Set(scripts.map(\.lastPathComponent))
        if items.keys.contains(where: { !names.contains($0) }) {
            items = items.filter { names.contains($0.key) }
            publish()
        }
        for script in scripts {
            let name = script.lastPathComponent
            let due = (lastRun[name] ?? .distantPast).addingTimeInterval(Self.interval(name)) <= Date()
            guard due, !running.contains(name) else { continue }
            lastRun[name] = Date()
            running.insert(name)
            queue.async { [weak self] in
                let output = Self.run(script)
                DispatchQueue.main.async { self?.apply(name: name, output: output) }
            }
        }
    }

    static func interval(_ name: String) -> TimeInterval {
        let parts = name.split(separator: ".")
        guard parts.count >= 3, let token = parts.dropLast().last, let unit = token.last,
              let number = Double(token.dropLast()), number > 0 else { return 60 }
        switch unit {
        case "s": return max(5, number)
        case "m": return number * 60
        case "h": return number * 3600
        default: return 60
        }
    }

    /// Runs a plugin (or another tool) for at most 10 seconds and returns the start of its output.
    static func run(_ script: URL, arguments: [String] = [], limit: Int = 8192) -> String? {
        let process = Process()
        process.executableURL = script
        process.arguments = arguments
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile().prefix(limit)
        process.waitUntilExit()
        deadline.cancel()
        return String(data: data, encoding: .utf8)
    }

    private func apply(name: String, output: String?) {
        running.remove(name)
        guard let output else { return }
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            fields[key] = String(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces).prefix(80))
        }
        let base = name.split(separator: ".").first.map(String.init) ?? name
        let symbol = fields["symbol"].flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0
        } ?? "puzzlepiece.extension.fill"
        let tint = Self.color(fields["tint"])
        items[name] = PluginItem(
            id: name, title: fields["title"] ?? base, value: fields["value"], symbol: symbol, tint: tint,
            progress: fields["progress"].flatMap(Double.init).map { min(1, max(0, $0)) },
            url: fields["url"].flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme) ? $0 : nil })
        publish()

        let alert = fields["alert"] ?? ""
        if !alert.isEmpty, alert != lastAlert[name] {
            onAlert?(Banner(symbol: symbol, title: alert, tint: tint, duration: 5, showsTitle: true))
        }
        lastAlert[name] = alert
    }

    private func publish() {
        onUpdate?(items.values.sorted { $0.id < $1.id })
    }

    private static func color(_ name: String?) -> NSColor {
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
