import XCTest
@testable import CS2LauncherCore

/// A fake engine folder in a temp directory.
struct EngineFixture {
    let root = makeTempDir()
    var engine: FreeEngine { FreeEngine(root: root) }

    func touch(_ url: URL, _ bytes: Int = 0) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }
    func installWine() throws {
        try touch(engine.wineExecutable)
        try touch(engine.wineserver)
    }
    func installD3DMetal() throws {
        try touch(engine.d3dmetalDirectory.appendingPathComponent("wine/x86_64-windows/d3d11.dll"))
        try touch(engine.libd3dshared)
    }
}

final class FreeEngineTests: XCTestCase {
    func testPinnedConstants() {
        XCTAssertEqual(FreeEngineInstaller.sha256.count, 64)
        XCTAssertTrue(FreeEngineInstaller.downloadURL.absoluteString.hasSuffix("cs2l-wine-crossover-26.3.0-4-x86_64.tar.xz"))
    }

    func testValidity() throws {
        let fx = EngineFixture()
        XCTAssertFalse(fx.engine.isEngineInstalled)
        XCTAssertFalse(fx.engine.isD3DMetalValid)
        XCTAssertFalse(fx.engine.isPrefixReady)
        try fx.installWine()
        try fx.installD3DMetal()
        XCTAssertTrue(fx.engine.isEngineInstalled)
        XCTAssertTrue(fx.engine.isD3DMetalValid)
        try fx.touch(fx.engine.prefix.appendingPathComponent("system.reg"))
        XCTAssertFalse(fx.engine.isPrefixReady)
        try fx.touch(fx.engine.prefixMarker)
        XCTAssertTrue(fx.engine.isPrefixReady)
    }

    func testEnvironment() {
        let e = FreeEngine(root: URL(fileURLWithPath: "/E"))
        let env = e.environment()
        XCTAssertEqual(env["WINEPREFIX"], "/E/prefix")
        XCTAssertEqual(env["WINEDLLPATH"], "/E/wine/lib/wine/x86_64-windows:/E/wine/lib/wine/i386-windows:/E/wine/lib/wine")
        XCTAssertEqual(env["CX_GRAPHICS_BACKEND"], "d3dmetal")
        XCTAssertEqual(env["CS2L_D3DMETAL_DIR"], "/E/d3dmetal")
        XCTAssertEqual(env["CX_APPLEGPTK_LIBD3DSHARED_PATH"], "/E/d3dmetal/external/libd3dshared.dylib")
        XCTAssertEqual(env["ROSETTA_ADVERTISE_AVX"], "1")
        XCTAssertEqual(env["WINEDEBUG"], "-all")
        XCTAssertNil(env["WINEMSYNC"])
        XCTAssertNil(env["MTL_HUD_ENABLED"])
        XCTAssertEqual(e.environment(metalHUD: true)["MTL_HUD_ENABLED"], "1")
    }

    func testRunnerUsesEngineEnvironmentAndKillsWithPrefix() async throws {
        let fx = EngineFixture()
        try fx.installWine()
        let mock = MockProcessRunner()
        let w = FreeWineRunner(engine: fx.engine, runner: mock)
        _ = try await w.run(["wineboot", "--init"])
        _ = try w.start(["steam.exe"], extraEnvironment: ["MTL_HUD_ENABLED": "1"])
        await w.killAll()
        XCTAssertEqual(mock.calls[0].executable, fx.engine.wineExecutable)
        XCTAssertEqual(mock.calls[0].arguments, ["wineboot", "--init"])
        XCTAssertEqual(mock.calls[0].environment["WINEDLLPATH"], fx.engine.environment()["WINEDLLPATH"])
        XCTAssertEqual(mock.calls[1].arguments, ["steam.exe"])
        XCTAssertEqual(mock.calls[1].environment["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(mock.calls[2].executable, fx.engine.wineserver)
        XCTAssertEqual(mock.calls[2].arguments, ["-k"])
        XCTAssertEqual(mock.calls[2].environment["WINEPREFIX"], fx.engine.prefix.path)
    }

    func testRunnerThrowsWithoutEngine() async {
        let fx = EngineFixture()
        let w = FreeWineRunner(engine: fx.engine, runner: MockProcessRunner())
        do { _ = try await w.run(["x"]); XCTFail() } catch { XCTAssertEqual(error as? EngineError, .engineMissing) }
    }

    func testLaunchUsesSteamFlagsAndGameArguments() throws {
        let fx = EngineFixture()
        try fx.installWine()
        try fx.touch(fx.engine.steamExe)
        let mock = MockProcessRunner()
        var s = Settings(); s.metalHUD = true
        _ = try GameLauncher(wine: FreeWineRunner(engine: fx.engine, runner: mock))
            .launch(settings: s, launchGame: true, log: { _ in })
        XCTAssertEqual(mock.calls[0].arguments,
                       [fx.engine.steamExe.path, "-noverifyfiles", "-norepairfiles", "-nobootstrapupdate",
                        "-skipinitialbootstrap", "-applaunch", "730", "-novid", "-windowed", "-noborder",
                        "-w", "1024", "-h", "768"])
        XCTAssertEqual(mock.calls[0].environment["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(mock.calls[0].environment["WINEPREFIX"], fx.engine.prefix.path)
    }

    func testGameArgumentsReplaceSizeAndNative() {
        var s = Settings()
        s.gameArgs = "-novid -w 800 -h 600 -windowed"
        s.windowWidth = 1280; s.windowHeight = 720
        XCTAssertEqual(GameLauncher.gameArguments(settings: s), ["-novid", "-windowed", "-w", "1280", "-h", "720"])
        s.nativeAspect = true
        XCTAssertEqual(GameLauncher.gameArguments(settings: s), ["-novid", "-windowed"])
    }

    func testSettingsEngineAndOldArgsMigration() throws {
        let url = makeTempDir().appendingPathComponent("s.json")
        try Data(#"{"gameArgs":"-novid","engine":"crossover"}"#.utf8).write(to: url)
        let s = Settings.load(from: url)
        XCTAssertEqual(s.engine, .crossover)
        XCTAssertEqual(s.gameArgs, Settings.defaultGameArgs)
        try Data(#"{"engine":"bogus"}"#.utf8).write(to: url)
        XCTAssertEqual(Settings.load(from: url).engine, .free)
        try Data(#"{"gameArgs":"-novid -console"}"#.utf8).write(to: url)
        XCTAssertEqual(Settings.load(from: url).gameArgs, "-novid -console")
    }
}

final class FreeEngineInstallerTests: XCTestCase {
    /// Writes a small file as the "download".
    final class FileDownloader: Downloading, @unchecked Sendable {
        let payload: Data
        init(_ payload: Data) { self.payload = payload }
        func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
            try payload.write(to: destination)
            progress(1)
        }
    }

    private func sha(_ d: Data) throws -> String {
        let f = makeTempDir().appendingPathComponent("x")
        try d.write(to: f)
        return try FreeEngineInstaller.sha256Hex(of: f)
    }

    func testSha256Hex() throws {
        XCTAssertEqual(try sha(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testInstallVerifiesAndExtractsWine() async throws {
        let fx = EngineFixture()
        let payload = Data("archive".utf8)
        let mock = MockProcessRunner()
        mock.exitCodeHandler = { call in
            // Stand-in for tar: create wine/bin/wine in the -C directory.
            let dir = URL(fileURLWithPath: call.arguments[3])
            let wine = dir.appendingPathComponent("wine/bin/wine")
            try? FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: wine)
            try? Data().write(to: dir.appendingPathComponent("wine/bin/wineserver"))
            try? Data().write(to: dir.appendingPathComponent("LICENSE"))
            return 0
        }
        let downloads = makeTempDir()
        let inst = FreeEngineInstaller(runner: mock, downloader: FileDownloader(payload), engine: fx.engine,
                                       downloads: downloads, sha256: try sha(payload))
        try await inst.install(progress: { _ in }, log: { _ in })
        XCTAssertEqual(mock.calls.first?.executable.path, "/usr/bin/tar")
        XCTAssertEqual(Array(mock.calls[0].arguments.prefix(2)), ["-xJf", downloads.appendingPathComponent(FreeEngineInstaller.downloadURL.lastPathComponent).path])
        XCTAssertTrue(fx.engine.isEngineInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.root.appendingPathComponent("wine-extract").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.root.appendingPathComponent("LICENSE").path))
    }

    func testChecksumMismatchRefused() async throws {
        let fx = EngineFixture()
        let mock = MockProcessRunner()
        let downloads = makeTempDir()
        let inst = FreeEngineInstaller(runner: mock, downloader: FileDownloader(Data("bad".utf8)), engine: fx.engine,
                                       downloads: downloads, sha256: String(repeating: "0", count: 64))
        do { try await inst.install(progress: { _ in }, log: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? InstallerError, .checksumMismatch) }
        XCTAssertTrue(mock.calls.isEmpty)
        XCTAssertFalse(fx.engine.isEngineInstalled)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: downloads.path))?.count, 0)
    }

    func testExistingEngineSkipsDownload() async throws {
        let fx = EngineFixture()
        try fx.installWine()
        let mock = MockProcessRunner()
        let downloads = makeTempDir()
        try await FreeEngineInstaller(runner: mock, downloader: FileDownloader(Data()), engine: fx.engine, downloads: downloads)
            .install(progress: { _ in }, log: { _ in })
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: downloads.path))?.count ?? 0, 0)
        XCTAssertTrue(mock.calls.isEmpty)
    }

    func testArchiveWithoutWineRejected() async throws {
        let fx = EngineFixture()
        let payload = Data("x".utf8)
        let inst = FreeEngineInstaller(runner: MockProcessRunner(), downloader: FileDownloader(payload), engine: fx.engine,
                                       downloads: makeTempDir(), sha256: try sha(payload))
        do { try await inst.install(progress: { _ in }, log: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? InstallerError, .engineNotFoundInArchive) }
    }
}

final class GPTKInstallerTests: XCTestCase {
    func testFindsNewestDmg() throws {
        let dir = makeTempDir()
        let old = dir.appendingPathComponent("Game_Porting_Toolkit_2.1.dmg")
        let new = dir.appendingPathComponent("Game_Porting_Toolkit_3.0.dmg")
        for u in [old, new, dir.appendingPathComponent("other.dmg")] { try Data().write(to: u) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: new.path)
        XCTAssertEqual(GPTKInstaller.findDmg(in: dir), new)
        XCTAssertNil(GPTKInstaller.findDmg(in: makeTempDir()))
    }

    func testNoDmgThrows() async {
        let fx = EngineFixture()
        let mock = MockProcessRunner()
        let g = GPTKInstaller(runner: mock, engine: fx.engine, searchDirectory: makeTempDir())
        do { try await g.install(log: { _ in }); XCTFail() } catch { XCTAssertEqual(error as? EngineError, .gptkNotFound) }
        XCTAssertTrue(mock.calls.isEmpty)
    }

    /// Fake hdiutil/ditto: attach fills the mountpoint, ditto copies into the staging folder.
    private func fakeRunner(fx: EngineFixture, failDitto: Bool = false) -> MockProcessRunner {
        let mock = MockProcessRunner()
        mock.exitCodeHandler = { call in
            let fm = FileManager.default
            switch (call.executable.lastPathComponent, call.arguments.first) {
            case ("hdiutil", "attach"):
                let mnt = URL(fileURLWithPath: call.arguments[5])
                if mnt.lastPathComponent == "outer" {
                    try? Data().write(to: mnt.appendingPathComponent("Evaluation environment for Windows games 3.0.dmg"))
                } else {
                    let lib = mnt.appendingPathComponent("redist/lib")
                    try? fm.createDirectory(at: lib.appendingPathComponent("wine/x86_64-windows"), withIntermediateDirectories: true)
                    try? fm.createDirectory(at: lib.appendingPathComponent("external"), withIntermediateDirectories: true)
                    try? Data().write(to: lib.appendingPathComponent("wine/x86_64-windows/d3d11.dll"))
                    try? Data().write(to: lib.appendingPathComponent("external/libd3dshared.dylib"))
                }
                return 0
            case ("ditto", _):
                if failDitto { return 1 }
                try? fm.copyItem(at: URL(fileURLWithPath: call.arguments[0]), to: URL(fileURLWithPath: call.arguments[1]))
                return 0
            default: return 0
            }
        }
        return mock
    }

    func testInstallCopiesAndDetachesBoth() async throws {
        let fx = EngineFixture()
        let mock = fakeRunner(fx: fx)
        let dmg = makeTempDir().appendingPathComponent("Game_Porting_Toolkit_3.0.dmg")
        try Data().write(to: dmg)
        try await GPTKInstaller(runner: mock, engine: fx.engine, searchDirectory: makeTempDir(), scratch: makeTempDir())
            .install(dmg: dmg, log: { _ in })
        XCTAssertTrue(fx.engine.isD3DMetalValid)
        let verbs = mock.calls.map { $0.arguments.first ?? "" }
        XCTAssertEqual(verbs.filter { $0 == "attach" }.count, 2)
        XCTAssertEqual(verbs.filter { $0 == "detach" }.count, 2)
        XCTAssertTrue(mock.calls[0].arguments.starts(with: ["attach", "-readonly", "-nobrowse", "-noverify", "-mountpoint"]))
    }

    func testDetachesEvenWhenCopyFails() async throws {
        let fx = EngineFixture()
        let mock = fakeRunner(fx: fx, failDitto: true)
        let dmg = makeTempDir().appendingPathComponent("Game_Porting_Toolkit_3.0.dmg")
        try Data().write(to: dmg)
        let g = GPTKInstaller(runner: mock, engine: fx.engine, searchDirectory: makeTempDir(), scratch: makeTempDir())
        do { try await g.install(dmg: dmg, log: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? EngineError, .commandFailed("ditto", 1)) }
        XCTAssertEqual(mock.calls.filter { $0.arguments.first == "detach" }.count, 2)
        XCTAssertFalse(fx.engine.isD3DMetalValid)
    }

    func testMountFailure() async throws {
        let fx = EngineFixture()
        let mock = MockProcessRunner()
        mock.defaultExitCode = 1
        let dmg = makeTempDir().appendingPathComponent("Game_Porting_Toolkit_3.0.dmg")
        try Data().write(to: dmg)
        let g = GPTKInstaller(runner: mock, engine: fx.engine, searchDirectory: makeTempDir(), scratch: makeTempDir())
        do { try await g.install(dmg: dmg, log: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? EngineError, .mountFailed(dmg.lastPathComponent)) }
    }
}

final class FreePrefixTests: XCTestCase {
    func testCreateRunsWinebootThenRegistryTweak() async throws {
        let fx = EngineFixture()
        try fx.installWine()
        try fx.touch(fx.engine.prefix.appendingPathComponent("system.reg"))
        try fx.touch(fx.engine.d3dmetalDirectory.appendingPathComponent("wine/x86_64-windows/nvapi64.dll"))
        let mock = MockProcessRunner()
        try await FreePrefixManager(engine: fx.engine, runner: mock).create(log: { _ in })
        XCTAssertEqual(mock.calls[0].arguments, ["wineboot", "--init"])
        XCTAssertEqual(mock.calls[1].arguments, FreePrefixManager.disableSDLArguments)
        XCTAssertTrue(mock.calls[1].arguments.contains("Enable SDL"))
        XCTAssertEqual(mock.calls[0].environment["WINEPREFIX"], fx.engine.prefix.path)
        XCTAssertTrue(fx.engine.isPrefixReady)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fx.engine.driveC.appendingPathComponent("windows/system32/nvapi64.dll").path))
    }

    func testFailedWinebootLeavesNoMarker() async throws {
        let fx = EngineFixture()
        try fx.installWine()
        let mock = MockProcessRunner()
        mock.defaultExitCode = 1
        do { try await FreePrefixManager(engine: fx.engine, runner: mock).create(log: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? EngineError, .commandFailed("wineboot --init", 1)) }
        XCTAssertFalse(fx.engine.isPrefixReady)
    }
}

final class SteamWebHelperPatchTests: XCTestCase {
    private let wrapper = Data("WRAPPER".utf8)

    private func makeSteam(original: Bool = true) throws -> (SteamWebHelperPatch, URL) {
        let steam = makeTempDir().appendingPathComponent("Steam")
        let dir = steam.appendingPathComponent("bin/cef/cef.win64")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: original ? 2_000_000 : 10).write(to: dir.appendingPathComponent("steamwebhelper.exe"))
        return (SteamWebHelperPatch(steamDirectory: steam, wrapperData: wrapper), dir)
    }

    func testWrapsOriginal() throws {
        let (patch, dir) = try makeSteam()
        XCTAssertFalse(patch.isApplied)
        XCTAssertEqual(try patch.apply().map(\.path), [dir.path])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("steamwebhelper.exe")), wrapper)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("steamwebhelper_real.exe")).count, 2_000_000)
        XCTAssertTrue(patch.isApplied)
        XCTAssertEqual(try patch.apply(), [])
    }

    func testSteamRestoringOriginalIsWrappedAgain() throws {
        let (patch, dir) = try makeSteam()
        try patch.apply()
        try Data(count: 3_000_000).write(to: dir.appendingPathComponent("steamwebhelper.exe"))
        XCTAssertFalse(patch.isApplied)
        try patch.apply()
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("steamwebhelper_real.exe")).count, 3_000_000)
        XCTAssertTrue(patch.isApplied)
    }

    func testNothingWithoutCefFolder() throws {
        let patch = SteamWebHelperPatch(steamDirectory: makeTempDir(), wrapperData: wrapper)
        XCTAssertEqual(try patch.apply(), [])
        XCTAssertFalse(patch.isApplied)
    }

    func testBundledWrapperIsSmallPE() throws {
        let data = try SteamWebHelperPatch.bundledWrapper()
        XCTAssertLessThan(data.count, SteamWebHelperPatch.originalMinimumSize)
        XCTAssertEqual(data.prefix(2), Data("MZ".utf8))
    }
}

final class VideoConfigTests: XCTestCase {
    func testNewFileHasRecommendedValues() throws {
        let text = try XCTUnwrap(VideoConfig.updating(nil, width: 1024, height: 768, nativeAspect: false))
        let doc = try XCTUnwrap(KVDocument.parse(text))
        XCTAssertEqual(doc.string(at: ["video.cfg", "setting.defaultres"]), "1024")
        XCTAssertEqual(doc.string(at: ["video.cfg", "setting.defaultresheight"]), "768")
        XCTAssertEqual(doc.string(at: ["video.cfg", "setting.aspectratiomode"]), "0")
        XCTAssertEqual(doc.string(at: ["video.cfg", "setting.mat_vsync"]), "1")
        XCTAssertEqual(doc.string(at: ["video.cfg", "setting.videocfg_fsr_detail"]), "4")
        XCTAssertEqual(doc.string(at: ["video.cfg", "setting.gpu_mem_level"]), "2")
    }

    func testNativeUsesAspectMode2AndKeepsOtherKeys() throws {
        let old = "\"video.cfg\"\n{\n\t\"Version\"\t\t\"1\"\n\t\"setting.fullscreen\"\t\t\"0\"\n\t\"setting.defaultres\"\t\t\"640\"\n}\n"
        let text = try XCTUnwrap(VideoConfig.updating(old, width: 1470, height: 956, nativeAspect: true))
        let doc = try XCTUnwrap(KVDocument.parse(text))
        XCTAssertEqual(doc.string(at: ["video.cfg", "setting.fullscreen"]), "0")
        XCTAssertEqual(doc.string(at: ["video.cfg", "setting.defaultres"]), "1470")
        XCTAssertEqual(doc.string(at: ["video.cfg", "setting.aspectratiomode"]), "2")
    }

    func testUnparsableFileUntouched() {
        XCTAssertNil(VideoConfig.updating("\"video.cfg\" {", width: 1, height: 1, nativeAspect: false))
    }

    func testApplyWritesPerAccountAndSkipsWithoutAccount() throws {
        let userdata = makeTempDir().appendingPathComponent("userdata")
        XCTAssertTrue(VideoConfig.apply(userdata: userdata, width: 1024, height: 768, nativeAspect: false).isEmpty)
        try FileManager.default.createDirectory(at: userdata.appendingPathComponent("4242"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userdata.appendingPathComponent("anonymous"), withIntermediateDirectories: true)
        let written = VideoConfig.apply(userdata: userdata, width: 1024, height: 768, nativeAspect: false)
        XCTAssertEqual(written, [userdata.appendingPathComponent("4242/730/local/cfg/cs2_video.txt")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: written[0].path))
    }
}
