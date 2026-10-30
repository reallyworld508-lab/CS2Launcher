import XCTest
@testable import CS2LauncherCore

enum LocalConfigSample {
    static let text = """
    "UserLocalConfigStore"
    {
    \t// launcher test sample
    \t"Broadcast"
    \t{
    \t\t"Permissions"\t\t"1"
    \t}
    \t"friends"
    \t{
    \t\t"PersonaName"\t\t"Say \\"hi\\" \\\\ there"
    \t\t"Note"\t\t"line1\\nline2\\tTabbed"
    \t\t"Empty"\t\t""
    \t}
    \t"Software"
    \t{
    \t\t"Valve"
    \t\t{
    \t\t\t"Steam"
    \t\t\t{
    \t\t\t\t"apps"
    \t\t\t\t{
    \t\t\t\t\t"7"
    \t\t\t\t\t{
    \t\t\t\t\t\t"cloud"
    \t\t\t\t\t\t{
    \t\t\t\t\t\t\t"last_sync_state"\t\t"synchronized"
    \t\t\t\t\t\t}
    \t\t\t\t\t}
    \t\t\t\t\t"730"
    \t\t\t\t\t{
    \t\t\t\t\t\t"LastPlayed"\t\t"1793389785"
    \t\t\t\t\t\t"LaunchOptions"\t\t"-novid"
    \t\t\t\t\t}
    \t\t\t\t}
    \t\t\t}
    \t\t}
    \t}
    \t"system"
    \t{
    \t\t"PushToTalkKey"\t\t"0"
    \t}
    }

    """
}

final class KVDocumentTests: XCTestCase {
    func testRoundTripIsByteIdentical() throws {
        let doc = try XCTUnwrap(KVDocument.parse(LocalConfigSample.text))
        XCTAssertEqual(doc.serialize(), LocalConfigSample.text)
    }

    func testEscapesDecoded() throws {
        let doc = try XCTUnwrap(KVDocument.parse(LocalConfigSample.text))
        XCTAssertEqual(doc.string(at: ["UserLocalConfigStore", "friends", "PersonaName"]), "Say \"hi\" \\ there")
        XCTAssertEqual(doc.string(at: ["userlocalconfigstore", "FRIENDS", "note"]), "line1\nline2\tTabbed")
    }

    func testCRLFAndBOMPreserved() throws {
        let text = "\u{FEFF}\"A\"\r\n{\r\n\t\"k\"\t\t\"v\"\r\n}\r\n"
        let doc = try XCTUnwrap(KVDocument.parse(text))
        XCTAssertEqual(doc.serialize(), text)
    }

    func testRejectsMalformedOrUnsupported() {
        for bad in ["\"A\"\n{\n\"k\"\t\"v\"\n", "\"A\"\n{\n\"k\"\n}\n", "}\n", "\"A\" {", "\"A\"\n{\n\"k\"\t\"v\\q\"\n}\n",
                    "A\n{\n}\n", "\"A\"\n{\n\"k\"\t\"unterminated\n}\n"] {
            XCTAssertNil(KVDocument.parse(bad), bad)
        }
    }

    func testSetCreatesNestedBlocks() throws {
        var doc = try XCTUnwrap(KVDocument.parse("\"Root\"\n{\n}\n"))
        XCTAssertTrue(doc.setString("0", at: ["Root", "a", "b", "c"]))
        XCTAssertEqual(doc.serialize(), "\"Root\"\n{\n\t\"a\"\n\t{\n\t\t\"b\"\n\t\t{\n\t\t\t\"c\"\t\t\"0\"\n\t\t}\n\t}\n}\n")
    }

    func testSetRefusesWrongKind() throws {
        var doc = try XCTUnwrap(KVDocument.parse("\"Root\"\n{\n\t\"a\"\t\t\"x\"\n}\n"))
        let before = doc
        XCTAssertFalse(doc.setString("0", at: ["Root", "a", "b"]))
        XCTAssertEqual(doc, before)
    }
}

final class SteamOverlayTests: XCTestCase {
    func makeUserdata(accounts: [String: String]) throws -> SteamOverlay {
        let root = makeTempDir().appendingPathComponent("userdata")
        for (id, text) in accounts {
            let cfg = root.appendingPathComponent("\(id)/config")
            try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
            try text.write(to: cfg.appendingPathComponent("localconfig.vdf"), atomically: true, encoding: .utf8)
        }
        return SteamOverlay(userdata: root)
    }
    func file(_ o: SteamOverlay, _ id: String, _ name: String = "localconfig.vdf") -> URL {
        o.userdata.appendingPathComponent("\(id)/config/\(name)")
    }
    func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
    func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

    func testCreatesNestedBlocksWhenMissing() throws {
        let o = try makeUserdata(accounts: ["111": "\"UserLocalConfigStore\"\n{\n\t\"x\"\t\t\"1\"\n}\n"])
        let r = o.disable()
        XCTAssertEqual(r[file(o, "111")], .changed)
        let doc = try XCTUnwrap(KVDocument.parse(try XCTUnwrap(read(file(o, "111")))))
        XCTAssertEqual(doc.string(at: SteamOverlay.valuePath), "0")
        XCTAssertEqual(doc.string(at: ["UserLocalConfigStore", "x"]), "1")
    }

    func testUpdatesExistingValueAndKeepsRest() throws {
        let o = try makeUserdata(accounts: ["111": LocalConfigSample.text])
        var withOverlay = try XCTUnwrap(KVDocument.parse(LocalConfigSample.text))
        withOverlay.setString("1", at: SteamOverlay.valuePath)
        try withOverlay.serialize().write(to: file(o, "111"), atomically: true, encoding: .utf8)
        o.disable()
        var expected = withOverlay
        expected.setString("0", at: SteamOverlay.valuePath)
        XCTAssertEqual(read(file(o, "111")), expected.serialize())
        // Everything else is byte-for-byte what it was.
        XCTAssertTrue(read(file(o, "111"))!.contains("\"PersonaName\"\t\t\"Say \\\"hi\\\" \\\\ there\""))
        XCTAssertTrue(read(file(o, "111"))!.contains("// launcher test sample"))
    }

    func testAllAccountsAndNonNumericIgnored() throws {
        let o = try makeUserdata(accounts: ["111": LocalConfigSample.text, "222": LocalConfigSample.text,
                                            "ac": LocalConfigSample.text])
        let r = o.disable()
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(read(file(o, "ac")), LocalConfigSample.text)
    }

    func testParseFailureLeavesFileUntouched() throws {
        let broken = "\"UserLocalConfigStore\"\n{\n\t\"a\"\t\t\"1\"\n"
        let o = try makeUserdata(accounts: ["111": broken])
        var logs: [String] = []
        let r = o.disable(log: { logs.append($0) })
        XCTAssertEqual(r[file(o, "111")], .skippedParseFailure)
        XCTAssertEqual(read(file(o, "111")), broken)
        XCTAssertFalse(exists(file(o, "111", SteamOverlay.backupName)))
        XCTAssertFalse(exists(file(o, "111", SteamOverlay.markerName)))
        XCTAssertFalse(logs.isEmpty)
    }

    func testBackupCreatedOnce() throws {
        let o = try makeUserdata(accounts: ["111": LocalConfigSample.text])
        o.disable()
        XCTAssertEqual(read(file(o, "111", SteamOverlay.backupName)), LocalConfigSample.text)
        o.restore()   // back to "1"
        // Steam rewrites the file; a second disable must not overwrite the first backup.
        var doc = try XCTUnwrap(KVDocument.parse(read(file(o, "111"))!))
        doc.setString("zzz", at: ["UserLocalConfigStore", "extra"])
        try doc.serialize().write(to: file(o, "111"), atomically: true, encoding: .utf8)
        o.disable()
        XCTAssertEqual(read(file(o, "111", SteamOverlay.backupName)), LocalConfigSample.text)
    }

    func testAlreadyDisabledIsUntouchedWithoutMarker() throws {
        var doc = try XCTUnwrap(KVDocument.parse(LocalConfigSample.text))
        doc.setString("0", at: SteamOverlay.valuePath)
        let o = try makeUserdata(accounts: ["111": doc.serialize()])
        XCTAssertEqual(o.disable()[file(o, "111")], .unchanged)
        XCTAssertFalse(exists(file(o, "111", SteamOverlay.markerName)))
        XCTAssertFalse(exists(file(o, "111", SteamOverlay.backupName)))
        // The user disabled it themselves, so turning performance mode off must not re-enable it.
        XCTAssertTrue(o.restore().isEmpty)
        XCTAssertEqual(read(file(o, "111")), doc.serialize())
    }

    func testRestoreOnlyWithMarker() throws {
        let o = try makeUserdata(accounts: ["111": LocalConfigSample.text])
        o.disable()
        XCTAssertTrue(exists(file(o, "111", SteamOverlay.markerName)))
        XCTAssertEqual(o.restore()[file(o, "111")], .changed)
        let doc = try XCTUnwrap(KVDocument.parse(read(file(o, "111"))!))
        XCTAssertEqual(doc.string(at: SteamOverlay.valuePath), "1")
        XCTAssertFalse(exists(file(o, "111", SteamOverlay.markerName)))
        XCTAssertTrue(o.restore().isEmpty)
    }

    func testRestoreSkipsBrokenFileAndKeepsMarker() throws {
        let o = try makeUserdata(accounts: ["111": LocalConfigSample.text])
        o.disable()
        try "garbage {".write(to: file(o, "111"), atomically: true, encoding: .utf8)
        XCTAssertEqual(o.restore()[file(o, "111")], .skippedParseFailure)
        XCTAssertEqual(read(file(o, "111")), "garbage {")
        XCTAssertTrue(exists(file(o, "111", SteamOverlay.markerName)))
    }

    func testApplyDoesNothingWhileSteamRuns() throws {
        let o = try makeUserdata(accounts: ["111": LocalConfigSample.text])
        XCTAssertTrue(o.apply(performanceMode: true, steamRunning: true).isEmpty)
        XCTAssertEqual(read(file(o, "111")), LocalConfigSample.text)
        XCTAssertEqual(o.apply(performanceMode: true, steamRunning: false).count, 1)
    }

    func testPerformanceTweaksAppliesConfAndOverlay() throws {
        let fx = CrossOverFixture()
        try fx.writeConf("[EnvironmentVariables]\n")
        let cfg = fx.bottle.steamUserdata.appendingPathComponent("42/config")
        try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        try LocalConfigSample.text.write(to: cfg.appendingPathComponent("localconfig.vdf"), atomically: true, encoding: .utf8)
        var s = Settings(); s.metalHUD = true
        PerformanceTweaks.apply(bottle: fx.bottle, settings: s, steamRunning: true)
        XCTAssertEqual(try String(contentsOf: fx.bottle.configURL, encoding: .utf8), "[EnvironmentVariables]\n")
        PerformanceTweaks.apply(bottle: fx.bottle, settings: s, steamRunning: false)
        let conf = try String(contentsOf: fx.bottle.configURL, encoding: .utf8)
        XCTAssertTrue(conf.contains("\"MTL_HUD_ENABLED\" = \"1\""))
        XCTAssertTrue(conf.contains("\"CX_GRAPHICS_BACKEND\" = \"d3dmetal\""))
        let vdf = try String(contentsOf: cfg.appendingPathComponent("localconfig.vdf"), encoding: .utf8)
        XCTAssertEqual(KVDocument.parse(vdf)?.string(at: SteamOverlay.valuePath), "0")
        s.metalHUD = false; s.performanceMode = false
        PerformanceTweaks.apply(bottle: fx.bottle, settings: s, steamRunning: false)
        XCTAssertFalse(try String(contentsOf: fx.bottle.configURL, encoding: .utf8).contains("MTL_HUD_ENABLED"))
        let vdf2 = try String(contentsOf: cfg.appendingPathComponent("localconfig.vdf"), encoding: .utf8)
        XCTAssertEqual(KVDocument.parse(vdf2)?.string(at: SteamOverlay.valuePath), "1")
    }
}

final class SettingEnvironmentTests: XCTestCase {
    func testAddsAfterHeader() {
        let out = Bottle.settingEnvironment("MTL_HUD_ENABLED", "1", in: "[A]\n\"x\" = \"y\"\n\n[EnvironmentVariables]\n\"FOO\" = \"bar\"\n")
        XCTAssertEqual(out, "[A]\n\"x\" = \"y\"\n\n[EnvironmentVariables]\n\"MTL_HUD_ENABLED\" = \"1\"\n\"FOO\" = \"bar\"\n")
    }
    func testReplacesInPlace() {
        let conf = "[EnvironmentVariables]\n\"A\" = \"1\"\n\"mtl_hud_enabled\" = \"0\"\n\"B\" = \"2\"\n"
        XCTAssertEqual(Bottle.settingEnvironment("MTL_HUD_ENABLED", "1", in: conf),
                       "[EnvironmentVariables]\n\"A\" = \"1\"\n\"MTL_HUD_ENABLED\" = \"1\"\n\"B\" = \"2\"\n")
    }
    func testRemoves() {
        let conf = "[EnvironmentVariables]\n\"A\" = \"1\"\n\"MTL_HUD_ENABLED\" = \"1\"\n;;\"MTL_HUD_ENABLED\" = \"9\"\n[Other]\n\"MTL_HUD_ENABLED\" = \"keep\"\n"
        XCTAssertEqual(Bottle.settingEnvironment("MTL_HUD_ENABLED", nil, in: conf),
                       "[EnvironmentVariables]\n\"A\" = \"1\"\n;;\"MTL_HUD_ENABLED\" = \"9\"\n[Other]\n\"MTL_HUD_ENABLED\" = \"keep\"\n")
    }
    func testRemoveMissingIsNoOp() {
        let conf = "[Bottle]\n\"A\" = \"b\"\n"
        XCTAssertEqual(Bottle.settingEnvironment("K", nil, in: conf), conf)
    }
    func testCreatesSectionAndIsIdempotent() {
        let once = Bottle.settingEnvironment("K", "v", in: "[Bottle]\n\"A\" = \"b\"\n")
        XCTAssertEqual(once, "[Bottle]\n\"A\" = \"b\"\n\n[EnvironmentVariables]\n\"K\" = \"v\"\n")
        XCTAssertEqual(Bottle.settingEnvironment("K", "v", in: once), once)
    }
    func testIgnoresSameKeyInOtherSection() {
        let conf = "[Other]\n\"K\" = \"x\"\n[EnvironmentVariables]\n"
        XCTAssertEqual(Bottle.settingEnvironment("K", "v", in: conf), "[Other]\n\"K\" = \"x\"\n[EnvironmentVariables]\n\"K\" = \"v\"\n")
    }
    func testApplyingEnvironmentRoundTrip() throws {
        let fx = CrossOverFixture()
        try fx.writeConf("[EnvironmentVariables]\n")
        XCTAssertTrue(try fx.bottle.ensureEnvironment(metalHUD: true))
        XCTAssertFalse(try fx.bottle.ensureEnvironment(metalHUD: true))
        XCTAssertTrue(fx.bottle.hasD3DMetal)
        XCTAssertTrue(try fx.bottle.ensureEnvironment(metalHUD: false))
        XCTAssertFalse(try String(contentsOf: fx.bottle.configURL, encoding: .utf8).contains("MTL_HUD"))
    }
}

final class PollCadenceTests: XCTestCase {
    func testNormalVsGame() {
        XCTAssertEqual(PollCadence.plan(gameRunning: false), .init(interval: 5, heavyWork: true))
        XCTAssertEqual(PollCadence.plan(gameRunning: true), .init(interval: 30, heavyWork: false))
    }
    func testPerformanceModeOffKeepsNormalCadence() {
        XCTAssertEqual(PollCadence.plan(gameRunning: true, performanceMode: false), .init(interval: 5, heavyWork: true))
    }
    func testShouldCheckGame() {
        XCTAssertFalse(PollCadence.shouldCheckGame(steamRunning: false, gameRunning: false))
        XCTAssertTrue(PollCadence.shouldCheckGame(steamRunning: true, gameRunning: false))
        XCTAssertTrue(PollCadence.shouldCheckGame(steamRunning: false, gameRunning: true))
    }
    func testSettingsDefaultAndTolerantDecoding() throws {
        XCTAssertTrue(Settings().performanceMode)
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"metalHUD": true}"#.utf8))
        XCTAssertTrue(old.performanceMode)
        let off = try JSONDecoder().decode(Settings.self, from: Data(#"{"performanceMode": false}"#.utf8))
        XCTAssertFalse(off.performanceMode)
        let junk = try JSONDecoder().decode(Settings.self, from: Data(#"{"performanceMode": "yes"}"#.utf8))
        XCTAssertTrue(junk.performanceMode)
    }
    func testGameDetectionUsesPgrep() async {
        let m = MockProcessRunner()
        let r = await GameLauncher.isGameRunning(runner: m)
        XCTAssertTrue(r)
        XCTAssertEqual(m.calls.first?.arguments, ["-f", "cs2.exe"])
        m.defaultExitCode = 1
        let r2 = await GameLauncher.isGameRunning(runner: m)
        XCTAssertFalse(r2)
    }
}
