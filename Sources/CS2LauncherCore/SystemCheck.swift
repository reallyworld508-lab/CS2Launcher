import Foundation

public struct SystemCheckResult: Equatable, Sendable {
    public var rosettaInstalled: Bool
    public var macOSVersion: String
    public var macOSSupported: Bool
    public var freeDiskBytes: Int64
    public var enoughDisk: Bool
    public var isAppleSilicon: Bool

    public init(rosettaInstalled: Bool, macOSVersion: String, macOSSupported: Bool,
                freeDiskBytes: Int64, enoughDisk: Bool, isAppleSilicon: Bool) {
        self.rosettaInstalled = rosettaInstalled
        self.macOSVersion = macOSVersion
        self.macOSSupported = macOSSupported
        self.freeDiskBytes = freeDiskBytes
        self.enoughDisk = enoughDisk
        self.isAppleSilicon = isAppleSilicon
    }

    /// Checks that Rosetta's own installer cannot fix. Low disk space only warns: CS2 may already be installed.
    public var blockingPassed: Bool { macOSSupported && isAppleSilicon }

    public var allPassed: Bool { rosettaInstalled && macOSSupported && enoughDisk && isAppleSilicon }
}

public struct SystemCheck: Sendable {
    let runner: ProcessRunning
    let volumeURL: URL

    public static let requiredFreeBytes: Int64 = 45 * 1024 * 1024 * 1024

    public init(runner: ProcessRunning, volumeURL: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.runner = runner
        self.volumeURL = volumeURL
    }

    public func perform() async -> SystemCheckResult {
        let rosetta: Bool
        if let code = try? await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/arch"),
            arguments: ["-x86_64", "/usr/bin/true"], environment: [:],
            currentDirectory: nil, onOutput: { _ in }) {
            rosetta = (code == 0)
        } else {
            rosetta = false
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        var free: Int64 = 0
        if let vals = try? volumeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = vals.volumeAvailableCapacityForImportantUsage {
            free = cap
        }
        #if arch(arm64)
        let arm = true
        #else
        let arm = Self.sysctlArm64()
        #endif
        return SystemCheckResult(
            rosettaInstalled: rosetta, macOSVersion: version, macOSSupported: v.majorVersion >= 15,
            freeDiskBytes: free, enoughDisk: free >= Self.requiredFreeBytes, isAppleSilicon: arm)
    }

    static func sysctlArm64() -> Bool {
        var val: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &val, &size, nil, 0) == 0 && val == 1
    }
}
