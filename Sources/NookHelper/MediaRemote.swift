import Foundation

struct MediaRemote {
    typealias GetNowPlayingInfo = @convention(c) (
        DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void
    ) -> Void
    typealias GetIsPlaying = @convention(c) (
        DispatchQueue, @escaping @convention(block) (DarwinBoolean) -> Void
    ) -> Void
    typealias RegisterForNotifications = @convention(c) (DispatchQueue) -> Void
    typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> DarwinBoolean
    typealias SetElapsedTime = @convention(c) (Double) -> Void
    typealias GetPID = @convention(c) (
        DispatchQueue, @escaping @convention(block) (Int32) -> Void
    ) -> Void

    enum Command: UInt32 {
        case play = 0, pause = 1, togglePlayPause = 2, stop = 3, nextTrack = 4, previousTrack = 5
        case toggleShuffle = 6, toggleRepeat = 7
    }

    private static let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

    private let handle: UnsafeMutableRawPointer
    let getNowPlayingInfo: GetNowPlayingInfo
    let getIsPlaying: GetIsPlaying
    let registerForNotifications: RegisterForNotifications
    let sendCommand: SendCommand
    let setElapsedTime: SetElapsedTime?
    let getPID: GetPID?

    static func load() -> MediaRemote? {
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard
            let info = symbol("MRMediaRemoteGetNowPlayingInfo", as: GetNowPlayingInfo.self),
            let playing = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: GetIsPlaying.self),
            let register = symbol("MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterForNotifications.self),
            let send = symbol("MRMediaRemoteSendCommand", as: SendCommand.self)
        else { return nil }
        return MediaRemote(handle: handle, getNowPlayingInfo: info, getIsPlaying: playing,
                           registerForNotifications: register, sendCommand: send,
                           setElapsedTime: symbol("MRMediaRemoteSetElapsedTime", as: SetElapsedTime.self),
                           getPID: symbol("MRMediaRemoteGetNowPlayingApplicationPID", as: GetPID.self))
    }

    func constant(_ name: String) -> String {
        guard let pointer = dlsym(handle, name) else { return name }
        return pointer.assumingMemoryBound(to: CFString.self).pointee as String
    }
}
