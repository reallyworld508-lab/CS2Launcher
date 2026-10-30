import Foundation
@testable import CS2LauncherCore

/// Reusable mock. Records every run/start call; returns configurable exit codes and output.
final class MockProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
        var currentDirectory: URL?
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

    /// Default exit code when no handler matches.
    var defaultExitCode: Int32 = 0
    /// Lines emitted to onOutput on every call.
    var outputLines: [String] = []
    /// Optional per-call override: return an exit code based on the call.
    var exitCodeHandler: (@Sendable (Call) -> Int32)?
    /// If set, run() throws this.
    var errorToThrow: Error?

    private func record(_ c: Call) -> Int32 {
        lock.lock(); _calls.append(c); lock.unlock()
        return exitCodeHandler?(c) ?? defaultExitCode
    }

    func run(executable: URL, arguments: [String], environment: [String: String],
             currentDirectory: URL?, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let code = record(Call(executable: executable, arguments: arguments,
                               environment: environment, currentDirectory: currentDirectory))
        if let e = errorToThrow { throw e }
        outputLines.forEach(onOutput)
        return code
    }

    func start(executable: URL, arguments: [String], environment: [String: String],
               currentDirectory: URL?, onOutput: @escaping @Sendable (String) -> Void) throws -> RunningProcess {
        let code = record(Call(executable: executable, arguments: arguments,
                               environment: environment, currentDirectory: currentDirectory))
        if let e = errorToThrow { throw e }
        outputLines.forEach(onOutput)
        return MockRunningProcess(exitCode: code)
    }
}

final class MockRunningProcess: RunningProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    let exitCode: Int32
    init(exitCode: Int32 = 0) { self.exitCode = exitCode }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    func terminate() { lock.lock(); running = false; lock.unlock() }
    func waitUntilExit() async -> Int32 { exitCode }
}
