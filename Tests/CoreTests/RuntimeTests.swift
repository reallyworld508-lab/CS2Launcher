import XCTest
@testable import CS2LauncherCore

private struct FixedDownloader: Downloading {
    let bytes: Data
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: destination)
        progress(1)
    }
}

final class RuntimeTests: XCTestCase {
    func testSha256KnownValue() throws {
        let f = makeTempDir().appendingPathComponent("a.txt")
        try Data("abc".utf8).write(to: f)
        XCTAssertEqual(try RuntimeManager.sha256(of: f),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testChecksumMismatchDeletesFile() async throws {
        let paths = Paths(root: makeTempDir())
        let runner = MockProcessRunner()
        let m = RuntimeManager(paths: paths, downloader: FixedDownloader(bytes: Data("bad".utf8)), runner: runner)
        do {
            try await m.installWine(progress: { _ in }, log: { _ in })
            XCTFail("expected throw")
        } catch let RuntimeError.checksumMismatch(expected, actual) {
            XCTAssertEqual(expected, RuntimeManager.wineRelease.sha256)
            XCTAssertNotEqual(actual, expected)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.downloads.path)
        XCTAssertTrue(leftovers.isEmpty)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testFindGPTKImagePicksNewest() throws {
        let dir = makeTempDir()
        let fm = FileManager.default
        func make(_ name: String, age: TimeInterval) throws {
            let u = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: u)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: u.path)
        }
        try make("Game_Porting_Toolkit_2.0.dmg", age: 1000)
        try make("game porting toolkit 3.0.dmg", age: 10)
        try make("Other.dmg", age: 1)
        try make("Game Porting Toolkit.txt", age: 0)
        XCTAssertEqual(RuntimeManager.findGPTKImage(in: [dir])?.lastPathComponent, "game porting toolkit 3.0.dmg")
        XCTAssertNil(RuntimeManager.findGPTKImage(in: [makeTempDir()]))
    }

    func testRegistryFile() {
        var s = Settings(); s.retinaMode = true
        let on = PrefixManager.registryFile(for: s)
        XCTAssertTrue(on.hasPrefix("Windows Registry Editor Version 5.00\r\n"))
        XCTAssertTrue(on.contains("[HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]\r\n\"RetinaMode\"=\"y\""))
        XCTAssertTrue(on.contains("\"Version\"=\"win10\""))
        s.retinaMode = false
        XCTAssertTrue(PrefixManager.registryFile(for: s).contains("\"RetinaMode\"=\"n\""))
        XCTAssertFalse(on.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    func testPrefixInitializeRunsWinebootThenRegedit() async throws {
        let paths = Paths(root: makeTempDir())
        let runner = MockProcessRunner()
        let pm = PrefixManager(wine: WineRunner(paths: paths, runner: runner))
        try await pm.initialize(log: { _ in })
        let args = runner.calls.map(\.arguments)
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args[0], ["wineboot", "--init"])
        XCTAssertEqual(Array(args[1].prefix(2)), ["regedit", "/S"])
        XCTAssertTrue(args[1][2].hasSuffix(".reg"))
    }

    func testPrefixInitializeFailure() async {
        let runner = MockProcessRunner(); runner.defaultExitCode = 3
        let pm = PrefixManager(wine: WineRunner(paths: Paths(root: makeTempDir()), runner: runner))
        do { try await pm.initialize(log: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? RuntimeError, .commandFailed("wineboot --init", 3)) }
    }

    func testInstalledFlags() throws {
        let paths = Paths(root: makeTempDir())
        let m = RuntimeManager(paths: paths, downloader: FixedDownloader(bytes: Data()), runner: MockProcessRunner())
        let pm = PrefixManager(wine: WineRunner(paths: paths, runner: MockProcessRunner()))
        XCTAssertFalse(m.isWineInstalled); XCTAssertFalse(m.isD3DMetalInstalled); XCTAssertFalse(pm.isInitialized)
        let fm = FileManager.default
        try fm.createDirectory(at: paths.wineBin, withIntermediateDirectories: true)
        try Data().write(to: paths.wineBin.appendingPathComponent("wine64"))
        try fm.createDirectory(at: paths.wineRoot.appendingPathComponent("lib/external/D3DMetal.framework"), withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        XCTAssertTrue(m.isWineInstalled); XCTAssertTrue(m.isD3DMetalInstalled); XCTAssertTrue(pm.isInitialized)
    }

    func testInstallD3DMetalRequiresWine() async {
        let m = RuntimeManager(paths: Paths(root: makeTempDir()), downloader: FixedDownloader(bytes: Data()), runner: MockProcessRunner())
        do { try await m.installD3DMetal(fromGPTKImage: URL(fileURLWithPath: "/x.dmg"), log: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? RuntimeError, .commandFailed("wine not installed", -1)) }
    }

    func testParseMountPoint() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>system-entities</key><array>
        <dict><key>dev-entry</key><string>/dev/disk4</string></dict>
        <dict><key>mount-point</key><string>/Volumes/GPTK</string></dict>
        </array></dict></plist>
        """
        XCTAssertEqual(RuntimeManager.parseMountPoint(plist: plist), "/Volumes/GPTK")
    }
}
