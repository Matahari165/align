import Foundation
import Darwin
import Combine
import AppKit

public struct SystemResourceSnapshot: Equatable, Sendable {
    public let systemCPUPercentage: Double?
    public let systemMemoryPercentage: Double?
    public let systemMemoryUsedBytes: UInt64?
    public let systemMemoryTotalBytes: UInt64
    public let appCPUPercentage: Double?
    public let appMemoryFootprintBytes: UInt64?
    public let timestamp: Date

    public init(
        systemCPUPercentage: Double? = nil,
        systemMemoryPercentage: Double? = nil,
        systemMemoryUsedBytes: UInt64? = nil,
        systemMemoryTotalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        appCPUPercentage: Double? = nil,
        appMemoryFootprintBytes: UInt64? = nil,
        timestamp: Date = Date()
    ) {
        self.systemCPUPercentage = systemCPUPercentage
        self.systemMemoryPercentage = systemMemoryPercentage
        self.systemMemoryUsedBytes = systemMemoryUsedBytes
        self.systemMemoryTotalBytes = systemMemoryTotalBytes
        self.appCPUPercentage = appCPUPercentage
        self.appMemoryFootprintBytes = appMemoryFootprintBytes
        self.timestamp = timestamp
    }

    public var systemCPUFormatted: String {
        guard let systemCPUPercentage else { return "—" }
        return String(format: "%.0f %%", max(0.0, systemCPUPercentage))
    }

    public var systemMemoryFormatted: String {
        guard let systemMemoryPercentage else { return "—" }
        return String(format: "%.0f %%", max(0.0, systemMemoryPercentage))
    }

    public var appCPUFormatted: String {
        guard let appCPUPercentage else { return "—" }
        return String(format: "%.1f %%", max(0.0, appCPUPercentage))
    }

    public var appMemoryFormatted: String {
        guard let appMemoryFootprintBytes else { return "—" }
        let mb = Double(appMemoryFootprintBytes) / (1024 * 1024)
        if mb >= 1000 {
            return String(format: "%.1f Go", mb / 1024.0)
        } else {
            return String(format: "%.0f Mo", max(0.0, mb))
        }
    }

    public var detailedTooltip: String {
        var lines: [String] = []
        if let systemCPUPercentage {
            let appDetail = appCPUPercentage.map { String(format: " (Align : %.1f %%)", $0) } ?? ""
            lines.append(String(format: "CPU Système : %.1f %%%@", systemCPUPercentage, appDetail))
        }
        if let systemMemoryPercentage {
            let usedGB = systemMemoryUsedBytes.map { Double($0) / 1_073_741_824.0 } ?? 0
            let totalGB = Double(systemMemoryTotalBytes) / 1_073_741_824.0
            let appRAM = appMemoryFormatted
            lines.append(String(format: "Mémoire vive Système : %.1f %% (%.2f Go / %.2f Go)", systemMemoryPercentage, usedGB, totalGB))
            lines.append("Mémoire vive Align : \(appRAM)")
        }
        return lines.isEmpty ? "Utilisation des ressources" : lines.joined(separator: "\n")
    }
}

public protocol SystemResourceSampling: Sendable {
    func sample() async -> SystemResourceSnapshot
}

public actor DarwinResourceSampler: SystemResourceSampling {
    private var previousCPUTicks: host_cpu_load_info?

    public init() {}

    public func sample() async -> SystemResourceSnapshot {
        let (currentTicks, systemCPU) = Self.sampleSystemCPU(previousTicks: previousCPUTicks)
        let memoryInfo = Self.sampleSystemMemory()
        let appCPU = Self.sampleProcessCPU()
        let appMemory = Self.sampleProcessMemoryFootprint()

        if let currentTicks {
            self.previousCPUTicks = currentTicks
        }

        return SystemResourceSnapshot(
            systemCPUPercentage: systemCPU,
            systemMemoryPercentage: memoryInfo?.percentage,
            systemMemoryUsedBytes: memoryInfo?.usedBytes,
            systemMemoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
            appCPUPercentage: appCPU,
            appMemoryFootprintBytes: appMemory,
            timestamp: Date()
        )
    }

    public static func sampleSystemCPUTicks() -> host_cpu_load_info? {
        var cpuLoad = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &cpuLoad) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return cpuLoad
    }

    public static func sampleSystemCPU(previousTicks: host_cpu_load_info?) -> (host_cpu_load_info?, Double?) {
        guard let current = sampleSystemCPUTicks() else { return (nil, nil) }
        guard let prev = previousTicks else { return (current, nil) }

        let user = Double(current.cpu_ticks.0 - prev.cpu_ticks.0)
        let sys = Double(current.cpu_ticks.1 - prev.cpu_ticks.1)
        let idle = Double(current.cpu_ticks.2 - prev.cpu_ticks.2)
        let nice = Double(current.cpu_ticks.3 - prev.cpu_ticks.3)
        let total = user + sys + idle + nice
        guard total > 0 else { return (current, 0.0) }
        let used = user + sys + nice
        let pct = max(0.0, min(100.0, (used / total) * 100.0))
        return (current, pct)
    }

    public static func sampleSystemMemory(
        totalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> (percentage: Double, usedBytes: UInt64)? {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return nil
        }
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let wire = UInt64(vmStats.wire_count) * UInt64(pageSize)
        let active = UInt64(vmStats.active_count) * UInt64(pageSize)
        let compressed = UInt64(vmStats.compressor_page_count) * UInt64(pageSize)
        let usedBytes = min(wire + active + compressed, totalMemory)
        let percentage = totalMemory > 0 ? (Double(usedBytes) / Double(totalMemory)) * 100.0 : 0.0
        return (max(0.0, min(100.0, percentage)), usedBytes)
    }

    public static func sampleProcessCPU() -> Double? {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let kr = task_threads(mach_task_self_, &threadList, &threadCount)
        guard kr == KERN_SUCCESS, let threads = threadList else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: threads),
                vm_size_t(threadCount * UInt32(MemoryLayout<thread_t>.size))
            )
        }
        var totalUsage: Float = 0
        let infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var currentCount = infoCount
            let threadKr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(currentCount)) {
                    Darwin.thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &currentCount)
                }
            }
            if threadKr == KERN_SUCCESS && (info.flags & TH_FLAGS_IDLE) == 0 {
                totalUsage += Float(info.cpu_usage) / Float(TH_USAGE_SCALE) * 100.0
            }
        }
        return Double(totalUsage)
    }

    public static func sampleProcessMemoryFootprint() -> UInt64? {
        var taskVM = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &taskVM) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return UInt64(taskVM.phys_footprint)
    }
}

@MainActor
public final class SystemResourceMonitor: ObservableObject {
    @Published public private(set) var snapshot: SystemResourceSnapshot
    @Published public private(set) var isMonitoringActive: Bool = false

    private let sampler: SystemResourceSampling
    private let sampleInterval: TimeInterval
    private var samplingTask: Task<Void, Never>?
    private var appActiveObserver: NSObjectProtocol?
    private var appResignObserver: NSObjectProtocol?
    private var presentationAllowsSampling: Bool = false

    public init(
        sampler: SystemResourceSampling = DarwinResourceSampler(),
        sampleInterval: TimeInterval = 5,
        initialSnapshot: SystemResourceSnapshot = .init()
    ) {
        self.sampler = sampler
        self.sampleInterval = sampleInterval
        self.snapshot = initialSnapshot
        setupAppNotifications()
    }

    deinit {
        samplingTask?.cancel()
        if let appActiveObserver { NotificationCenter.default.removeObserver(appActiveObserver) }
        if let appResignObserver { NotificationCenter.default.removeObserver(appResignObserver) }
    }

    public func start() {
        presentationAllowsSampling = true
        evaluateSamplingState()
    }

    public func stop() {
        presentationAllowsSampling = false
        evaluateSamplingState()
    }

    public func setPresentationActive(_ active: Bool) {
        presentationAllowsSampling = active
        evaluateSamplingState()
    }

    private func setupAppNotifications() {
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluateSamplingState()
            }
        }

        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluateSamplingState()
            }
        }
    }

    private func evaluateSamplingState() {
        let isAppActive = NSApp?.isActive ?? true
        let shouldSample = presentationAllowsSampling && isAppActive

        if shouldSample && !isMonitoringActive {
            startSamplingLoop()
        } else if !shouldSample && isMonitoringActive {
            stopSamplingLoop()
        }
    }

    private func startSamplingLoop() {
        isMonitoringActive = true
        samplingTask?.cancel()
        samplingTask = Task { [weak self, sampler, sampleInterval] in
            let initial = await sampler.sample()
            if Task.isCancelled { return }
            await MainActor.run {
                self?.snapshot = initial
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            let second = await sampler.sample()
            if Task.isCancelled { return }
            await MainActor.run {
                self?.snapshot = second
            }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(sampleInterval * 1_000_000_000))
                if Task.isCancelled { break }
                let newSnapshot = await sampler.sample()
                if Task.isCancelled { break }
                await MainActor.run {
                    self?.snapshot = newSnapshot
                }
            }
        }
    }

    private func stopSamplingLoop() {
        isMonitoringActive = false
        samplingTask?.cancel()
        samplingTask = nil
    }
}
