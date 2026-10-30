import XCTest
@testable import CS2LauncherCore

/// A fake CrossOver.app and bottles folder in a temp directory.
struct CrossOverFixture {
    let root: URL
    let app: URL
    let locator: CrossOverLocator
    let bottle: Bottle

    init(installed: Bool = true, runner: ProcessRunning = MockProcessRunner()) {
        root = makeTempDir()
        app = root.appendingPathComponent("CrossOver.app", isDirectory: true)
        if installed {
            let bin = app.appendingPathComponent("Contents/SharedSupport/CrossOver/bin", isDirectory: true)
            try! FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for t in ["wine", "wineserver", "cxbottle"] {
                FileManager.default.createFile(atPath: bin.appendingPathComponent(t).path, contents: Data())
            }
            let plist: [String: Any] = ["CFBundleShortVersionString": "26.3.0"]
            try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
        }
        locator = CrossOverLocator(searchPaths: [app])
        bottle = Bottle(directory: root.appendingPathComponent("Bottles"), locator: locator, runner: runner)
    }

    func writeConf(_ text: String) throws {
        try FileManager.default.createDirectory(at: bottle.path, withIntermediateDirectories: true)
        try text.write(to: bottle.configURL, atomically: true, encoding: .utf8)
    }
}

final class CrossOverLocatorTests: XCTestCase {
    func testFound() {
        let fx = CrossOverFixture()
        XCTAssertTrue(fx.locator.isInstalled)
        XCTAssertEqual(fx.locator.version, "26.3.0")
        XCTAssertEqual(fx.locator.wineScript.lastPathComponent, "wine")
        XCTAssertEqual(fx.locator.wineserver.lastPathComponent, "wineserver")
        XCTAssertEqual(fx.locator.cxbottle.lastPathComponent, "cxbottle")
        XCTAssertTrue(fx.locator.wineScript.path.hasPrefix(fx.app.path))
    }
    func testMissing() {
        let fx = CrossOverFixture(installed: false)
        XCTAssertFalse(fx.locator.isInstalled)
        XCTAssertNil(fx.locator.version)
        XCTAssertNil(fx.locator.appURL)
    }
    func testSecondCandidateWins() {
        let fx = CrossOverFixture()
        let none = makeTempDir().appendingPathComponent("CrossOver.app")
        let l = CrossOverLocator(searchPaths: [none, fx.app])
        XCTAssertEqual(l.appURL, fx.app)
    }
    func testDefaultSearchPaths() {
        let paths = CrossOverLocator.defaultSearchPaths.map(\.path)
        XCTAssertEqual(paths.first, "/Applications/CrossOver.app")
        XCTAssertTrue(paths.last!.hasSuffix("/Applications/CrossOver.app"))
    }
}

final class BottleTests: XCTestCase {
    func testPaths() {
        let fx = CrossOverFixture()
        XCTAssertEqual(fx.bottle.name, "CS2")
        XCTAssertTrue(fx.bottle.steamExe.path.hasSuffix("Bottles/CS2/drive_c/Program Files (x86)/Steam/steam.exe"))
        XCTAssertTrue(Bottle.defaultDirectory.path.hasSuffix("Library/Application Support/CrossOver/Bottles"))
        XCTAssertFalse(fx.bottle.exists)
    }

    func testEnableFresh() {
        let conf = "[Bottle]\n\"Version\" = \"1\"\n\n[EnvironmentVariables]\n\"FOO\" = \"bar\"\n"
        let out = Bottle.enablingD3DMetal(in: conf)
        XCTAssertEqual(out, "[Bottle]\n\"Version\" = \"1\"\n\n[EnvironmentVariables]\n\"CX_GRAPHICS_BACKEND\" = \"d3dmetal\"\n\"FOO\" = \"bar\"\n")
    }
    func testEnableIdempotent() {
        let conf = "[EnvironmentVariables]\n\"FOO\" = \"bar\"\n"
        let once = Bottle.enablingD3DMetal(in: conf)
        XCTAssertEqual(Bottle.enablingD3DMetal(in: once), once)
        XCTAssertEqual(once.components(separatedBy: "CX_GRAPHICS_BACKEND").count, 2)
        XCTAssertFalse(once.contains("WINEMSYNC"))
    }
    func testReplacesOtherBackend() {
        let conf = "[EnvironmentVariables]\n\"CX_GRAPHICS_BACKEND\" = \"dxvk\"\n\"WINEMSYNC\" = \"0\"\n[Other]\n"
        let out = Bottle.enablingD3DMetal(in: conf)
        XCTAssertEqual(out, "[EnvironmentVariables]\n\"CX_GRAPHICS_BACKEND\" = \"d3dmetal\"\n[Other]\n")
        XCTAssertFalse(out.contains("dxvk"))
    }
    func testRemovesForcedMSync() {
        let conf = "[EnvironmentVariables]\n\"WINEMSYNC\" = \"1\"\n\"FOO\" = \"bar\"\n"
        XCTAssertEqual(Bottle.enablingD3DMetal(in: conf),
                       "[EnvironmentVariables]\n\"CX_GRAPHICS_BACKEND\" = \"d3dmetal\"\n\"FOO\" = \"bar\"\n")
        XCTAssertFalse(Bottle.applyingEnvironment(metalHUD: true, in: conf).contains("WINEMSYNC"))
    }
    func testAddsSectionWhenMissing() {
        let out = Bottle.enablingD3DMetal(in: "[Bottle]\n\"A\" = \"b\"\n")
        XCTAssertTrue(out.contains("[EnvironmentVariables]\n\"CX_GRAPHICS_BACKEND\" = \"d3dmetal\""))
        XCTAssertEqual(Bottle.enablingD3DMetal(in: out), out)
    }

    func testEnsureD3DMetalWritesFile() throws {
        let fx = CrossOverFixture()
        XCTAssertThrowsError(try fx.bottle.ensureD3DMetal())
        try fx.writeConf("[EnvironmentVariables]\n")
        XCTAssertTrue(fx.bottle.exists)
        XCTAssertFalse(fx.bottle.hasD3DMetal)
        try fx.bottle.ensureD3DMetal()
        XCTAssertTrue(fx.bottle.hasD3DMetal)
        let text = try String(contentsOf: fx.bottle.configURL, encoding: .utf8)
        try fx.bottle.ensureD3DMetal()
        XCTAssertEqual(try String(contentsOf: fx.bottle.configURL, encoding: .utf8), text)
    }

    func testCreateRunsCxbottle() async throws {
        let mock = MockProcessRunner()
        let fx = CrossOverFixture(runner: mock)
        try await fx.bottle.create(log: { _ in })
        XCTAssertEqual(mock.calls[0].executable, fx.locator.cxbottle)
        XCTAssertEqual(mock.calls[0].arguments,
                       ["--bottle", "CS2", "--create", "--template", "win10_64", "--description", "CS2 Launcher"])
    }
    func testCreateFailsWithoutCrossOver() async {
        let fx = CrossOverFixture(installed: false)
        do { try await fx.bottle.create(log: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? CrossOverError, .notInstalled) }
    }
}

final class LegacyMigrationTests: XCTestCase {
    private func makeLegacy(_ paths: Paths) throws -> URL {
        let steam = paths.legacyPrefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let cef = steam.appendingPathComponent("bin/cef/cef.win64")
        try FileManager.default.createDirectory(at: cef, withIntermediateDirectories: true)
        try Data("steam".utf8).write(to: steam.appendingPathComponent("steam.exe"))
        try Data("wrapper".utf8).write(to: cef.appendingPathComponent("steamwebhelper.exe"))
        try Data("real".utf8).write(to: cef.appendingPathComponent("steamwebhelper_real.exe"))
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        try Data("acf".utf8).write(to: steam.appendingPathComponent("steamapps/appmanifest_730.acf"))
        return steam
    }

    func testCloneAndRestoreHelper() async throws {
        let fx = CrossOverFixture()
        try fx.writeConf("[EnvironmentVariables]\n")
        let paths = Paths(root: makeTempDir())
        let legacy = try makeLegacy(paths)
        let m = LegacyMigration(paths: paths, bottle: fx.bottle)
        XCTAssertTrue(m.isAvailable)
        try await m.migrate(runner: SystemProcessRunner(), log: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fx.bottle.steamExe.path))
        let cef = fx.bottle.steamDirectory.appendingPathComponent("bin/cef/cef.win64")
        XCTAssertEqual(try String(contentsOf: cef.appendingPathComponent("steamwebhelper.exe"), encoding: .utf8), "real")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cef.appendingPathComponent("steamwebhelper_real.exe").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fx.bottle.steamapps.appendingPathComponent("appmanifest_730.acf").path))
        // The original is untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("bin/cef/cef.win64/steamwebhelper_real.exe").path))
        XCTAssertFalse(m.isAvailable)
    }

    func testNoOpWhenSteamAlreadyInBottle() async throws {
        let mock = MockProcessRunner()
        let fx = CrossOverFixture(runner: mock)
        try fx.writeConf("[EnvironmentVariables]\n")
        let paths = Paths(root: makeTempDir())
        _ = try makeLegacy(paths)
        try FileManager.default.createDirectory(at: fx.bottle.steamDirectory, withIntermediateDirectories: true)
        try Data().write(to: fx.bottle.steamExe)
        let m = LegacyMigration(paths: paths, bottle: fx.bottle)
        XCTAssertFalse(m.isAvailable)
        try await m.migrate(runner: mock, log: { _ in })
        XCTAssertTrue(mock.calls.isEmpty)
    }

    func testUnavailableWithoutLegacyOrBottle() throws {
        let fx = CrossOverFixture()
        let paths = Paths(root: makeTempDir())
        XCTAssertFalse(LegacyMigration(paths: paths, bottle: fx.bottle).isAvailable)
        _ = try makeLegacy(paths)
        XCTAssertFalse(LegacyMigration(paths: paths, bottle: fx.bottle).isAvailable)   // bottle missing
    }

    func testRestoreWebHelpersOnlyWhereRealExists() throws {
        let steam = makeTempDir()
        let a = steam.appendingPathComponent("bin/cef/cef.win64")
        let b = steam.appendingPathComponent("bin/cef/cef.win7x64")
        for d in [a, b] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("w".utf8).write(to: a.appendingPathComponent("steamwebhelper.exe"))
        try Data("r".utf8).write(to: a.appendingPathComponent("steamwebhelper_real.exe"))
        try Data("orig".utf8).write(to: b.appendingPathComponent("steamwebhelper.exe"))
        XCTAssertEqual(LegacyMigration.restoreWebHelpers(in: steam), ["cef.win64"])
        XCTAssertEqual(try String(contentsOf: a.appendingPathComponent("steamwebhelper.exe"), encoding: .utf8), "r")
        XCTAssertEqual(try String(contentsOf: b.appendingPathComponent("steamwebhelper.exe"), encoding: .utf8), "orig")
        XCTAssertEqual(LegacyMigration.restoreWebHelpers(in: steam), [])
    }
}
