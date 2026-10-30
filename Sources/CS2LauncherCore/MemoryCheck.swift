import Foundation

public struct AppMemory: Equatable, Sendable {
    public let name: String
    public let bytes: Int64
    public init(name: String, bytes: Int64) {
        self.name = name
        self.bytes = bytes
    }
}

public struct MemoryReport: Equatable, Sendable {
    public var freePercent: Int?
    public var swapUsedBytes: Int64?
    public var topApps: [AppMemory]
    public init(freePercent: Int?, swapUsedBytes: Int64?, topApps: [AppMemory]) {
        self.freePercent = freePercent
        self.swapUsedBytes = swapUsedBytes
        self.topApps = topApps
    }
    public var isLow: Bool { MemoryCheck.isLow(freePercent: freePercent, swapUsedBytes: swapUsedBytes) }
}

public enum MemoryCheck {
    public static let minFreePercent = 30
    public static let maxSwapBytes: Int64 = 3 * 1024 * 1024 * 1024

    public static func isLow(freePercent: Int?, swapUsedBytes: Int64?) -> Bool {
        if let f = freePercent, f < minFreePercent { return true }
        if let s = swapUsedBytes, s > maxSwapBytes { return true }
        return false
    }

    /// "System-wide memory free percentage: 42%"
    public static func parseFreePercent(_ lines: [String]) -> Int? {
        for l in lines where l.contains("System-wide memory free percentage:") {
            let digits = l.split(separator: ":").last?.filter(\.isNumber) ?? ""
            if let v = Int(digits) { return v }
        }
        return nil
    }

    /// "vm.swapusage: total = 5120.00M  used = 4505.25M  free = 614.75M  (encrypted)"
    public static func parseSwapUsed(_ lines: [String]) -> Int64? {
        for l in lines {
            guard let r = l.range(of: "used = ") else { continue }
            let token = l[r.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            guard let unit = token.last, let value = Double(token.dropLast()) else { continue }
            let mult: Double
            switch unit {
            case "K": mult = 1024
            case "M": mult = 1024 * 1024
            case "G": mult = 1024 * 1024 * 1024
            default: continue
            }
            return Int64(value * mult)
        }
        return nil
    }

    /// Display name: the outermost `.app` bundle, otherwise the executable name.
    static func appName(of command: String) -> String {
        let comps = command.split(separator: "/")
        if let app = comps.first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
        return comps.last.map(String.init) ?? command
    }

    /// Parses `ps -axo rss=,comm=` (RSS in KiB), sums by app and returns the biggest `limit`.
    public static func topApps(_ lines: [String], limit: Int = 5) -> [AppMemory] {
        var totals: [String: Int64] = [:]
        for raw in lines {
            let parts = raw.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let kb = Int64(parts[0]) else { continue }
            totals[appName(of: String(parts[1])), default: 0] += kb * 1024
        }
        return totals.map { AppMemory(name: $0.key, bytes: $0.value) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
            .prefix(limit).map { $0 }
    }

    public static func collect(runner: ProcessRunning) async -> MemoryReport {
        func output(_ exe: String, _ args: [String]) async -> [String] {
            let box = OutputBox()
            _ = try? await runner.run(executable: URL(fileURLWithPath: exe), arguments: args,
                                      environment: [:], currentDirectory: nil, onOutput: { box.add($0) })
            return box.lines
        }
        let free = parseFreePercent(await output("/usr/bin/memory_pressure", []))
        let swap = parseSwapUsed(await output("/usr/sbin/sysctl", ["vm.swapusage"]))
        let top = topApps(await output("/bin/ps", ["-axo", "rss=,comm="]))
        return MemoryReport(freePercent: free, swapUsedBytes: swap, topApps: top)
    }
}

public enum ShaderCacheHint {
    public static let launchesShown = 3
    public static func shouldShow(launchCount: Int) -> Bool { launchCount < launchesShown }
}
