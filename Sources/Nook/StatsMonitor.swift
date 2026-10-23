import Darwin
import Foundation
import IOKit

final class StatsMonitor {
    var onUpdate: ((SystemStats) -> Void)?
    var isVisible: () -> Bool = { false }

    private var timer: Timer?
    private var previousCPU: host_cpu_load_info?
    private var previousNetwork: (received: UInt64, sent: UInt64, at: Date)?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard isVisible() else {
            previousCPU = nil
            previousNetwork = nil
            return
        }
        let memory = Self.memoryUsed()
        let disk = Self.disk()
        let network = networkRates()
        onUpdate?(SystemStats(
            cpu: cpuUsage() ?? 0,
            gpu: Self.gpuUsage(),
            memoryUsed: memory,
            memoryTotal: Double(ProcessInfo.processInfo.physicalMemory),
            networkIn: network.received,
            networkOut: network.sent,
            diskFree: disk.free,
            diskTotal: disk.total
        ))
    }

    private func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        defer { previousCPU = info }
        guard let previous = previousCPU else { return nil }

        func delta(_ index: Int32) -> Double {
            let now = withUnsafeBytes(of: info.cpu_ticks) { $0.load(fromByteOffset: Int(index) * 4, as: UInt32.self) }
            let then = withUnsafeBytes(of: previous.cpu_ticks) { $0.load(fromByteOffset: Int(index) * 4, as: UInt32.self) }
            return Double(now &- then)
        }
        let user = delta(CPU_STATE_USER), system = delta(CPU_STATE_SYSTEM)
        let nice = delta(CPU_STATE_NICE), idle = delta(CPU_STATE_IDLE)
        let total = user + system + nice + idle
        return total > 0 ? (user + system + nice) / total : nil
    }

    private static func memoryUsed() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pages = Double(stats.internal_page_count) - Double(stats.purgeable_count)
            + Double(stats.wire_count) + Double(stats.compressor_page_count)
        return pages * Double(vm_kernel_page_size)
    }

    private func networkRates() -> (received: Double, sent: Double) {
        var received: UInt64 = 0, sent: UInt64 = 0
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return (0, 0) }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: entry.ifa_name).hasPrefix("en"),
                  let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self).pointee
            else { continue }
            received += UInt64(data.ifi_ibytes)
            sent += UInt64(data.ifi_obytes)
        }
        let now = Date()
        defer { previousNetwork = (received, sent, now) }
        guard let previous = previousNetwork else { return (0, 0) }
        let seconds = max(0.1, now.timeIntervalSince(previous.at))
        let inRate = received >= previous.received ? Double(received - previous.received) / seconds : 0
        let outRate = sent >= previous.sent ? Double(sent - previous.sent) / seconds : 0
        return (inRate, outRate)
    }

    private static func disk() -> (free: Double, total: Double) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (Double(values?.volumeAvailableCapacityForImportantUsage ?? 0),
                Double(values?.volumeTotalCapacity ?? 0))
    }

    private static func gpuUsage() -> Double? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
                == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var usage: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                           kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let percent = stats["Device Utilization %"] as? Int {
                usage = max(usage ?? 0, Double(percent) / 100)
            }
        }
        return usage
    }
}
