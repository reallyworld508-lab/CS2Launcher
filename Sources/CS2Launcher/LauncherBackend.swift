import Foundation
import CS2LauncherCore

protocol LauncherBackend: Sendable {
    var paths: Paths { get }
    func systemCheck() async -> SystemCheckResult
    func isWineInstalled() -> Bool
    func installWine(progress: @escaping @Sendable (Double) -> Void, log: @escaping @Sendable (String) -> Void) async throws
    func isPrefixReady() -> Bool
    func createPrefix(log: @escaping @Sendable (String) -> Void) async throws
    func applySettings(_ s: Settings, log: @escaping @Sendable (String) -> Void) async throws
    func isSteamInstalled() -> Bool
    func installSteam(progress: @escaping @Sendable (Double) -> Void, log: @escaping @Sendable (String) -> Void) async throws
    func isCS2Installed() -> Bool
    func launch(settings: Settings, launchGame: Bool, log: @escaping @Sendable (String) -> Void) throws -> RunningProcess
    func stopAll() async
}

/// Fake process for previews.
final class FakeRunningProcess: RunningProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    func terminate() { lock.lock(); running = false; lock.unlock() }
    func waitUntilExit() async -> Int32 {
        while isRunning { try? await Task.sleep(nanoseconds: 200_000_000) }
        return 0
    }
}

/// Fake backend: everything succeeds after short delays. State is kept in memory.
final class PreviewBackend: LauncherBackend, @unchecked Sendable {
    let paths: Paths
    private let lock = NSLock()
    private var wine = false, prefix = false, steam = false, cs2 = false

    init(paths: Paths = Paths(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("CS2LauncherPreview", isDirectory: true))) {
        self.paths = paths
    }

    private func set(_ f: () -> Void) { lock.lock(); f(); lock.unlock() }
    private func get(_ f: () -> Bool) -> Bool { lock.lock(); defer { lock.unlock() }; return f() }
    private func nap(_ ms: UInt64 = 400) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    func systemCheck() async -> SystemCheckResult {
        await nap()
        return SystemCheckResult(rosettaInstalled: true, macOSVersion: "26.0.0", macOSSupported: true,
                                 freeDiskBytes: 200 * 1024 * 1024 * 1024, enoughDisk: true, isAppleSilicon: true)
    }
    func isWineInstalled() -> Bool { get { wine } }
    func installWine(progress: @escaping @Sendable (Double) -> Void, log: @escaping @Sendable (String) -> Void) async throws {
        log("[preview] Загрузка Wine…")
        for i in 1...10 { await nap(150); progress(Double(i) / 10) }
        log("[preview] Wine установлен")
        set { wine = true }
    }
    func isPrefixReady() -> Bool { get { prefix } }
    func createPrefix(log: @escaping @Sendable (String) -> Void) async throws {
        log("[preview] wineboot --init")
        await nap(1000)
        set { prefix = true }
    }
    func applySettings(_ s: Settings, log: @escaping @Sendable (String) -> Void) async throws {
        log("[preview] Настройки применены")
    }
    func isSteamInstalled() -> Bool { get { steam } }
    func installSteam(progress: @escaping @Sendable (Double) -> Void, log: @escaping @Sendable (String) -> Void) async throws {
        log("[preview] Загрузка SteamSetup.exe…")
        for i in 1...10 { await nap(120); progress(Double(i) / 10) }
        set { steam = true }
    }
    func isCS2Installed() -> Bool { get { cs2 } }
    func launch(settings: Settings, launchGame: Bool, log: @escaping @Sendable (String) -> Void) throws -> RunningProcess {
        log(launchGame ? "[preview] Запуск CS2 \(settings.gameArgs)" : "[preview] Запуск Steam \(settings.steamArgs)")
        set { cs2 = true }
        let p = FakeRunningProcess()
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { p.terminate() }
        return p
    }
    func stopAll() async { await nap(200) }
}

typealias LauncherSettings = CS2LauncherCore.Settings
