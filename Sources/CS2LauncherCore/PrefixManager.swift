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
