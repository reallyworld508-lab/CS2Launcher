import XCTest
@testable import CS2LauncherCore

func makeTempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("cs2test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

final class SettingsTests: XCTestCase {
    func testDefaults() {
        let s = Settings()
        XCTAssertEqual(s.gameArgs, "-novid -windowed -noborder -w 1024 -h 768")
        XCTAssertEqual(s.engine, .free)
        XCTAssertEqual(s.steamArgs, "")
        XCTAssertFalse(s.metalHUD)
        XCTAssertNil(s.fpsCap)
    }
    func testRoundTrip() throws {
        let url = makeTempDir().appendingPathComponent("s.json")
        var s = Settings(); s.metalHUD = true; s.fpsCap = 120; s.gameArgs = "-x"
        try s.save(to: url)
        XCTAssertEqual(Settings.load(from: url), s)
    }
    func testMissingKeysTolerated() throws {
        let url = makeTempDir().appendingPathComponent("s.json")
        try Data(#"{"metalHUD": true}"#.utf8).write(to: url)
        let s = Settings.load(from: url)
        XCTAssertTrue(s.metalHUD)
        XCTAssertEqual(s.gameArgs, Settings.defaultGameArgs)
    }
    func testOldKeysIgnored() throws {
        let url = makeTempDir().appendingPathComponent("s.json")
        try Data(#"{"msync": false, "advertiseAVX": false, "retinaMode": true, "fpsCap": 90}"#.utf8).write(to: url)
        var expected = Settings(); expected.fpsCap = 90
        XCTAssertEqual(Settings.load(from: url), expected)
    }
    func testCorruptAndMissingFile() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("s.json")
        XCTAssertEqual(Settings.load(from: url), Settings())
        try Data("not json{".utf8).write(to: url)
        XCTAssertEqual(Settings.load(from: url), Settings())
    }
}

final class PathsTests: XCTestCase {
    func testLayout() throws {
        let root = makeTempDir()
        let p = Paths(root: root)
        XCTAssertEqual(p.logs.lastPathComponent, "Logs")
        XCTAssertEqual(p.downloads.lastPathComponent, "Downloads")
        XCTAssertEqual(p.settingsFile.lastPathComponent, "settings.json")
        XCTAssertEqual(p.legacyPrefix.path, root.path + "/Prefix")
        XCTAssertTrue(Paths.default.root.path.hasSuffix("Library/Application Support/CS2Launcher"))
    }
    func testEnsureDirectories() throws {
        let p = Paths(root: makeTempDir().appendingPathComponent("a/b"))
        try p.ensureDirectories()
        for d in [p.logs, p.downloads] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: d.path))
        }
    }
}

final class WineRunnerTests: XCTestCase {
    func testRunUsesBottleAndScript() async throws {
        let fx = CrossOverFixture()
        let mock = MockProcessRunner()
        mock.defaultExitCode = 3
        let w = WineRunner(locator: fx.locator, bottle: fx.bottle, runner: mock)
        XCTAssertEqual(w.baseEnvironment()["WINEDEBUG"], "-all")
        let code = try await w.run(["a.exe", "/S"], extraEnvironment: ["WINEDEBUG": "err"])
        XCTAssertEqual(code, 3)
        XCTAssertEqual(mock.calls[0].executable, fx.locator.wineScript)
        XCTAssertEqual(mock.calls[0].arguments, ["--bottle", "CS2", "a.exe", "/S"])
        XCTAssertEqual(mock.calls[0].environment["WINEDEBUG"], "err")
    }
    func testStartIsNoWait() throws {
        let fx = CrossOverFixture()
        let mock = MockProcessRunner()
        _ = try WineRunner(locator: fx.locator, bottle: fx.bottle, runner: mock).start(["steam.exe"])
        XCTAssertEqual(mock.calls[0].arguments, ["--bottle", "CS2", "--no-wait", "steam.exe"])
    }
    func testKillAllUsesWineserverWithBottlePrefix() async {
        let fx = CrossOverFixture()
        let mock = MockProcessRunner()
        await WineRunner(locator: fx.locator, bottle: fx.bottle, runner: mock).killAll()
        XCTAssertEqual(mock.calls[0].executable.lastPathComponent, "wineserver")
        XCTAssertEqual(mock.calls[0].arguments, ["-k"])
        XCTAssertEqual(mock.calls[0].environment["WINEPREFIX"], fx.bottle.path.path)
    }
    func testThrowsWithoutCrossOver() async {
        let missing = CrossOverLocator(searchPaths: [makeTempDir().appendingPathComponent("CrossOver.app")])
        let mock = MockProcessRunner()
        let w = WineRunner(locator: missing, bottle: Bottle(directory: makeTempDir(), locator: missing, runner: mock), runner: mock)
        do { _ = try await w.run(["x"]); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? CrossOverError, .notInstalled) }
        XCTAssertTrue(mock.calls.isEmpty)
    }
}

final class SystemCheckTests: XCTestCase {
    func testRosettaPresent() async {
        let mock = MockProcessRunner()
        let r = await SystemCheck(runner: mock).perform()
        XCTAssertTrue(r.rosettaInstalled)
        XCTAssertEqual(mock.calls[0].executable.path, "/usr/bin/arch")
        XCTAssertEqual(mock.calls[0].arguments, ["-x86_64", "/usr/bin/true"])
        XCTAssertTrue(r.macOSSupported)
        XCTAssertGreaterThan(r.freeDiskBytes, 0)
    }
    func testRosettaAbsent() async {
        let mock = MockProcessRunner(); mock.defaultExitCode = 1
        let r = await SystemCheck(runner: mock).perform()
        XCTAssertFalse(r.rosettaInstalled)
        XCTAssertFalse(r.allPassed)
    }
    func testRosettaThrows() async {
        let mock = MockProcessRunner(); mock.errorToThrow = URLError(.unknown)
        let r = await SystemCheck(runner: mock).perform()
        XCTAssertFalse(r.rosettaInstalled)
    }
    func testRequiredBytes() { XCTAssertEqual(SystemCheck.requiredFreeBytes, 45 * 1024 * 1024 * 1024) }
}

final class RealRunnerTests: XCTestCase {
    func testSystemRunnerEcho() async throws {
        let lines = LockedBox<[String]>([])
        let code = try await SystemProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo a; echo b >&2; echo $FOO"],
            environment: ["FOO": "bar"], currentDirectory: nil, onOutput: { l in lines.mutate { $0.append(l) } })
        XCTAssertEqual(code, 0)
        XCTAssertEqual(Set(lines.value), ["a", "b", "bar"])
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}
