import Foundation

public struct GameLauncher: Sendable {
    public static let appID = 730
    let wine: WineRunner

    public init(wine: WineRunner) { self.wine = wine }

    public var cs2Executable: URL {
        wine.bottle.steamapps.appendingPathComponent(
            "common/Counter-Strike Global Offensive/game/bin/win64/cs2.exe")
    }

    /// Executable-only check; use `SteamLibrary.cs2State()` for the full picture.
    public var isCS2Installed: Bool {
        FileManager.default.fileExists(atPath: cs2Executable.path)
    }

    public static func splitArguments(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var hasToken = false
        var quote: Character? = nil
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hasToken = true
            } else if ch.isWhitespace {
                if hasToken { result.append(current); current = ""; hasToken = false }
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { result.append(current) }
        return result
    }

    public static func steamArguments(steamExe: URL, settings: Settings, launchGame: Bool) -> [String] {
        var args = [steamExe.path] + splitArguments(settings.steamArgs)
        if launchGame {
            args += ["-applaunch", String(appID)] + splitArguments(settings.gameArgs)
            if let cap = settings.fpsCap, cap > 0 { args += ["+fps_max", "\(cap)"] }
        }
        return args
    }

    /// D3DMetal comes from the bottle's cxbottle.conf; only the HUD is a per-launch switch.
    public static func environment(for settings: Settings) -> [String: String] {
        settings.metalHUD ? ["MTL_HUD_ENABLED": "1"] : [:]
    }

    public func launch(settings: Settings, launchGame: Bool,
                       log: @escaping @Sendable (String) -> Void) throws -> RunningProcess {
        guard FileManager.default.fileExists(atPath: wine.bottle.steamExe.path) else {
            throw LauncherError.steamNotInstalled
        }
        log(launchGame ? "Запуск Steam и Counter-Strike 2…" : "Запуск Steam…")
        return try wine.start(
            Self.steamArguments(steamExe: wine.bottle.steamExe, settings: settings, launchGame: launchGame),
            extraEnvironment: Self.environment(for: settings), onOutput: log)
    }

    /// True when a `steam.exe` process is alive (ours or otherwise). `pgrep` exits 0 on a match.
    public static func isSteamRunning(runner: ProcessRunning) async -> Bool {
        let code = try? await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/pgrep"), arguments: ["-f", "steam.exe"],
            environment: [:], currentDirectory: nil, onOutput: { _ in })
        return code == 0
    }

    /// True when a `cs2.exe` process is alive.
    public static func isGameRunning(runner: ProcessRunning) async -> Bool {
        let code = try? await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/pgrep"), arguments: ["-f", "cs2.exe"],
            environment: [:], currentDirectory: nil, onOutput: { _ in })
        return code == 0
    }

    public func stop() async { await wine.killAll() }
}
