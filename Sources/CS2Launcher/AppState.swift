import SwiftUI
import Observation
import CS2LauncherCore

enum SetupStep: String, CaseIterable, Identifiable {
    case systemCheck, wine, gptk, prefix, steam, cs2
    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemCheck: "Проверка системы"
        case .wine: "Wine"
        case .gptk: "Game Porting Toolkit"
        case .prefix: "Префикс Wine"
        case .steam: "Steam"
        case .cs2: "Counter-Strike 2"
        }
    }
    var explanation: String {
        switch self {
        case .systemCheck: "Apple Silicon, Rosetta, версия macOS и свободное место (от 45 ГБ)."
        case .wine: "Загрузка среды Wine, в которой будет работать Windows-версия игры."
        case .gptk: "Скачайте Game Porting Toolkit с developer.apple.com (бесплатный Apple ID)"
        case .prefix: "Создание изолированного Windows-окружения для Steam и игры."
        case .steam: "Загрузка и установка Windows-клиента Steam в префикс."
        case .cs2: "Откройте Steam, войдите и установите Counter-Strike 2"
        }
    }
    var icon: String {
        switch self {
        case .systemCheck: "checkmark.shield"
        case .wine: "wineglass"
        case .gptk: "cpu"
        case .prefix: "shippingbox"
        case .steam: "gamecontroller"
        case .cs2: "scope"
        }
    }
}

enum StepStatus: Equatable {
    case pending
    case running(Double?)   // nil = indeterminate
    case done
    case failed(String)

    var isDone: Bool { if case .done = self { true } else { false } }
    var isRunning: Bool { if case .running = self { true } else { false } }
}

@MainActor @Observable
final class AppState {
    let backend: LauncherBackend
    var settings: LauncherSettings {
        didSet { if settings != oldValue { saveSettings() } }
    }
    private(set) var logLines: [String] = []
    private(set) var stepStatus: [SetupStep: StepStatus]
    private(set) var systemCheckResult: SystemCheckResult?
    private(set) var gptkImage: URL?
    private(set) var isGameRunning = false
    private(set) var statusText = ""

    private var process: RunningProcess?
    private var logHandle: FileHandle?
    private static let maxLines = 5000

    var logFileURL: URL { backend.paths.logs.appendingPathComponent("launcher.log") }

    init(backend: LauncherBackend) {
        self.backend = backend
        self.settings = LauncherSettings.load(from: backend.paths.settingsFile)
        var s: [SetupStep: StepStatus] = [:]
        SetupStep.allCases.forEach { s[$0] = .pending }
        self.stepStatus = s
        try? backend.paths.ensureDirectories()
        refresh()
    }

    // MARK: Derived

    func status(_ step: SetupStep) -> StepStatus { stepStatus[step] ?? .pending }

    var isSetupComplete: Bool { SetupStep.allCases.allSatisfy { status($0).isDone } }

    /// A step can be started only when all previous steps are done.
    func isUnlocked(_ step: SetupStep) -> Bool {
        for s in SetupStep.allCases {
            if s == step { return true }
            if !status(s).isDone { return false }
        }
        return true
    }

    // MARK: Lifecycle

    func start() async {
        if systemCheckResult == nil { await runSystemCheck() }
        refresh()
    }

    /// Re-derives done-ness from the backend. Running/failed steps are left alone unless now satisfied.
    func refresh() {
        gptkImage = backend.findGPTKImage()
        if let r = systemCheckResult { set(.systemCheck, r.allPassed ? .done : .failed(Self.describe(r))) }
        derive(.wine, backend.isWineInstalled())
        derive(.gptk, backend.isD3DMetalInstalled())
        derive(.prefix, backend.isPrefixReady())
        derive(.steam, backend.isSteamInstalled())
        derive(.cs2, backend.isCS2Installed())
    }

    private func derive(_ step: SetupStep, _ ok: Bool) {
        let cur = status(step)
        if cur.isRunning { return }
        if ok { set(step, .done) } else if cur.isDone { set(step, .pending) }
    }

    private func set(_ step: SetupStep, _ st: StepStatus) { stepStatus[step] = st }

    static func describe(_ r: SystemCheckResult) -> String {
        var p: [String] = []
        if !r.isAppleSilicon { p.append("нужен Mac на Apple Silicon") }
        if !r.rosettaInstalled { p.append("не установлена Rosetta (softwareupdate --install-rosetta)") }
        if !r.macOSSupported { p.append("macOS \(r.macOSVersion) не поддерживается") }
        if !r.enoughDisk {
            let gb = Double(r.freeDiskBytes) / 1_073_741_824
            p.append(String(format: "мало места: %.0f ГБ свободно", gb))
        }
        return p.joined(separator: "; ")
    }

    // MARK: Step actions

    func runSystemCheck() async {
        set(.systemCheck, .running(nil))
        let r = await backend.systemCheck()
        systemCheckResult = r
        log("Проверка системы: macOS \(r.macOSVersion), Rosetta \(r.rosettaInstalled ? "да" : "нет"), свободно \(r.freeDiskBytes / 1_073_741_824) ГБ")
        set(.systemCheck, r.allPassed ? .done : .failed(Self.describe(r)))
    }

    func installWine() {
        runStep(.wine, "Установка Wine") { [backend] progress, log in
            try await backend.installWine(progress: progress, log: log)
        }
    }

    func chooseGPTK(url: URL) {
        gptkImage = url
        runStep(.gptk, "Установка D3DMetal") { [backend] _, log in
            try await backend.installD3DMetal(from: url, log: log)
        }
    }

    func createPrefix() {
        let s = settings
        runStep(.prefix, "Создание префикса") { [backend] _, log in
            try await backend.createPrefix(log: log)
            try await backend.applySettings(s, log: log)
        }
    }

    func installSteam() {
        runStep(.steam, "Установка Steam") { [backend] progress, log in
            try await backend.installSteam(progress: progress, log: log)
        }
    }

    private func runStep(_ step: SetupStep, _ name: String,
                         _ work: @escaping @Sendable (@escaping @Sendable (Double) -> Void,
                                                      @escaping @Sendable (String) -> Void) async throws -> Void) {
        guard !status(step).isRunning else { return }
        set(step, .running(nil))
        log("▶ \(name)")
        let progress: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                guard let self, self.status(step).isRunning else { return }
                self.set(step, .running(p))
            }
        }
        let logger = makeLogger()
        Task {
            do {
                try await work(progress, logger)
                log("✔ \(name): готово")
                set(step, .done)
                refresh()
            } catch {
                log("✘ \(name): \(error.localizedDescription)")
                set(step, .failed(error.localizedDescription))
            }
        }
    }

    // MARK: Running

    func openSteam() { launch(game: false) }
    func play() { launch(game: true) }

    private func launch(game: Bool) {
        guard !isGameRunning else { return }
        isGameRunning = true
        statusText = game ? "Запуск игры…" : "Запуск Steam…"
        let s = settings
        let logger = makeLogger()
        Task {
            do {
                try await backend.applySettings(s, log: logger)
                let p = try backend.launch(settings: s, launchGame: game, log: logger)
                process = p
                statusText = game ? "Игра запущена" : "Steam запущен"
                let code = await p.waitUntilExit()
                log("Процесс завершён, код \(code)")
                statusText = code == 0 ? "Готово к игре" : "Процесс завершился с кодом \(code)"
            } catch {
                log("✘ Запуск: \(error.localizedDescription)")
                statusText = "Ошибка: \(error.localizedDescription)"
            }
            process = nil
            isGameRunning = false
            refresh()
        }
    }

    func stop() {
        statusText = "Остановка…"
        process?.terminate()
        Task {
            await backend.stopAll()
            log("Всё остановлено")
        }
    }

    // MARK: Settings & log

    private func saveSettings() {
        do { try settings.save(to: backend.paths.settingsFile) }
        catch { log("Не удалось сохранить настройки: \(error.localizedDescription)") }
    }

    func log(_ line: String) {
        logLines.append(line)
        if logLines.count > Self.maxLines { logLines.removeFirst(logLines.count - Self.maxLines) }
        appendToFile(line)
    }

    /// A Sendable logger usable from background callbacks.
    func makeLogger() -> @Sendable (String) -> Void {
        { [weak self] line in Task { @MainActor in self?.log(line) } }
    }

    func clearLog() { logLines.removeAll() }

    private func appendToFile(_ line: String) {
        let url = logFileURL
        if logHandle == nil {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            logHandle = try? FileHandle(forWritingTo: url)
            _ = try? logHandle?.seekToEnd()
        }
        if let d = (line + "\n").data(using: .utf8) { try? logHandle?.write(contentsOf: d) }
    }
}
