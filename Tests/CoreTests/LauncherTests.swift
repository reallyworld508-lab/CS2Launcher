import XCTest
@testable import CS2LauncherCore

private final class MockDownloader: Downloading, @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        lock.lock(); _urls.append(url); lock.unlock()
        progress(0.5); progress(1)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: destination)
    }
}

private final class DoubleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: [Double] = []
    func add(_ d: Double) { lock.lock(); _v.append(d); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return _v }
}

final class LauncherTests: XCTestCase {
    private let steamExe = URL(fileURLWithPath: "/b/steam.exe")

    func testOldDefaultSteamArgsMigrated() throws {
        let url = makeTempDir().appendingPathComponent("s.json")
        try Data(#"{"steamArgs":"-cef-disable-gpu-compositing"}"#.utf8).write(to: url)
        XCTAssertEqual(Settings.load(from: url).steamArgs, "")
        try Data(#"{"steamArgs":"-foo"}"#.utf8).write(to: url)
        XCTAssertEqual(Settings.load(from: url).steamArgs, "-foo")
    }

    private func makeWine() -> (WineRunner, MockProcessRunner, Bottle) {
        let fx = CrossOverFixture()
        let mock = MockProcessRunner()
        return (WineRunner(locator: fx.locator, bottle: fx.bottle, runner: mock), mock, fx.bottle)
    }

    private func createSteamExe(_ bottle: Bottle) throws {
        try FileManager.default.createDirectory(at: bottle.steamExe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: bottle.steamExe)
    }

    func testSplitPlain() {
        XCTAssertEqual(GameLauncher.splitArguments("-novid -fullscreen"), ["-novid", "-fullscreen"])
    }
    func testSplitQuoted() {
        XCTAssertEqual(GameLauncher.splitArguments(#"-a "b c" 'd e' f"#), ["-a", "b c", "d e", "f"])
        XCTAssertEqual(GameLauncher.splitArguments(#"+name "" x"#), ["+name", "", "x"])
    }
    func testSplitEmptyAndSpaces() {
        XCTAssertEqual(GameLauncher.splitArguments(""), [])
        XCTAssertEqual(GameLauncher.splitArguments("   "), [])
        XCTAssertEqual(GameLauncher.splitArguments("  -a    -b  "), ["-a", "-b"])
    }

    func testSteamArgumentsWithoutGame() {
        XCTAssertEqual(GameLauncher.steamArguments(steamExe: steamExe, settings: Settings(), launchGame: false),
                       [steamExe.path])
        var s = Settings(); s.steamArgs = "-foo"
        XCTAssertEqual(GameLauncher.steamArguments(steamExe: steamExe, settings: s, launchGame: false),
                       [steamExe.path, "-foo"])
    }
    func testSteamArgumentsWithGameAndFps() {
        var s = Settings(); s.fpsCap = 144
        XCTAssertEqual(GameLauncher.steamArguments(steamExe: steamExe, settings: s, launchGame: true),
                       [steamExe.path, "-applaunch", "730", "-novid", "-windowed", "-noborder", "-w", "1024", "-h", "768",
                        "+fps_max", "144"])
    }
    func testNoRendererOrVerifyFlagsForced() {
        var s = Settings(); s.gameArgs = ""
        let a = GameLauncher.steamArguments(steamExe: steamExe, settings: s, launchGame: true)
        XCTAssertEqual(a, [steamExe.path, "-applaunch", "730", "-w", "1024", "-h", "768"])
        XCTAssertFalse(a.contains("-vulkan"))
        XCTAssertFalse(a.contains("-noverifyfiles"))
        XCTAssertFalse(GameLauncher.steamArguments(steamExe: steamExe, settings: Settings(), launchGame: true).contains("-vulkan"))
    }
    func testSteamArgumentsNoFpsWhenZeroOrNil() {
        var s = Settings()
        XCTAssertFalse(GameLauncher.steamArguments(steamExe: steamExe, settings: s, launchGame: true).contains("+fps_max"))
        s.fpsCap = 0
        XCTAssertFalse(GameLauncher.steamArguments(steamExe: steamExe, settings: s, launchGame: true).contains("+fps_max"))
    }

    func testEnvironmentToggles() {
        var s = Settings(); s.metalHUD = false
        XCTAssertEqual(GameLauncher.environment(for: s), [:])
        s.metalHUD = true
        XCTAssertEqual(GameLauncher.environment(for: s), ["MTL_HUD_ENABLED": "1"])
    }

    func testLaunchThrowsWhenSteamMissing() {
        let (wine, mock, _) = makeWine()
        XCTAssertThrowsError(try GameLauncher(wine: wine).launch(settings: Settings(), launchGame: true, log: { _ in })) {
            XCTAssertEqual($0 as? LauncherError, .steamNotInstalled)
        }
        XCTAssertTrue(mock.calls.isEmpty)
    }

    func testLaunchStartsSteam() throws {
        let (wine, mock, bottle) = makeWine()
        try createSteamExe(bottle)
        var st = Settings(); st.metalHUD = true
        _ = try GameLauncher(wine: wine).launch(settings: st, launchGame: true, log: { _ in })
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls[0].arguments,
                       ["--bottle", "CS2", "--no-wait", bottle.steamExe.path, "-applaunch", "730", "-novid", "-windowed", "-noborder", "-w", "1024", "-h", "768"])
        XCTAssertEqual(mock.calls[0].environment["MTL_HUD_ENABLED"], "1")
    }

    func testStopRunsWineserverKill() async {
        let (wine, mock, _) = makeWine()
        await GameLauncher(wine: wine).stop()
        XCTAssertEqual(mock.calls.first?.arguments, ["-k"])
        XCTAssertEqual(mock.calls.first?.executable.lastPathComponent, "wineserver")
    }

    func testCS2Path() {
        let (wine, _, _) = makeWine()
        let g = GameLauncher(wine: wine)
        XCTAssertTrue(g.cs2Executable.path.hasSuffix("Counter-Strike Global Offensive/game/bin/win64/cs2.exe"))
        XCTAssertFalse(g.isCS2Installed)
        try? FileManager.default.createDirectory(at: g.cs2Executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: g.cs2Executable)
        XCTAssertTrue(g.isCS2Installed)
    }

    func testInstallHappyPath() async throws {
        let (wine, mock, bottle) = makeWine()
        let downloads = makeTempDir()
        mock.exitCodeHandler = { _ in
            try? FileManager.default.createDirectory(at: bottle.steamExe.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: bottle.steamExe)
            return 0
        }
        let dl = MockDownloader()
        let inst = SteamInstaller(wine: wine, downloader: dl, downloads: downloads, pollInterval: .milliseconds(10), pollTimeout: .seconds(1))
        XCTAssertFalse(inst.isInstalled)
        let prog = DoubleBox()
        try await inst.install(progress: { prog.add($0) }, log: { _ in })
        XCTAssertTrue(inst.isInstalled)
        XCTAssertEqual(dl.urls, [SteamInstaller.installerURL])
        let installerPath = downloads.appendingPathComponent("SteamSetup.exe").path
        XCTAssertEqual(mock.calls.first?.arguments, ["--bottle", "CS2", installerPath, "/S"])
        XCTAssertEqual(prog.values.last, 1.0)
        XCTAssertTrue(prog.values.contains(0.6))
    }

    func testInstallPollTimeoutIsSixMinutes() {
        let (wine, _, _) = makeWine()
        let inst = SteamInstaller(wine: wine, downloader: MockDownloader(), downloads: makeTempDir())
        XCTAssertEqual(inst.pollTimeout, .seconds(360))
    }

    func testInstallerFailure() async {
        let (wine, mock, _) = makeWine()
        mock.defaultExitCode = 3
        let inst = SteamInstaller(wine: wine, downloader: MockDownloader(), downloads: makeTempDir(), pollInterval: .milliseconds(10), pollTimeout: .milliseconds(50))
        do {
            try await inst.install(progress: { _ in }, log: { _ in })
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? LauncherError, .installerFailed(3))
        }
    }

    func testSteamExeMissingAfterInstall() async {
        let (wine, _, _) = makeWine()
        let inst = SteamInstaller(wine: wine, downloader: MockDownloader(), downloads: makeTempDir(), pollInterval: .milliseconds(10), pollTimeout: .milliseconds(50))
        do {
            try await inst.install(progress: { _ in }, log: { _ in })
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? LauncherError, .steamExeMissingAfterInstall)
        }
    }
}
