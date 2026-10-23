import Foundation

public let nookHelperServiceName = "com.apple.controlcenter.NookHelper"

@objc public protocol NookHelperProtocol {
    func start(reply: @escaping (Bool) -> Void)
    func send(command: Int, reply: @escaping (Bool) -> Void)
    func seek(to seconds: Double, reply: @escaping (Bool) -> Void)
}

@objc public protocol NookHelperClientProtocol {
    func nowPlayingChanged(_ payload: Data?)
}

public enum HelperCommand: Int {
    case playPause, next, previous, toggleShuffle, toggleRepeat
}

public struct NowPlayingPayload: Codable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double
    public var elapsed: Double
    public var timestamp: Date
    public var isPlaying: Bool
    public var artwork: Data?
    public var shuffleMode: Int?
    public var repeatMode: Int?
    public var pid: Int32?

    public init(title: String, artist: String, album: String, duration: Double,
                elapsed: Double, timestamp: Date, isPlaying: Bool, artwork: Data?,
                shuffleMode: Int? = nil, repeatMode: Int? = nil, pid: Int32? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.timestamp = timestamp
        self.isPlaying = isPlaying
        self.artwork = artwork
        self.shuffleMode = shuffleMode
        self.repeatMode = repeatMode
        self.pid = pid
    }

    public func encoded() -> Data? {
        try? PropertyListEncoder().encode(self)
    }

    public static func decode(_ data: Data) -> NowPlayingPayload? {
        try? PropertyListDecoder().decode(NowPlayingPayload.self, from: data)
    }
}
