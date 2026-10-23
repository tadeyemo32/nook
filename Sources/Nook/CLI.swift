import Foundation

/// `nook <command>`: the Nook binary is its own command-line tool. Application Support/Nook/bin/nook wraps it,
/// and every command turns into a nook:// link, so it behaves exactly like the links do.
enum CLI {
    static let commands: Set<String> = ["show", "progress", "done", "clear", "timer", "open", "close", "run", "help"]

    static let usage = """
    usage: nook show <title> [--value V] [--symbol S] [--tint T] [--duration SECONDS]
           nook progress <id> <0-1 or N%> [--title T] [--symbol S]
           nook done <id> [--title T]
           nook clear [id]
           nook timer <minutes>
           nook open [home|shelf|widgets|clipboard|stats|agents|timer]
           nook close
           nook run [--agent claude|codex] [--resume SESSION] [--] <task>

    run hands the task to Nook, which runs the agent in this folder in the background:
    you can close the terminal. The notch shows the agent while it works and Done when it ends.
    """

    static func run(_ arguments: [String]) -> Int32 {
        do {
            guard let url = try url(for: arguments) else {
                print(usage)
                return 0
            }
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", url.absoluteString]
            try open.run()
            open.waitUntilExit()
            if arguments.first == "run", open.terminationStatus == 0 {
                print("Nook is running it in the background. You can close this terminal.")
            }
            return open.terminationStatus
        } catch {
            FileHandle.standardError.write(Data("nook: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// The nook:// link for a command line, or nil for help. `run` also writes the task request.
    static func url(for arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
                    cwd: String = FileManager.default.currentDirectoryPath) throws -> URL? {
        guard let command = arguments.first, command != "help" else { return nil }
        let (words, options) = parse(Array(arguments.dropFirst()))
        let text = words.joined(separator: " ")
        switch command {
        case "show":
            guard !text.isEmpty else { throw Failure("show needs a title") }
            return link("show", ["title": text, "value": options["value"], "symbol": options["symbol"],
                                 "tint": options["tint"], "duration": options["duration"]])
        case "progress":
            guard words.count >= 2, let fraction = fraction(words[1]) else {
                throw Failure("progress needs an id and a fraction, like: nook progress build 0.4")
            }
            return link("progress", ["id": words[0], "progress": String(fraction), "title": options["title"],
                                     "symbol": options["symbol"]])
        case "done":
            guard let id = words.first else { throw Failure("done needs the progress id") }
            return link("progress", ["id": id, "done": "1", "title": options["title"]])
        case "clear":
            return link("clear", ["id": words.first])
        case "timer":
            guard let minutes = words.first.flatMap(Double.init), minutes > 0 else { throw Failure("timer needs minutes") }
            return link("timer", ["minutes": String(minutes)])
        case "open":
            return link("open", ["tab": words.first])
        case "close":
            return link("close", [:])
        case "run":
            guard environment["NOOK_TASK"] == nil else { throw Failure("already running inside a Nook task") }
            guard !text.isEmpty else { throw Failure("run needs a task") }
            guard let agent = AgentUsage.Agent(rawValue: options["agent"] ?? "claude"),
                  AgentTaskRequest.agents.contains(agent) else { throw Failure("--agent is claude or codex") }
            let path = environment["PATH"] ?? AgentTaskRequest.defaultPath
            guard let executable = AgentTaskRequest.find(agent.rawValue, in: path) else {
                throw Failure("couldn't find \(agent.rawValue) on your PATH")
            }
            let id = try AgentTaskRequest(agent: agent, prompt: text, cwd: cwd, executable: executable, path: path,
                                          resume: options["resume"]).write()
            return link("task", ["id": id])
        default:
            throw Failure("unknown command \(command)\n\n\(usage)")
        }
    }

    static func parse(_ arguments: [String]) -> (words: [String], options: [String: String]) {
        var words: [String] = [], options: [String: String] = [:]
        var index = 0, rest = false
        while index < arguments.count {
            let argument = arguments[index]
            if rest || !argument.hasPrefix("--") {
                words.append(argument)
            } else if argument == "--" {
                rest = true
            } else if index + 1 < arguments.count {
                options[String(argument.dropFirst(2))] = arguments[index + 1]
                index += 1
            }
            index += 1
        }
        return (words, options)
    }

    private static func fraction(_ text: String) -> Double? {
        if text.hasSuffix("%") { return Double(text.dropLast()).map { $0 / 100 } }
        return Double(text)
    }

    /// URLComponents leaves & and = alone in query values, so encode everything but the unreserved characters.
    static func link(_ command: String, _ query: [String: String?]) -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let items = query.compactMap { key, value in
            value.map { "\(key)=\($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
        }.sorted()
        return URL(string: "nook://\(command)" + (items.isEmpty ? "" : "?" + items.joined(separator: "&")))!
    }

    /// Rewritten at every launch so the command follows the app if it moves.
    static func installWrapper() {
        guard let executable = Bundle.main.executablePath else { return }
        let bin = NookSupport.folder.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let url = bin.appendingPathComponent("nook")
        let script = "#!/bin/sh\n# Installed by Nook: the nook command.\nexec \(AgentTaskRunner.quoted(executable)) \"$@\"\n"
        guard (try? String(contentsOf: url, encoding: .utf8)) != script else { return }
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static var wrapper: URL { NookSupport.folder.appendingPathComponent("bin/nook") }

    private static var binFolders: [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin"]
    }

    static var linkedCommand: String? {
        binFolders.map { "\($0)/nook" }.first { (try? FileManager.default.destinationOfSymbolicLink(atPath: $0)) == wrapper.path }
    }

    /// Links `nook` into the first bin folder on the PATH this user can write to.
    static func linkCommand() throws -> String {
        if let linkedCommand { return linkedCommand }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for folder in binFolders {
            if folder.hasPrefix(home) { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
            guard FileManager.default.isWritableFile(atPath: folder) else { continue }
            let link = "\(folder)/nook"
            guard !FileManager.default.fileExists(atPath: link) else { throw Failure("\(link) already exists") }
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: wrapper.path)
            return link
        }
        throw Failure("no writable bin folder; add \(wrapper.deletingLastPathComponent().path) to your PATH")
    }
}
