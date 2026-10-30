import Foundation

public enum LauncherError: LocalizedError, Equatable {
    case steamNotInstalled
    case installerFailed(Int32)
    case steamExeMissingAfterInstall

    public var errorDescription: String? {
        switch self {
        case .steamNotInstalled: return "Steam is not installed yet."
        case .installerFailed(let code): return "The Steam installer failed with exit code \(code)."
        case .steamExeMissingAfterInstall: return "Steam finished installing but steam.exe was not found."
        }
    }
}

public struct SteamInstaller: Sendable {
    public static let installerURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    let wine: WineRunner
    let downloader: Downloading
    var pollInterval: Duration = .seconds(2)
    var pollTimeout: Duration = .seconds(120)

    public init(wine: WineRunner, downloader: Downloading) {
        self.wine = wine
        self.downloader = downloader
    }

    init(wine: WineRunner, downloader: Downloading, pollInterval: Duration, pollTimeout: Duration) {
        self.wine = wine
        self.downloader = downloader
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: wine.paths.steamExe.path)
    }

    public func install(progress: @escaping @Sendable (Double) -> Void,
                        log: @escaping @Sendable (String) -> Void) async throws {
        let installer = wine.paths.downloads.appendingPathComponent("SteamSetup.exe")
        try FileManager.default.createDirectory(at: wine.paths.downloads, withIntermediateDirectories: true)
        progress(0)
        log("Downloading the Steam installer...")
        try await downloader.download(from: Self.installerURL, to: installer) { p in
            progress(max(0, min(1, p)) * 0.5)
        }
        progress(0.5)
        log("Download finished. Running the Steam installer silently...")
        progress(0.6)
        let code = try await wine.run([installer.path, "/S"], onOutput: log)
        guard code == 0 else {
            log("The Steam installer exited with code \(code).")
            throw LauncherError.installerFailed(code)
        }
        log("Installer finished. Waiting for steam.exe to appear...")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: pollTimeout)
        while !isInstalled {
            if clock.now >= deadline {
                log("steam.exe did not appear in time.")
                throw LauncherError.steamExeMissingAfterInstall
            }
            try await Task.sleep(for: pollInterval)
        }
        do {
            let patch = SteamWebHelperPatch(paths: wine.paths, wrapperData: try SteamWebHelperPatch.bundledWrapper())
            let dirs = try patch.apply()
            if !dirs.isEmpty { log("Patched steamwebhelper in \(dirs.map(\.lastPathComponent).joined(separator: ", "))") }
        } catch {
            log("Could not patch steamwebhelper: \(error.localizedDescription)")
        }
        log("Steam is installed.")
        progress(1.0)
    }
}
