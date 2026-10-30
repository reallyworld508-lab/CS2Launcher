import Foundation

/// Runs CrossOver's `wine` driver script inside one bottle.
public struct WineRunner: Sendable {
    public let locator: CrossOverLocator
    public let bottle: Bottle
    public let runner: ProcessRunning

    public init(locator: CrossOverLocator, bottle: Bottle, runner: ProcessRunning) {
        self.locator = locator
        self.bottle = bottle
        self.runner = runner
    }

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
