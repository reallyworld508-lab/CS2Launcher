import Foundation
import CS2LauncherCore

/// Real backend: wires the UI to the core managers.
struct LiveBackend: LauncherBackend {
    let paths: Paths
    private let runner: ProcessRunning
    private let downloader: Downloading

    init(paths: Paths = .default,
         runner: ProcessRunning = SystemProcessRunner(),
         downloader: Downloading = URLSessionDownloader()) {
        self.paths = paths
        self.runner = runner
        self.downloader = downloader
    }

    private var wine: WineRunner { WineRunner(paths: paths, runner: runner) }
    private var runtime: RuntimeManager { RuntimeManager(paths: paths, downloader: downloader, runner: runner) }
    private var prefix: PrefixManager { PrefixManager(wine: wine) }
    private var steam: SteamInstaller { SteamInstaller(wine: wine, downloader: downloader) }
    private var game: GameLauncher { GameLauncher(wine: wine) }

    func systemCheck() async -> SystemCheckResult {
        await SystemCheck(runner: runner).perform()
    }

    func isWineInstalled() -> Bool { runtime.isWineInstalled }

    func installWine(progress: @escaping @Sendable (Double) -> Void,
                     log: @escaping @Sendable (String) -> Void) async throws {
        try paths.ensureDirectories()
        try await runtime.installWine(progress: progress, log: log)
    }

    func isPrefixReady() -> Bool { prefix.isInitialized }

    func createPrefix(log: @escaping @Sendable (String) -> Void) async throws {
        try await prefix.initialize(log: log)
    }

    func prefixNeedsUpdate() -> Bool { prefix.needsUpdate }

    func updatePrefix(log: @escaping @Sendable (String) -> Void) async throws {
        try await prefix.update(log: log)
    }

    func applySettings(_ s: Settings, log: @escaping @Sendable (String) -> Void) async throws {
        try await prefix.apply(s, log: log)
    }

    func isSteamInstalled() -> Bool { steam.isInstalled }

    func installSteam(progress: @escaping @Sendable (Double) -> Void,
                      log: @escaping @Sendable (String) -> Void) async throws {
        try await steam.install(progress: progress, log: log)
    }

    func isCS2Installed() -> Bool { game.isCS2Installed }

    func launch(settings: Settings, launchGame: Bool,
                log: @escaping @Sendable (String) -> Void) throws -> RunningProcess {
        try game.launch(settings: settings, launchGame: launchGame, log: log)
    }

    func stopAll() async { await game.stop() }
}
