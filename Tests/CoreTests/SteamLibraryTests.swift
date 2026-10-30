import XCTest
@testable import CS2LauncherCore

final class SteamLibraryTests: XCTestCase {
    static func manifest(flags: Int, downloaded: Int64 = 0, toDownload: Int64 = 0, size: Int64 = 0) -> String {
        """
        "AppState"
        {
        \t"appid"\t\t"730"
        \t"Universe"\t\t"1"
        \t"name"\t\t"Counter-Strike 2"
        \t"StateFlags"\t\t"\(flags)"
        \t"installdir"\t\t"Counter-Strike Global Offensive"
        \t"SizeOnDisk"\t\t"\(size)"
        \t"BytesToDownload"\t\t"\(toDownload)"
        \t"BytesDownloaded"\t\t"\(downloaded)"
        \t"UserConfig"
        \t{
        \t\t"language"\t\t"english"
        \t}
        \t"InstalledDepots"
        \t{
        \t\t"2347771"
        \t\t{
        \t\t\t"manifest"\t\t"123"
        \t\t}
        \t}
        }
        """
    }

    func testParseInstalled() throws {
        let m = try XCTUnwrap(CS2Manifest.parse(Self.manifest(flags: 4, downloaded: 100, toDownload: 100, size: 35_000_000_000)))
        XCTAssertEqual(m.stateFlags, 4)
        XCTAssertEqual(m.sizeOnDisk, 35_000_000_000)
        XCTAssertTrue(m.isFullyInstalled)
        XCTAssertEqual(SteamLibrary.state(manifest: m, executableExists: true), .installed)
    }

    func testInstalledFlagWithoutExeIsDownloading() throws {
        let m = try XCTUnwrap(CS2Manifest.parse(Self.manifest(flags: 4, downloaded: 10, toDownload: 100)))
        XCTAssertEqual(SteamLibrary.state(manifest: m, executableExists: false), .downloading(progress: 0.1))
    }

    func testDownloadingHalf() throws {
        let m = try XCTUnwrap(CS2Manifest.parse(Self.manifest(flags: 1026, downloaded: 500, toDownload: 1000)))
        XCTAssertEqual(SteamLibrary.state(manifest: m, executableExists: true), .downloading(progress: 0.5))
    }

    func testZeroBytesDoesNotDivideByZero() throws {
        let m = try XCTUnwrap(CS2Manifest.parse(Self.manifest(flags: 1026)))
        XCTAssertEqual(m.progress, 0)
        XCTAssertEqual(SteamLibrary.state(manifest: m, executableExists: false), .downloading(progress: 0))
    }

    func testProgressClamped() {
        XCTAssertEqual(CS2Manifest(stateFlags: 1026, bytesDownloaded: 200, bytesToDownload: 100).progress, 1)
    }

    func testMalformed() {
        XCTAssertNil(CS2Manifest.parse(""))
        XCTAssertNil(CS2Manifest.parse("garbage"))
        XCTAssertNil(CS2Manifest.parse("\"AppState\" { \"StateFlags\" \"4\""))        // unbalanced
        XCTAssertNil(CS2Manifest.parse("\"AppState\" { \"StateFlags\" \"4"))           // unterminated string
        XCTAssertNil(CS2Manifest.parse("\"AppState\" { \"appid\" \"730\" }"))         // no StateFlags
        XCTAssertNil(CS2Manifest.parse("\"AppState\" { \"StateFlags\" \"abc\" }"))     // not a number
        XCTAssertNil(CS2Manifest.parse("\"AppState\" { } }"))                          // stray close
        XCTAssertEqual(SteamLibrary.state(manifest: nil, executableExists: true), .notInstalled)
    }

    func testKeyValuesBasics() throws {
        let kv = try XCTUnwrap(KeyValues.parse("""
        // comment
        "Root" { "a" "1" "B" { "c" "x\\"y" } unquoted value
        "Extra" { } }
        """))
        XCTAssertEqual(kv["root"]?["A"]?.stringValue, "1")
        XCTAssertEqual(kv["Root"]?["b"]?["c"]?.stringValue, "x\"y")
        XCTAssertEqual(kv["Root"]?["unquoted"]?.stringValue, "value")
        XCTAssertNotNil(kv["Root"]?["extra"])
    }

    func testUnknownKeysIgnoredAndKeysCaseInsensitive() throws {
        let m = try XCTUnwrap(CS2Manifest.parse("\"appstate\" { \"stateflags\" \"4\" \"Whatever\" { \"x\" \"y\" } }"))
        XCTAssertEqual(m.stateFlags, 4)
    }

    func testFileBasedState() throws {
        let paths = Paths(root: makeTempDir())
        let lib = SteamLibrary(paths: paths)
        XCTAssertEqual(lib.cs2State(), .notInstalled)
        try FileManager.default.createDirectory(at: lib.steamapps, withIntermediateDirectories: true)
        try Self.manifest(flags: 1026, downloaded: 370, toDownload: 1000).write(to: lib.manifestURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(lib.cs2State(), .downloading(progress: 0.37))
        try Self.manifest(flags: 4, downloaded: 1000, toDownload: 1000).write(to: lib.manifestURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(lib.cs2State(), .downloading(progress: 1))   // exe not there yet
        try FileManager.default.createDirectory(at: lib.cs2Executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: lib.cs2Executable)
        XCTAssertEqual(lib.cs2State(), .installed)
        try "broken {".write(to: lib.manifestURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(lib.cs2State(), .notInstalled)
    }

    func testSteamRunningProbe() async {
        let mock = MockProcessRunner()
        let running = await GameLauncher.isSteamRunning(runner: mock)
        XCTAssertTrue(running)
        XCTAssertEqual(mock.calls.first?.executable.path, "/usr/bin/pgrep")
        XCTAssertEqual(mock.calls.first?.arguments, ["-f", "steam.exe"])
        mock.defaultExitCode = 1
        let notRunning = await GameLauncher.isSteamRunning(runner: mock)
        XCTAssertFalse(notRunning)
    }
}

final class SetupPlannerTests: XCTestCase {
    func testFreshPlan() {
        XCTAssertEqual(SetupPlanner.plan(completed: []), [.systemCheck, .wine, .prefix, .steam, .openSteam])
    }

    func testSkipsDone() {
        XCTAssertEqual(SetupPlanner.plan(completed: [.systemCheck, .wine]), [.prefix, .steam, .openSteam])
        XCTAssertEqual(SetupPlanner.plan(completed: [.systemCheck, .wine, .prefix, .steam, .openSteam]), [])
        // CS2 never part of the plan
        XCTAssertFalse(SetupPlanner.plan(completed: []).contains(.cs2))
    }

    func testCompleteness() {
        XCTAssertTrue(SetupPlanner.isComplete([.wine, .prefix, .steam, .cs2]))
        XCTAssertFalse(SetupPlanner.isComplete([.wine, .prefix, .steam]))
    }

    func testStopsOnFirstFailureAndResumes() async {
        var ran: [SetupStage] = []
        var starts: [Int] = []
        let plan = SetupPlanner.plan(completed: [.systemCheck])
        let r = await SetupPlanner.execute(plan: plan, onStart: { i, _ in starts.append(i) }) { st in
            ran.append(st)
            return st != .prefix
        }
        XCTAssertEqual(ran, [.wine, .prefix])
        XCTAssertEqual(starts, [0, 1])
        XCTAssertEqual(r, SetupResult(completed: [.wine], failed: .prefix, cancelled: false))
        XCTAssertFalse(r.succeeded)

        // Retry: wine is done now, the failed stage is first.
        let retry = SetupPlanner.plan(completed: [.systemCheck, .wine])
        XCTAssertEqual(retry.first, .prefix)
        var ran2: [SetupStage] = []
        let r2 = await SetupPlanner.execute(plan: retry) { ran2.append($0); return true }
        XCTAssertEqual(ran2, [.prefix, .steam, .openSteam])
        XCTAssertTrue(r2.succeeded)
    }

    func testCancellation() async {
        let t = Task { () -> SetupResult in
            await withTaskCancellationHandler {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                return await SetupPlanner.execute(plan: [.wine]) { _ in true }
            } onCancel: {}
        }
        t.cancel()
        let r = await t.value
        XCTAssertTrue(r.cancelled)
        XCTAssertTrue(r.completed.isEmpty)
    }

    func testOverallProgress() {
        XCTAssertEqual(SetupPlanner.overallProgress(index: 1, total: 4, stepProgress: 0.5), 0.375, accuracy: 1e-9)
        XCTAssertEqual(SetupPlanner.overallProgress(index: 0, total: 0, stepProgress: 1), 0)
        XCTAssertEqual(SetupPlanner.overallProgress(index: 2, total: 4, stepProgress: nil), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SetupPlanner.overallProgress(index: 3, total: 4, stepProgress: 5), 1, accuracy: 1e-9)
    }
}
