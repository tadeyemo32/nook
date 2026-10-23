import AppKit
import ApplicationServices
import CoreGraphics

final class MediaKeyTap {
    var onHUD: ((HUD) -> Void)?

    private static let systemDefinedType: UInt32 = 14
    private static let auxControlSubtype: Int16 = 8
    private static let soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7

    private let brightness = DisplayBrightness()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var trustTimer: Timer?

    var isRunning: Bool { tap != nil }

    func start(prompt: Bool) {
        guard tap == nil else { return }
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            trustTimer?.invalidate()
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.trustTimer = nil
                self?.start(prompt: false)
            }
            return
        }

        let mask = CGEventMask(1) << CGEventMask(Self.systemDefinedType)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<MediaKeyTap>.fromOpaque(context).takeUnretainedValue()
                return tap.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    func stop() {
        trustTimer?.invalidate()
        trustTimer = nil
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

        guard type.rawValue == Self.systemDefinedType,
              let ns = NSEvent(cgEvent: event),
              ns.subtype.rawValue == Self.auxControlSubtype
        else { return pass }

        let data = ns.data1
        let key = (data & 0xFFFF_0000) >> 16
        let isDown = (data & 0xFF00) >> 8 == 0xA
        let fine = ns.modifierFlags.contains([.option, .shift])
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16

        switch key {
        case Self.soundUp, Self.soundDown, Self.mute:
            guard SystemVolume.isSettable else { return pass }
            if isDown { changeVolume(key: key, step: step) }
            return nil
        case Self.brightnessUp, Self.brightnessDown:
            guard brightness.isAvailable else { return pass }
            if isDown { changeBrightness(up: key == Self.brightnessUp, step: step) }
            return nil
        default:
            return pass
        }
    }

    private func changeVolume(key: Int, step: Float) {
        guard let current = SystemVolume.level() else { return }
        var muted = SystemVolume.isMuted()
        var level = current

        if key == Self.mute {
            muted.toggle()
            SystemVolume.setMuted(muted)
        } else {
            level = Self.stepped(current, by: key == Self.soundUp ? step : -step)
            SystemVolume.setLevel(level)
            muted = level == 0
            SystemVolume.setMuted(muted)
        }
        onHUD?(.volume(level: level, muted: muted))
    }

    private func changeBrightness(up: Bool, step: Float) {
        guard let current = brightness.level() else { return }
        let level = Self.stepped(current, by: up ? step : -step)
        brightness.setLevel(level)
        onHUD?(.brightness(level: level))
    }

    private static func stepped(_ value: Float, by step: Float) -> Float {
        let size = abs(step)
        let snapped = ((value + step) / size).rounded() * size
        return min(1, max(0, snapped))
    }
}

final class DisplayBrightness {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getBrightness: GetBrightness?
    private let setBrightness: SetBrightness?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        getBrightness = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
            .map { unsafeBitCast($0, to: GetBrightness.self) }
        setBrightness = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
            .map { unsafeBitCast($0, to: SetBrightness.self) }
    }

    var isAvailable: Bool { setBrightness != nil && level() != nil }

    func level() -> Float? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        return getBrightness(display, &value) == 0 ? value : nil
    }

    func setLevel(_ value: Float) {
        _ = setBrightness?(display, value)
    }

    private var display: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success,
           let builtIn = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            return builtIn
        }
        return CGMainDisplayID()
    }
}
