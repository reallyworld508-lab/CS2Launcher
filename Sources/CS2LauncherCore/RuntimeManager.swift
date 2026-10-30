import Foundation
import CryptoKit

public struct WineRelease: Sendable, Equatable {
    public let version: String
    public let url: URL
    public let sha256: String
    public init(version: String, url: URL, sha256: String) {
        self.version = version; self.url = url; self.sha256 = sha256
    }
}

public enum RuntimeError: LocalizedError, Equatable {
    case checksumMismatch(expected: String, actual: String)
    case wineNotFoundInArchive
    case gptkContentsNotFound
    case commandFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .checksumMismatch(let e, let a):
            return "Checksum mismatch (expected \(e.isEmpty ? "<none>" : e), got \(a))."
        case .wineNotFoundInArchive: return "Could not find Wine inside the downloaded archive."
        case .gptkContentsNotFound: return "The disk image does not contain redist/lib (is this Apple's Game Porting Toolkit image?)."
        case .commandFailed(let c, let code): return "Command failed (\(code)): \(c)"
        }
    }
}

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}

public struct RuntimeManager: Sendable {
    let paths: Paths
    let downloader: Downloading
    let runner: ProcessRunning

    public init(paths: Paths, downloader: Downloading, runner: ProcessRunning) {
        self.paths = paths; self.downloader = downloader; self.runner = runner
    }

    /// Pinned from the GitHub API (Gcenx/game-porting-toolkit, latest); sha256 is GitHub's asset `digest`.
    public static let wineRelease = WineRelease(
        version: "Game-Porting-Toolkit-3.0-3",
        url: URL(string: "https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-3.0-3/game-porting-toolkit-3.0-3.tar.xz")!,
        sha256: "d377683937340f914823dbb2e1252b329cbf834ff58907d0293db8cebf0e392e")

    public var isWineInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: paths.wineBin.appendingPathComponent("wine64").path)
            || fm.fileExists(atPath: paths.wineBin.appendingPathComponent("wine").path)
    }

    public var isD3DMetalInstalled: Bool {
        FileManager.default.fileExists(
            atPath: paths.wineRoot.appendingPathComponent("lib/external/D3DMetal.framework").path)
    }

    // MARK: Wine

    public func installWine(progress: @escaping @Sendable (Double) -> Void,
                            log: @escaping @Sendable (String) -> Void) async throws {
        let release = Self.wineRelease
        let fm = FileManager.default
        try paths.ensureDirectories()
        let archive = paths.downloads.appendingPathComponent(release.url.lastPathComponent)
        log("Downloading Wine \(release.version)...")
        progress(0)
        try await downloader.download(from: release.url, to: archive) { progress($0 * 0.8) }
        progress(0.8)

        log("Verifying checksum...")
        let actual = try Self.sha256(of: archive)
        guard !release.sha256.isEmpty, actual == release.sha256.lowercased() else {
            try? fm.removeItem(at: archive)
            throw RuntimeError.checksumMismatch(expected: release.sha256, actual: actual)
        }

        let tmp = paths.runtime.appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        log("Extracting...")
        try await exec("/usr/bin/tar", ["-xf", archive.path, "-C", tmp.path], log: log)
        progress(0.9)

        guard let wineDir = Self.findWineDir(in: tmp) else { throw RuntimeError.wineNotFoundInArchive }
        if fm.fileExists(atPath: paths.wineRoot.path) { try fm.removeItem(at: paths.wineRoot) }
        try fm.createDirectory(at: paths.runtime, withIntermediateDirectories: true)
        try fm.moveItem(at: wineDir, to: paths.wineRoot)

        _ = try? await runner.run(executable: URL(fileURLWithPath: "/usr/bin/xattr"),
                                  arguments: ["-dr", "com.apple.quarantine", paths.wineRoot.path],
                                  environment: [:], currentDirectory: nil, onOutput: { _ in })
        try? fm.removeItem(at: archive)
        log("Wine installed.")
        progress(1.0)
    }

    static func findWineDir(in root: URL) -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        var best: URL?
        for case let url as URL in en where url.lastPathComponent == "wineserver" {
            let bin = url.deletingLastPathComponent()
            guard bin.lastPathComponent == "bin" else { continue }
            let dir = bin.deletingLastPathComponent()
            if best == nil || dir.pathComponents.count < best!.pathComponents.count { best = dir }
        }
        return best
    }

    // MARK: D3DMetal

    public static func findGPTKImage(in directories: [URL]) -> URL? {
        let fm = FileManager.default
        var best: (URL, Date)?
        for dir in directories {
            guard let items = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in items {
                let name = url.lastPathComponent.lowercased()
                guard name.hasSuffix(".dmg"), name.contains("game"), name.contains("porting"),
                      name.contains("toolkit") else { continue }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if best == nil || date > best!.1 { best = (url, date) }
            }
        }
        return best?.0
    }

    public func installD3DMetal(fromGPTKImage dmg: URL,
                                log: @escaping @Sendable (String) -> Void) async throws {
        guard isWineInstalled else { throw RuntimeError.commandFailed("wine not installed", -1) }
        var mounts: [String] = []
        do {
            let top = try await attach(dmg, log: log)
            mounts.append(top)
            var libDir = Self.findRedistLib(in: URL(fileURLWithPath: top))
            if libDir == nil {
                for nested in Self.findDMGs(in: URL(fileURLWithPath: top)) {
                    let m = try await attach(nested, log: log)
                    mounts.append(m)
                    if let found = Self.findRedistLib(in: URL(fileURLWithPath: m)) { libDir = found; break }
                }
            }
            guard let src = libDir else { throw RuntimeError.gptkContentsNotFound }
            log("Copying D3DMetal libraries...")
            let dst = paths.wineRoot.appendingPathComponent("lib", isDirectory: true)
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
            try await exec("/usr/bin/ditto", [src.path, dst.path], log: log)
        } catch {
            await detachAll(mounts)
            throw error
        }
        await detachAll(mounts)
        log("D3DMetal installed.")
    }

    private func attach(_ image: URL, log: @escaping @Sendable (String) -> Void) async throws -> String {
        log("Mounting \(image.lastPathComponent)...")
        let out = LineCollector()
        let code = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["attach", "-nobrowse", "-readonly", "-plist", image.path],
            environment: [:], currentDirectory: nil, onOutput: { out.add($0) })
        guard code == 0 else { throw RuntimeError.commandFailed("hdiutil attach", code) }
        guard let mp = Self.parseMountPoint(plist: out.text) else {
            throw RuntimeError.commandFailed("hdiutil attach (no mount point)", code)
        }
        return mp
    }

    static func parseMountPoint(plist: String) -> String? {
        guard let start = plist.range(of: "<?xml") else { return nil }
        let data = Data(plist[start.lowerBound...].utf8)
        guard let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = obj["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first
    }

    private func detachAll(_ mounts: [String]) async {
        for m in mounts.reversed() {
            _ = try? await runner.run(executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                      arguments: ["detach", m, "-quiet"],
                                      environment: [:], currentDirectory: nil, onOutput: { _ in })
        }
    }

    static func findRedistLib(in root: URL) -> URL? {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in en where url.lastPathComponent == "lib"
            && url.deletingLastPathComponent().lastPathComponent == "redist" {
            return url
        }
        return nil
    }

    static func findDMGs(in root: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return en.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "dmg" }
    }

    // MARK: Helpers

    private func exec(_ tool: String, _ args: [String],
                      log: @escaping @Sendable (String) -> Void) async throws {
        let code = try await runner.run(executable: URL(fileURLWithPath: tool), arguments: args,
                                        environment: [:], currentDirectory: nil, onOutput: log)
        guard code == 0 else {
            throw RuntimeError.commandFailed(([tool] + args).joined(separator: " "), code)
        }
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
