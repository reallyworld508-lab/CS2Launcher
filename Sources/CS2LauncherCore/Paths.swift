import Foundation

/// Launcher-owned files (engine, logs, downloads, settings). A CrossOver bottle lives in CrossOver's own folder.
public struct Paths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static let `default` = Paths(
        root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CS2Launcher", isDirectory: true))

    /// The free Wine engine: `wine/`, `d3dmetal/` and the Wine `prefix/`.
    public var engine: URL { root.appendingPathComponent("Engine", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var downloads: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    /// Wine prefix created by the previous (standalone Wine) versions of the launcher.
    public var legacyPrefix: URL { root.appendingPathComponent("Prefix", isDirectory: true) }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [root, logs, downloads] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
