import Foundation

/// Turns the Steam in-game overlay off for CS2 by editing `userdata/<accountid>/config/localconfig.vdf`.
///
/// Steam rewrites that file on exit, so every method must only be used while Steam is NOT running
/// (`PerformanceTweaks.apply` enforces this). Files that fail to parse are never touched.
public struct SteamOverlay: Sendable {
    /// `UserLocalConfigStore > Software > Valve > Steam > apps > 730 > OverlayAppEnable`.
    public static let valuePath = ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps",
                                   String(GameLauncher.appID), "OverlayAppEnable"]
    public static let backupName = "localconfig.vdf.cs2l-backup"
    public static let markerName = ".cs2l-overlay-disabled"

    public enum Outcome: Equatable, Sendable {
        case changed, unchanged, skippedParseFailure, failed(String)
    }

    /// The bottle's `Steam/userdata` folder.
    public let userdata: URL

    public init(userdata: URL) { self.userdata = userdata }

    /// Every `<accountid>/config/localconfig.vdf` that exists (numeric account folders only).
    public var configFiles: [URL] {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(atPath: userdata.path)) ?? [])
            .filter { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }.sorted()
        return dirs.map { userdata.appendingPathComponent($0).appendingPathComponent("config/localconfig.vdf") }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    static func marker(for config: URL) -> URL {
        config.deletingLastPathComponent().appendingPathComponent(markerName)
    }
    static func backup(for config: URL) -> URL {
        config.deletingLastPathComponent().appendingPathComponent(backupName)
    }

    /// Sets OverlayAppEnable = "0" in every account's file.
    @discardableResult
    public func disable(log: (String) -> Void = { _ in }) -> [URL: Outcome] {
        var results: [URL: Outcome] = [:]
        for file in configFiles {
            let r = disable(file, log: log)
            results[file] = r
        }
        return results
    }

    /// Sets OverlayAppEnable back to "1" where (and only where) this launcher turned it off.
    @discardableResult
    public func restore(log: (String) -> Void = { _ in }) -> [URL: Outcome] {
        var results: [URL: Outcome] = [:]
        for file in configFiles where FileManager.default.fileExists(atPath: Self.marker(for: file).path) {
            results[file] = restore(file, log: log)
        }
        return results
    }

    /// Applies the performance-mode switch. Does nothing while Steam runs.
    @discardableResult
    public func apply(performanceMode: Bool, steamRunning: Bool, log: (String) -> Void = { _ in }) -> [URL: Outcome] {
        guard !steamRunning else { return [:] }
        return performanceMode ? disable(log: log) : restore(log: log)
    }

    private func load(_ file: URL, log: (String) -> Void) -> (text: String, doc: KVDocument)? {
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8),
              let doc = KVDocument.parse(text) else {
            log("Оверлей Steam: не удалось разобрать \(file.path), файл пропущен")
            return nil
        }
        return (text, doc)
    }

    private func disable(_ file: URL, log: (String) -> Void) -> Outcome {
        guard var (text, doc) = load(file, log: log) else { return .skippedParseFailure }
        if doc.string(at: Self.valuePath) == "0" { return .unchanged }
        guard doc.setString("0", at: Self.valuePath) else {
            log("Оверлей Steam: неожиданная структура \(file.path), файл пропущен")
            return .skippedParseFailure
        }
        let fm = FileManager.default
        do {
            let backup = Self.backup(for: file)
            if !fm.fileExists(atPath: backup.path) {
                try text.write(to: backup, atomically: true, encoding: .utf8)
            }
            text = doc.serialize()
            try text.write(to: file, atomically: true, encoding: .utf8)
            try "1".write(to: Self.marker(for: file), atomically: true, encoding: .utf8)
            log("Оверлей Steam для CS2 отключён (\(file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent))")
            return .changed
        } catch {
            log("Оверлей Steam: ошибка записи — \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    private func restore(_ file: URL, log: (String) -> Void) -> Outcome {
        guard var (_, doc) = load(file, log: log) else { return .skippedParseFailure }
        let marker = Self.marker(for: file)
        do {
            guard doc.string(at: Self.valuePath) == "0" else {
                try? FileManager.default.removeItem(at: marker)   // the user changed it themselves
                return .unchanged
            }
            doc.setString("1", at: Self.valuePath)
            try doc.serialize().write(to: file, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: marker)
            log("Оверлей Steam для CS2 включён обратно")
            return .changed
        } catch {
            log("Оверлей Steam: ошибка записи — \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }
}

/// Everything "Режим производительности" and the Metal HUD switch change on disk before a launch.
public enum PerformanceTweaks {
    /// Writes the bottle's environment (D3DMetal, MSync, Metal HUD) and the Steam overlay switch.
    /// Skipped entirely while Steam is running, because Steam rewrites its config on exit.
    public static func apply(bottle: Bottle, settings: Settings, steamRunning: Bool,
                             log: (String) -> Void = { _ in }) {
        guard !steamRunning, bottle.exists else { return }
        do {
            if try bottle.ensureEnvironment(metalHUD: settings.metalHUD) {
                log("Настройки бутылки обновлены (Metal HUD: \(settings.metalHUD ? "вкл" : "выкл"))")
            }
        } catch {
            log("Не удалось обновить cxbottle.conf: \(error.localizedDescription)")
        }
        SteamOverlay(userdata: bottle.steamUserdata)
            .apply(performanceMode: settings.performanceMode, steamRunning: false, log: log)
    }
}

/// How often the launcher looks at Steam/CS2 state.
public enum PollCadence {
    public struct Plan: Equatable, Sendable {
        public let interval: TimeInterval
        /// Full refresh (disk reads, version lookup, steam.exe check) instead of just watching for the game to exit.
        public let heavyWork: Bool
    }
    public static let normalInterval: TimeInterval = 5
    public static let gameInterval: TimeInterval = 30

    public static func plan(gameRunning: Bool, performanceMode: Bool = true) -> Plan {
        (gameRunning && performanceMode) ? Plan(interval: gameInterval, heavyWork: false)
                                         : Plan(interval: normalInterval, heavyWork: true)
    }

    /// cs2.exe can only be running while Steam (or a previous detection of the game) says so.
    public static func shouldCheckGame(steamRunning: Bool, gameRunning: Bool) -> Bool {
        steamRunning || gameRunning
    }
}
