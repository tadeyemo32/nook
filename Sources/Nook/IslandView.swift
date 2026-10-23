import SwiftUI

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4)
        let body = CGRect(x: rect.minX + t, y: rect.minY, width: rect.width - 2 * t, height: rect.height)
        let b = min(bottomRadius, body.height / 2, body.width / 2)
        var path = UnevenRoundedRectangle(bottomLeadingRadius: b, bottomTrailingRadius: b, style: .continuous)
            .path(in: body)
        guard t > 0 else { return path }

        let k: CGFloat = 0.5523
        var flares = Path()
        flares.move(to: CGPoint(x: rect.minX, y: rect.minY))
        flares.addLine(to: CGPoint(x: body.minX, y: rect.minY))
        flares.addLine(to: CGPoint(x: body.minX, y: rect.minY + t))
        flares.addCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                        control1: CGPoint(x: body.minX, y: rect.minY + t * (1 - k)),
                        control2: CGPoint(x: rect.minX + t * k, y: rect.minY))
        flares.closeSubpath()
        flares.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        flares.addLine(to: CGPoint(x: body.maxX, y: rect.minY))
        flares.addLine(to: CGPoint(x: body.maxX, y: rect.minY + t))
        flares.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                        control1: CGPoint(x: body.maxX, y: rect.minY + t * (1 - k)),
                        control2: CGPoint(x: rect.maxX - t * k, y: rect.minY))
        flares.closeSubpath()
        path.addPath(flares)
        return path
    }
}

private let motionSpeed = CommandLine.arguments.contains("--slow-animations") ? 0.2 : 1

extension Animation {
    static let islandOpen = Animation.spring(response: 0.51, dampingFraction: 0.82).speed(motionSpeed)
    static let islandClose = Animation.spring(response: 0.44, dampingFraction: 0.8).speed(motionSpeed)
    static let islandHover = Animation.spring(response: 0.3, dampingFraction: 0.75).speed(motionSpeed)
    static let islandFade = Animation.easeOut(duration: 0.22).speed(motionSpeed)
}

private struct BlurScale: ViewModifier {
    let hidden: Bool
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(hidden ? scale : 1, anchor: .top)
            .blur(radius: hidden ? 6 : 0)
            .opacity(hidden ? 0 : 1)
    }
}

extension AnyTransition {
    static var island: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurScale(hidden: true, scale: 0.8), identity: BlurScale(hidden: false, scale: 0.8))
                .animation(.spring(response: 0.42, dampingFraction: 0.86).speed(motionSpeed).delay(0.04 / motionSpeed)),
            removal: .modifier(active: BlurScale(hidden: true, scale: 0.6), identity: BlurScale(hidden: false, scale: 0.6))
                .animation(.easeOut(duration: 0.18).speed(motionSpeed)))
    }
}

private extension View {
    func pinned(to size: CGSize) -> some View {
        frame(width: size.width, height: size.height, alignment: .top)
    }
}

struct IslandView: View {
    let model: IslandModel
    let placement: IslandPlacement
    @AppStorage(Pref.outline.rawValue) private var outline = "none"
    @AppStorage(Pref.simulatedNotch.rawValue) private var simulatedNotch = false

    var body: some View {
        let mode = model.mode(on: placement.displayID)
        let size = model.size(on: placement)
        let isExpanded = mode == .expanded
        let flare: CGFloat = isExpanded ? 16 : 8
        let bottom: CGFloat = isExpanded ? 32 : 11
        let shape = NotchShape(topRadius: flare, bottomRadius: bottom)

        ZStack(alignment: .top) {
            shape.fill(Color.black)
                .animation(.islandFade) { $0.shadow(color: .black.opacity(isExpanded ? 0.4 : 0), radius: 18, y: 8) }
            if let outlineColor {
                shape.stroke(outlineColor, lineWidth: 1)
            }
            content(mode)
                .frame(width: size.width + 2 * flare, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(width: size.width + 2 * flare, height: size.height)
        .animation(.islandFade) { $0.opacity(isVisible(mode) ? 1 : 0) }
        .contentShape(Rectangle())
        .onTapGesture {
            if !model.expanded { model.expanded = true }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addToShelf(urls.filter(\.isFileURL))
            return true
        } isTargeted: { targeted in
            guard targeted else { return }
            model.tab = .shelf
            model.expanded = true
        }
        .animation(isExpanded ? .islandOpen : .islandClose, value: mode)
        .animation(.islandOpen, value: model.activity)
        .animation(.islandHover, value: model.hovering)
        .animation(.islandOpen, value: size)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func isVisible(_ mode: IslandMode) -> Bool {
        let active = placement.displayID == model.activeDisplay
        if (active && model.hovering) || mode == .hud || mode == .expanded { return true }
        if !(model.locked || model.unlocking), model.hiddenDisplays.contains(placement.displayID) { return false }
        return placement.hasNotch || simulatedNotch || mode != .idle
    }

    private var outlineColor: Color? {
        switch outline {
        case "contrast": return .white.opacity(0.28)
        case "color": return Color(model.artworkColor ?? .controlAccentColor).opacity(0.8)
        default: return nil
        }
    }

    @ViewBuilder private func content(_ mode: IslandMode) -> some View {
        let notch = placement.notchSize
        switch mode {
        case .idle:
            Color.clear
        case .compact:
            CompactView(model: model, notch: notch)
                .pinned(to: model.size(for: .compact, notch: notch))
                .id(model.activity)
                .transition(.island)
        case .hud:
            HUDView(model: model, notch: notch)
                .pinned(to: model.size(for: .hud, notch: notch))
                .transition(.island)
        case .expanded:
            ExpandedView(model: model)
                .pinned(to: model.size(for: .expanded, notch: notch))
                .transition(.island)
        }
    }
}

private struct CompactView: View {
    let model: IslandModel
    let notch: CGSize
    @AppStorage(Pref.artworkTint.rawValue) private var artworkTint = true

    var body: some View {
        let inset: CGFloat = 12
        let side = model.compactSideWidth - inset
        HStack(spacing: 0) {
            leading.frame(width: side, alignment: .leading)
            Spacer(minLength: notch.width)
            trailing.frame(width: side, alignment: .trailing)
        }
        .padding(.horizontal, inset)
        .frame(height: notch.height)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
    }

    @ViewBuilder private var leading: some View {
        switch model.activity {
        case .banner:
            if let banner = model.banner {
                HStack(spacing: 6) {
                    if let agent = banner.agent {
                        AgentLogo(agent: agent, size: 18).frame(width: 22)
                    } else {
                        Image(systemName: banner.symbol)
                            .foregroundStyle(Color(banner.tint))
                            .frame(width: 22)
                    }
                    if banner.displaysTitle { Text(banner.title) }
                }
            }
        case .lock:
            Image(systemName: model.locked ? "lock.fill" : "lock.open.fill")
                .contentTransition(.symbolEffect(.replace))
        case .custom:
            if let custom = model.custom {
                HStack(spacing: 6) {
                    if let agent = custom.agent {
                        AgentLogo(agent: agent, size: 18).frame(width: 22)
                    } else {
                        Image(systemName: custom.symbol).foregroundStyle(Color(custom.tint)).frame(width: 22)
                    }
                    Text(custom.title)
                }
            }
        case .task:
            if let task = model.runningTasks.first {
                HStack(spacing: 6) {
                    AgentLogo(agent: task.agent, size: 18).frame(width: 22)
                    Text(model.taskTitle)
                }
            }
        case .timer:
            if let timer = model.timer {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ProgressRing(fraction: timer.total > 0 ? timer.remaining(at: context.date) / timer.total : 0,
                                 color: .orange)
                }
            }
        case .download:
            ProgressRing(fraction: model.download?.progress, color: .blue, symbol: "arrow.down")
        case .nowPlaying:
            ArtworkView(image: model.artwork, size: min(20, notch.height - 8), radius: 6)
                .onTapGesture { model.nowPlaying.map(openSourceApp) }
        case .privacy:
            if model.cameraInUse {
                Image(systemName: "video.fill").foregroundStyle(.green)
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch model.activity {
        case .banner:
            if let value = model.banner?.value {
                Text(value).foregroundStyle(Color(model.banner?.tint ?? .white)).monospacedDigit()
            }
        case .lock:
            EmptyView()
        case .custom:
            if let badge = model.custom?.badge {
                Image(systemName: badge)
                    .foregroundStyle(Color(model.custom?.tint ?? .white))
                    .symbolEffect(.pulse)
            } else if let progress = model.custom?.progress {
                ProgressRing(fraction: progress, color: Color(model.custom?.tint ?? .white))
            } else {
                ProgressView().controlSize(.mini)
            }
        case .task:
            ProgressView().controlSize(.mini)
        case .timer:
            if let timer = model.timer {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(formatTime(timer.remaining(at: context.date)))
                        .foregroundStyle(timer.pausedRemaining == nil ? .orange : .orange.opacity(0.5))
                        .monospacedDigit()
                }
            }
        case .download:
            if let progress = model.download?.progress {
                Text("\(Int(progress * 100))%").foregroundStyle(.blue).monospacedDigit()
            } else {
                ProgressView().controlSize(.mini)
            }
        case .nowPlaying:
            Waveform(playing: true, levels: model.audioLevels,
                     color: artworkTint ? model.artworkColor.map(Color.init) ?? .white : .white)
        case .privacy:
            if model.micInUse {
                Image(systemName: "mic.fill").foregroundStyle(.orange)
            }
        case nil:
            EmptyView()
        }
    }
}

struct ProgressRing: View {
    let fraction: Double?
    var color: Color
    var symbol: String? = nil
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 2.5)
            if let fraction {
                Circle()
                    .trim(from: 0, to: min(1, max(0, fraction)))
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: fraction)
            }
            if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct HUDView: View {
    let model: IslandModel
    let notch: CGSize
    @AppStorage(Pref.hudShowsPercent.rawValue) private var showsPercent = false

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, alignment: .leading)
            Spacer(minLength: notch.width)
            if showsPercent {
                Text("\(Int((level * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText(value: Double(level)))
                    .frame(width: 52, alignment: .trailing)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white).frame(width: geo.size.width * CGFloat(level))
                    }
                }
                .frame(width: 52, height: 5)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: notch.height)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: level)
    }

    private var level: Float {
        switch model.hud {
        case let .volume(level, muted): return muted ? 0 : level
        case let .brightness(level): return level
        case nil: return 0
        }
    }

    private var symbol: String {
        if case let .brightness(level) = model.hud {
            return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
        guard case let .volume(level, muted) = model.hud, !muted, level > 0 else {
            return "speaker.slash.fill"
        }
        if let device = SystemVolume.outputSymbol() { return device }
        switch level {
        case ..<0.33: return "speaker.wave.1.fill"
        case ..<0.66: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}
