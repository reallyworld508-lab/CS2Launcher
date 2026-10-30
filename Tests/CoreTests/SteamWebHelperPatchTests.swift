import XCTest
@testable import CS2LauncherCore

final class SteamWebHelperPatchTests: XCTestCase {
    let wrapper = Data("MZ-wrapper".utf8)
    let valve = Data(count: 600_000)

    private func setup() -> (SteamWebHelperPatch, URL) {
        let paths = Paths(root: makeTempDir())
        let dir = paths.steamExe.deletingLastPathComponent()
            .appendingPathComponent("bin/cef/cef.win64", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SteamWebHelperPatch(paths: paths, wrapperData: wrapper), dir)
    }
    private func read(_ dir: URL, _ n: String) -> Data? { try? Data(contentsOf: dir.appendingPathComponent(n)) }
    private func write(_ dir: URL, _ n: String, _ d: Data) { try! d.write(to: dir.appendingPathComponent(n)) }

    func testMissingDirIsNoOp() throws {
        let patch = SteamWebHelperPatch(paths: Paths(root: makeTempDir()), wrapperData: wrapper)
        XCTAssertEqual(try patch.apply(), [])
        XCTAssertFalse(patch.isApplied)
    }

    func testFreshInstall() throws {
        let (patch, dir) = setup()
        write(dir, "steamwebhelper.exe", valve)
        XCTAssertFalse(patch.isApplied)
        XCTAssertEqual(try patch.apply().count, 1)
        XCTAssertEqual(read(dir, "steamwebhelper.exe"), wrapper)
        XCTAssertEqual(read(dir, "steamwebhelper_real.exe"), valve)
        XCTAssertTrue(patch.isApplied)
    }

    func testAfterSteamUpdate() throws {
        let (patch, dir) = setup()
        write(dir, "steamwebhelper.exe", wrapper)
        write(dir, "steamwebhelper_real.exe", Data(count: 600_000))
        let newValve = Data(repeating: 7, count: 700_000)
        write(dir, "steamwebhelper.exe", newValve)
        XCTAssertFalse(patch.isApplied)
        XCTAssertEqual(try patch.apply().count, 1)
        XCTAssertEqual(read(dir, "steamwebhelper_real.exe"), newValve)
        XCTAssertEqual(read(dir, "steamwebhelper.exe"), wrapper)
    }

    func testSteadyState() throws {
        let (patch, dir) = setup()
        write(dir, "steamwebhelper.exe", valve)
        _ = try patch.apply()
        XCTAssertEqual(try patch.apply(), [])
        XCTAssertTrue(patch.isApplied)
    }

    func testOutdatedWrapperRewritten() throws {
        let (patch, dir) = setup()
        write(dir, "steamwebhelper.exe", Data("old".utf8))
        write(dir, "steamwebhelper_real.exe", valve)
        XCTAssertEqual(try patch.apply().count, 1)
        XCTAssertEqual(read(dir, "steamwebhelper.exe"), wrapper)
        XCTAssertEqual(read(dir, "steamwebhelper_real.exe"), valve)
    }

    func testBundledWrapperIsPE() throws {
        let d = try SteamWebHelperPatch.bundledWrapper()
        XCTAssertFalse(d.isEmpty)
        XCTAssertEqual(Array(d.prefix(2)), Array("MZ".utf8))
        XCTAssertLessThan(d.count, SteamWebHelperPatch.wrapperSizeLimit)
    }
}
