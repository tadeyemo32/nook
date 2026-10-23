import XCTest
@testable import Nook

final class CLITests: XCTestCase {
    func testUnknownCommandUsesCLIErrorPath() {
        XCTAssertTrue(NookApp.isCLIInvocation(["sho", "hello"]))
        XCTAssertFalse(NookApp.isCLIInvocation([]))
        XCTAssertFalse(NookApp.isCLIInvocation(["-psn_0_12345"]))
        XCTAssertThrowsError(try CLI.url(for: ["sho", "hello"]))
    }

    func testShowEncodesEverythingButUnreserved() throws {
        let url = try XCTUnwrap(CLI.url(for: ["show", "Build", "passed", "&", "done=1", "--tint", "green"]))
        XCTAssertEqual(url.absoluteString, "nook://show?tint=green&title=Build%20passed%20%26%20done%3D1")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "title" }?.value, "Build passed & done=1")
    }

    func testProgressTakesPercentOrFraction() throws {
        XCTAssertEqual(try CLI.url(for: ["progress", "build", "40%"])?.absoluteString, "nook://progress?id=build&progress=0.4")
        XCTAssertEqual(try CLI.url(for: ["progress", "build", "0.25"])?.absoluteString, "nook://progress?id=build&progress=0.25")
        XCTAssertThrowsError(try CLI.url(for: ["progress", "build"]))
        XCTAssertEqual(try CLI.url(for: ["done", "build"])?.absoluteString, "nook://progress?done=1&id=build")
    }

    func testDoubleDashKeepsDashedWords() {
        let (words, options) = CLI.parse(["--agent", "codex", "--", "fix", "--verbose", "flag"])
        XCTAssertEqual(words, ["fix", "--verbose", "flag"])
        XCTAssertEqual(options, ["agent": "codex"])
    }

    func testRunRefusesInsideATask() {
        XCTAssertThrowsError(try CLI.url(for: ["run", "again"], environment: ["NOOK_TASK": "x", "PATH": "/usr/bin"]))
        XCTAssertThrowsError(try CLI.url(for: ["run", "--agent", "cursor", "x"], environment: ["PATH": "/usr/bin"]))
        XCTAssertNil(try CLI.url(for: ["help"]))
    }
}

final class AgentTaskTests: XCTestCase {
    private let request = AgentTaskRequest(agent: .claude, prompt: "fix it", cwd: "/tmp", executable: "/bin/claude",
                                           path: "/usr/bin", resume: "54aeb2b5-1217-4f75-9033-19e31e30e5a6")

    func testRecoveredTaskRequiresMatchingProcessStart() throws {
        var task = AgentTask(id: UUID().uuidString, agent: .claude, prompt: "test", cwd: "/tmp",
                             executable: "/bin/sh", started: Date())
        task.pid = getpid()
        task.pidStartMicros = try XCTUnwrap(AgentTaskRunner.processStartMicros(task.pid))
        XCTAssertTrue(AgentTaskRunner.isSameProcess(task))
        task.pidStartMicros! += 1
        XCTAssertFalse(AgentTaskRunner.isSameProcess(task))
        task.pidStartMicros = nil
        XCTAssertFalse(AgentTaskRunner.isSameProcess(task))
    }

    func testTaskLogReadsOnlyBoundedData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try ("start\n" + String(repeating: "x", count: 32 * 1024) + "\nend").write(to: url, atomically: true,
                                                                            encoding: .utf8)
        XCTAssertEqual(AgentTaskRunner.readBounded(url, limit: 8), "xxxx\nend")
        let both = try XCTUnwrap(AgentTaskRunner.readBounded(url, limit: 8, includePrefix: true))
        XCTAssertTrue(both.hasPrefix("start\n"))
        XCTAssertTrue(both.hasSuffix("xxxx\nend"))
    }

    func testClaudeArgumentsForkTheSessionAndEndWithThePrompt() {
        let arguments = AgentTaskRunner.arguments(for: request, id: "id", permissions: "auto")
        XCTAssertEqual(Array(arguments.prefix(5)), ["-p", "--output-format", "json", "--permission-mode", "auto"])
        XCTAssertTrue(arguments.contains("--fork-session"))
        XCTAssertEqual(arguments[arguments.count - 2], "--")
        XCTAssertTrue(arguments.last?.hasSuffix("Task: fix it") == true)
        XCTAssertTrue(AgentTaskRunner.arguments(for: request, id: "id", permissions: "edits").contains("acceptEdits"))
    }

    func testCodexStaysSandboxedUnlessAllowed() {
        var codex = request
        codex.agent = .codex
        XCTAssertTrue(AgentTaskRunner.arguments(for: codex, id: "id", permissions: "auto").contains("workspace-write"))
        XCTAssertTrue(AgentTaskRunner.arguments(for: codex, id: "id", permissions: "all").contains("danger-full-access"))
    }

    func testClaudeResult() {
        let output = #"{"type":"result","is_error":false,"result":"Fixed the test.","session_id":"abc"}"#
        let result = AgentTaskRunner.claudeResult("warming up\n" + output)
        XCTAssertEqual(result.ok, true)
        XCTAssertEqual(result.summary, "Fixed the test.")
        XCTAssertEqual(result.session, "abc")
        XCTAssertNil(AgentTaskRunner.claudeResult("not json").ok)
    }

    func testCodexResult() {
        let ok = AgentTaskRunner.codexResult("""
        {"type":"thread.started","thread_id":"t1"}
        {"type":"turn.completed"}
        """, lastMessage: "Done.\n")
        XCTAssertEqual(ok.ok, true)
        XCTAssertEqual(ok.summary, "Done.")
        XCTAssertEqual(ok.session, "t1")
        let failed = AgentTaskRunner.codexResult(#"{"type":"turn.failed","error":{"message":"quota"}}"#, lastMessage: nil)
        XCTAssertEqual(failed.ok, false)
        XCTAssertEqual(failed.summary, "quota")
    }

    func testMaxTurnsIsNotDone() {
        let output = #"{"type":"result","subtype":"error_max_turns","is_error":false,"session_id":"abc"}"#
        XCTAssertEqual(AgentTaskRunner.claudeResult(output).ok, false)
    }

    func testQuotedSurvivesSingleQuotes() {
        XCTAssertEqual(AgentTaskRunner.quoted("it's"), #"'it'\''s'"#)
    }
}

final class ConnectorTests: XCTestCase {
    func testUsageChipPicksMostUsedWindow() {
        let usage = AgentUsage(agent: .claude, windows: [
            .init(name: "5-hour", used: 23, resets: .distantFuture),
            .init(name: "Weekly", used: 98, resets: .distantFuture),
        ])
        XCTAssertEqual(usage.busiest?.name, "Weekly")
        XCTAssertEqual(usage.busiest?.used, 98)
    }

    func testStopIsOnlyDoneWhenNothingIsLeft() {
        XCTAssertEqual(AgentConnector.stopState([:], status: nil), .done)
        XCTAssertEqual(AgentConnector.stopState(["running": "2", "asks": "1"], status: nil), .running(2))
        XCTAssertEqual(AgentConnector.stopState(["running": "0", "crons": "1"], status: nil), .scheduled)
        XCTAssertEqual(AgentConnector.stopState(["running": "0", "crons": "0", "asks": "1"], status: nil), .question)
        XCTAssertEqual(AgentConnector.stopState(["running": "3"], status: "error"), .failed)
        XCTAssertEqual(AgentConnector.stopState([:], status: "aborted"), .aborted)
    }

    func testCursorHooksKeepOtherToolsAndDisconnectCleanly() {
        let theirs: [String: Any] = ["version": 1, "hooks": ["stop": [["command": "/other/hook.sh Stop"]]]]
        let connected = AgentConnector.connectedCursor(theirs, hookScript: "/x/Nook/claude-hook.sh")
        let stop = (connected["hooks"] as? [String: Any])?["stop"] as? [[String: String]]
        XCTAssertEqual(stop?.count, 2)
        XCTAssertEqual(stop?.last?["command"], #""/x/Nook/claude-hook.sh" Stop cursor"#)
        XCTAssertNil((connected["hooks"] as? [String: Any])?["beforeShellExecution"])

        let back = AgentConnector.disconnectedHooks(connected)
        XCTAssertEqual(((back["hooks"] as? [String: Any])?["stop"] as? [[String: String]])?.count, 1)
        XCTAssertNil((back["hooks"] as? [String: Any])?["sessionStart"])
    }

    func testGeminiMapsItsEventsToClaudeNames() {
        let settings = AgentConnector.connected(["theme": "dark"], hookScript: "/x/Nook/claude-hook.sh", statusScript: nil,
                                                events: AgentConnector.geminiEvents, agent: "gemini")
        let hooks = settings["hooks"] as? [String: Any]
        let after = (hooks?["AfterAgent"] as? [[String: Any]])?.first?["hooks"] as? [[String: String]]
        XCTAssertEqual(after?.first?["command"], #""/x/Nook/claude-hook.sh" Stop gemini"#)
        XCTAssertEqual(settings["theme"] as? String, "dark")
        XCTAssertNil(settings["statusLine"])
    }
}

final class IntegrationTests: XCTestCase {
    func testMeetingLinks() {
        XCTAssertEqual(CalendarService.meetingURL(in: [nil, "Room 4", "Join: https://acme.zoom.us/j/123?pwd=x)."])?.absoluteString,
                       "https://acme.zoom.us/j/123?pwd=x")
        XCTAssertEqual(CalendarService.meetingURL(in: ["https://meet.google.com/abc-defg-hij"])?.host, "meet.google.com")
        XCTAssertNil(CalendarService.meetingURL(in: ["https://example.com/zoom.us/j/1", "Lunch"]))
    }

    func testLyrics() {
        let lines = LyricsService.parse("[00:12.50] Hello\n[ti:Song]\n[00:05.00][00:20.00] Chorus\n")
        XCTAssertEqual(lines.map(\.time), [5, 12.5, 20])
        XCTAssertEqual(LyricsService.line(in: lines, at: 13), "Hello")
        XCTAssertNil(LyricsService.line(in: lines, at: 1))
    }

    func testNtfy() {
        XCTAssertTrue(NtfyMonitor.isValidTopic("my-backups_42"))
        XCTAssertFalse(NtfyMonitor.isValidTopic("../etc"))
        XCTAssertNil(NtfyMonitor.banner(from: #"{"event":"keepalive"}"#))
        let banner = NtfyMonitor.banner(from: #"{"event":"message","title":"Backup","message":"done","priority":5}"#)
        XCTAssertEqual(banner?.title, "Backup: done")
        XCTAssertEqual(banner?.urgent, true)
    }

    func testHomeAssistant() {
        XCTAssertEqual(HomeAssistantMonitor.entities(in: "light.office, bad entity\nbinary_sensor.door"),
                       ["light.office", "binary_sensor.door"])
        let light = HomeAssistantMonitor.item(entity: "light.office",
                                              json: ["state": "on", "attributes": ["friendly_name": "Office"]])
        XCTAssertEqual(light.title, "Office")
        XCTAssertEqual(light.entity, "light.office")
        let lock = HomeAssistantMonitor.item(entity: "lock.front", json: ["state": "locked"])
        XCTAssertNil(lock.entity, "locks are never toggled from a tap")
        let sensor = HomeAssistantMonitor.item(entity: "sensor.temp",
                                               json: ["state": "21.5", "attributes": ["unit_of_measurement": "°C"]])
        XCTAssertEqual(sensor.value, "21.5 °C")
    }

    func testGitHubBanners() {
        let failed = GitHubMonitor.banner(for: ["reason": "ci_activity", "subject": ["title": "Build workflow run failed"]])
        XCTAssertEqual(failed?.value, "CI failed")
        XCTAssertEqual(GitHubMonitor.banner(for: ["reason": "review_requested", "subject": ["title": "Add X"]])?.value, "Review")
        XCTAssertNil(GitHubMonitor.banner(for: ["reason": "mention"]))
    }

    func testPluginInterval() {
        XCTAssertEqual(PluginRunner.interval("disk.5m.sh"), 300)
        XCTAssertEqual(PluginRunner.interval("fast.1s.sh"), 5)
        XCTAssertEqual(PluginRunner.interval("plain.sh"), 60)
    }
}
