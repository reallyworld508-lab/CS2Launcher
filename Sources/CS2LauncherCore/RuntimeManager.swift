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
    case commandFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .checksumMismatch(let e, let a):
            return "Checksum mismatch (expected \(e.isEmpty ? "<none>" : e), got \(a))."
        case .wineNotFoundInArchive: return "Could not find Wine inside the downloaded archive."
        case .commandFailed(let c, let code): return "Command failed (\(code)): \(c)"
        }
    }
}

public struct RuntimeManager: Sendable {
    let paths: Paths
    let downloader: Downloading
    let runner: ProcessRunning

    public init(paths: Paths, downloader: Downloading, runner: ProcessRunning) {
        self.paths = paths; self.downloader = downloader; self.runner = runner
    }

    /// Pinned: Gcenx/macOS_Wine_builds wine-devel (bundles MoltenVK + Vulkan loader, no D3DMetal).
    public static let wineRelease = WineRelease(
        version: "wine-devel-11.20",
        url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.20/wine-devel-11.20-osx64.tar.xz")!,
        sha256: "33bbe09ac5d867d75d6d3aef23b66d25ff81cb62c33bc3f405c138bbf7195ad7")

    static let versionMarkerName = ".cs2l-runtime-version"

    var versionMarker: URL { paths.wineRoot.appendingPathComponent(Self.versionMarkerName) }

    /// Installed means a wine binary exists AND it was installed from the currently pinned release.
    public var isWineInstalled: Bool {
        let fm = FileManager.default
        let hasBinary = fm.fileExists(atPath: paths.wineBin.appendingPathComponent("wine64").path)
            || fm.fileExists(atPath: paths.wineBin.appendingPathComponent("wine").path)
        guard hasBinary,
              let marker = try? String(contentsOf: versionMarker, encoding: .utf8) else { return false }
        return marker.trimmingCharacters(in: .whitespacesAndNewlines) == Self.wineRelease.version
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
        try release.version.write(to: versionMarker, atomically: true, encoding: .utf8)
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
