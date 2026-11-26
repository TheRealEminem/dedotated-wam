import Darwin
import Foundation

// MARK: - Samples

/// The kernel's own verdict on memory, the same signal Activity Monitor colours its graph with.
public enum PressureLevel: Int, Codable, Comparable, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    public static func < (a: PressureLevel, b: PressureLevel) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

/// CPU load as fractions from 0 to 1.
public struct CPUSample: Sendable, Equatable {
    public var total: Double = 0
    public var user: Double = 0
    public var system: Double = 0
    public var perCore: [Double] = []

    public init(total: Double = 0, user: Double = 0, system: Double = 0, perCore: [Double] = []) {
        self.total = total
        self.user = user
        self.system = system
        self.perCore = perCore
    }
}

/// Memory in bytes, split the way Activity Monitor splits it.
public struct MemorySample: Sendable, Equatable {
    public var total: UInt64 = 0
    /// Anonymous memory apps are holding, minus what the system can purge.
    public var app: UInt64 = 0
    public var wired: UInt64 = 0
    /// Physical RAM occupied by the compressor.
    public var compressed: UInt64 = 0
    /// File cache and purgeable memory: counted as available.
    public var cached: UInt64 = 0
    public var free: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var swapTotal: UInt64 = 0
    public var pressure: PressureLevel = .normal

    public init(
        total: UInt64 = 0, app: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0,
        cached: UInt64 = 0, free: UInt64 = 0, swapUsed: UInt64 = 0, swapTotal: UInt64 = 0,
        pressure: PressureLevel = .normal
    ) {
        self.total = total
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
        self.free = free
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressure = pressure
    }

    /// "Memory Used" in Activity Monitor terms.
    public var used: UInt64 { app + wired + compressed }

    public var usedFraction: Double {
        total == 0 ? 0 : min(1, Double(used) / Double(total))
    }

    public var usedPercent: Int { Int((usedFraction * 100).rounded()) }
}

// MARK: - Samplers

private let hostPort: mach_port_t = mach_host_self()

/// Reads per-core CPU ticks and turns the difference since the last call into a load figure.
public final class CPUSampler {
    private struct Ticks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    private var previous: [Ticks] = []

    public init() {}

    public func sample() -> CPUSample {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(hostPort, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return CPUSample() }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let states = Int(CPU_STATE_MAX)
        var current: [Ticks] = []
        current.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = core * states
            current.append(Ticks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ))
        }
        defer { previous = current }
        guard previous.count == current.count else {
            return CPUSample(perCore: Array(repeating: 0, count: current.count))
        }

        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)
        var userSum = 0.0, systemSum = 0.0, allSum = 0.0
        for (now, before) in zip(current, previous) {
            // Tick counters wrap, so subtract with overflow.
            let user = Double(now.user &- before.user) + Double(now.nice &- before.nice)
            let system = Double(now.system &- before.system)
            let idle = Double(now.idle &- before.idle)
            let all = user + system + idle
            perCore.append(all > 0 ? (user + system) / all : 0)
            userSum += user
            systemSum += system
            allSum += all
        }
        guard allSum > 0 else { return CPUSample(perCore: perCore) }
        return CPUSample(
            total: (userSum + systemSum) / allSum,
            user: userSum / allSum,
            system: systemSum / allSum,
            perCore: perCore
        )
    }
}

public enum MemorySampler {
    public static let physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory

    private static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        host_page_size(hostPort, &size)
        return size > 0 ? UInt64(size) : 16384
    }()

    public static func sample() -> MemorySample {
        var sample = MemorySample(total: physicalMemory)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = pageSize
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            sample.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            sample.wired = UInt64(stats.wire_count) * page
            sample.compressed = UInt64(stats.compressor_page_count) * page
            sample.cached = (UInt64(stats.external_page_count) + purgeable) * page
            let freePages = UInt64(stats.free_count)
            let speculative = UInt64(stats.speculative_count)
            sample.free = (freePages > speculative ? freePages - speculative : 0) * page
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            sample.swapUsed = swap.xsu_used
            sample.swapTotal = swap.xsu_total
        }

        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.stride
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            sample.pressure = PressureLevel(rawValue: Int(level)) ?? .normal
        }
        return sample
    }
}

// MARK: - Formatting

public enum ByteFormat {
    /// "12.8 GB", "640 MB". Binary units, to match Activity Monitor.
    public static func string(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 10 { return String(format: "%.1f GB", gb) }
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}
