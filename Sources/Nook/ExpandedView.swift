import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExpandedView: View {
    let model: IslandModel
    @AppStorage(Pref.agentChipStyle.rawValue) private var chipStyle = "used"

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                if model.visibleTabs.count > 1 { tabBar }
                Spacer(minLength: model.notchSize.width)
                HStack(spacing: 12) {
                    if model.showsAgentChips {
                        ForEach(model.agents) { usage in
                            AgentChip(usage: usage, style: chipStyle)
                                .onTapGesture { if model.visibleTabs.contains(.agents) { model.tab = .agents } }
                        }
                    }
                    if let weather = model.weather {
                        Label("\(Int(weather.temperature.rounded()))°", systemImage: weather.symbol)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            .frame(height: model.notchSize.height)

            Group {
                switch model.visibleTabs.contains(model.tab) ? model.tab : .home {
                case .home: HomeTab(model: model)
                case .shelf: ShelfTab(model: model)
                case .widgets: WidgetsTab(model: model)
                case .clipboard: ClipboardTab(model: model)
                case .stats: StatsTab(model: model)
                case .agents: AgentsTab(model: model)
                case .timer: TimerTab(model: model)
                case .mirror: MirrorView().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .animation(.easeInOut(duration: 0.2), value: model.tab)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(model.visibleTabs) { tab in
                Button { model.tab = tab } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 20)
                        .background(Capsule().fill(.white.opacity(model.tab == tab ? 0.14 : 0)))
                        .foregroundStyle(.white.opacity(model.tab == tab ? 0.95 : 0.4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .help(tab.rawValue.capitalized)
            }
        }
    }
}

private struct HomeTab: View {
    let model: IslandModel

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            if let info = model.nowPlaying {
                MediaPlayerView(model: model, info: info)
            } else {
                ClockView()
            }
            if model.showsCalendar {
                Divider().overlay(.white.opacity(0.12))
                CalendarColumn(model: model).frame(width: 160)
            }
        }
    }
}

private struct ClockView: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 2) {
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Nothing playing")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

private struct CalendarColumn: View {
    let model: IslandModel
    @AppStorage(Pref.showCalendar.rawValue) private var showsEvents = false

    var body: some View {
        let events = showsEvents ? model.events : []
        let reminders = model.reminders.prefix(events.isEmpty ? 3 : 2)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Date.now, format: .dateTime.weekday(.abbreviated))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.red)
                    .textCase(.uppercase)
                Text(Date.now, format: .dateTime.day())
                    .font(.system(size: 20, weight: .semibold))
            }
            if showsEvents, events.isEmpty, reminders.isEmpty {
                Text("No more events today")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            ForEach(events.prefix(reminders.isEmpty ? 3 : 2)) { event in
                HStack(alignment: .top, spacing: 6) {
                    Capsule().fill(Color(event.color)).frame(width: 3, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(timeText(event)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength: 0)
                    if let url = event.meetingURL {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Image(systemName: "video.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 18)
                                .background(Capsule().fill(event.id == model.nextMeeting?.id ? Color.green : .white.opacity(0.15)))
                        }
                        .buttonStyle(PressableButtonStyle())
                        .help("Join")
                    }
                }
            }
            ForEach(reminders) { reminder in
                HStack(spacing: 6) {
                    Button { model.onCompleteReminder?(reminder.id) } label: {
                        Image(systemName: "circle").font(.system(size: 11)).foregroundStyle(Color(reminder.color))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Mark as done")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(reminder.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        if let due = reminder.due, due < Date() {
                            Text("Overdue").font(.system(size: 10)).foregroundStyle(.red.opacity(0.8))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        }
    }

    private func timeText(_ event: CalendarItem) -> String {
        if event.isAllDay { return "All day" }
        let now = Date()
        if event.start <= now { return "Now · until \(event.end.formatted(date: .omitted, time: .shortened))" }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        if minutes < 60 { return "In \(max(1, minutes)) min" }
        let day = Calendar.current.isDateInToday(event.start) ? "" : "Tomorrow "
        return day + event.start.formatted(date: .omitted, time: .shortened)
    }
}

private struct ShelfTab: View {
    let model: IslandModel

    var body: some View {
        if model.shelf.isEmpty {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 22))
                        Text("Drop files here to keep them handy").font(.system(size: 12))
                    }
                    .foregroundStyle(.white.opacity(0.5))
                }
        } else {
            HStack(alignment: .top, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.shelf, id: \.self) { url in
                            ShelfItem(model: model, url: url)
                        }
                    }
                }
                VStack(spacing: 8) {
                    Button { share(model.shelf, via: .sendViaAirDrop) } label: {
                        Label("AirDrop", systemImage: "dot.radiowaves.left.and.right").labelStyle(.iconOnly)
                    }
                    .help("AirDrop everything")
                    Button { model.clearShelf() } label: {
                        Label("Clear", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                    }
                    .help("Clear the shelf")
                }
                .font(.system(size: 16))
                .buttonStyle(PressableButtonStyle())
            }
        }
    }
}

private struct ShelfItem: View {
    let model: IslandModel
    let url: URL
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 48, height: 48)
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 76)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hovering ? 0.12 : 0)))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help(url.path)
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("AirDrop") { share([url], via: .sendViaAirDrop) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
            Divider()
            Button("Remove from Shelf") { model.removeFromShelf(url) }
        }
    }
}

private func share(_ urls: [URL], via name: NSSharingService.Name) {
    NSSharingService(named: name)?.perform(withItems: urls)
}

private struct WidgetsTab: View {
    let model: IslandModel

    var body: some View {
        if model.widgets.isEmpty && model.homeWidgets.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 20))
                Text("Add plugin scripts or Home Assistant in Settings → Connectors")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.white.opacity(0.5))
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(model.homeWidgets + model.widgets) { item in
                        WidgetTile(model: model, item: item)
                    }
                }
            }
        }
    }
}

private struct WidgetTile: View {
    let model: IslandModel
    let item: PluginItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(item.tint))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let value = item.value {
                        Text(value).font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                if let progress = item.progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15))
                            Capsule().fill(Color(item.tint)).frame(width: max(4, geo.size.width * progress))
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovering ? 0.1 : 0.06)))
        .onHover { hovering = $0 }
        .onTapGesture {
            if let entity = item.entity { model.onHomeToggle?(entity) } else { item.url.map { NSWorkspace.shared.open($0) } }
        }
    }
}

private struct ClipboardTab: View {
    let model: IslandModel
    @AppStorage(Pref.clipboardHistory.rawValue) private var enabled = false

    var body: some View {
        if !enabled {
            VStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 22))
                Text("Keep a history of the text you copy. It stays in memory on this Mac and skips passwords.")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.6))
                Button("Turn On Clipboard History") { enabled = true }
            }
            .frame(maxWidth: 360)
        } else if model.clipboard.isEmpty {
            Text("Copy some text and it shows up here")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
        } else {
            HStack(alignment: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.clipboard, id: \.self) { text in
                            ClipboardRow(model: model, text: text)
                        }
                    }
                }
                Button { model.clipboard.removeAll() } label: {
                    Image(systemName: "trash.fill")
                }
                .buttonStyle(PressableButtonStyle())
                .help("Clear history")
            }
        }
    }
}

private struct ClipboardRow: View {
    let model: IslandModel
    let text: String
    @State private var hovering = false

    var body: some View {
        Text(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
            .font(.system(size: 12))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hovering ? 0.12 : 0.04)))
            .onHover { hovering = $0 }
            .contentShape(Rectangle())
            .onTapGesture {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                model.show(Banner(symbol: "doc.on.clipboard.fill", title: "Copied", tint: .systemBlue, duration: 1.5))
            }
    }
}

private struct StatsTab: View {
    let model: IslandModel

    var body: some View {
        if let stats = model.stats {
            HStack(spacing: 18) {
                StatRing(title: "CPU", fraction: stats.cpu, color: .blue)
                if let gpu = stats.gpu { StatRing(title: "GPU", fraction: gpu, color: .purple) }
                StatRing(title: "Memory", fraction: stats.memoryUsed / max(1, stats.memoryTotal), color: .green,
                         detail: Self.bytes(stats.memoryUsed))
                StatRing(title: "Disk", fraction: 1 - stats.diskFree / max(1, stats.diskTotal), color: .orange,
                         detail: Self.bytes(stats.diskFree) + " free")
                VStack(alignment: .leading, spacing: 6) {
                    Label(Self.bytes(stats.networkIn) + "/s", systemImage: "arrow.down")
                    Label(Self.bytes(stats.networkOut) + "/s", systemImage: "arrow.up")
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .frame(width: 110, alignment: .leading)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}

private struct StatRing: View {
    let title: String
    let fraction: Double
    let color: Color
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(color.opacity(0.2), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: min(1, max(0, fraction)))
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: fraction)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            .frame(width: 56, height: 56)
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(detail ?? " ").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
    }
}

private struct TimerTab: View {
    let model: IslandModel
    @State private var customMinutes = 20

    var body: some View {
        if let timer = model.timer {
            HStack(spacing: 24) {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let remaining = timer.remaining(at: context.date)
                    ZStack {
                        ProgressRing(fraction: timer.total > 0 ? remaining / timer.total : 0, color: .orange, size: 96)
                        Text(formatTime(remaining))
                            .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Button(timer.pausedRemaining == nil ? "Pause" : "Resume") { model.toggleTimerPause() }
                    Button("Add 1 Minute") { model.startTimer(timer.remaining(at: Date()) + 60) }
                    Button("Cancel", role: .destructive) { model.cancelTimer() }
                }
                .controlSize(.regular)
            }
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    ForEach([1, 3, 5, 10, 15, 25, 45, 60], id: \.self) { minutes in
                        Button { model.startTimer(TimeInterval(minutes * 60)) } label: {
                            Text("\(minutes)m")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 44, height: 32)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.1)))
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                HStack(spacing: 10) {
                    Stepper("\(customMinutes) minutes", value: $customMinutes, in: 1...600)
                        .font(.system(size: 12))
                    Button("Start") { model.startTimer(TimeInterval(customMinutes * 60)) }
                }
            }
        }
    }
}

struct AgentLogo: View {
    let agent: AgentUsage.Agent
    var size: CGFloat = 16

    var body: some View {
        if let icon = agent.appIcon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: agent.symbol)
                .font(.system(size: size * 0.75, weight: .bold))
                .foregroundStyle(agent.tint == .white ? .primary : Color(agent.tint))
                .frame(width: size, height: size)
        }
    }
}

private func usageColor(_ used: Double) -> Color {
    used >= 90 ? .red : used >= 80 ? .orange : .white
}

private struct AgentChip: View {
    let usage: AgentUsage
    let style: String

    var body: some View {
        HStack(spacing: 4) {
            AgentLogo(agent: usage.agent, size: 15)
            if let window = usage.busiest {
                switch style {
                case "battery":
                    UsageBattery(left: 1 - window.used / 100, color: usageColor(window.used))
                case "left":
                    Text("\(Int((100 - window.used).rounded()))%")
                default:
                    Text("\(Int(window.used.rounded()))%")
                }
            }
        }
        .foregroundStyle(usage.busiest.map { usageColor($0.used) } ?? .white)
        .opacity(0.85)
        .help(usage.windows.map {
            "\(usage.agent.name) \($0.name.lowercased()) limit: \(Int($0.used))% used, resets \(resetText($0.resets))"
        }.joined(separator: "\n"))
    }
}

private struct UsageBattery: View {
    let left: Double
    let color: Color

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.white.opacity(0.45), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(color)
                    .frame(width: max(1.5, 17 * min(1, max(0, left))), height: 6)
                    .padding(.leading, 2)
            }
            .frame(width: 21, height: 10)
            Capsule().fill(.white.opacity(0.45)).frame(width: 1.5, height: 4)
        }
    }
}

private func resetText(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

private struct AgentsTab: View {
    let model: IslandModel

    var body: some View {
        if model.agents.isEmpty && model.tasks.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 20))
                Text("Connect Claude Code or use Codex, and their usage shows up here")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.white.opacity(0.5))
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(model.tasks) { task in
                        TaskRow(model: model, task: task)
                    }
                    if !model.agents.isEmpty {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(model.agents) { usage in
                                AgentCard(usage: usage)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct TaskRow: View {
    let model: IslandModel
    let task: AgentTask
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            AgentLogo(agent: task.agent, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(task.project).font(.system(size: 12, weight: .semibold))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(status(at: context.date))
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(color)
                    }
                }
                Text(task.summary ?? task.prompt)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if task.status == .running {
                button("stop.circle.fill", "Stop", .stop)
            } else {
                if task.session != nil { button("terminal.fill", "Continue in Terminal", .openInTerminal) }
                button("xmark.circle.fill", "Remove", .remove)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovering ? 0.1 : 0.06)))
        .onHover { hovering = $0 }
        .help(task.summary ?? task.prompt)
    }

    private func button(_ symbol: String, _ help: String, _ action: TaskAction) -> some View {
        Button { model.onTask?(task.id, action) } label: { Image(systemName: symbol).font(.system(size: 15)) }
            .buttonStyle(PressableButtonStyle())
            .help(help)
    }

    private var color: Color {
        switch task.status {
        case .running: return .white.opacity(0.6)
        case .done: return .green
        case .failed: return .red
        case .stopped: return .orange
        }
    }

    private func status(at date: Date) -> String {
        let elapsed = (task.finished ?? date).timeIntervalSince(task.started)
        switch task.status {
        case .running: return "Working · \(formatTime(elapsed))"
        case .done: return "Done in \(formatTime(elapsed))"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
}

private struct AgentCard: View {
    let usage: AgentUsage
    @AppStorage(Pref.agentShowModel.rawValue) private var showModel = true
    @AppStorage(Pref.agentShowContext.rawValue) private var showContext = true
    @AppStorage(Pref.agentShowCost.rawValue) private var showCost = false
    @AppStorage(Pref.agentShowLines.rawValue) private var showLines = false
    @AppStorage(Pref.agentShowPlan.rawValue) private var showPlan = true
    @AppStorage(Pref.agentShowResets.rawValue) private var showResets = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                AgentLogo(agent: usage.agent, size: 18)
                Text(usage.agent.name).font(.system(size: 13, weight: .semibold))
                if showModel, let model = usage.model {
                    Text([model, usage.effort].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 4)
                if showPlan, let plan = usage.plan {
                    Text(plan)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
            }
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)

            ForEach(usage.windows, id: \.name) { window in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(window.name).frame(width: 46, alignment: .leading)
                        UsageBar(fraction: window.used / 100, color: usageColor(window.used))
                        Text("\(Int(window.used.rounded()))%").frame(width: 32, alignment: .trailing)
                    }
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    if showResets {
                        Text("Resets \(resetText(window.resets))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.leading, 54)
                    }
                }
            }

            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
    }

    private var details: [String] {
        var parts: [String] = []
        if showContext, let context = usage.context { parts.append("Context \(Int(context.rounded()))%") }
        if showCost, let cost = usage.cost { parts.append(cost.formatted(.currency(code: "USD"))) }
        if showLines, let added = usage.linesAdded, let removed = usage.linesRemoved {
            parts.append("+\(added) −\(removed)")
        }
        if let project = usage.project { parts.append(project) }
        return parts
    }
}

private struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(color).frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
        .animation(.easeInOut(duration: 0.4), value: fraction)
    }
}
