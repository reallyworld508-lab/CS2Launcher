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

    let wine: any WineRunning
    let downloader: Downloading
    let downloads: URL
    var pollInterval: Duration = .seconds(2)
    var pollTimeout: Duration = .seconds(360)   // the first run of a new bottle registers DLLs for minutes

    public init(wine: any WineRunning, downloader: Downloading, downloads: URL) {
        self.wine = wine
        self.downloader = downloader
        self.downloads = downloads
    }

    init(wine: any WineRunning, downloader: Downloading, downloads: URL, pollInterval: Duration, pollTimeout: Duration) {
        self.wine = wine
        self.downloader = downloader
        self.downloads = downloads
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: wine.steamLayout.steamExe.path)
    }

    public func install(progress: @escaping @Sendable (Double) -> Void,
                        log: @escaping @Sendable (String) -> Void) async throws {
        let installer = downloads.appendingPathComponent("SteamSetup.exe")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        progress(0)
        log("Downloading the Steam installer...")
        try await downloader.download(from: Self.installerURL, to: installer) { p in
            progress(max(0, min(1, p)) * 0.5)
        }
        progress(0.5)
        log("Download finished. Running the Steam installer silently...")
        progress(0.6)
        let code = try await wine.run([installer.path, "/S"], extraEnvironment: [:], onOutput: log)
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
        log("Steam is installed.")
        progress(1.0)
    }
}
