import Foundation
import AppKit
import Darwin

public struct MemoryWarning: Sendable, Equatable {
    public let requiredGB: Double
    public let availableGB: Double
    /// Localized names of heavy apps currently running.
    public let heavyApps: [String]
    public var notEnoughMemory: Bool { requiredGB > availableGB }
}

/// Warns before a model load when memory is short or memory-hungry apps are running.
public struct MemoryGuard: Sendable {
    public static let heavyBundleIDs: [String] = ["com.microsoft.teams2", "com.microsoft.Outlook", "com.google.Chrome"]

    private let availableGB: @Sendable () -> Double
    private let runningHeavyApps: @Sendable () -> [String]

    public init(availableGB: @escaping @Sendable () -> Double = MemoryGuard.systemAvailableGB,
                runningHeavyApps: @escaping @Sendable () -> [String] = MemoryGuard.systemHeavyApps) {
        self.availableGB = availableGB
        self.runningHeavyApps = runningHeavyApps
    }

    public func check(requiredGB: Double, profile: MachineProfile) -> MemoryWarning? {
        let available = availableGB()
        let apps = runningHeavyApps()
        guard requiredGB > available || !apps.isEmpty else { return nil }
        return MemoryWarning(requiredGB: requiredGB, availableGB: available, heavyApps: apps)
    }

    /// (free + inactive + purgeable) pages x page size, in GiB.
    public static let systemAvailableGB: @Sendable () -> Double = {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return 0 }
        let pages = Double(stats.free_count) + Double(stats.inactive_count) + Double(stats.purgeable_count)
        return pages * Double(getpagesize()) / (1024 * 1024 * 1024)
    }

    public static let systemHeavyApps: @Sendable () -> [String] = {
        NSWorkspace.shared.runningApplications
            .filter { app in app.bundleIdentifier.map(heavyBundleIDs.contains) ?? false }
            .compactMap(\.localizedName)
    }
}
