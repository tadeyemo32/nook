import Foundation
import NookXPC

final class HelperService: NSObject, NookHelperProtocol {
    private weak var connection: NSXPCConnection?
    private let remote = MediaRemote.load()
    private var observers: [NSObjectProtocol] = []
    private var lastSent: Data?
    private var sentOnce = false

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func start(reply: @escaping (Bool) -> Void) {
        guard let remote else {
            reply(false)
            return
        }
        DispatchQueue.main.async { [self] in
            guard observers.isEmpty else { return refresh() }
            remote.registerForNotifications(.main)
            let names = [
                "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(
                    forName: Notification.Name(remote.constant(name)), object: nil, queue: .main
                ) { [weak self] _ in self?.refresh() })
            }
            refresh()
        }
        reply(true)
    }

    func send(command: Int, reply: @escaping (Bool) -> Void) {
        guard let remote, let command = HelperCommand(rawValue: command) else {
            reply(false)
            return
        }
        let mapped: MediaRemote.Command
        switch command {
        case .playPause: mapped = .togglePlayPause
        case .next: mapped = .nextTrack
        case .previous: mapped = .previousTrack
        case .toggleShuffle: mapped = .toggleShuffle
        case .toggleRepeat: mapped = .toggleRepeat
        }
        reply(remote.sendCommand(mapped.rawValue, nil).boolValue)
    }

    func seek(to seconds: Double, reply: @escaping (Bool) -> Void) {
        guard let setElapsedTime = remote?.setElapsedTime else {
            reply(false)
            return
        }
        setElapsedTime(max(0, seconds))
        reply(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    func stop() {
        DispatchQueue.main.async { [self] in
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }

    private func refresh() {
        guard let remote else { return }
        remote.getNowPlayingInfo(.main) { [weak self] info in
            remote.getIsPlaying(.main) { playing in
                guard let getPID = remote.getPID else {
                    self?.publish(info as? [String: Any], isPlaying: playing.boolValue, pid: nil)
                    return
                }
                getPID(.main) { pid in
                    self?.publish(info as? [String: Any], isPlaying: playing.boolValue, pid: pid > 0 ? pid : nil)
                }
            }
        }
    }

    private func publish(_ info: [String: Any]?, isPlaying: Bool, pid: Int32?) {
        guard let remote else { return }
        func value<T>(_ key: String) -> T? {
            info?[remote.constant("kMRMediaRemoteNowPlayingInfo" + key)] as? T
        }

        var data: Data?
        if let title: String = value("Title"), !title.isEmpty {
            let rate: Double = value("PlaybackRate") ?? 0
            data = NowPlayingPayload(
                title: title,
                artist: value("Artist") ?? "",
                album: value("Album") ?? "",
                duration: value("Duration") ?? 0,
                elapsed: value("ElapsedTime") ?? 0,
                timestamp: value("Timestamp") ?? Date(),
                isPlaying: isPlaying || rate > 0,
                artwork: value("ArtworkData"),
                shuffleMode: value("ShuffleMode"),
                repeatMode: value("RepeatMode"),
                pid: pid
            ).encoded()
        }

        guard !sentOnce || data != lastSent else { return }
        sentOnce = true
        lastSent = data
        (connection?.remoteObjectProxy as? NookHelperClientProtocol)?.nowPlayingChanged(data)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: NookHelperProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: NookHelperClientProtocol.self)
        let service = HelperService(connection: connection)
        connection.exportedObject = service
        connection.invalidationHandler = { service.stop() }
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
