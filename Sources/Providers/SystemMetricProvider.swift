import Foundation
import Darwin
import IOKit.ps
import Network

/// A flag that answers `true` once. A path monitor can fire its handler more
/// than once before `cancel()` lands, and a continuation may resume only once.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// What this Mac reports about itself, shown in the notch beside the providers.
///
/// Each reading is a provider in the store's sense, so it gets a ring, a place
/// in Settings and an on/off switch like any other. Nothing here asks for a
/// credential, and nothing leaves the Mac.
enum SystemMetric: String, CaseIterable, Sendable {
    case cpu
    case memory
    case storage
    case network
    case battery
    case thermal
    case swap
    case connectivity
    case batteryTime

    var providerID: String { "system-\(rawValue)" }

    var displayName: String {
        switch self {
        case .cpu:          return L10n.t("CPU")
        case .memory:       return L10n.t("Memory")
        case .storage:      return L10n.t("Storage")
        case .network:      return L10n.t("Network")
        case .battery:      return L10n.t("Battery")
        case .thermal:      return L10n.t("Thermal")
        case .swap:         return L10n.t("Swap")
        case .connectivity: return L10n.t("Connectivity")
        case .batteryTime:  return L10n.t("Time left")
        }
    }

    var glyph: ProviderGlyph {
        switch self {
        case .cpu:          return .systemCPU
        case .memory:       return .systemMemory
        case .storage:      return .systemStorage
        case .network:      return .systemNetwork
        case .battery:      return .systemBattery
        case .thermal:      return .systemThermal
        case .swap:         return .systemSwap
        case .connectivity: return .systemConnectivity
        case .batteryTime:  return .systemBatteryTime
        }
    }

    /// Only offered where the Mac has the thing measured: a desktop has no battery.
    var isAvailable: Bool {
        switch self {
        case .battery, .batteryTime: return SystemSampler.batteryCharge() != nil
        default:                     return true
        }
    }
}

/// The arithmetic, apart from the kernel calls, so it can be checked on its own.
enum SystemMetricMath {
    /// Share of CPU time spent busy between two cumulative readings of
    /// `(user, system, idle, nice)` ticks. Nil when nothing ticked in between.
    static func busyFraction(from before: [UInt32], to after: [UInt32]) -> Double? {
        guard before.count == 4, after.count == 4 else { return nil }
        // Wrapping subtraction: the kernel counters are 32-bit and roll over.
        let delta = zip(before, after).map { $1 &- $0 }
        let total = delta.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard total > 0 else { return nil }
        let idle = UInt64(delta[2])   // CPU_STATE_IDLE
        return Double(total - idle) / Double(total)
    }

    /// Share of the boot volume in use, from its total and the space still
    /// free for important use (what Finder reports).
    static func usedFraction(total: Int64, available: Int64) -> Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, 1 - Double(available) / Double(total)))
    }

    /// Download and upload speed between two per-interface byte counters, each
    /// a 32-bit kernel value that wraps. An interface seen on only one side is
    /// left out rather than guessed at.
    static func throughput(from before: [String: (rx: UInt32, tx: UInt32)],
                           to after: [String: (rx: UInt32, tx: UInt32)],
                           over seconds: TimeInterval) -> (down: Double, up: Double) {
        guard seconds > 0 else { return (0, 0) }
        var down: UInt64 = 0
        var up: UInt64 = 0
        for (name, end) in after {
            guard let start = before[name] else { continue }
            down += UInt64(end.rx &- start.rx)
            up += UInt64(end.tx &- start.tx)
        }
        return (Double(down) / seconds, Double(up) / seconds)
    }

    /// "2.1 MB/s", the way the rest of the app writes sizes.
    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    /// Share of physical memory in use: active, wired and compressed pages.
    static func memoryUsedFraction(used: UInt64, total: UInt64) -> Double? {
        guard total > 0 else { return nil }
        return min(1, Double(used) / Double(total))
    }

    /// "2 h 15 min", or "45 min" under an hour.
    static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        return hours > 0 ? "\(hours) h \(rest) min" : "\(rest) min"
    }

    /// The connection in one word: "Offline", or "Online · Wi-Fi" and so on.
    static func connectionWord(online: Bool, wifi: Bool, wired: Bool, cellular: Bool) -> String {
        guard online else { return L10n.t("Offline") }
        let link: String
        if wifi { link = L10n.t("Wi-Fi") }
        else if wired { link = L10n.t("Ethernet") }
        else if cellular { link = L10n.t("Cellular") }
        else { link = L10n.t("Other") }
        return L10n.t("Online") + " · " + link
    }

    /// "1.2 GB / 4 GB", the swap in use against what is reserved.
    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .memory)
    }

    /// Charge left in the battery, 0...1, from the power source's own counts.
    static func batteryCharge(current: Int, full: Int) -> Double? {
        guard full > 0 else { return nil }
        return min(1, Swift.max(0, Double(current) / Double(full)))
    }

    /// Where the thermal state sits on the ring. The macOS state is four steps,
    /// not a temperature, so the ring is a scale and the words say the rest.
    static func thermalLevel(_ state: ProcessInfo.ThermalState) -> Double {
        switch state {
        case .nominal:  return 0.25
        case .fair:     return 0.5
        case .serious:  return 0.75
        case .critical: return 1
        @unknown default: return 1
        }
    }
}

/// Reads the kernel and the file system. Each call is a single reading.
enum SystemSampler {
    static func memoryUsedFraction() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let used = pages * UInt64(vm_kernel_page_size)
        return SystemMetricMath.memoryUsedFraction(used: used, total: ProcessInfo.processInfo.physicalMemory)
    }

    /// The internal battery's description from the power-source API, or nil
    /// on a Mac without one.
    static func internalBattery() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            return description
        }
        return nil
    }

    /// The internal battery's charge, 0...1, or nil on a Mac without one.
    static func batteryCharge() -> Double? {
        guard let battery = internalBattery(),
              let current = battery[kIOPSCurrentCapacityKey] as? Int,
              let full = battery[kIOPSMaxCapacityKey] as? Int
        else { return nil }
        return SystemMetricMath.batteryCharge(current: current, full: full)
    }

    /// Minutes until empty, or until full while charging. Nil while macOS is
    /// still estimating, which it reports as a negative figure.
    static func batteryMinutesLeft() -> (minutes: Int, charging: Bool)? {
        guard let battery = internalBattery() else { return nil }
        let charging = battery[kIOPSIsChargingKey] as? Bool ?? false
        let key = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        guard let minutes = battery[key] as? Int, minutes >= 0 else { return nil }
        return (minutes, charging)
    }

    /// Swap in use and reserved, in bytes. Total is 0 when the Mac has no swap.
    static func swapUsage() -> (used: UInt64, total: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (usage.xsu_used, usage.xsu_total)
    }

    /// The current network path, waiting for the first answer from the system.
    static func currentPath() async -> NWPath {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = OnceFlag()
            monitor.pathUpdateHandler = { path in
                guard once.take() else { return }
                monitor.cancel()
                continuation.resume(returning: path)
            }
            monitor.start(queue: DispatchQueue(label: "codenotch.system.path"))
        }
    }

    static func cpuTicks() -> [UInt32]? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return withUnsafeBytes(of: info.cpu_ticks) { raw in
            (0..<4).map { raw.load(fromByteOffset: $0 * MemoryLayout<UInt32>.stride, as: UInt32.self) }
        }
    }

    static func storageUsedFraction() -> Double? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return SystemMetricMath.usedFraction(total: Int64(total), available: available)
    }

    /// Byte counters for every up, non-loopback link interface, by name.
    static func interfaceCounters() -> [String: (rx: UInt32, tx: UInt32)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }

        var counters: [String: (rx: UInt32, tx: UInt32)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            cursor = entry.ifa_next
            guard let address = entry.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.ifa_data,
                  entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            counters[String(cString: entry.ifa_name)] = (stats.ifi_ibytes, stats.ifi_obytes)
        }
        return counters
    }
}

/// One system reading as a provider. A rate needs two samples, so the network
/// and CPU readings take a second's sample pair per fetch.
actor SystemMetricProvider: UsageProvider {
    nonisolated let metric: SystemMetric

    nonisolated var id: String { metric.providerID }
    nonisolated var displayName: String { metric.displayName }
    nonisolated var glyph: ProviderGlyph { metric.glyph }
    nonisolated var kind: ProviderKind { .system }

    init(metric: SystemMetric) {
        self.metric = metric
    }

    /// The span a rate is measured over. Ponytail: one second is enough for a
    /// glance; a longer span would smooth spikes at the cost of a slower fetch.
    private static let sampleSpan: TimeInterval = 1

    func fetchSnapshot() async throws -> ProviderSnapshot {
        var fraction: Double?
        var text: String?

        switch metric {
        case .cpu:
            let before = SystemSampler.cpuTicks()
            try await Task.sleep(nanoseconds: UInt64(Self.sampleSpan * 1_000_000_000))
            if let before, let after = SystemSampler.cpuTicks() {
                fraction = SystemMetricMath.busyFraction(from: before, to: after)
            }
        case .memory:
            fraction = SystemSampler.memoryUsedFraction()
        case .storage:
            fraction = SystemSampler.storageUsedFraction()
        case .battery:
            // The ring fills as the charge drains, the way every other ring fills
            // as a thing is used up, so a low battery reads as a warning. The
            // figure shown is the charge itself.
            if let charge = SystemSampler.batteryCharge() {
                fraction = 1 - charge
                text = "\(Int((charge * 100).rounded()))%"
            }
        case .thermal:
            let state = ProcessInfo.processInfo.thermalState
            fraction = SystemMetricMath.thermalLevel(state)
            text = Self.thermalWord(state)
        case .swap:
            if let swap = SystemSampler.swapUsage() {
                fraction = SystemMetricMath.memoryUsedFraction(used: swap.used, total: swap.total)
                text = swap.total == 0
                    ? L10n.t("No swap")
                    : "\(SystemMetricMath.bytes(swap.used)) / \(SystemMetricMath.bytes(swap.total))"
            }
        case .connectivity:
            let path = await SystemSampler.currentPath()
            text = SystemMetricMath.connectionWord(
                online: path.status == .satisfied,
                wifi: path.usesInterfaceType(.wifi),
                wired: path.usesInterfaceType(.wiredEthernet),
                cellular: path.usesInterfaceType(.cellular))
        case .batteryTime:
            if let left = SystemSampler.batteryMinutesLeft() {
                let span = SystemMetricMath.duration(minutes: left.minutes)
                text = left.charging ? L10n.t("\(span) to full") : L10n.t("\(span) left")
            } else {
                text = L10n.t("Calculating")
            }
        case .network:
            let before = SystemSampler.interfaceCounters()
            try await Task.sleep(nanoseconds: UInt64(Self.sampleSpan * 1_000_000_000))
            let after = SystemSampler.interfaceCounters()
            let speed = SystemMetricMath.throughput(from: before, to: after, over: Self.sampleSpan)
            // No ceiling for a network, so no ring fraction: the figure is the reading.
            text = "↓ \(SystemMetricMath.rate(speed.down))  ↑ \(SystemMetricMath.rate(speed.up))"
        }

        let windowID = "\(id).primary"
        let window = LimitWindow(
            id: windowID,
            label: metric.displayName,
            usedFraction: fraction,
            usedText: text,
            prefersUsedText: [.network, .connectivity, .batteryTime].contains(metric)
        )
        var snapshot = ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: [window],
            headlineID: windowID
        )
        snapshot.kind = .system
        return snapshot
    }

    private static func thermalWord(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return L10n.t("Normal")
        case .fair:     return L10n.t("Warm")
        case .serious:  return L10n.t("Hot")
        case .critical: return L10n.t("Critical")
        @unknown default: return L10n.t("Unknown")
        }
    }

    nonisolated func account() -> ProviderAccount? {
        ProviderAccount(label: nil, plan: nil, source: "macOS", manageURL: nil)
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Reads this Mac's own counters. Nothing to sign in to."))
    }
}
