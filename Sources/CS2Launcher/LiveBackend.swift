import Foundation
import CS2LauncherCore

/// Real backend: wires the UI to the core managers.
struct LiveBackend: LauncherBackend {
    let paths: Paths
    private let runner: ProcessRunning
    private let downloader: Downloading
    private let locator: CrossOverLocator

    init(paths: Paths = .default,
         runner: ProcessRunning = SystemProcessRunner(),
         downloader: Downloading = URLSessionDownloader(),
         locator: CrossOverLocator = CrossOverLocator()) {
        self.paths = paths
        self.runner = runner
        self.downloader = downloader
        self.locator = locator
    }

    private var bottle: Bottle { Bottle(locator: locator, runner: runner) }
    private var wine: WineRunner { WineRunner(locator: locator, bottle: bottle, runner: runner) }
    private var steam: SteamInstaller { SteamInstaller(wine: wine, downloader: downloader, downloads: paths.downloads) }
    private var game: GameLauncher { GameLauncher(wine: wine) }
    private var migration: LegacyMigration { LegacyMigration(paths: paths, bottle: bottle) }

    func systemCheck() async -> SystemCheckResult {
        await SystemCheck(runner: runner).perform()
    }

    func isCrossOverInstalled() -> Bool { locator.isInstalled }
    func crossOverVersion() -> String? { locator.version }

    func isBottleReady() -> Bool { bottle.exists && bottle.hasD3DMetal }

    func createBottle(log: @escaping @Sendable (String) -> Void) async throws {
        let b = bottle
        if !b.exists { try await b.create(log: log) }
        try b.ensureD3DMetal()
        log("D3DMetal включён в бутылке «\(b.name)».")
    }

    func isLegacyMigrationAvailable() -> Bool { migration.isAvailable }

    func migrateLegacy(log: @escaping @Sendable (String) -> Void) async throws {
        try await migration.migrate(runner: runner, log: log)
    }

    func isSteamInstalled() -> Bool { steam.isInstalled }

    func installSteam(progress: @escaping @Sendable (Double) -> Void,
                      log: @escaping @Sendable (String) -> Void) async throws {
        try await steam.install(progress: progress, log: log)
    }

    func cs2InstallState() -> CS2InstallState { SteamLibrary(bottle: bottle).cs2State() }

    func isSteamRunning() async -> Bool { await GameLauncher.isSteamRunning(runner: runner) }

    func isGameRunning() async -> Bool { await GameLauncher.isGameRunning(runner: runner) }

    func applyPerformanceTweaks(settings: Settings, steamRunning: Bool,
                                log: @escaping @Sendable (String) -> Void) {
        PerformanceTweaks.apply(bottle: bottle, settings: settings, steamRunning: steamRunning, log: log)
    }

    func launch(settings: Settings, launchGame: Bool,
                log: @escaping @Sendable (String) -> Void) throws -> RunningProcess {
        try game.launch(settings: settings, launchGame: launchGame, log: log)
    }

    func stopAll() async { await game.stop() }
}
