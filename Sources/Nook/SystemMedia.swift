import AppKit
import NookXPC

final class SystemMediaClient: NSObject, NookHelperClientProtocol {
    var onUpdate: ((NowPlaying?) -> Void)?
    var onArtwork: ((NSImage?) -> Void)?

    private var connection: NSXPCConnection?
    private var lastTrackKey = ""
    private var lastArtwork: Data?

    func start() {
        let connection = NSXPCConnection(serviceName: nookHelperServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: NookHelperProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: NookHelperClientProtocol.self)
        connection.exportedObject = self
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.apply(nil)
                self?.handshake()
            }
        }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.connection = nil
                self?.apply(nil)
            }
        }
        connection.resume()
        self.connection = connection
        handshake()
    }

    func send(_ command: MediaCommand) {
        let mapped: HelperCommand
        switch command {
        case .playPause: mapped = .playPause
        case .next: mapped = .next
        case .previous: mapped = .previous
        case .toggleShuffle: mapped = .toggleShuffle
        case .toggleRepeat: mapped = .toggleRepeat
        case let .seek(seconds):
            proxy()?.seek(to: seconds) { _ in }
            return
        }
        proxy()?.send(command: mapped.rawValue) { _ in }
    }

    func nowPlayingChanged(_ payload: Data?) {
        let decoded = payload.flatMap(NowPlayingPayload.decode)
        DispatchQueue.main.async { self.apply(decoded) }
    }

    private static func repeatMode(_ value: Int) -> RepeatMode? {
        switch value {
        case 1: return .off
        case 2: return .one
        case 3: return .all
        default: return nil
        }
    }

    private func proxy() -> NookHelperProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { _ in } as? NookHelperProtocol
    }

    private func handshake() {
        proxy()?.start { _ in }
    }

    private func apply(_ payload: NowPlayingPayload?) {
        guard let payload else {
            lastTrackKey = ""
            lastArtwork = nil
            onUpdate?(nil)
            onArtwork?(nil)
            return
        }

        let info = NowPlaying(
            source: .system,
            title: payload.title,
            artist: payload.artist,
            album: payload.album,
            isPlaying: payload.isPlaying,
            position: payload.elapsed,
            duration: payload.duration,
            fetchedAt: payload.timestamp,
            artworkURL: nil,
            shuffle: payload.shuffleMode.flatMap { $0 > 0 ? $0 > 1 : nil },
            repeatMode: payload.repeatMode.flatMap(Self.repeatMode),
            appBundleID: payload.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        )
        onUpdate?(info)

        guard info.trackKey != lastTrackKey || payload.artwork != lastArtwork else { return }
        lastTrackKey = info.trackKey
        lastArtwork = payload.artwork
        onArtwork?(payload.artwork.flatMap(NSImage.init(data:)))
    }
}

final class MediaRouter {
    var onUpdate: ((NowPlaying?) -> Void)?
    var onArtwork: ((NSImage?) -> Void)?

    private let system = SystemMediaClient()
    private let scripted = MediaController()

    private var systemInfo: NowPlaying?
    private var systemArtwork: NSImage?
    private var scriptedInfo: NowPlaying?
    private var scriptedArtwork: NSImage?
    private var publishedArtwork: NSImage?

    func start() {
        system.onUpdate = { [weak self] info in
            guard let self else { return }
            systemInfo = info
            scripted.isSuspended = info != nil
            publish()
        }
        system.onArtwork = { [weak self] image in
            self?.systemArtwork = image
            self?.publish()
        }
        scripted.onUpdate = { [weak self] info in
            self?.scriptedInfo = info
            self?.publish()
        }
        scripted.onArtwork = { [weak self] image in
            self?.scriptedArtwork = image
            self?.publish()
        }
        system.start()
        scripted.start()
    }

    func send(_ command: MediaCommand) {
        if systemInfo != nil {
            system.send(command)
        } else {
            scripted.send(command)
        }
    }

    private func publish() {
        let useSystem = systemInfo != nil
        onUpdate?(useSystem ? systemInfo : scriptedInfo)

        let artwork = useSystem ? systemArtwork : scriptedArtwork
        guard artwork !== publishedArtwork else { return }
        publishedArtwork = artwork
        onArtwork?(artwork)
    }
}
