import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

final class SystemAudioTap {
    static let bandCount = 4
    static let deviceName = "Nook Waveform"

    var onLevels: (([Float]?) -> Void)?

    private let queue = DispatchQueue(label: "nook.waveform", qos: .userInteractive)
    private var session: AnyObject?
    private var stopWork: DispatchWorkItem?
    private var failed = false
    private var starting = false
    private var wantsActive = false
    private var deviceListener: AudioObjectPropertyListenerBlock?

    func setActive(_ active: Bool) {
        wantsActive = active
        if active {
            stopWork?.cancel()
            stopWork = nil
            startIfNeeded()
        } else if session != nil, stopWork == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.stopWork = nil
                self?.stop()
            }
            stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    private func startIfNeeded() {
        guard session == nil, !starting, !failed else { return }
        guard #available(macOS 14.2, *) else {
            failed = true
            return
        }
        starting = true
        let ioQueue = queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try TapSession(queue: ioQueue) { levels in
                    DispatchQueue.main.async { self?.onLevels?(levels) }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                starting = false
                switch result {
                case let .success(tap):
                    session = tap
                    observeDefaultOutput()
                    if !wantsActive { setActive(false) }
                case let .failure(error):
                    failed = true
                    NSLog("Nook: system audio tap unavailable (\(error))")
                }
            }
        }
    }

    private func stop() {
        session = nil
        onLevels?(nil)
    }

    private func observeDefaultOutput() {
        guard deviceListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, session != nil else { return }
            session = nil
            failed = false
            startIfNeeded()
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }
}

struct CoreAudioError: Error, CustomStringConvertible {
    let call: String
    let status: OSStatus
    var description: String { "\(call) failed: \(status)" }
}

private func check(_ status: OSStatus, _ call: String) throws {
    guard status == noErr else { throw CoreAudioError(call: call, status: status) }
}

@available(macOS 14.2, *)
private final class TapSession {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var analyzer: BandAnalyzer?

    init(queue: DispatchQueue, onLevels: @escaping ([Float]) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = SystemAudioTap.deviceName
        try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")

        do {
            let format = try Self.tapFormat(tapID)
            guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
                throw CoreAudioError(call: "tap format (not Float32)", status: -1)
            }
            let analyzer = BandAnalyzer(format: format, onLevels: onLevels)
            self.analyzer = analyzer

            guard let outputUID = Self.defaultOutputUID() else {
                throw CoreAudioError(call: "default output device UID", status: -1)
            }
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: SystemAudioTap.deviceName,
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                      "AudioHardwareCreateAggregateDevice")

            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
                analyzer.process(input)
            }, "AudioDeviceCreateIOProcIDWithBlock")
            try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        } catch {
            teardown()
            throw error
        }
    }

    deinit {
        teardown()
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "kAudioTapPropertyFormat")
        return format
    }

    private static func defaultOutputUID() -> String? {
        guard let device = SystemVolume.defaultOutputDevice else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}

private final class BandAnalyzer {
    private static let size = 1024
    private static let bands: [(low: Double, high: Double)] = [(40, 250), (250, 1000), (1000, 4000), (4000, 12000)]
    private static let publishInterval = 1.0 / 30

    private let channels: Int
    private let interleaved: Bool
    private let sampleRate: Double
    private let onLevels: ([Float]) -> Void

    private let setup: vDSP_DFT_Setup?
    private var window = [Float](repeating: 0, count: size)
    private var ring = [Float](repeating: 0, count: size)
    private var ringIndex = 0
    private var filled = 0
    private var peaks = [Float](repeating: 1e-3, count: bands.count)
    private var smoothed = [Float](repeating: 0, count: bands.count)
    private var lastPublish = Date.distantPast

    init(format: AudioStreamBasicDescription, onLevels: @escaping ([Float]) -> Void) {
        channels = max(1, Int(format.mChannelsPerFrame))
        interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        self.onLevels = onLevels
        setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Self.size), .FORWARD)
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let setup { vDSP_DFT_DestroySetup(setup) }
    }

    func process(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData else { return }

        let stride = interleaved ? channels : 1
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / stride
        let samples = data.assumingMemoryBound(to: Float.self)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<stride { sum += samples[frame * stride + channel] }
            ring[ringIndex] = sum / Float(stride)
            ringIndex = (ringIndex + 1) % Self.size
            filled = min(Self.size, filled + 1)
        }

        let now = Date()
        guard filled == Self.size, now.timeIntervalSince(lastPublish) >= Self.publishInterval else { return }
        lastPublish = now
        onLevels(analyze())
    }

    private func analyze() -> [Float] {
        guard let setup else { return smoothed }
        let n = Self.size, half = n / 2

        var signal = [Float](repeating: 0, count: n)
        for i in 0..<n { signal[i] = ring[(ringIndex + i) % n] * window[i] }

        var inReal = [Float](repeating: 0, count: half), inImag = inReal
        for i in 0..<half {
            inReal[i] = signal[2 * i]
            inImag[i] = signal[2 * i + 1]
        }
        var outReal = inReal, outImag = inImag
        vDSP_DFT_Execute(setup, inReal, inImag, &outReal, &outImag)

        let binWidth = sampleRate / Double(n)
        for (b, band) in Self.bands.enumerated() {
            let low = max(1, Int(band.low / binWidth))
            let high = min(half - 1, max(low, Int(band.high / binWidth)))
            var power: Float = 0
            for k in low...high { power += outReal[k] * outReal[k] + outImag[k] * outImag[k] }
            let magnitude = sqrt(power / Float(high - low + 1))

            peaks[b] = max(magnitude, peaks[b] * 0.997, 1e-3)
            let level = min(1, pow(magnitude / peaks[b], 0.8))
            smoothed[b] = level > smoothed[b] ? level : smoothed[b] * 0.75 + level * 0.25
        }
        return smoothed
    }
}
