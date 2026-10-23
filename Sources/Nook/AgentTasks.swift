import AppKit
import Darwin

/// A Claude Code or Codex run that Nook holds in the background, so the terminal that asked for it can close.
struct AgentTask: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case running, done, failed, stopped }

    var id: String
    var agent: AgentUsage.Agent
    var prompt: String
    var cwd: String
    var executable: String
    var started: Date
    var finished: Date?
    var status: Status = .running
    var summary: String?
    var session: String?
    var pid: Int32 = 0
    /// Process start time disambiguates a PID after Nook restarts.
    var pidStartMicros: UInt64?
    /// The session that handed this task over.
    var parent: String?

    var project: String { URL(fileURLWithPath: cwd).lastPathComponent }
}

/// What `nook run` or a Shortcut leaves in the Tasks folder; `nook://task?id=` then starts it.
struct AgentTaskRequest: Codable {
    var agent: AgentUsage.Agent
    var prompt: String
    var cwd: String
    var executable: String
    var path: String
    var resume: String?

    static let agents: [AgentUsage.Agent] = [.claude, .codex]
    static let defaultPath = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        .map { NSString(string: $0).expandingTildeInPath }.joined(separator: ":")

    static func find(_ name: String, in path: String) -> String? {
        path.split(separator: ":").map { "\($0)/\(name)" }.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    /// The request file is the only way to start a task, and it lives in a folder only this user can write,
    /// so a web page opening nook://task can't run anything.
    func write() throws -> String {
        let id = UUID().uuidString
        let url = AgentTaskRunner.folder.appendingPathComponent("\(id).request.json")
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return id
    }
}

enum TaskAction { case stop, openInTerminal, remove }

final class AgentTaskRunner {
    var onChange: (([AgentTask]) -> Void)?
    var onBanner: ((Banner) -> Void)?

    static var folder: URL {
        let url = NookSupport.folder.appendingPathComponent("Tasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private static var listURL: URL { folder.appendingPathComponent("tasks.json") }

    private(set) var tasks: [AgentTask] = []
    private var processes: [String: Process] = [:]
    private var watchers: [String: DispatchSourceProcess] = [:]

    static func processStartMicros(_ pid: Int32) -> UInt64? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    static func isSameProcess(_ task: AgentTask) -> Bool {
        guard let start = task.pidStartMicros else { return false }
        return processStartMicros(task.pid) == start
    }

    /// Picks up tasks that were still running when Nook last quit: they keep going without it.
    func resume() {
        tasks = (try? Data(contentsOf: Self.listURL)).flatMap { try? JSONDecoder().decode([AgentTask].self, from: $0) } ?? []
        for task in tasks where task.status == .running {
            if Self.isSameProcess(task) {
                let source = DispatchSource.makeProcessSource(identifier: task.pid, eventMask: .exit, queue: .main)
                source.setEventHandler { [weak self] in self?.finish(task.id, exitCode: nil) }
                source.resume()
                watchers[task.id] = source
            } else {
                finish(task.id, exitCode: nil)
            }
        }
        publish()
    }

    func start(id: String) {
        guard UUID(uuidString: id) != nil else { return }
        let url = Self.folder.appendingPathComponent("\(id).request.json")
        guard let data = try? Data(contentsOf: url) else { return }
        try? FileManager.default.removeItem(at: url)
        guard var request = try? JSONDecoder().decode(AgentTaskRequest.self, from: data),
              AgentTaskRequest.agents.contains(request.agent),
              FileManager.default.isExecutableFile(atPath: request.executable)
        else { return }
        request.resume = request.resume.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }

        let output = Self.file(id, "out"), log = Self.file(id, "log")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = Self.arguments(for: request, id: id, permissions: Pref.string(.taskPermissions))
        process.currentDirectoryURL = URL(fileURLWithPath: request.cwd)
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDECODE"] = nil
        environment["PATH"] = request.path
        environment["NOOK_TASK"] = id
        process.environment = environment
        let handles = [try? FileHandle(forWritingTo: output), try? FileHandle(forWritingTo: log)]
        defer { handles.forEach { try? $0?.close() } }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handles[0]
        process.standardError = handles[1]
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async { self?.finish(id, exitCode: status) }
        }

        var task = AgentTask(id: id, agent: request.agent, prompt: String(request.prompt.prefix(300)), cwd: request.cwd,
                             executable: request.executable, started: Date(), parent: request.resume)
        do { try process.run() } catch {
            task.status = .failed
            task.finished = Date()
            task.summary = error.localizedDescription
            add(task)
            return
        }
        task.pid = process.processIdentifier
        task.pidStartMicros = Self.processStartMicros(task.pid)
        processes[id] = process
        add(task)
        onBanner?(Banner(symbol: "play.circle.fill", title: task.project, value: "Working", tint: task.agent.tint,
                         duration: 3, showsTitle: true, agent: task.agent))
    }

    /// A session that just handed its work to Nook isn't done: the work goes on here.
    func isHandedOff(session: String?, cwd: String?) -> Bool {
        tasks.contains { task in
            task.status == .running && (session != nil && task.parent == session
                || task.cwd == cwd && Date().timeIntervalSince(task.started) < 120)
        }
    }

    func perform(_ action: TaskAction, on id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks[index]
        switch action {
        case .stop:
            guard task.status == .running else { return }
            if processes[id] == nil {
                guard Self.isSameProcess(task) else {
                    finish(id, exitCode: nil)
                    return
                }
            }
            tasks[index].status = .stopped
            if let process = processes[id] { process.terminate() } else if task.pid > 1 { kill(task.pid, SIGTERM) }
            save()
            publish()
        case .openInTerminal:
            openInTerminal(task)
        case .remove:
            guard task.status != .running else { return }
            tasks.remove(at: index)
            for ext in ["out", "log", "last", "command"] { try? FileManager.default.removeItem(at: Self.file(id, ext)) }
            save()
            publish()
        }
    }

    static func arguments(for request: AgentTaskRequest, id: String, permissions: String) -> [String] {
        let brief = """
        You're running in the background through Nook. The user may have closed the terminal and can't answer \
        questions, so do the whole task yourself and end with a short summary of what you did.

        Task: \(request.prompt)
        """
        switch request.agent {
        case .codex:
            let sandbox = permissions == "all" ? "danger-full-access" : "workspace-write"
            return ["exec", "--json", "--skip-git-repo-check", "-s", sandbox, "-o", file(id, "last").path, brief]
        default:
            let mode = ["edits": "acceptEdits", "all": "bypassPermissions"][permissions] ?? "auto"
            var arguments = ["-p", "--output-format", "json", "--permission-mode", mode]
            if let resume = request.resume { arguments += ["--resume", resume, "--fork-session"] }
            return arguments + ["--", brief]
        }
    }

    /// Claude's `--output-format json` prints one result object at the end.
    static func claudeResult(_ text: String) -> (ok: Bool?, summary: String?, session: String?) {
        let line = text.split(separator: "\n").last { $0.hasPrefix("{") }.map(String.init) ?? text
        guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return (nil, nil, nil)
        }
        // A run that hit its turn or budget limit says is_error: false but isn't done.
        let succeeded = (json["is_error"] as? Bool).map { !$0 && (json["subtype"] as? String ?? "success") == "success" }
        return (succeeded, json["result"] as? String, json["session_id"] as? String)
    }

    /// Codex's `exec --json` prints one event per line; the last message goes to the -o file.
    static func codexResult(_ text: String, lastMessage: String?) -> (ok: Bool?, summary: String?, session: String?) {
        var ok: Bool?, session: String?, failure: String?
        for line in text.split(separator: "\n") {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch json["type"] as? String {
            case "thread.started": session = json["thread_id"] as? String
            case "turn.completed": ok = ok ?? true
            case "turn.failed", "error":
                ok = false
                failure = ((json["error"] as? [String: Any])?["message"] ?? json["message"]) as? String
            default: break
            }
        }
        let message = lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (ok, ok == false ? failure ?? message : message.flatMap { $0.isEmpty ? nil : $0 }, session)
    }

    private func finish(_ id: String, exitCode: Int32?) {
        processes[id] = nil
        watchers[id]?.cancel()
        watchers[id] = nil
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].finished == nil else { return }
        var task = tasks[index]
        // Agent logs can be very large; only the beginning and end carry the result events.
        let output = Self.readBounded(Self.file(id, "out"), limit: 4 * 1024 * 1024,
                                      includePrefix: task.agent == .codex) ?? ""
        let result = task.agent == .codex
            ? Self.codexResult(output, lastMessage: Self.readBounded(Self.file(id, "last"), limit: 8192))
            : Self.claudeResult(output)
        task.finished = Date()
        if task.status == .running { task.status = result.ok ?? (exitCode == 0) ? .done : .failed }
        let errors = Self.readBounded(Self.file(id, "log"), limit: 8192)?
            .split(separator: "\n").last.map(String.init)
        task.summary = (result.summary ?? (task.status == .failed ? errors : nil)).map { String($0.prefix(600)) }
        task.session = result.session ?? task.session
        tasks[index] = task
        save()
        publish()

        guard task.status != .stopped else { return }
        let done = task.status == .done
        onBanner?(Banner(symbol: done ? "checkmark.circle.fill" : "xmark.octagon.fill", title: task.project,
                         value: done ? "Done" : "Failed", tint: done ? .systemGreen : .systemRed, duration: 6,
                         showsTitle: true, agent: task.agent, urgent: true))
        playSystemSound(done ? "Glass" : "Basso")
    }

    private func openInTerminal(_ task: AgentTask) {
        guard let session = task.session else { return }
        let resume = task.agent == .codex ? "resume \(Self.quoted(session))" : "--resume \(Self.quoted(session))"
        let url = Self.file(task.id, "command")
        let script = "#!/bin/sh\ncd \(Self.quoted(task.cwd)) && exec \(Self.quoted(task.executable)) \(resume)\n"
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    private func add(_ task: AgentTask) {
        tasks.insert(task, at: 0)
        let finished = tasks.filter { $0.status != .running }
        for old in finished.dropFirst(20) { perform(.remove, on: old.id) }
        save()
        publish()
    }

    private func save() {
        try? JSONEncoder().encode(tasks).write(to: Self.listURL, options: .atomic)
    }

    private func publish() {
        onChange?(tasks)
    }

    static func readBounded(_ url: URL, limit: Int, includePrefix: Bool = false) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd() else { return nil }
        let start = length > UInt64(limit) ? length - UInt64(limit) : 0
        let prefix: Data
        if includePrefix, start > 0 {
            try? handle.seek(toOffset: 0)
            prefix = (try? handle.read(upToCount: 16 * 1024)) ?? Data()
        } else {
            prefix = Data()
        }
        guard (try? handle.seek(toOffset: start)) != nil,
              let suffix = try? handle.read(upToCount: limit) else { return nil }
        let data = prefix.isEmpty ? suffix : prefix + Data("\n".utf8) + suffix
        return String(decoding: data, as: UTF8.self)
    }

    static func file(_ id: String, _ ext: String) -> URL { folder.appendingPathComponent("\(id).\(ext)") }

    static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
