import Foundation

/// Where Steam lives inside a Wine prefix (a CrossOver bottle or the free engine's prefix).
public protocol SteamLayout: Sendable {
    var driveC: URL { get }
}

public extension SteamLayout {
    var steamDirectory: URL { driveC.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true) }
    var steamExe: URL { steamDirectory.appendingPathComponent("steam.exe") }
    var steamUserdata: URL { steamDirectory.appendingPathComponent("userdata", isDirectory: true) }
    var steamapps: URL { steamDirectory.appendingPathComponent("steamapps", isDirectory: true) }
}

/// A Wine that can run programs in one prefix; implemented for CrossOver and for the free engine.
public protocol WineRunning: Sendable {
    var steamLayout: any SteamLayout { get }
    /// Extra flags for `steam.exe` that keep Steam from undoing the web helper wrapper (free engine only).
    var steamFlags: [String] { get }
    func run(_ args: [String], extraEnvironment: [String: String],
             onOutput: @escaping @Sendable (String) -> Void) async throws -> Int32
    func start(_ args: [String], extraEnvironment: [String: String],
               onOutput: @escaping @Sendable (String) -> Void) throws -> RunningProcess
    func killAll() async
}

/// Runs CrossOver's `wine` driver script inside one bottle.
public struct WineRunner: Sendable, WineRunning {
    public let locator: CrossOverLocator
    public let bottle: Bottle
    public let runner: ProcessRunning

    public init(locator: CrossOverLocator, bottle: Bottle, runner: ProcessRunning) {
        self.locator = locator
        self.bottle = bottle
        self.runner = runner
    }

    public var steamLayout: any SteamLayout { bottle }
    public var steamFlags: [String] { [] }

    public var wineExecutable: URL { locator.wineScript }
    public var wineserverExecutable: URL { locator.wineserver }

    public func baseEnvironment() -> [String: String] {
        ["WINEDEBUG": "-all"]
    }

    private func env(_ extra: [String: String]) -> [String: String] {
        baseEnvironment().merging(extra) { _, new in new }
    }

    public func arguments(_ args: [String], noWait: Bool = false) -> [String] {
        ["--bottle", bottle.name] + (noWait ? ["--no-wait"] : []) + args
    }

    public func run(_ args: [String], extraEnvironment: [String: String] = [:],
                    onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Int32 {
        guard locator.isInstalled else { throw CrossOverError.notInstalled }
        return try await runner.run(executable: wineExecutable, arguments: arguments(args),
                                    environment: env(extraEnvironment), currentDirectory: nil, onOutput: onOutput)
    }

    public func start(_ args: [String], extraEnvironment: [String: String] = [:],
                      onOutput: @escaping @Sendable (String) -> Void = { _ in }) throws -> RunningProcess {
        guard locator.isInstalled else { throw CrossOverError.notInstalled }
        return try runner.start(executable: wineExecutable, arguments: arguments(args, noWait: true),
                                environment: env(extraEnvironment), currentDirectory: nil, onOutput: onOutput)
    }

    /// `wineserver` is a plain binary without `--bottle`, so it is pointed at the bottle through WINEPREFIX.
    public func killAll() async {
        _ = try? await runner.run(executable: wineserverExecutable, arguments: ["-k"],
                                  environment: env(["WINEPREFIX": bottle.path.path]),
                                  currentDirectory: nil, onOutput: { _ in })
    }
}
