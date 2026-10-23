import AppKit
import SwiftUI

struct MediaPlayerView: View {
    let model: IslandModel
    let info: NowPlaying
    var showsOutputPicker = true
    @AppStorage(Pref.artworkTint.rawValue) private var artworkTint = true
    @AppStorage(Pref.dimArtworkOnPause.rawValue) private var dimOnPause = true

    var body: some View {
        let tint = artworkTint ? model.artworkColor.map(Color.init) ?? .white : .white
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { openSourceApp(info) } label: {
                    ArtworkView(image: model.artwork, size: 56, radius: 12)
                        .opacity(dimOnPause && !info.isPlaying ? 0.6 : 1)
                        .scaleEffect(info.isPlaying ? 1 : 0.92)
                        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: info.isPlaying)
                }
                .buttonStyle(PressableButtonStyle())
                .help("Open \(info.appBundleID.flatMap(appName) ?? "the player")")

                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: info.title, font: .system(size: 13.5, weight: .semibold), height: 17)
                        .id(info.title)
                    Text(info.artist)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                    if let lyrics = model.lyrics {
                        TimelineView(.periodic(from: .now, by: 0.25)) { context in
                            Text(LyricsService.line(in: lyrics, at: info.elapsed(at: context.date)) ?? "♪")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(tint.opacity(0.85))
                                .lineLimit(1)
                                .contentTransition(.opacity)
                        }
                    }
                }
                Spacer(minLength: 8)
                if showsOutputPicker { OutputPicker() }
                Waveform(playing: info.isPlaying, levels: model.audioLevels, color: tint, seed: info.title)
                    .frame(width: 20)
            }
            ProgressRow(model: model, info: info, tint: tint)
                .padding(.top, 16)
            MediaControls(model: model, info: info, tint: tint)
                .padding(.top, 8)
        }
    }
}

private struct OutputPicker: View {
    var body: some View {
        Menu {
            let current = SystemVolume.defaultOutputDevice
            ForEach(SystemVolume.outputs()) { output in
                Button {
                    SystemVolume.setDefaultOutput(output.id)
                } label: {
                    if output.id == current {
                        Label(output.name, systemImage: "checkmark")
                    } else {
                        Text(output.name)
                    }
                }
            }
        } label: {
            Image(systemName: SystemVolume.outputSymbol() ?? "airplayaudio")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(0.6)
        .help("Output")
    }
}

func openSourceApp(_ info: NowPlaying) {
    guard let id = info.appBundleID ?? (info.source == .system ? nil : info.source.bundleID),
          let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
}

private func appName(_ bundleID: String) -> String? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
}

func formatTime(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

struct ProgressRow: View {
    let model: IslandModel
    let info: NowPlaying
    var tint: Color = .white

    @State private var dragFraction: Double?
    @State private var seeked: (fraction: Double, at: Date)?

    var body: some View {
        if info.duration <= 0 {
            HStack {
                Text("LIVE")
                    .font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red))
                Spacer()
            }
            .frame(height: 12)
        } else {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let fraction = displayedFraction(at: context.date)
                HStack(spacing: 8) {
                    Text(formatTime(fraction * info.duration))
                        .frame(minWidth: 30, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.2))
                            Capsule().fill(tint).frame(width: max(6, geo.size.width * fraction))
                        }
                        .frame(height: dragFraction == nil ? 6 : 9)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { dragFraction = Self.clamp($0.location.x / geo.size.width) }
                            .onEnded { value in
                                let target = Self.clamp(value.location.x / geo.size.width)
                                dragFraction = nil
                                seeked = (target, Date())
                                model.send(.seek(target * info.duration))
                            })
                    }
                    .frame(height: 12)
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragFraction == nil)
                    Text("-" + formatTime(info.duration * (1 - fraction)))
                        .frame(minWidth: 30, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func displayedFraction(at date: Date) -> Double {
        if let dragFraction { return dragFraction }
        if let seeked, date.timeIntervalSince(seeked.at) < 1.5 { return seeked.fraction }
        return info.duration > 0 ? min(1, info.elapsed(at: date) / info.duration) : 0
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}

struct MediaControls: View {
    let model: IslandModel
    let info: NowPlaying
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 8) {
            mode("shuffle", active: info.shuffle == true, .toggleShuffle)
            control("backward.fill", size: 19, .previous)
            control(info.isPlaying ? "pause.fill" : "play.fill", size: 25, .playPause)
            control("forward.fill", size: 19, .next)
            mode(info.repeatMode == .one ? "repeat.1" : "repeat", active: (info.repeatMode ?? .off) != .off, .toggleRepeat)
        }
    }

    private func control(_ symbol: String, size: CGFloat, _ command: MediaCommand) -> some View {
        Button { model.send(command) } label: {
            Image(systemName: symbol)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 48, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(ControlButtonStyle())
    }

    private func mode(_ symbol: String, active: Bool, _ command: MediaCommand) -> some View {
        Button { model.send(command) } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? tint : .white.opacity(0.4))
                .frame(width: 48, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(ControlButtonStyle())
    }
}

private struct ControlButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(configuration.isPressed ? 0.16 : hovering ? 0.08 : 0)))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note").font(.system(size: size * 0.45))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct Waveform: View {
    let playing: Bool
    let levels: [Float]?
    var color: Color = .white
    var seed = ""

    var body: some View {
        Group {
            if playing, let levels, levels.count >= 4 {
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule().frame(width: 3, height: 3 + 13 * CGFloat(levels[i]))
                    }
                }
                .frame(height: 16)
                .animation(.linear(duration: 1.0 / 30), value: levels)
            } else {
                placeholder
            }
        }
        .foregroundStyle(color)
    }

    private var placeholder: some View {
        let phase = Double(seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }) / 997
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate + phase
            let beat = 0.75 + 0.25 * sin(t * 7.3)
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let k = Double(i)
                    let wave = (sin(t * (5.1 + k * 1.7) + k * 2.1) + sin(t * (8.3 - k) + k) * 0.6
                        + sin(t * (2.3 + k * 0.9) + phase)) / 2.6
                    Capsule().frame(width: 3, height: playing ? 3 + 13 * beat * (0.5 + 0.5 * wave) : 3)
                }
            }
            .frame(height: 16)
        }
    }
}

struct MarqueeText: View {
    let text: String
    let font: Font
    let height: CGFloat

    @State private var textWidth: CGFloat = 0
    @State private var start = Date()
    private let gap: CGFloat = 36
    private let speed: Double = 28
    private let pause: Double = 2.5

    var body: some View {
        GeometryReader { geo in
            let overflows = textWidth > geo.size.width + 1
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !overflows)) { context in
                HStack(spacing: gap) {
                    Text(text)
                    if overflows { Text(text) }
                }
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .offset(x: overflows ? offset(at: context.date) : 0)
            }
            .frame(width: geo.size.width, alignment: .leading)
            .mask(fade(overflows))
        }
        .frame(height: height)
        .clipped()
        .background(
            Text(text).font(font).lineLimit(1).fixedSize().hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
        )
    }

    private func offset(at date: Date) -> CGFloat {
        let distance = Double(textWidth + gap)
        let cycle = pause + distance / speed
        let t = date.timeIntervalSince(start).truncatingRemainder(dividingBy: cycle)
        return t < pause ? 0 : -CGFloat((t - pause) * speed)
    }

    private func fade(_ on: Bool) -> some View {
        LinearGradient(stops: [
            .init(color: on ? .clear : .black, location: 0),
            .init(color: .black, location: 0.06),
            .init(color: .black, location: 0.94),
            .init(color: on ? .clear : .black, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }
}

struct LockScreenView: View {
    let model: IslandModel
    @AppStorage(Pref.lockScreenWidgets.rawValue) private var showWidgets = true
    @AppStorage(Pref.lockHideWhenPaused.rawValue) private var hideWhenPaused = false

    static let cardSize = CGSize(width: 328, height: 174)

    var body: some View {
        VStack(spacing: 14) {
            if showWidgets { widgets }
            if let info = model.nowPlaying, info.isPlaying || !hideWhenPaused {
                MediaPlayerView(model: model, info: info, showsOutputPicker: false)
                    .padding(17)
                    .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                    .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.black.opacity(0.3)))
                    .glassCard(cornerRadius: 28)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.islandOpen, value: model.nowPlaying.map { $0.isPlaying || !hideWhenPaused } ?? false)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var widgets: some View {
        HStack(spacing: 16) {
            if let weather = model.weather {
                Label("\(Int(weather.temperature.rounded()))°", systemImage: weather.symbol)
            }
            if let battery = model.battery {
                Label("\(Int((battery.level * 100).rounded()))%",
                      systemImage: battery.isPluggedIn ? "battery.100.bolt" : BatterySymbol.name(battery.level))
            }
            if let timer = model.timer {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label(formatTime(timer.remaining(at: context.date)), systemImage: "timer")
                }
            }
        }
        .font(.system(size: 14, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white.opacity(0.9))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 1)
    }
}

enum BatterySymbol {
    static func name(_ level: Double) -> String {
        switch level {
        case ..<0.13: return "battery.0"
        case ..<0.38: return "battery.25"
        case ..<0.63: return "battery.50"
        case ..<0.88: return "battery.75"
        default: return "battery.100"
        }
    }
}

extension View {
    @ViewBuilder func glassCard(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
        #else
        background(.ultraThinMaterial, in: shape)
        #endif
    }
}
