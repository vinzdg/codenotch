import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

// MARK: - RAM Provider
public actor RAMProvider: UsageProvider {
    public let id = "system-ram"
    public let displayName = "RAM"
    public let glyph = ProviderGlyph.ram
    public let signInRoute = SignInRoute.guidance(L10n.t("System Activity Monitor"))

    public init() {}

    public func account() -> ProviderAccount? {
        let totalGB = String(format: "%.0f GB", Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0)
        return ProviderAccount(id: id, displayName: "System Memory (\(totalGB))", manageURL: nil)
    }

    public func signOut() async {}
    public func forgetCachedCredential() {}

    public func fetchSnapshot() async throws -> ProviderSnapshot {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }

        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        var usedFraction = 0.0
        var usedGB = 0.0
        var appGB = 0.0
        var wiredGB = 0.0
        var compressedGB = 0.0

        if result == KERN_SUCCESS {
            let pageSize = Double(vm_kernel_page_size)
            let active = Double(vmStats.active_count) * pageSize
            let wired = Double(vmStats.wire_count) * pageSize
            let compressed = Double(vmStats.compressor_page_count) * pageSize
            let purgeable = Double(vmStats.purgeable_count) * pageSize

            let usedBytes = active + wired + compressed - purgeable
            usedFraction = min(max(usedBytes / totalBytes, 0), 1)
            usedGB = usedBytes / 1_073_741_824.0
            appGB = (active - purgeable) / 1_073_741_824.0
            wiredGB = wired / 1_073_741_824.0
            compressedGB = compressed / 1_073_741_824.0
        }

        let totalGBNum = totalBytes / 1_073_741_824.0
        let formattedUsed = String(format: "%.1f GB", usedGB)
        let formattedTotal = String(format: "%.0f GB", totalGBNum)

        let primaryWindow = LimitWindow(
            id: "ram-usage",
            label: L10n.t("Memory Used"),
            usedFraction: usedFraction,
            usedText: formattedUsed,
            detail: "\(formattedUsed) / \(formattedTotal)"
        )

        let appWindow = LimitWindow(
            id: "ram-app",
            label: L10n.t("App Memory"),
            usedText: String(format: "%.1f GB", max(0, appGB))
        )

        let wiredWindow = LimitWindow(
            id: "ram-wired",
            label: L10n.t("Wired Memory"),
            usedText: String(format: "%.1f GB", max(0, wiredGB))
        )

        let compressedWindow = LimitWindow(
            id: "ram-compressed",
            label: L10n.t("Compressed"),
            usedText: String(format: "%.1f GB", max(0, compressedGB))
        )

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: [primaryWindow, appWindow, wiredWindow, compressedWindow],
            headlineID: "ram-usage"
        )
    }
}

// MARK: - CPU Provider
public actor CPUProvider: UsageProvider {
    public let id = "system-cpu"
    public let displayName = "CPU"
    public let glyph = ProviderGlyph.cpu
    public let signInRoute = SignInRoute.guidance(L10n.t("System Activity Monitor"))

    private var previousInfo: host_cpu_load_info?

    public init() {}

    public func account() -> ProviderAccount? {
        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        return ProviderAccount(id: id, displayName: "\(coreCount) Cores", manageURL: nil)
    }

    public func signOut() async {}
    public func forgetCachedCredential() {}

    public func fetchSnapshot() async throws -> ProviderSnapshot {
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &cpuInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        var cpuFraction = 0.0
        var userPercent = 0
        var sysPercent = 0

        if result == KERN_SUCCESS {
            if let prev = previousInfo {
                let userDelta = Double(cpuInfo.cpu_ticks.0 - prev.cpu_ticks.0)
                let sysDelta = Double(cpuInfo.cpu_ticks.1 - prev.cpu_ticks.1)
                let idleDelta = Double(cpuInfo.cpu_ticks.2 - prev.cpu_ticks.2)
                let niceDelta = Double(cpuInfo.cpu_ticks.3 - prev.cpu_ticks.3)

                let totalDelta = userDelta + sysDelta + idleDelta + niceDelta
                if totalDelta > 0 {
                    let usedDelta = userDelta + sysDelta + niceDelta
                    cpuFraction = min(max(usedDelta / totalDelta, 0), 1)
                    userPercent = Int((userDelta / totalDelta * 100).rounded())
                    sysPercent = Int((sysDelta / totalDelta * 100).rounded())
                }
            }
            previousInfo = cpuInfo
        }

        let primaryWindow = LimitWindow(
            id: "cpu-usage",
            label: L10n.t("CPU Load"),
            usedFraction: cpuFraction,
            detail: "User: \(userPercent)% · System: \(sysPercent)%"
        )

        let userWindow = LimitWindow(
            id: "cpu-user",
            label: L10n.t("User"),
            usedText: "\(userPercent)%"
        )

        let sysWindow = LimitWindow(
            id: "cpu-system",
            label: L10n.t("System"),
            usedText: "\(sysPercent)%"
        )

        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        let coresWindow = LimitWindow(
            id: "cpu-cores",
            label: L10n.t("Cores"),
            usedText: "\(coreCount)"
        )

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: [primaryWindow, userWindow, sysWindow, coresWindow],
            headlineID: "cpu-usage"
        )
    }
}

// MARK: - Thermals Provider
public actor ThermalsProvider: UsageProvider {
    public let id = "system-thermals"
    public let displayName = "Thermals"
    public let glyph = ProviderGlyph.thermals
    public let signInRoute = SignInRoute.guidance(L10n.t("System Activity Monitor"))

    public init() {}

    public func account() -> ProviderAccount? {
        return ProviderAccount(id: id, displayName: "Thermal State", manageURL: nil)
    }

    public func signOut() async {}
    public func forgetCachedCredential() {}

    public func fetchSnapshot() async throws -> ProviderSnapshot {
        let thermalState = ProcessInfo.processInfo.thermalState
        let fraction: Double
        let labelText: String

        switch thermalState {
        case .nominal:
            fraction = 0.0
            labelText = L10n.t("Nominal")
        case .fair:
            fraction = 0.33
            labelText = L10n.t("Fair")
        case .serious:
            fraction = 0.67
            labelText = L10n.t("Serious")
        case .critical:
            fraction = 1.0
            labelText = L10n.t("Critical")
        @unknown default:
            fraction = 0.0
            labelText = L10n.t("Normal")
        }

        let primaryWindow = LimitWindow(
            id: "thermals-state",
            label: L10n.t("Thermal Pressure"),
            usedFraction: fraction,
            usedText: labelText,
            detail: labelText
        )

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: [primaryWindow],
            headlineID: "thermals-state"
        )
    }
}

// MARK: - Network Provider
public actor NetworkProvider: UsageProvider {
    public let id = "system-network"
    public let displayName = "Network"
    public let glyph = ProviderGlyph.network
    public let signInRoute = SignInRoute.guidance(L10n.t("System Activity Monitor"))

    private var lastBytesIn: UInt64 = 0
    private var lastBytesOut: UInt64 = 0
    private var lastTime: Date?

    public init() {}

    public func account() -> ProviderAccount? {
        return ProviderAccount(id: id, displayName: "Network Activity", manageURL: nil)
    }

    public func signOut() async {}
    public func forgetCachedCredential() {}

    public func fetchSnapshot() async throws -> ProviderSnapshot {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            throw UsageProviderError.badResponse(status: 0)
        }
        defer { freeifaddrs(ifaddr) }

        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0

        var ptr = UnsafeMutablePointer<ifaddrs>? (firstAddr)
        while ptr != nil {
            guard let interface = ptr?.pointee else { break }
            let name = String(cString: interface.ifa_name)
            // Exclude loopback
            if !name.hasPrefix("lo"), let data = interface.ifa_data {
                let networkData = data.pointing(to: if_data.self)
                bytesIn += UInt64(networkData.pointee.ifi_ibytes)
                bytesOut += UInt64(networkData.pointee.ifi_obytes)
            }
            ptr = interface.ifa_next
        }

        let now = Date()
        var downloadRate: Double = 0
        var uploadRate: Double = 0

        if let prevTime = lastTime {
            let elapsed = now.timeIntervalSince(prevTime)
            if elapsed > 0 {
                if bytesIn >= lastBytesIn {
                    downloadRate = Double(bytesIn - lastBytesIn) / elapsed
                }
                if bytesOut >= lastBytesOut {
                    uploadRate = Double(bytesOut - lastBytesOut) / elapsed
                }
            }
        }

        lastBytesIn = bytesIn
        lastBytesOut = bytesOut
        lastTime = now

        let dlText = formatRate(downloadRate)
        let ulText = formatRate(uploadRate)

        // Fraction based on soft peak scale of 10 MB/s (10,485,760 bytes/sec)
        let networkFraction = min(max(downloadRate / 10_485_760.0, 0), 1)

        let primaryWindow = LimitWindow(
            id: "network-speed",
            label: L10n.t("Network Speed"),
            usedFraction: networkFraction,
            usedText: "↓ \(dlText)",
            detail: "↓ \(dlText)  ↑ \(ulText)"
        )

        let downloadWindow = LimitWindow(
            id: "network-download",
            label: L10n.t("Download Speed"),
            usedText: dlText
        )

        let uploadWindow = LimitWindow(
            id: "network-upload",
            label: L10n.t("Upload Speed"),
            usedText: ulText
        )

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: [primaryWindow, downloadWindow, uploadWindow],
            headlineID: "network-speed"
        )
    }

    private func formatRate(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 {
            return "0 KB/s"
        } else if bytesPerSec < 1_048_576 {
            return "\(Int((bytesPerSec / 1024.0).rounded())) KB/s"
        } else {
            return String(format: "%.1f MB/s", bytesPerSec / 1_048_576.0)
        }
    }
}

// Helper extension to safely bind memory
private extension UnsafeMutableRawPointer {
    func pointing<T>(to type: T.Type) -> UnsafeMutablePointer<T> {
        return self.assumingMemoryBound(to: type)
    }
}

// MARK: - Energy Provider
public actor EnergyProvider: UsageProvider {
    public let id = "system-energy"
    public let displayName = "Energy"
    public let glyph = ProviderGlyph.energy
    public let signInRoute = SignInRoute.guidance(L10n.t("System Activity Monitor"))

    public init() {}

    public func account() -> ProviderAccount? {
        return ProviderAccount(id: id, displayName: "Power & Energy", manageURL: nil)
    }

    public func signOut() async {}
    public func forgetCachedCredential() {}

    public func fetchSnapshot() async throws -> ProviderSnapshot {
        var batteryLevel: Double = 1.0
        var isCharging = false
        var powerSource = L10n.t("AC Power")
        var hasBattery = false

        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                if let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                    hasBattery = true
                    if let current = description[kIOPSCurrentCapacityKey] as? Int,
                       let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                        batteryLevel = min(max(Double(current) / Double(max), 0), 1)
                    }
                    if let state = description[kIOPSPowerSourceStateKey] as? String {
                        if state == kIOPSACPowerValue {
                            powerSource = L10n.t("AC Power")
                        } else {
                            powerSource = L10n.t("On Battery")
                        }
                    }
                    if let charging = description[kIOPSIsChargingKey] as? Bool {
                        isCharging = charging
                    }
                }
            }
        }

        let percent = Int((batteryLevel * 100).rounded())
        let statusString: String
        if !hasBattery {
            statusString = L10n.t("AC Power")
        } else if isCharging {
            statusString = "\(percent)% · " + L10n.t("Charging")
        } else {
            statusString = "\(percent)% · " + powerSource
        }

        let batteryBand: UsageBand
        if batteryLevel >= 0.50 {
            batteryBand = .ample
        } else if batteryLevel >= 0.20 {
            batteryBand = .watch
        } else {
            batteryBand = .critical
        }

        let primaryWindow = LimitWindow(
            id: "energy-status",
            label: L10n.t("Battery Level"),
            usedFraction: batteryLevel,
            usedText: "\(percent)%",
            detail: statusString,
            bandOverride: batteryBand
        )

        let powerSourceWindow = LimitWindow(
            id: "energy-source",
            label: L10n.t("Power Source"),
            usedText: powerSource
        )

        let chargingWindow = LimitWindow(
            id: "energy-charging",
            label: L10n.t("State"),
            usedText: isCharging ? L10n.t("Charging") : (hasBattery ? L10n.t("Discharging") : L10n.t("Connected"))
        )

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: [primaryWindow, powerSourceWindow, chargingWindow],
            headlineID: "energy-status"
        )
    }
}

// MARK: - SMC Helper for Fan Speed
private struct SMCKeyData {
    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
    }
    struct LimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = LimitData()
    var keyInfo = KeyInfo()
    var padding: UInt8 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
}

private enum SMCSpeedReader {
    private static func fourCharKey(_ key: String) -> UInt32 {
        var result: UInt32 = 0
        for char in key.utf8 {
            result = (result << 8) | UInt32(char)
        }
        return result
    }

    static func getFanRPM() -> Int {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else {
            return 0
        }
        defer { IOServiceClose(conn) }

        func readKey(_ keyStr: String) -> Double? {
            let keyNum = fourCharKey(keyStr)
            var input = SMCKeyData()
            var output = SMCKeyData()
            input.key = keyNum
            input.data8 = 9 // kSMCGetKeyInfo

            let inputSize = MemoryLayout<SMCKeyData>.stride
            var outputSize = MemoryLayout<SMCKeyData>.stride

            let status = IOConnectCallStructMethod(conn, 2, &input, inputSize, &output, &outputSize)
            guard status == kIOReturnSuccess else { return nil }

            input.keyInfo = output.keyInfo
            input.data8 = 5 // kSMCReadKey

            let readStatus = IOConnectCallStructMethod(conn, 2, &input, inputSize, &output, &outputSize)
            guard readStatus == kIOReturnSuccess else { return nil }

            let bytes = output.bytes
            let size = output.keyInfo.dataSize
            let type = output.keyInfo.dataType

            if type == 0x666C7420 && size == 4 { // flt
                var floatVal: Float = 0
                var rawBytes = (bytes.0, bytes.1, bytes.2, bytes.3)
                withUnsafeBytes(of: &rawBytes) { ptr in
                    if let base = ptr.baseAddress {
                        floatVal = base.assumingMemoryBound(to: Float.self).pointee
                    }
                }
                return Double(floatVal)
            } else if size >= 2 {
                let val = (UInt16(bytes.0) << 8) | UInt16(bytes.1)
                if type == 0x66706532 { // fpe2
                    return Double(val) / 4.0
                }
                return Double(val)
            }
            return nil
        }

        let fan0 = readKey("F0Ac") ?? 0
        let fan1 = readKey("F1Ac") ?? 0
        let maxFan = max(fan0, fan1)
        return Int(maxFan.rounded())
    }
}

// MARK: - Fan Speed Provider
public actor FanProvider: UsageProvider {
    public let id = "system-fan"
    public let displayName = "Fan Speed"
    public let glyph = ProviderGlyph.fan
    public let signInRoute = SignInRoute.guidance(L10n.t("System Activity Monitor"))

    public init() {}

    public func account() -> ProviderAccount? {
        return ProviderAccount(id: id, displayName: "Fan Speed RPM", manageURL: nil)
    }

    public func signOut() async {}
    public func forgetCachedCredential() {}

    public func fetchSnapshot() async throws -> ProviderSnapshot {
        let rpm = SMCSpeedReader.getFanRPM()
        let maxExpectedRPM = 6000.0
        let fraction = min(max(Double(rpm) / maxExpectedRPM, 0), 1)

        let labelText = rpm > 0 ? "\(rpm) RPM" : L10n.t("0 RPM")

        let primaryWindow = LimitWindow(
            id: "fan-speed",
            label: L10n.t("Fan Speed"),
            usedFraction: fraction,
            usedText: labelText,
            detail: labelText
        )

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: [primaryWindow],
            headlineID: "fan-speed"
        )
    }
}
