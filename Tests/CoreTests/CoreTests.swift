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
        XCTAssertEqual(s.gameArgs, "-novid -fullscreen")
        XCTAssertEqual(s.steamArgs, "-cef-disable-gpu-compositing")
        XCTAssertFalse(s.metalHUD); XCTAssertFalse(s.retinaMode)
        XCTAssertTrue(s.msync); XCTAssertTrue(s.advertiseAVX)
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
        XCTAssertEqual(s.gameArgs, "-novid -fullscreen")
        XCTAssertTrue(s.msync)
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
        XCTAssertEqual(p.runtime.path, root.path + "/Runtime")
        XCTAssertEqual(p.wineRoot.path, root.path + "/Runtime/wine")
        XCTAssertEqual(p.wineBin.path, root.path + "/Runtime/wine/bin")
        XCTAssertEqual(p.prefix.lastPathComponent, "Prefix")
        XCTAssertEqual(p.logs.lastPathComponent, "Logs")
        XCTAssertEqual(p.downloads.lastPathComponent, "Downloads")
        XCTAssertEqual(p.settingsFile.lastPathComponent, "settings.json")
        XCTAssertTrue(p.steamExe.path.hasSuffix("Prefix/drive_c/Program Files (x86)/Steam/steam.exe"))
        XCTAssertTrue(Paths.default.root.path.hasSuffix("Library/Application Support/CS2Launcher"))
    }
    func testEnsureDirectories() throws {
        let p = Paths(root: makeTempDir().appendingPathComponent("a/b"))
        try p.ensureDirectories()
        for d in [p.runtime, p.prefix, p.logs, p.downloads] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: d.path))
        }
    }
}

final class WineRunnerTests: XCTestCase {
    func testExecutableSelection() throws {
        let p = Paths(root: makeTempDir())
        let w = WineRunner(paths: p, runner: MockProcessRunner())
        XCTAssertEqual(w.wineExecutable.lastPathComponent, "wine")
        XCTAssertEqual(w.wineserverExecutable.lastPathComponent, "wineserver")
        try FileManager.default.createDirectory(at: p.wineBin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p.wineBin.appendingPathComponent("wine64").path, contents: Data())
        XCTAssertEqual(w.wineExecutable.lastPathComponent, "wine64")
    }
    func testBaseEnvironment() {
        let p = Paths(root: makeTempDir())
        let env = WineRunner(paths: p, runner: MockProcessRunner()).baseEnvironment()
        XCTAssertEqual(env["WINEPREFIX"], p.prefix.path)
        XCTAssertEqual(env["WINEDEBUG"], "-all")
        XCTAssertEqual(env["WINEDLLOVERRIDES"], "winemenubuilder.exe=d")
        XCTAssertTrue(env["PATH"]!.hasPrefix(p.wineBin.path + ":"))
    }
    func testRunMergesExtraEnvAndKillAll() async throws {
        let mock = MockProcessRunner()
        mock.defaultExitCode = 3
        let w = WineRunner(paths: Paths(root: makeTempDir()), runner: mock)
        let code = try await w.run(["a.exe"], extraEnvironment: ["WINEDEBUG": "err"])
        XCTAssertEqual(code, 3)
        XCTAssertEqual(mock.calls[0].arguments, ["a.exe"])
        XCTAssertEqual(mock.calls[0].environment["WINEDEBUG"], "err")
        await w.killAll()
        XCTAssertEqual(mock.calls[1].arguments, ["-k"])
        XCTAssertEqual(mock.calls[1].executable.lastPathComponent, "wineserver")
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
