import Foundation

public enum InstallerError: LocalizedError, Equatable {
    case rosettaFailed
    case extractFailed(Int32)
    case appNotFoundInArchive
    case signatureInvalid
    case wrongTeam(String?)
    case destinationExists(String)
    case moveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .rosettaFailed:
            return "Не удалось установить Rosetta. Откройте Терминал и выполните: \(RosettaInstaller.manualCommand)"
        case .extractFailed(let c): return "Не удалось распаковать архив CrossOver (код \(c))."
        case .appNotFoundInArchive: return "В скачанном архиве нет CrossOver.app. Файл удалён."
        case .signatureInvalid:
            return "Подпись скачанного CrossOver недействительна. Файл удалён, установка отменена."
        case .wrongTeam(let t):
            return "Скачанный CrossOver подписан не CodeWeavers (\(t ?? "без подписи")). Файл удалён, установка отменена."
        case .destinationExists(let p): return "По пути \(p) уже что-то есть. Лаунчер ничего не перезаписывает."
        case .moveFailed(let m): return "Не удалось установить CrossOver: \(m)"
        }
    }
}

public struct RosettaInstaller: Sendable {
    public static let manualCommand = "softwareupdate --install-rosetta"
    let runner: ProcessRunning

    public init(runner: ProcessRunning) { self.runner = runner }

    public static func isInstalled(runner: ProcessRunning) async -> Bool {
        let code = try? await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/arch"), arguments: ["-x86_64", "/usr/bin/true"],
            environment: [:], currentDirectory: nil, onOutput: { _ in })
        return code == 0
    }

    public func install(log: @escaping @Sendable (String) -> Void) async throws {
        if await Self.isInstalled(runner: runner) { log("Rosetta 2 уже установлена."); return }
        log("Установка Rosetta 2…")
        let code = try? await runner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/softwareupdate"),
            arguments: ["--install-rosetta", "--agree-to-license"],
            environment: [:], currentDirectory: nil, onOutput: log)
        guard code == 0, await Self.isInstalled(runner: runner) else {
            log("Rosetta не установилась (возможно, нужны права администратора).")
            throw InstallerError.rosettaFailed
        }
        log("Rosetta 2 установлена.")
    }
}

public struct CrossOverInstaller: Sendable {
    public static let version = "26.3.0"
    public static let teamID = "9C6B7X7Z8E"
    public static let expectedBytes: Int64 = 387_192_026
    public static var downloadURL: URL {
        URL(string: "https://media.codeweavers.com/pub/crossover/cxmac/demo/crossover-\(version).zip")!
    }
    static let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")

    let runner: ProcessRunning
    let downloader: Downloading
    let locator: CrossOverLocator
    let downloads: URL
    let systemApplications: URL
    let userApplications: URL
    let systemWritable: @Sendable () -> Bool

    public init(runner: ProcessRunning, downloader: Downloading, locator: CrossOverLocator, downloads: URL,
                systemApplications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
                userApplications: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications", isDirectory: true),
                systemWritable: (@Sendable () -> Bool)? = nil) {
        self.runner = runner
        self.downloader = downloader
        self.locator = locator
        self.downloads = downloads
        self.systemApplications = systemApplications
        self.userApplications = userApplications
        self.systemWritable = systemWritable ?? { FileManager.default.isWritableFile(atPath: systemApplications.path) }
    }

    /// `TeamIdentifier=…` from `codesign -dv` output; nil when absent or "not set".
    public static func parseTeamIdentifier(_ lines: [String]) -> String? {
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("TeamIdentifier=") else { continue }
            let v = String(t.dropFirst("TeamIdentifier=".count)).trimmingCharacters(in: .whitespaces)
            return (v.isEmpty || v == "not set") ? nil : v
        }
        return nil
    }

    public static func isTrustedTeam(_ lines: [String]) -> Bool { parseTeamIdentifier(lines) == teamID }

    /// /Applications when writable, otherwise ~/Applications.
    public static func destinationDirectory(system: URL, user: URL, systemWritable: Bool) -> URL {
        systemWritable ? system : user
    }

    public var destinationApp: URL {
        Self.destinationDirectory(system: systemApplications, user: userApplications, systemWritable: systemWritable())
            .appendingPathComponent("CrossOver.app", isDirectory: true)
    }

    func verify(_ app: URL, log: @escaping @Sendable (String) -> Void) async throws {
        let strict = try? await runner.run(executable: Self.codesign,
                                           arguments: ["--verify", "--deep", "--strict", app.path],
                                           environment: [:], currentDirectory: nil, onOutput: log)
        guard strict == 0 else { throw InstallerError.signatureInvalid }
        let out = OutputBox()
        _ = try? await runner.run(executable: Self.codesign, arguments: ["-dv", app.path],
                                  environment: [:], currentDirectory: nil, onOutput: { out.add($0) })
        let team = Self.parseTeamIdentifier(out.lines)
        guard team == Self.teamID else { throw InstallerError.wrongTeam(team) }
    }

    public func install(progress: @escaping @Sendable (Double) -> Void,
                        log: @escaping @Sendable (String) -> Void) async throws {
        if locator.isInstalled {
            log("CrossOver уже установлен, пропускаю.")
            progress(1)
            return
        }
        let dest = destinationApp
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest.path) else { throw InstallerError.destinationExists(dest.path) }
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let zip = downloads.appendingPathComponent("crossover-\(Self.version).zip")
        let extractDir = downloads.appendingPathComponent("crossover-extract", isDirectory: true)
        try? fm.removeItem(at: extractDir)
        defer {
            try? fm.removeItem(at: zip)
            try? fm.removeItem(at: extractDir)
        }
        progress(0)
        log("Загрузка CrossOver \(Self.version) с codeweavers.com (~370 МБ)…")
        try await downloader.download(from: Self.downloadURL, to: zip) { progress(max(0, min(1, $0)) * 0.8) }
        if let size = (try? fm.attributesOfItem(atPath: zip.path))?[.size] as? Int64, size != Self.expectedBytes {
            log("Размер файла \(size) байт отличается от ожидаемого; проверяю подпись.")
        }
        progress(0.8)
        log("Распаковка…")
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let code = try await runner.run(executable: Self.ditto, arguments: ["-x", "-k", zip.path, extractDir.path],
                                        environment: [:], currentDirectory: nil, onOutput: log)
        guard code == 0 else { throw InstallerError.extractFailed(code) }
        let app = extractDir.appendingPathComponent("CrossOver.app", isDirectory: true)
        guard fm.fileExists(atPath: app.path) else { throw InstallerError.appNotFoundInArchive }
        progress(0.9)
        log("Проверка подписи CodeWeavers…")
        try await verify(app, log: log)
        log("Подпись верна (CodeWeavers, \(Self.teamID)). Установка в \(dest.deletingLastPathComponent().path)…")
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: app, to: dest)
        } catch {
            throw InstallerError.moveFailed(error.localizedDescription)
        }
        progress(1)
        log("CrossOver установлен.")
    }
}
