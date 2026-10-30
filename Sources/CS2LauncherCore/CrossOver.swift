import Foundation

public enum CrossOverError: LocalizedError, Equatable {
    case notInstalled
    case bottleMissing(String)
    case commandFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "CrossOver не найден. Установите его и нажмите «Проверить снова»."
        case .bottleMissing(let n): return "Бутылка «\(n)» не найдена."
        case .commandFailed(let c, let code): return "Команда завершилась с ошибкой (\(code)): \(c)"
        }
    }
}

/// Finds CrossOver.app and the command-line tools inside it.
public struct CrossOverLocator: Sendable {
    public static var defaultSearchPaths: [URL] {
        [URL(fileURLWithPath: "/Applications/CrossOver.app", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/CrossOver.app", isDirectory: true)]
    }

    let searchPaths: [URL]

    public init(searchPaths: [URL] = CrossOverLocator.defaultSearchPaths) {
        self.searchPaths = searchPaths
    }

    private static func binDirectory(of app: URL) -> URL {
        app.appendingPathComponent("Contents/SharedSupport/CrossOver/bin", isDirectory: true)
    }

    /// First candidate that actually contains the `wine` driver script.
    public var appURL: URL? {
        searchPaths.first {
            FileManager.default.fileExists(atPath: Self.binDirectory(of: $0).appendingPathComponent("wine").path)
        }
    }

    public var isInstalled: Bool { appURL != nil }

    private func tool(_ name: String) -> URL {
        Self.binDirectory(of: appURL ?? searchPaths.first ?? CrossOverLocator.defaultSearchPaths[0])
            .appendingPathComponent(name)
    }

    public var wineScript: URL { tool("wine") }
    public var wineserver: URL { tool("wineserver") }
    public var cxbottle: URL { tool("cxbottle") }

    /// CFBundleShortVersionString of the installed app.
    public var version: String? {
        guard let app = appURL,
              let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }
}

/// A CrossOver bottle (a Wine prefix managed by CrossOver).
public struct Bottle: Sendable {
    public static let defaultName = "CS2"
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
    }

    public let name: String
    public let directory: URL            // folder that contains all bottles
    public let locator: CrossOverLocator
    public let runner: ProcessRunning

    public init(name: String = Bottle.defaultName,
                directory: URL = Bottle.defaultDirectory,
                locator: CrossOverLocator = CrossOverLocator(),
                runner: ProcessRunning = SystemProcessRunner()) {
        self.name = name
        self.directory = directory
        self.locator = locator
        self.runner = runner
    }

    public var path: URL { directory.appendingPathComponent(name, isDirectory: true) }
    public var configURL: URL { path.appendingPathComponent("cxbottle.conf") }
    public var driveC: URL { path.appendingPathComponent("drive_c", isDirectory: true) }
    public var steamDirectory: URL { driveC.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true) }
    public var steamExe: URL { steamDirectory.appendingPathComponent("steam.exe") }
    public var steamUserdata: URL { steamDirectory.appendingPathComponent("userdata", isDirectory: true) }
    public var steamapps: URL { steamDirectory.appendingPathComponent("steamapps", isDirectory: true) }

    public var exists: Bool { FileManager.default.fileExists(atPath: configURL.path) }

    public func create(log: @escaping @Sendable (String) -> Void) async throws {
        guard locator.isInstalled else { throw CrossOverError.notInstalled }
        log("Создание бутылки «\(name)»…")
        let args = ["--bottle", name, "--create", "--template", "win10_64", "--description", "CS2 Launcher"]
        let code = try await runner.run(executable: locator.cxbottle, arguments: args,
                                        environment: ["WINEDEBUG": "-all"], currentDirectory: nil, onOutput: log)
        guard code == 0 else { throw CrossOverError.commandFailed("cxbottle --create", code) }
    }

    // MARK: D3DMetal

    static let backendKey = "CX_GRAPHICS_BACKEND"
    static let msyncKey = "WINEMSYNC"

    static let hudKey = "MTL_HUD_ENABLED"

    /// Returns `conf` with `key` set to `value` in `[EnvironmentVariables]` (nil removes the line).
    /// An existing line is replaced in place; a missing one is inserted right after the section header, and the
    /// section is appended when absent. Other sections and commented-out lines are left alone. Idempotent.
    public static func settingEnvironment(_ key: String, _ value: String?, in conf: String) -> String {
        var lines = conf.components(separatedBy: "\n")
        func isHeader(_ l: String) -> Bool {
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("[") && t.hasSuffix("]")
        }
        let header = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "[EnvironmentVariables]" }
        var matches: [Int] = []
        if let h = header {
            var i = h + 1
            while i < lines.count, !isHeader(lines[i]) {
                if lines[i].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("\"\(key.lowercased())\"") {
                    matches.append(i)
                }
                i += 1
            }
        }
        guard let value else {
            for i in matches.reversed() { lines.remove(at: i) }
            return lines.joined(separator: "\n")
        }
        let line = "\"\(key)\" = \"\(value)\""
        if let first = matches.first {
            lines[first] = line
            for i in matches.dropFirst().reversed() { lines.remove(at: i) }
        } else if let h = header {
            lines.insert(line, at: h + 1)
        } else {
            if let last = lines.last, last.isEmpty { lines.removeLast() }
            lines += ["", "[EnvironmentVariables]", line, ""]
        }
        return lines.joined(separator: "\n")
    }

    /// Returns `conf` with D3DMetal enabled in `[EnvironmentVariables]`. Idempotent. Any forced `WINEMSYNC` line
    /// is removed: CrossOver's own default is safer (a forced value caused hangs inside ntdll).
    public static func enablingD3DMetal(in conf: String) -> String {
        let withoutSync = settingEnvironment(msyncKey, nil, in: conf)
        return settingEnvironment(backendKey, "d3dmetal", in: withoutSync)
    }

    /// D3DMetal and the Metal HUD switch, so they also apply when the game is started from inside Steam.
    public static func applyingEnvironment(metalHUD: Bool, in conf: String) -> String {
        settingEnvironment(hudKey, metalHUD ? "1" : nil, in: enablingD3DMetal(in: conf))
    }

    public var hasD3DMetal: Bool {
        guard let conf = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
        return Self.settingEnvironment(Self.backendKey, "d3dmetal", in: conf) == conf
    }

    public func ensureD3DMetal() throws {
        guard exists else { throw CrossOverError.bottleMissing(name) }
        let conf = try String(contentsOf: configURL, encoding: .utf8)
        let updated = Self.enablingD3DMetal(in: conf)
        if updated != conf { try updated.write(to: configURL, atomically: true, encoding: .utf8) }
    }

    /// Writes D3DMetal/Metal HUD into cxbottle.conf. Returns true when the file changed.
    @discardableResult
    public func ensureEnvironment(metalHUD: Bool) throws -> Bool {
        guard exists else { throw CrossOverError.bottleMissing(name) }
        let conf = try String(contentsOf: configURL, encoding: .utf8)
        let updated = Self.applyingEnvironment(metalHUD: metalHUD, in: conf)
        guard updated != conf else { return false }
        try updated.write(to: configURL, atomically: true, encoding: .utf8)
        return true
    }
}

/// One-time move of Steam (and the games inside it) from the old standalone-Wine prefix into the bottle.
public struct LegacyMigration: Sendable {
    public let paths: Paths
    public let bottle: Bottle

    public init(paths: Paths, bottle: Bottle) {
        self.paths = paths
        self.bottle = bottle
    }

    public var legacySteamDirectory: URL {
        paths.legacyPrefix.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true)
    }

    public var legacySteamExists: Bool {
        FileManager.default.fileExists(atPath: legacySteamDirectory.appendingPathComponent("steam.exe").path)
    }

    /// Old Steam exists, the bottle exists, and the bottle has no Steam yet.
    public var isAvailable: Bool {
        legacySteamExists && bottle.exists
            && !FileManager.default.fileExists(atPath: bottle.steamExe.path)
    }

    /// Clones the old Steam folder into the bottle (APFS clone, falls back to a plain copy), then restores the
    /// original `steamwebhelper.exe`. A no-op when the bottle already has Steam.
    public func migrate(runner: ProcessRunning, log: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        guard isAvailable else { log("Перенос не нужен."); return }
        let dst = bottle.steamDirectory
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) {
            let items = (try? fm.contentsOfDirectory(atPath: dst.path)) ?? []
            guard items.isEmpty else { throw CrossOverError.commandFailed("целевая папка Steam не пуста", 1) }
            try fm.removeItem(at: dst)
        }
        log("Копирование Steam в бутылку (клон APFS)…")
        let cp = URL(fileURLWithPath: "/bin/cp")
        var code = try await runner.run(executable: cp, arguments: ["-Rc", legacySteamDirectory.path, dst.path],
                                        environment: [:], currentDirectory: nil, onOutput: log)
        if code != 0 {
            log("Клонирование недоступно, обычное копирование…")
            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
            code = try await runner.run(executable: cp, arguments: ["-R", legacySteamDirectory.path, dst.path],
                                        environment: [:], currentDirectory: nil, onOutput: log)
        }
        guard code == 0 else { throw CrossOverError.commandFailed("cp", code) }
        let restored = Self.restoreWebHelpers(in: dst)
        if !restored.isEmpty { log("Восстановлен оригинальный steamwebhelper.exe: \(restored.joined(separator: ", "))") }
        log("Steam перенесён.")
    }

    /// In every `bin/cef/cef.win*` puts `steamwebhelper_real.exe` back as `steamwebhelper.exe`.
    /// Returns the names of the directories that were changed.
    @discardableResult
    public static func restoreWebHelpers(in steamDir: URL) -> [String] {
        let fm = FileManager.default
        let cef = steamDir.appendingPathComponent("bin/cef", isDirectory: true)
        let items = ((try? fm.contentsOfDirectory(atPath: cef.path)) ?? []).filter { $0.hasPrefix("cef.win") }.sorted()
        var changed: [String] = []
        for item in items {
            let dir = cef.appendingPathComponent(item, isDirectory: true)
            let real = dir.appendingPathComponent("steamwebhelper_real.exe")
            let target = dir.appendingPathComponent("steamwebhelper.exe")
            guard fm.fileExists(atPath: real.path) else { continue }
            do {
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: real, to: target)
                changed.append(item)
            } catch { continue }
        }
        return changed
    }
}
