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
        XCTAssertFalse(m.isWineInstalled); XCTAssertFalse(pm.isInitialized)
        let fm = FileManager.default
        try fm.createDirectory(at: paths.wineBin, withIntermediateDirectories: true)
        try Data().write(to: paths.wineBin.appendingPathComponent("wine"))
        try fm.createDirectory(at: paths.prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        XCTAssertTrue(pm.isInitialized)
        // Binary present but no marker: old runtime, treated as not installed.
        XCTAssertFalse(m.isWineInstalled)
        let marker = paths.wineRoot.appendingPathComponent(".cs2l-runtime-version")
        try "Game-Porting-Toolkit-3.0-3".write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertFalse(m.isWineInstalled)
        try RuntimeManager.wineRelease.version.write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertTrue(m.isWineInstalled)
        // Marker without a binary is not enough.
        try fm.removeItem(at: paths.wineBin.appendingPathComponent("wine"))
        XCTAssertFalse(m.isWineInstalled)
    }

    func testPinnedRelease() {
        XCTAssertEqual(RuntimeManager.wineRelease.version, "wine-devel-11.20")
        XCTAssertEqual(RuntimeManager.wineRelease.sha256.count, 64)
    }

    func testFindWineDirHandlesWineDevelLayout() throws {
        let root = makeTempDir()
        let bin = root.appendingPathComponent("Wine Devel.app/Contents/Resources/wine/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: bin.appendingPathComponent("wine"))
        try Data().write(to: bin.appendingPathComponent("wineserver"))
        XCTAssertEqual(RuntimeManager.findWineDir(in: root)?.lastPathComponent, "wine")
    }
}
