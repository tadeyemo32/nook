import AppKit

final class LockScreenSpace {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias RemoveWindows = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private static let lockScreenLevel: Int32 = 400

    private let connection: Int32
    private let space: Int32
    private let addWindows: AddWindows
    private let removeWindows: RemoveWindows

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY),
              let mainConnectionID = Self.load(handle, "SLSMainConnectionID", as: MainConnectionID.self),
              let spaceCreate = Self.load(handle, "SLSSpaceCreate", as: SpaceCreate.self),
              let setLevel = Self.load(handle, "SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
              let showSpaces = Self.load(handle, "SLSShowSpaces", as: ShowSpaces.self),
              let add = Self.load(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindows.self),
              let remove = Self.load(handle, "SLSRemoveWindowsFromSpaces", as: RemoveWindows.self)
        else { return nil }

        connection = mainConnectionID()
        space = spaceCreate(connection, 1, 0)
        addWindows = add
        removeWindows = remove
        _ = setLevel(connection, space, Self.lockScreenLevel)
        _ = showSpaces(connection, [space] as CFArray)
    }

    func add(_ window: NSWindow) {
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
    }

    func remove(_ window: NSWindow) {
        _ = removeWindows(connection, [window.windowNumber] as CFArray, [space] as CFArray)
    }

    private static func load<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as _: T.Type) -> T? {
        dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
    }
}
