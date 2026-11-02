import Foundation
import CS2LauncherCore

/// Real backend: wires the UI to the core managers.
struct LiveBackend: LauncherBackend {
    let paths: Paths
    private let runner: ProcessRunning
    private let downloader: Downloading
    private let locator: CrossOverLocator
    private let throttler: BackgroundThrottler

    init(paths: Paths = .default,
         runner: ProcessRunning = SystemProcessRunner(),
         downloader: Downloading = URLSessionDownloader(),
         locator: CrossOverLocator = CrossOverLocator()) {
        self.paths = paths
        self.runner = runner
        self.downloader = downloader
        self.locator = locator
        self.throttler = BackgroundThrottler(runner: runner)
    }

    /// The engine chosen in the settings (read on every call, so a change applies at once).
    var engineKind: EngineKind { Settings.load(from: paths.settingsFile).engine }

    private var freeEngine: FreeEngine { FreeEngine(root: paths.engine) }
    private var bottle: Bottle { Bottle(locator: locator, runner: runner) }
    private var wine: any WineRunning {
        engineKind == .free ? FreeWineRunner(engine: freeEngine, runner: runner)
                            : WineRunner(locator: locator, bottle: bottle, runner: runner)
    }
    private var layout: any SteamLayout { engineKind == .free ? freeEngine : bottle }
    private var steam: SteamInstaller {
        var installer = SteamInstaller(wine: wine, downloader: downloader, downloads: paths.downloads)
        installer.primesClient = engineKind == .free
        return installer
    }
    private var game: GameLauncher { GameLauncher(wine: wine) }
    private var migration: LegacyMigration { LegacyMigration(paths: paths, bottle: bottle) }

    func systemCheck() async -> SystemCheckResult {
        await SystemCheck(runner: runner).perform()
    }

    func isEngineInstalled() -> Bool { freeEngine.isEngineInstalled }
    func isGPTKReady() -> Bool { freeEngine.isD3DMetalValid }
    func isFreePrefixReady() -> Bool { freeEngine.isPrefixReady }
    func detectedGPTKDmg() -> URL? { GPTKInstaller(runner: runner, engine: freeEngine).detectedDmg }

    func installEngine(progress: @escaping @Sendable (Double) -> Void,
                       log: @escaping @Sendable (String) -> Void) async throws {
        try await FreeEngineInstaller(runner: runner, downloader: downloader, engine: freeEngine,
                                      downloads: paths.downloads).install(progress: progress, log: log)
    }

    func installGPTK(dmg: URL?, log: @escaping @Sendable (String) -> Void) async throws {
        try await GPTKInstaller(runner: runner, engine: freeEngine).install(dmg: dmg, log: log)
    }

    func createPrefix(log: @escaping @Sendable (String) -> Void) async throws {
        try await FreePrefixManager(engine: freeEngine, runner: runner).create(log: log)
    }

    func applyRecommendedGraphics(settings: Settings, displaySize: (width: Int, height: Int)?,
                                  log: @escaping @Sendable (String) -> Void) -> Int {
        let size = settings.nativeAspect ? (displaySize ?? (settings.windowWidth, settings.windowHeight))
                                         : (settings.windowWidth, settings.windowHeight)
        return VideoConfig.apply(userdata: layout.steamUserdata, width: size.0, height: size.1,
                                 nativeAspect: settings.nativeAspect, log: log).count
    }

    func ensureWebHelperPatched(log: @escaping @Sendable (String) -> Void) -> Bool {
        guard engineKind == .free, let data = try? SteamWebHelperPatch.bundledWrapper() else { return false }
        let patch = SteamWebHelperPatch(steamDirectory: layout.steamDirectory, wrapperData: data)
        guard !patch.isApplied else { return false }
        do {
            let changed = try patch.apply()
            if !changed.isEmpty { log("Установлена обёртка steamwebhelper (\(changed.count))") }
            return !changed.isEmpty
        } catch {
            log("Не удалось установить обёртку steamwebhelper: \(error.localizedDescription)")
            return false
        }
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

    func isLegacyMigrationAvailable() -> Bool { engineKind == .crossover && migration.isAvailable }

    func migrateLegacy(log: @escaping @Sendable (String) -> Void) async throws {
        try await migration.migrate(runner: runner, log: log)
    }

    func isSteamInstalled() -> Bool { steam.isInstalled }

    func installSteam(progress: @escaping @Sendable (Double) -> Void,
                      log: @escaping @Sendable (String) -> Void) async throws {
        try await steam.install(progress: progress, log: log)
        _ = ensureWebHelperPatched(log: log)
    }

    func cs2InstallState() -> CS2InstallState { SteamLibrary(layout: layout).cs2State() }

    func isSteamRunning() async -> Bool { await GameLauncher.isSteamRunning(runner: runner) }

    func isGameRunning() async -> Bool { await GameLauncher.isGameRunning(runner: runner) }

    func applyPerformanceTweaks(settings: Settings, steamRunning: Bool,
                                log: @escaping @Sendable (String) -> Void) {
        if engineKind == .free {
            PerformanceTweaks.apply(layout: freeEngine, settings: settings, steamRunning: steamRunning, log: log)
        } else {
            PerformanceTweaks.apply(bottle: bottle, settings: settings, steamRunning: steamRunning, log: log)
        }
    }

    func launch(settings: Settings, launchGame: Bool,
                log: @escaping @Sendable (String) -> Void) throws -> RunningProcess {
        _ = ensureWebHelperPatched(log: log)
        return try game.launch(settings: settings, launchGame: launchGame, log: log)
    }

    func stopAll() async { await game.stop() }

    func throttleBackground() async -> Int { await throttler.demoteNew() }
    func restoreBackground() async -> Int { await throttler.restoreAll() }
    func restoreBackgroundBlocking() { throttler.restoreAllBlocking() }
    func memoryReport() async -> MemoryReport { await MemoryCheck.collect(runner: runner) }

    func installRosetta(log: @escaping @Sendable (String) -> Void) async throws {
        try await RosettaInstaller(runner: runner).install(log: log)
    }

    func installCrossOver(progress: @escaping @Sendable (Double) -> Void,
                          log: @escaping @Sendable (String) -> Void) async throws {
        try await CrossOverInstaller(runner: runner, downloader: downloader, locator: locator,
                                     downloads: paths.downloads).install(progress: progress, log: log)
    }
}
