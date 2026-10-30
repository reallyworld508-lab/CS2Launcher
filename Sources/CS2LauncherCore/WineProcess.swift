import Foundation

public struct WineRunner: Sendable {
    public let paths: Paths
    public let runner: ProcessRunning

    public init(paths: Paths, runner: ProcessRunning) {
        self.paths = paths
        self.runner = runner
    }

    public var wineExecutable: URL {
        let w64 = paths.wineBin.appendingPathComponent("wine64")
        return FileManager.default.fileExists(atPath: w64.path)
            ? w64 : paths.wineBin.appendingPathComponent("wine")
    }

    public var wineserverExecutable: URL { paths.wineBin.appendingPathComponent("wineserver") }

    public func baseEnvironment() -> [String: String] {
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return [
            "WINEPREFIX": paths.prefix.path,
            "WINEDEBUG": "-all",
            "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
            "PATH": paths.wineBin.path + ":" + currentPath,
        ]
    }

    private func env(_ extra: [String: String]) -> [String: String] {
        baseEnvironment().merging(extra) { _, new in new }
    }

    public func run(_ arguments: [String], extraEnvironment: [String: String] = [:],
                    onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Int32 {
        try await runner.run(executable: wineExecutable, arguments: arguments,
                             environment: env(extraEnvironment), currentDirectory: nil, onOutput: onOutput)
    }

    public func start(_ arguments: [String], extraEnvironment: [String: String] = [:],
                      onOutput: @escaping @Sendable (String) -> Void = { _ in }) throws -> RunningProcess {
        try runner.start(executable: wineExecutable, arguments: arguments,
                         environment: env(extraEnvironment), currentDirectory: nil, onOutput: onOutput)
    }

    public func killAll() async {
        _ = try? await runner.run(executable: wineserverExecutable, arguments: ["-k"],
                                  environment: baseEnvironment(), currentDirectory: nil, onOutput: { _ in })
    }
}
