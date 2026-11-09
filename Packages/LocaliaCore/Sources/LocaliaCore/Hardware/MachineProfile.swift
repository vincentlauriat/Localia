import Foundation
import Metal

/// Hardware facts that bound which local models fit. Sizes are GiB (bytes / 1024^3),
/// matching the figures llmfit reports.
public struct MachineProfile: Sendable {
    public let chip: String
    public let totalRAMGB: Double
    /// Metal's `recommendedMaxWorkingSetSize`: what the GPU can really use.
    public let gpuWorkingSetGB: Double
    public let isAppleSilicon: Bool

    public init(chip: String, totalRAMGB: Double, gpuWorkingSetGB: Double, isAppleSilicon: Bool) {
        self.chip = chip
        self.totalRAMGB = totalRAMGB
        self.gpuWorkingSetGB = gpuWorkingSetGB
        self.isAppleSilicon = isAppleSilicon
    }

    /// Memory available for a model: GPU working set on Apple Silicon (unified memory), else RAM, minus headroom.
    public var usablePoolGB: Double {
        max(0, (isAppleSilicon ? gpuWorkingSetGB : totalRAMGB) - LocaliaConstants.gpuHeadroomGB)
    }

    public static func current() -> MachineProfile {
        let gib = 1024.0 * 1024.0 * 1024.0
        let total = Double(ProcessInfo.processInfo.physicalMemory) / gib
        let workingSet = MTLCreateSystemDefaultDevice().map { Double($0.recommendedMaxWorkingSetSize) / gib } ?? 0
        #if arch(arm64)
        let arm = true
        #else
        let arm = false
        #endif
        return MachineProfile(chip: brandString(), totalRAMGB: total, gpuWorkingSetGB: workingSet, isAppleSilicon: arm)
    }

    private static func brandString() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "Unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 else { return "Unknown" }
        return String(cString: buf)
    }
}
