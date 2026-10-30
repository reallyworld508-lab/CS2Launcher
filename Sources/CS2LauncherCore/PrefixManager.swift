import Foundation

public struct PrefixManager: Sendable {
    let wine: WineRunner

    public init(wine: WineRunner) { self.wine = wine }

    public var isInitialized: Bool {
        FileManager.default.fileExists(atPath: wine.paths.prefix.appendingPathComponent("drive_c").path)
    }

    public func initialize(log: @escaping @Sendable (String) -> Void) async throws {
        try wine.paths.ensureDirectories()
        log("Initializing Wine prefix...")
        let code = try await wine.run(["wineboot", "--init"], onOutput: log)
        guard code == 0 else { throw RuntimeError.commandFailed("wineboot --init", code) }
        try await apply(Settings(), log: log)
        try writeMarker()
    }

    static let markerName = ".cs2l-prefix-runtime"

    var markerURL: URL { wine.paths.prefix.appendingPathComponent(Self.markerName) }

    private func writeMarker() throws {
        try RuntimeManager.wineRelease.version.write(to: markerURL, atomically: true, encoding: .utf8)
    }

    /// True when the prefix exists but was last set up by a different Wine release (missing marker counts).
    public var needsUpdate: Bool {
        guard isInitialized else { return false }
        let marker = (try? String(contentsOf: markerURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return marker != RuntimeManager.wineRelease.version
    }

    /// Upgrades an existing prefix to the current Wine (`wineboot -u`).
    public func update(log: @escaping @Sendable (String) -> Void) async throws {
        log("Updating Wine prefix...")
        let code = try await wine.run(["wineboot", "-u"], onOutput: log)
        guard code == 0 else { throw RuntimeError.commandFailed("wineboot -u", code) }
        try writeMarker()
    }

    public func apply(_ settings: Settings, log: @escaping @Sendable (String) -> Void) async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs2launcher-\(UUID().uuidString).reg")
        try Self.registryFile(for: settings).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let code = try await wine.run(["regedit", "/S", file.path], onOutput: log)
        guard code == 0 else { throw RuntimeError.commandFailed("regedit", code) }
    }

    public static func registryFile(for settings: Settings) -> String {
        let lines = [
            "Windows Registry Editor Version 5.00",
            "",
            "[HKEY_CURRENT_USER\\Software\\Wine]",
            "\"Version\"=\"win10\"",
            "",
            "[HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]",
            "\"RetinaMode\"=\"\(settings.retinaMode ? "y" : "n")\"",
            "",
        ]
        return lines.joined(separator: "\r\n")
    }
}
