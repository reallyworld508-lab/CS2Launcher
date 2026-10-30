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
    private func makeWine() -> (WineRunner, MockProcessRunner, Paths) {
        let paths = Paths(root: makeTempDir())
        let mock = MockProcessRunner()
        return (WineRunner(paths: paths, runner: mock), mock, paths)
    }

    private func createSteamExe(_ paths: Paths) throws {
        try FileManager.default.createDirectory(at: paths.steamExe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: paths.steamExe)
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
        let p = Paths(root: makeTempDir()); let s = Settings()
        XCTAssertEqual(GameLauncher.steamArguments(paths: p, settings: s, launchGame: false),
                       [p.steamExe.path, "-cef-disable-gpu-compositing"])
    }
    func testSteamArgumentsWithGameAndFps() {
        let p = Paths(root: makeTempDir()); var s = Settings(); s.fpsCap = 144
        XCTAssertEqual(GameLauncher.steamArguments(paths: p, settings: s, launchGame: true),
                       [p.steamExe.path, "-cef-disable-gpu-compositing", "-applaunch", "730",
                        "-novid", "-fullscreen", "+fps_max", "144"])
    }
    func testSteamArgumentsNoFpsWhenZeroOrNil() {
        let p = Paths(root: makeTempDir()); var s = Settings()
        XCTAssertFalse(GameLauncher.steamArguments(paths: p, settings: s, launchGame: true).contains("+fps_max"))
        s.fpsCap = 0
        XCTAssertFalse(GameLauncher.steamArguments(paths: p, settings: s, launchGame: true).contains("+fps_max"))
    }

    func testEnvironmentToggles() {
        var s = Settings(); s.metalHUD = false; s.msync = false; s.advertiseAVX = false
        XCTAssertEqual(GameLauncher.environment(for: s), ["D3DM_SUPPORT_DXR": "0"])
        s.metalHUD = true
        XCTAssertEqual(GameLauncher.environment(for: s)["MTL_HUD_ENABLED"], "1")
        s.msync = true
        let e = GameLauncher.environment(for: s)
        XCTAssertEqual(e["WINEMSYNC"], "1"); XCTAssertEqual(e["WINEESYNC"], "1")
        s.advertiseAVX = true
        XCTAssertEqual(GameLauncher.environment(for: s)["ROSETTA_ADVERTISE_AVX"], "1")
        XCTAssertNil(GameLauncher.environment(for: Settings())["MTL_HUD_ENABLED"])
    }

    func testLaunchThrowsWhenSteamMissing() {
        let (wine, mock, _) = makeWine()
        XCTAssertThrowsError(try GameLauncher(wine: wine).launch(settings: Settings(), launchGame: true, log: { _ in })) {
            XCTAssertEqual($0 as? LauncherError, .steamNotInstalled)
        }
        XCTAssertTrue(mock.calls.isEmpty)
    }

    func testLaunchStartsSteam() throws {
        let (wine, mock, paths) = makeWine()
        try createSteamExe(paths)
        _ = try GameLauncher(wine: wine).launch(settings: Settings(), launchGame: true, log: { _ in })
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls[0].arguments.first, paths.steamExe.path)
        XCTAssertTrue(mock.calls[0].arguments.contains("730"))
        XCTAssertEqual(mock.calls[0].environment["D3DM_SUPPORT_DXR"], "0")
        XCTAssertEqual(mock.calls[0].environment["WINEPREFIX"], paths.prefix.path)
    }

    func testStopRunsWineserverKill() async {
        let (wine, mock, _) = makeWine()
        await GameLauncher(wine: wine).stop()
        XCTAssertEqual(mock.calls.first?.arguments, ["-k"])
    }

    func testCS2Path() {
        let (wine, _, paths) = makeWine()
        let g = GameLauncher(wine: wine)
        XCTAssertTrue(g.cs2Executable.path.hasSuffix("Counter-Strike Global Offensive/game/bin/win64/cs2.exe"))
        XCTAssertFalse(g.isCS2Installed)
        try? FileManager.default.createDirectory(at: g.cs2Executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: g.cs2Executable)
        XCTAssertTrue(g.isCS2Installed)
        _ = paths
    }

    func testInstallHappyPath() async throws {
        let (wine, mock, paths) = makeWine()
        mock.exitCodeHandler = { _ in
            try? FileManager.default.createDirectory(at: paths.steamExe.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: paths.steamExe)
            return 0
        }
        let dl = MockDownloader()
        let inst = SteamInstaller(wine: wine, downloader: dl, pollInterval: .milliseconds(10), pollTimeout: .seconds(1))
        XCTAssertFalse(inst.isInstalled)
        let prog = DoubleBox()
        try await inst.install(progress: { prog.add($0) }, log: { _ in })
        XCTAssertTrue(inst.isInstalled)
        XCTAssertEqual(dl.urls, [SteamInstaller.installerURL])
        let installerPath = paths.downloads.appendingPathComponent("SteamSetup.exe").path
        XCTAssertEqual(mock.calls.first?.arguments, [installerPath, "/S"])
        XCTAssertEqual(prog.values.last, 1.0)
        XCTAssertTrue(prog.values.contains(0.6))
    }

    func testInstallerFailure() async {
        let (wine, mock, _) = makeWine()
        mock.defaultExitCode = 3
        let inst = SteamInstaller(wine: wine, downloader: MockDownloader(), pollInterval: .milliseconds(10), pollTimeout: .milliseconds(50))
        do {
            try await inst.install(progress: { _ in }, log: { _ in })
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? LauncherError, .installerFailed(3))
        }
    }

    func testSteamExeMissingAfterInstall() async {
        let (wine, _, _) = makeWine()
        let inst = SteamInstaller(wine: wine, downloader: MockDownloader(), pollInterval: .milliseconds(10), pollTimeout: .milliseconds(50))
        do {
            try await inst.install(progress: { _ in }, log: { _ in })
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? LauncherError, .steamExeMissingAfterInstall)
        }
    }
}
