import AudioToolbox
import CoreAudio
import Foundation
import IOKit.ps

final class VolumeMonitor {
    var onChange: ((Float, Bool) -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var listener: AudioObjectPropertyListenerBlock?

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, .main
        ) { [weak self] _, _ in
            self?.attachToDefaultDevice()
        }
        attachToDefaultDevice()
    }

    private func attachToDefaultDevice() {
        if let listener, device != AudioObjectID(kAudioObjectUnknown) {
            AudioObjectRemovePropertyListenerBlock(device, &volumeAddress, .main, listener)
            AudioObjectRemovePropertyListenerBlock(device, &muteAddress, .main, listener)
        }

        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, &size, &id
        )
        guard status == noErr else { return }
        device = id

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.emit() }
        listener = block
        AudioObjectAddPropertyListenerBlock(id, &volumeAddress, .main, block)
        AudioObjectAddPropertyListenerBlock(id, &muteAddress, .main, block)
    }

    private func emit() {
        var volume = Float32(0)
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &volumeSize, &volume)

        var muted = UInt32(0)
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &muteSize, &muted)

        onChange?(volume, muted != 0)
    }
}

enum SystemVolume {
    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    static var defaultOutputDevice: AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static var isSettable: Bool {
        guard let device = defaultOutputDevice, AudioObjectHasProperty(device, &volumeAddress) else {
            return false
        }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &volumeAddress, &settable) == noErr && settable.boolValue
    }

    static func level() -> Float? {
        guard let device = defaultOutputDevice else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    static func setLevel(_ level: Float) {
        guard let device = defaultOutputDevice else { return }
        var volume = Float32(level)
        AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
    }

    static func isMuted() -> Bool {
        guard let device = defaultOutputDevice else { return false }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted)
        return muted != 0
    }

    static func setMuted(_ muted: Bool) {
        guard let device = defaultOutputDevice, AudioObjectHasProperty(device, &muteAddress) else { return }
        var value = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

func playSystemSound(_ name: String) {
    DispatchQueue.global(qos: .userInitiated).async {
        var id: SystemSoundID = 0
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff") as CFURL
        guard AudioServicesCreateSystemSoundID(url, &id) == noErr else { return }
        AudioServicesPlaySystemSoundWithCompletion(id) { AudioServicesDisposeSystemSoundID(id) }
    }
}

func headphonesSymbol(named name: String) -> String? {
    let name = name.lowercased()
    if name.contains("airpods max") { return "airpodsmax" }
    if name.contains("airpods pro") { return "airpodspro" }
    if name.contains("airpods") { return "airpods" }
    if name.contains("beats") { return "beats.headphones" }
    return nil
}

struct AudioOutput: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
}

extension SystemVolume {
    static func outputs() -> [AudioOutput] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
                  let name = name(of: id), name != SystemAudioTap.deviceName
            else { return nil }
            return AudioOutput(id: id, name: name)
        }
    }

    static func setDefaultOutput(_ id: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &device)
    }

    static func outputSymbol() -> String? {
        guard let device = defaultOutputDevice else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return nil }

        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return headphonesSymbol(named: name(of: device) ?? "") ?? "headphones"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeBuiltIn:
            var source = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(device, &source, 0, nil, &size, &value)
            return status == noErr && value == 0x6864_706E ? "headphones" : nil
        default:
            return nil
        }
    }

    private static func name(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}

final class BatteryMonitor {
    var onChange: ((BatteryInfo?) -> Void)?
    var onLowPowerModeChange: ((Bool) -> Void)?

    private var runLoopSource: CFRunLoopSource?

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
        }, context)?.takeRetainedValue()

        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
        refresh()

        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.onLowPowerModeChange?(ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
    }

    func refresh() {
        onChange?(Self.read())
    }

    private static func read() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            let current = info[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = info[kIOPSMaxCapacityKey] as? Int ?? 100
            let isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = info[isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int ?? -1
            return BatteryInfo(
                level: max > 0 ? Double(current) / Double(max) : 0,
                isCharging: isCharging,
                isPluggedIn: info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                minutesRemaining: minutes > 0 ? minutes : nil
            )
        }
        return nil
    }
}
