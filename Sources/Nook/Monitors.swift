import AppKit
import CoreAudio
import CoreMediaIO
import IOBluetooth

final class BluetoothMonitor: NSObject {
    var onBanner: ((Banner) -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [IOBluetoothUserNotification] = []
    private var startedAt = Date()

    func setEnabled(_ enabled: Bool) {
        if enabled, connectNotification == nil {
            startedAt = Date()
            connectNotification = IOBluetoothDevice.register(
                forConnectNotifications: self, selector: #selector(connected(_:device:)))
        } else if !enabled, let connectNotification {
            connectNotification.unregister()
            self.connectNotification = nil
            disconnectNotifications.forEach { $0.unregister() }
            disconnectNotifications.removeAll()
        }
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let disconnect = device.register(forDisconnectNotification: self,
                                            selector: #selector(disconnected(_:device:))) {
            disconnectNotifications.append(disconnect)
        }
        guard Date().timeIntervalSince(startedAt) > 3 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.onBanner?(Banner(symbol: Self.symbol(for: device), title: device.name ?? "Device",
                                   value: Self.battery(of: device).map { "\($0)%" },
                                   tint: .systemBlue, duration: 4))
        }
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        disconnectNotifications.removeAll { $0 === note }
        onBanner?(Banner(symbol: Self.symbol(for: device), title: device.name ?? "Device",
                         value: "Off", tint: .systemGray))
    }

    private static func battery(of device: IOBluetoothDevice) -> Int? {
        let keys = ["batteryPercentSingle", "batteryPercentCombined", "batteryPercentLeft", "batteryPercentRight"]
        let values = keys.compactMap { key -> Int? in
            guard device.responds(to: NSSelectorFromString(key)),
                  let value = device.value(forKey: key) as? Int, value > 0 else { return nil }
            return value
        }
        return values.min()
    }

    private static func symbol(for device: IOBluetoothDevice) -> String {
        if let headphones = headphonesSymbol(named: device.name ?? "") { return headphones }
        let name = (device.name ?? "").lowercased()
        if name.contains("keyboard") { return "keyboard" }
        if name.contains("mouse") { return "magicmouse" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if name.contains("controller") { return "gamecontroller.fill" }
        if device.deviceClassMajor == kBluetoothDeviceClassMajorAudio { return "headphones" }
        return "dot.radiowaves.left.and.right"
    }
}

final class PrivacyMonitor {
    var onChange: ((_ camera: Bool, _ mic: Bool) -> Void)?
    private var timer: Timer?

    func setEnabled(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else {
            onChange?(false, false)
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.onChange?(Self.cameraInUse(), Self.micInUse())
        }
        timer?.fire()
    }

    private static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == 0
        else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                        size, &used, &devices) == 0
        else { return false }

        var running = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        return devices.contains { device in
            var value: UInt32 = 0
            var used: UInt32 = 0
            return CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size),
                                             &used, &value) == 0 && value != 0
        }
    }

    private static func micInUse() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr
        else { return false }

        var running = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &running, 0, nil, &size, &value) == noErr && value != 0
    }
}

final class ClipboardMonitor {
    var onCopy: ((String) -> Void)?
    private var changeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    private static let privateTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
    ]

    func setEnabled(_ enabled: Bool) {
        if enabled, timer == nil {
            changeCount = NSPasteboard.general.changeCount
            timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in self?.poll() }
        } else if !enabled {
            timer?.invalidate()
            timer = nil
        }
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        let types = Set(pasteboard.types?.map(\.rawValue) ?? [])
        guard types.isDisjoint(with: Self.privateTypes),
              let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 20_000
        else { return }
        onCopy?(text)
    }
}

final class DownloadsMonitor {
    var onUpdate: ((DownloadInfo?) -> Void)?
    var onFinished: ((String) -> Void)?
    private var timer: Timer?
    private var current: DownloadInfo?

    private static let partialExtensions: Set<String> = ["download", "crdownload", "part", "opdownload"]

    func setEnabled(_ enabled: Bool) {
        if enabled, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        } else if !enabled, timer != nil {
            timer?.invalidate()
            timer = nil
            current = nil
            onUpdate?(nil)
        }
    }

    private func poll() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        let partial = items
            .filter { Self.partialExtensions.contains($0.pathExtension.lowercased()) }
            .max { Self.modified($0) < Self.modified($1) }

        let info = partial.map(Self.describe)
        if info == nil, let finished = current,
           FileManager.default.fileExists(atPath: folder.appendingPathComponent(finished.name).path) {
            onFinished?(finished.name)
        }
        guard info != current else { return }
        current = info
        onUpdate?(info)
    }

    private static func describe(_ url: URL) -> DownloadInfo {
        let name = url.deletingPathExtension().lastPathComponent
        if url.pathExtension == "download",
           let plist = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")),
           let done = plist["DownloadEntryProgressBytesSoFar"] as? Double,
           let total = plist["DownloadEntryProgressTotalToLoad"] as? Double, total > 0 {
            return DownloadInfo(name: name, progress: min(1, done / total))
        }
        return DownloadInfo(name: name, progress: nil)
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

final class FullscreenMonitor {
    var onChange: ((Set<CGDirectDisplayID>) -> Void)?
    var displayIDs: () -> [CGDirectDisplayID] = { [] }
    private var timer: Timer?
    private var hidden: Set<CGDirectDisplayID> = []
    private var checksFullscreen = false
    private var checksGames = false

    func setEnabled(fullscreen: Bool, games: Bool) {
        checksFullscreen = fullscreen
        checksGames = games
        if fullscreen || games, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        } else if !(fullscreen || games), timer != nil {
            timer?.invalidate()
            timer = nil
            update([])
        }
    }

    private func poll() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return update([]) }
        let displays = displayIDs()
        if checksGames, Self.isGame(front) { return update(Set(displays)) }
        guard checksFullscreen,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return update([]) }

        let frontWindows = windows.compactMap { window -> CGRect? in
            guard window[kCGWindowOwnerPID as String] as? pid_t == front.processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0
            else { return nil }
            return (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        }
        update(Set(displays.filter { id in
            let bounds = CGDisplayBounds(id)
            let minHeight = bounds.height - Self.topInset(id)
            return frontWindows.contains { $0.width >= bounds.width && $0.height >= minHeight && $0.intersects(bounds) }
        }))
    }

    private static func topInset(_ id: CGDirectDisplayID) -> CGFloat {
        NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == id
        }?.safeAreaInsets.top ?? 0
    }

    private static func isGame(_ app: NSRunningApplication) -> Bool {
        let category = app.bundleURL.flatMap(Bundle.init(url:))?.object(forInfoDictionaryKey: "LSApplicationCategoryType")
        return (category as? String)?.hasSuffix("games") == true
    }

    private func update(_ value: Set<CGDirectDisplayID>) {
        guard value != hidden else { return }
        hidden = value
        onChange?(value)
    }
}
