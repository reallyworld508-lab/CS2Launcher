import Foundation

public struct Paths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static let `default` = Paths(
        root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CS2Launcher", isDirectory: true))

    public var runtime: URL { root.appendingPathComponent("Runtime", isDirectory: true) }
    public var wineRoot: URL { runtime.appendingPathComponent("wine", isDirectory: true) }
    public var wineBin: URL { wineRoot.appendingPathComponent("bin", isDirectory: true) }
    public var prefix: URL { root.appendingPathComponent("Prefix", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var downloads: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    public var steamExe: URL {
        prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [root, runtime, prefix, logs, downloads] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
