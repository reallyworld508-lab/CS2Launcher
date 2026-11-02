import XCTest
@testable import CS2LauncherCore

private final class FileDownloader: Downloading, @unchecked Sendable {
    var requested: [URL] = []
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        requested.append(url)
        try Data("zip".utf8).write(to: destination)
        progress(1)
    }
}

final class BackgroundThrottleTests: XCTestCase {
    let ps = [
        "  101   501 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "  102   501 /Applications/Google Chrome.app/Contents/Frameworks/X/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper (Renderer)",
        "  103   501 /Applications/Discord.app/Contents/MacOS/Discord",
        "  104   0   /Applications/Telegram.app/Contents/MacOS/Telegram",
        "  105   501 /System/Library/CoreServices/Archive Utility.app/Contents/MacOS/Archive Utility",
        "  106   501 /Applications/Steam.app/Contents/MacOS/steam_osx",
        "  107   501 /Users/x/Library/Application Support/CrossOver/Bottles/CS2/drive_c/Discord.app/x",
        "  108   501 /Applications/CS2 Launcher.app/Contents/MacOS/CS2Launcher",
        "  109   501 /Applications/Arc.app/Contents/MacOS/Arc",
        "  110   501 /Applications/Archiver.app/Contents/MacOS/Archiver",
        "  111   501 /Applications/CrossOver.app/Contents/MacOS/CrossOver",
        "  junk",
    ]

    func testParsePS() {
        let e = BackgroundThrottle.parsePS(ps)
        XCTAssertEqual(e.count, 11)
        XCTAssertEqual(e[0], ProcessEntry(pid: 101, uid: 501, command: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))
    }

    func testCandidatesAreOwnAllowedNonSystem() {
        let c = BackgroundThrottle.candidates(in: BackgroundThrottle.parsePS(ps), uid: 501, ownPID: 108)
        XCTAssertEqual(c, [101, 102, 103, 109])   // not other uid, system, steam, wine path, self, Archiver
    }

    func testCustomAllowList() {
        let c = BackgroundThrottle.candidates(in: BackgroundThrottle.parsePS(ps), uid: 501, ownPID: 1, allowList: ["discord"])
        XCTAssertEqual(c, [103])
    }

    func testDiffs() {
        XCTAssertEqual(BackgroundThrottle.toDemote(candidates: [1, 2, 3], alreadyDemoted: [2]), [1, 3])
        XCTAssertEqual(BackgroundThrottle.toRestore(demoted: [1, 2, 3], alive: [2, 3, 9]), [2, 3])
    }

    func testThrottlerDemotesThenRestoresOnlyAlive() async {
        let m = MockProcessRunner()
        m.outputLines = Array(ps.prefix(3))
        let t = BackgroundThrottler(runner: m, uid: 501, ownPID: 999)
        let n = await t.demoteNew()
        XCTAssertEqual(n, 3)
        XCTAssertEqual(t.demoted, [101, 102, 103])
        let policy = m.calls.filter { $0.executable.lastPathComponent == "taskpolicy" }
        XCTAssertEqual(policy.map(\.arguments), [["-b", "-p", "101"], ["-b", "-p", "102"], ["-b", "-p", "103"]])
        // Second poll: nothing new.
        let again = await t.demoteNew()
        XCTAssertEqual(again, 0)
        // 102 exited before restore.
        m.outputLines = [ps[0], ps[2]]
        let r = await t.restoreAll()
        XCTAssertEqual(r, 2)
        let restored = m.calls.filter { $0.arguments.first == "-B" }.map(\.arguments)
        XCTAssertEqual(restored, [["-B", "-p", "101"], ["-B", "-p", "103"]])
        XCTAssertTrue(t.demoted.isEmpty)
    }

    func testFailedTaskpolicyNotRemembered() async {
        let m = MockProcessRunner()
        m.outputLines = [ps[0]]
        m.exitCodeHandler = { $0.executable.lastPathComponent == "taskpolicy" ? 1 : 0 }
        let t = BackgroundThrottler(runner: m, uid: 501, ownPID: 999)
        let n = await t.demoteNew()
        XCTAssertEqual(n, 0)
        XCTAssertTrue(t.demoted.isEmpty)
    }

    func testRestoreWithNothingDemotedRunsNothing() async {
        let m = MockProcessRunner()
        let t = BackgroundThrottler(runner: m)
        _ = await t.restoreAll()
        XCTAssertTrue(m.calls.isEmpty)
    }

    func testSettingsDefaults() throws {
        XCTAssertTrue(Settings().throttleBackgroundApps)
        XCTAssertEqual(Settings().gameLaunchCount, 0)
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"throttleBackgroundApps": false, "gameLaunchCount": 2}"#.utf8))
        XCTAssertFalse(s.throttleBackgroundApps)
        XCTAssertEqual(s.gameLaunchCount, 2)
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"metalHUD": true}"#.utf8))
        XCTAssertTrue(old.throttleBackgroundApps)
    }
}

final class MemoryCheckTests: XCTestCase {
    func testParseFreePercent() {
        XCTAssertEqual(MemoryCheck.parseFreePercent(["The system has 17179869184 (1048576 pages)", "System-wide memory free percentage: 27%"]), 27)
        XCTAssertNil(MemoryCheck.parseFreePercent(["nothing"]))
    }

    func testParseSwap() {
        XCTAssertEqual(MemoryCheck.parseSwapUsed(["vm.swapusage: total = 5120.00M  used = 4505.25M  free = 614.75M  (encrypted)"]),
                       Int64(4505.25 * 1024 * 1024))
        XCTAssertEqual(MemoryCheck.parseSwapUsed(["vm.swapusage: total = 2.00G  used = 1.00G  free = 1.00G"]), 1_073_741_824)
        XCTAssertNil(MemoryCheck.parseSwapUsed(["garbage"]))
    }

    func testIsLow() {
        XCTAssertTrue(MemoryCheck.isLow(freePercent: 29, swapUsedBytes: 0))
        XCTAssertFalse(MemoryCheck.isLow(freePercent: 30, swapUsedBytes: 3 * 1024 * 1024 * 1024))
        XCTAssertTrue(MemoryCheck.isLow(freePercent: 80, swapUsedBytes: 3 * 1024 * 1024 * 1024 + 1))
        XCTAssertFalse(MemoryCheck.isLow(freePercent: nil, swapUsedBytes: nil))
    }

    func testTopAppsGroupedByBundle() {
        let lines = [
            " 500000 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            " 400000 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
            " 600000 /Applications/Discord.app/Contents/MacOS/Discord",
            " 100 /usr/sbin/distnoted", " 200 /bin/zsh", " 300 /bin/a", " 10 /bin/b",
            " bad line",
        ]
        let top = MemoryCheck.topApps(lines, limit: 5)
        XCTAssertEqual(top.count, 5)
        XCTAssertEqual(top[0], AppMemory(name: "Google Chrome", bytes: 900000 * 1024))
        XCTAssertEqual(top[1].name, "Discord")
    }

    func testCollectUsesCommands() async {
        let m = MockProcessRunner()
        m.outputLines = ["System-wide memory free percentage: 10%"]
        let r = await MemoryCheck.collect(runner: m)
        XCTAssertEqual(r.freePercent, 10)
        XCTAssertTrue(r.isLow)
        XCTAssertEqual(m.calls.map { $0.executable.lastPathComponent }, ["memory_pressure", "sysctl", "ps"])
    }

    func testShaderHint() {
        XCTAssertTrue(ShaderCacheHint.shouldShow(launchCount: 0))
        XCTAssertTrue(ShaderCacheHint.shouldShow(launchCount: 2))
        XCTAssertFalse(ShaderCacheHint.shouldShow(launchCount: 3))
    }
}

final class InstallerTests: XCTestCase {
    func testTeamParsing() {
        XCTAssertTrue(CrossOverInstaller.isTrustedTeam(["Identifier=com.codeweavers.CrossOver", "TeamIdentifier=9C6B7X7Z8E"]))
        XCTAssertFalse(CrossOverInstaller.isTrustedTeam(["TeamIdentifier=ABCDE12345"]))
        XCTAssertFalse(CrossOverInstaller.isTrustedTeam(["TeamIdentifier=not set"]))
        XCTAssertFalse(CrossOverInstaller.isTrustedTeam(["Signature=adhoc"]))
        XCTAssertFalse(CrossOverInstaller.isTrustedTeam(["TeamIdentifier=9C6B7X7Z8EX"]))
    }

    func testURLAndDestination() {
        XCTAssertEqual(CrossOverInstaller.downloadURL.absoluteString,
                       "https://media.codeweavers.com/pub/crossover/cxmac/demo/crossover-26.3.0.zip")
        let a = URL(fileURLWithPath: "/Applications"), u = URL(fileURLWithPath: "/Users/x/Applications")
        XCTAssertEqual(CrossOverInstaller.destinationDirectory(system: a, user: u, systemWritable: true), a)
        XCTAssertEqual(CrossOverInstaller.destinationDirectory(system: a, user: u, systemWritable: false), u)
    }

    private struct Rig {
        let root = makeTempDir()
        var downloads: URL { root.appendingPathComponent("dl") }
        var sys: URL { root.appendingPathComponent("Applications") }
        var user: URL { root.appendingPathComponent("UserApps") }
        let runner = MockProcessRunner()
        let dl = FileDownloader()
        func installer(writable: Bool = true) -> CrossOverInstaller {
            CrossOverInstaller(runner: runner, downloader: dl,
                               locator: CrossOverLocator(searchPaths: [sys.appendingPathComponent("CrossOver.app"),
                                                                       user.appendingPathComponent("CrossOver.app")]),
                               downloads: downloads, systemApplications: sys, userApplications: user,
                               systemWritable: { writable })
        }
        /// ditto "creates" the app; codesign answers with `team`.
        func arm(team: String, strictCode: Int32 = 0) {
            runner.outputLines = ["TeamIdentifier=\(team)"]
            let dl = downloads
            runner.exitCodeHandler = { call in
                if call.executable.lastPathComponent == "ditto" {
                    let dest = URL(fileURLWithPath: call.arguments.last!)
                    try? FileManager.default.createDirectory(at: dest.appendingPathComponent("CrossOver.app/Contents"),
                                                             withIntermediateDirectories: true)
                    _ = dl
                    return 0
                }
                if call.arguments.first == "--verify" { return strictCode }
                return 0
            }
        }
    }

    func testInstallsToApplicationsAndCleansUp() async throws {
        let r = Rig()
        r.arm(team: "9C6B7X7Z8E")
        try await r.installer().install(progress: { _ in }, log: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.sys.appendingPathComponent("CrossOver.app/Contents").path))
        XCTAssertEqual(r.dl.requested, [CrossOverInstaller.downloadURL])
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: r.downloads.path)), [])
        let ditto = try XCTUnwrap(r.runner.calls.first { $0.executable.lastPathComponent == "ditto" })
        XCTAssertEqual(Array(ditto.arguments.prefix(2)), ["-x", "-k"])
        let cs = r.runner.calls.filter { $0.executable.lastPathComponent == "codesign" }.map(\.arguments.first)
        XCTAssertEqual(cs, ["--verify", "-dv"])
    }

    func testFallsBackToUserApplications() async throws {
        let r = Rig()
        r.arm(team: "9C6B7X7Z8E")
        try await r.installer(writable: false).install(progress: { _ in }, log: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.user.appendingPathComponent("CrossOver.app").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.sys.appendingPathComponent("CrossOver.app").path))
    }

    func testWrongTeamRejectedAndDeleted() async throws {
        let r = Rig()
        r.arm(team: "EVIL123456")
        do {
            try await r.installer().install(progress: { _ in }, log: { _ in })
            XCTFail("should throw")
        } catch { XCTAssertEqual(error as? InstallerError, .wrongTeam("EVIL123456")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.sys.appendingPathComponent("CrossOver.app").path))
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: r.downloads.path)), [])
    }

    func testUnsignedRejected() async throws {
        let r = Rig()
        r.arm(team: "not set")
        do {
            try await r.installer().install(progress: { _ in }, log: { _ in })
            XCTFail("should throw")
        } catch { XCTAssertEqual(error as? InstallerError, .wrongTeam(nil)) }
    }

    func testBrokenSignatureRejected() async throws {
        let r = Rig()
        r.arm(team: "9C6B7X7Z8E", strictCode: 3)
        do {
            try await r.installer().install(progress: { _ in }, log: { _ in })
            XCTFail("should throw")
        } catch { XCTAssertEqual(error as? InstallerError, .signatureInvalid) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.sys.appendingPathComponent("CrossOver.app").path))
    }

    func testNeverOverwritesExisting() async throws {
        let r = Rig()
        r.arm(team: "9C6B7X7Z8E")
        let existing = r.sys.appendingPathComponent("CrossOver.app/Contents")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        do {
            try await r.installer().install(progress: { _ in }, log: { _ in })
            XCTFail("should throw")
        } catch { XCTAssertTrue(error is InstallerError) }
        XCTAssertTrue(r.dl.requested.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
    }

    func testSkipsWhenAlreadyInstalled() async throws {
        let r = Rig()
        let bin = r.sys.appendingPathComponent("CrossOver.app/Contents/SharedSupport/CrossOver/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("wine").path, contents: Data())
        try await r.installer().install(progress: { _ in }, log: { _ in })
        XCTAssertTrue(r.dl.requested.isEmpty)
        XCTAssertTrue(r.runner.calls.isEmpty)
    }

    func testRosettaInstallRunsSoftwareupdate() async throws {
        let m = MockProcessRunner()
        // arch fails first (missing), then succeeds after softwareupdate ran.
        let ran = Flag()
        m.exitCodeHandler = { c in
            if c.executable.lastPathComponent == "softwareupdate" { ran.set(); return 0 }
            return ran.value ? 0 : 1
        }
        try await RosettaInstaller(runner: m).install(log: { _ in })
        let su = try XCTUnwrap(m.calls.first { $0.executable.path == "/usr/sbin/softwareupdate" })
        XCTAssertEqual(su.arguments, ["--install-rosetta", "--agree-to-license"])
    }

    func testRosettaAlreadyInstalledSkips() async throws {
        let m = MockProcessRunner()
        try await RosettaInstaller(runner: m).install(log: { _ in })
        XCTAssertFalse(m.calls.contains { $0.executable.lastPathComponent == "softwareupdate" })
    }

    func testRosettaFailureMessageHasManualCommand() async {
        let m = MockProcessRunner()
        m.defaultExitCode = 1
        do {
            try await RosettaInstaller(runner: m).install(log: { _ in })
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? InstallerError, .rosettaFailed)
            XCTAssertTrue(error.localizedDescription.contains("Откройте Терминал и выполните: softwareupdate --install-rosetta"))
        }
    }

    func testPlannerOrderWithNewSteps() {
        XCTAssertEqual(SetupPlanner.automatic, [.systemCheck, .rosetta, .engine, .gptk, .prefix, .steam, .openSteam])
        XCTAssertEqual(SetupPlanner.plan(completed: [.systemCheck, .rosetta]), [.engine, .gptk, .prefix, .steam, .openSteam])
        XCTAssertEqual(SetupPlanner.plan(completed: [.systemCheck, .engine]), [.rosetta, .gptk, .prefix, .steam, .openSteam])
        XCTAssertEqual(SetupPlanner.plan(completed: [.systemCheck, .crossOver], engine: .crossover), [.rosetta, .bottle, .steam, .openSteam])
    }

    func testBlockingChecksIgnoreRosetta() {
        let r = SystemCheckResult(rosettaInstalled: false, macOSVersion: "26.0.0", macOSSupported: true,
                                  freeDiskBytes: 100, enoughDisk: true, isAppleSilicon: true)
        XCTAssertTrue(r.blockingPassed)
        XCTAssertFalse(r.allPassed)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}
