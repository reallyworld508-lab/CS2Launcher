import Foundation

public struct GameLauncher: Sendable {
    public static let appID = 730
    let wine: WineRunner

    public init(wine: WineRunner) { self.wine = wine }

    public var cs2Executable: URL {
        wine.paths.prefix.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/steamapps/common/Counter-Strike Global Offensive/game/bin/win64/cs2.exe")
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

    public static func steamArguments(paths: Paths, settings: Settings, launchGame: Bool) -> [String] {
        let user = splitArguments(settings.steamArgs)
        let lower = Set(user.map { $0.lowercased() })
        let required = ["-noverifyfiles", "-norepairfiles", "-nobootstrapupdate", "-skipinitialbootstrap"]
        var args = [paths.steamExe.path] + required.filter { !lower.contains($0) } + user
        if launchGame {
            let user = splitArguments(settings.gameArgs)
            args += ["-applaunch", String(appID)]
            let hasRenderer = user.contains { ["-vulkan", "-dx11"].contains($0.lowercased()) }
            if !hasRenderer { args.append("-vulkan") }
            args += user
            if let cap = settings.fpsCap, cap > 0 { args += ["+fps_max", "\(cap)"] }
        }
        return args
    }

    public static func environment(for settings: Settings) -> [String: String] {
        var env: [String: String] = [:]
        if settings.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        if settings.msync { env["WINEMSYNC"] = "1"; env["WINEESYNC"] = "1" }
        if settings.advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        return env
    }

    public func launch(settings: Settings, launchGame: Bool,
                       log: @escaping @Sendable (String) -> Void) throws -> RunningProcess {
        guard FileManager.default.fileExists(atPath: wine.paths.steamExe.path) else {
            throw LauncherError.steamNotInstalled
        }
        do {
            let patch = SteamWebHelperPatch(paths: wine.paths, wrapperData: try SteamWebHelperPatch.bundledWrapper())
            let dirs = try patch.apply()
            if !dirs.isEmpty { log("Patched steamwebhelper in \(dirs.map(\.lastPathComponent).joined(separator: ", "))") }
        } catch {
            log("Could not patch steamwebhelper: \(error.localizedDescription)")
        }
        log(launchGame ? "Starting Steam and launching Counter-Strike 2..." : "Starting Steam...")
        return try wine.start(
            Self.steamArguments(paths: wine.paths, settings: settings, launchGame: launchGame),
            extraEnvironment: Self.environment(for: settings), onOutput: log)
    }

    /// True when a `steam.exe` process is alive (ours or otherwise). `pgrep` exits 0 on a match.
    public static func isSteamRunning(runner: ProcessRunning) async -> Bool {
        let code = try? await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/pgrep"), arguments: ["-f", "steam.exe"],
            environment: [:], currentDirectory: nil, onOutput: { _ in })
        return code == 0
    }

    public func stop() async { await wine.killAll() }
}
