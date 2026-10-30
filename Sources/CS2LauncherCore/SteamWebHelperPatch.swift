import Foundation

/// Replaces Steam's `steamwebhelper.exe` with a tiny wrapper that launches the
/// renamed original (`steamwebhelper_real.exe`) with `--disable-gpu --single-process`,
/// which fixes black CEF windows under Wine.
public struct SteamWebHelperPatch: Sendable {
    public static let wrapperSizeLimit = 500 * 1024
    static let targetName = "steamwebhelper.exe"
    static let realName = "steamwebhelper_real.exe"

    let paths: Paths
    let wrapperData: Data

    public init(paths: Paths, wrapperData: Data) {
        self.paths = paths
        self.wrapperData = wrapperData
    }

    public static func bundledWrapper() throws -> Data {
        guard let url = Bundle.module.url(forResource: "steamwebhelper-wrapper", withExtension: "exe") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    var steamDir: URL { paths.steamExe.deletingLastPathComponent() }

    /// All `bin/cef/cef.win*` directories that contain a steamwebhelper.exe.
    func cefDirectories() -> [URL] {
        let cef = steamDir.appendingPathComponent("bin/cef", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(atPath: cef.path)) ?? []
        return items.filter { $0.hasPrefix("cef.win") }.sorted().map {
            cef.appendingPathComponent($0, isDirectory: true)
        }.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(Self.targetName).path)
        }
    }

    private func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    private func isWrapperLike(_ url: URL) -> Bool {
        (size(of: url) ?? Int.max) < Self.wrapperSizeLimit
    }

    private func needsPatch(_ dir: URL) -> Bool {
        let target = dir.appendingPathComponent(Self.targetName)
        let real = dir.appendingPathComponent(Self.realName)
        guard FileManager.default.fileExists(atPath: real.path), isWrapperLike(target),
              let data = try? Data(contentsOf: target) else { return true }
        return data != wrapperData
    }

    public var isApplied: Bool {
        let dirs = cefDirectories()
        return !dirs.isEmpty && dirs.allSatisfy { !needsPatch($0) }
    }

    /// Returns the directories that were changed.
    @discardableResult
    public func apply() throws -> [URL] {
        let fm = FileManager.default
        var patched: [URL] = []
        for dir in cefDirectories() {
            let target = dir.appendingPathComponent(Self.targetName)
            let real = dir.appendingPathComponent(Self.realName)
            if isWrapperLike(target) {
                // Already a wrapper (or ours from an older build): rewrite only if different.
                if let current = try? Data(contentsOf: target), current == wrapperData { continue }
                try wrapperData.write(to: target, options: .atomic)
            } else {
                // Valve binary. Never delete it without keeping it as the real one.
                if fm.fileExists(atPath: real.path) { try fm.removeItem(at: real) }
                try fm.moveItem(at: target, to: real)
                do {
                    try wrapperData.write(to: target, options: .atomic)
                } catch {
                    try? fm.moveItem(at: real, to: target)   // roll back
                    throw error
                }
            }
            patched.append(dir)
        }
        return patched
    }
}
