import SwiftUI
import Observation
import CS2LauncherCore

enum SetupStep: String, CaseIterable, Identifiable {
    case systemCheck, rosetta, engine, gptk, prefix, crossOver, bottle, steam, cs2
    var id: String { rawValue }

    /// Steps shown for an engine, in order.
    static func steps(for engine: EngineKind) -> [SetupStep] {
        switch engine {
        case .free: [.systemCheck, .rosetta, .engine, .gptk, .prefix, .steam, .cs2]
        case .crossover: [.systemCheck, .rosetta, .crossOver, .bottle, .steam, .cs2]
        }
    }

    var title: String {
        switch self {
        case .systemCheck: "Проверка системы"
        case .rosetta: "Rosetta 2"
        case .engine: "Движок Wine"
        case .gptk: "D3DMetal (Apple GPTK)"
        case .prefix: "Префикс Wine"
        case .crossOver: "CrossOver"
        case .bottle: "Бутылка"
        case .steam: "Steam"
        case .cs2: "Counter-Strike 2"
        }
    }
    var explanation: String {
        switch self {
        case .systemCheck: "Apple Silicon, версия macOS и свободное место (от 45 ГБ)."
        case .rosetta: "Слой совместимости Apple для Windows-программ. Устанавливается автоматически."
        case .engine: "Бесплатный движок Wine на исходниках CrossOver (~80 МБ). Лаунчер скачает его и проверит контрольную сумму."
        case .gptk: "D3DMetal берётся из Game Porting Toolkit от Apple: скачайте Game_Porting_Toolkit*.dmg на странице Apple (нужен Apple ID) в «Загрузки» — лаунчер найдёт его сам — или выберите файл вручную."
        case .prefix: "Создание префикса Wine и настройка ввода. Занимает около минуты."
        case .crossOver: "Лаунчер сам скачает и установит CrossOver (D3DMetal + DirectX 11) с codeweavers.com. CrossOver — платная программа: 14 дней бесплатно, затем нужна лицензия на codeweavers.com"
        case .bottle: "Создание бутылки CrossOver «CS2» и включение D3DMetal. Если CrossOver покажет окно пробной версии — нажмите «Try Now»."
        case .steam: "Загрузка и установка Windows-клиента Steam в бутылку. Первый запуск может занять несколько минут."
        case .cs2: "Откройте Steam, войдите и установите Counter-Strike 2"
        }
    }
    var stage: SetupStage {
        switch self {
        case .systemCheck: .systemCheck
        case .rosetta: .rosetta
        case .engine: .engine
        case .gptk: .gptk
        case .prefix: .prefix
        case .crossOver: .crossOver
        case .bottle: .bottle
        case .steam: .steam
        case .cs2: .cs2
        }
    }
    var icon: String {
        switch self {
        case .systemCheck: "checkmark.shield"
        case .rosetta: "cpu"
        case .engine: "wineglass"
        case .gptk: "memorychip"
        case .prefix: "shippingbox"
        case .crossOver: "wineglass"
        case .bottle: "shippingbox"
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

extension SetupStage {
    var title: String {
        switch self {
        case .systemCheck: "Проверка системы"
        case .rosetta: "Rosetta 2"
        case .engine: "Движок Wine"
        case .gptk: "D3DMetal"
        case .prefix: "Префикс Wine"
        case .crossOver: "CrossOver"
        case .bottle: "Подготовка бутылки"
        case .steam: "Установка Steam"
        case .openSteam: "Запуск Steam"
        case .cs2: "Counter-Strike 2"
        }
    }
    var step: SetupStep? {
        switch self {
        case .systemCheck: .systemCheck
        case .rosetta: .rosetta
        case .engine: .engine
        case .gptk: .gptk
        case .prefix: .prefix
        case .crossOver: .crossOver
        case .bottle: .bottle
        case .steam: .steam
        case .cs2: .cs2
        case .openSteam: nil
        }
    }
}

struct SetupFailure: Equatable {
    let stage: SetupStage
    let message: String
}

@MainActor @Observable
final class AppState {
    let backend: LauncherBackend
    var settings: LauncherSettings {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
            if settings.performanceMode != oldValue.performanceMode || settings.metalHUD != oldValue.metalHUD {
                backend.applyPerformanceTweaks(settings: settings, steamRunning: isSteamRunning, log: makeLogger())
            }
            if settings.engine != oldValue.engine { refresh() }
            if settings.throttleBackgroundApps != oldValue.throttleBackgroundApps, isGameRunning {
                Task { @MainActor in await applyThrottle() }
            }
        }
    }
    private(set) var logLines: [String] = []
    private(set) var stepStatus: [SetupStep: StepStatus]
    private(set) var systemCheckResult: SystemCheckResult?
    private(set) var statusText = ""

    // Run state. `isSteamRunning` (a steam.exe is alive) and `gameLaunched` (we asked Steam to start CS2)
    // are separate; neither blocks a new launch. `isLaunching` only covers the short spawn phase.
    private(set) var isSteamRunning = false
    private(set) var gameLaunched = false
    /// cs2.exe is alive; while true the monitor backs off (see `PollCadence`).
    private(set) var isGameRunning = false
    private(set) var isLaunching = false
    private(set) var cs2State: CS2InstallState = .notInstalled
    /// Latest memory snapshot (taken while the game is not running).
    private(set) var memoryReport: MemoryReport?
    private var rosettaVerified = false
    private(set) var crossOverVersion: String?
    private(set) var legacyMigrationAvailable = false
    static let crossOverDownloadURL = URL(string: "https://www.codeweavers.com/crossover")!

    // One-click setup
    private(set) var isInstallingAll = false
    private(set) var setupPlan: [SetupStage] = []
    private(set) var setupIndex = 0
    private(set) var setupFailure: SetupFailure?

    private var process: RunningProcess?
    private var setupTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
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
        let b = backend
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: nil) { _ in b.restoreBackgroundBlocking() }
        refresh()
    }

    /// Hint about the shader cache for the first few launches.
    var showShaderHint: Bool { ShaderCacheHint.shouldShow(launchCount: settings.gameLaunchCount) }

    var showMemoryWarning: Bool { memoryReport?.isLow == true }

    func refreshMemory() async {
        guard !isGameRunning else { return }
        memoryReport = await backend.memoryReport()
    }

    /// Demotes (or, with the setting off, restores) the user's chat/browser apps while the game runs.
    func applyThrottle() async {
        if isGameRunning && settings.throttleBackgroundApps {
            let n = await backend.throttleBackground()
            if n > 0 { log("Фоновый приоритет: \(n) процессов приложений переведено на E-ядра") }
        } else {
            let n = await backend.restoreBackground()
            if n > 0 { log("Приоритет \(n) процессов возвращён") }
        }
    }

    // MARK: Derived

    var engineKind: EngineKind { settings.engine }

    /// Setup steps of the chosen engine, in order.
    var steps: [SetupStep] { SetupStep.steps(for: engineKind) }

    func status(_ step: SetupStep) -> StepStatus { stepStatus[step] ?? .pending }

    /// Something is in progress (excluding the CS2 download, which Steam does on its own).
    var isBusy: Bool {
        isLaunching || isInstallingAll
            || steps.contains { $0 != .cs2 && status($0).isRunning }
    }

    func completedStages() -> Set<SetupStage> {
        var c = Set(steps.filter { status($0).isDone }.map(\.stage))
        if isSteamRunning || c.contains(.cs2) { c.insert(.openSteam) }
        return c
    }

    /// Everything needed to play exists. (The system check is advisory, so a later launch skips straight to MainView.)
    var isSetupComplete: Bool { SetupPlanner.isComplete(completedStages(), engine: engineKind) }

    /// True when "Установить всё" has something to do.
    var hasPendingAutomaticSteps: Bool { !SetupPlanner.plan(completed: completedStages(), engine: engineKind).isEmpty }

    /// A step can be started only when all previous steps are done.
    func isUnlocked(_ step: SetupStep) -> Bool {
        for s in steps {
            if s == step { return true }
            if !status(s).isDone { return false }
        }
        return true
    }

    var currentSetupStage: SetupStage? {
        isInstallingAll && setupIndex < setupPlan.count ? setupPlan[setupIndex] : nil
    }

    /// 0...1 over the whole one-click run.
    var overallSetupProgress: Double {
        var stepP: Double?
        if let st = currentSetupStage?.step, case .running(let p) = status(st) { stepP = p }
        return SetupPlanner.overallProgress(index: setupIndex, total: setupPlan.count, stepProgress: stepP)
    }

    var setupProgressText: String {
        guard let st = currentSetupStage else { return "" }
        return "Шаг \(setupIndex + 1) из \(setupPlan.count): \(st.title)"
    }

    // MARK: Lifecycle

    func start() async {
        // On later launches (everything installed) skip the check and go straight to MainView.
        if !isSetupComplete && systemCheckResult == nil { await runSystemCheck() }
        refresh()
        await refreshSteamRunning()
        await refreshMemory()
        startMonitoring()
    }

    /// Polls Steam/CS2 state; the CS2 step flips to done by itself. While the game runs (and performance mode
    /// is on) it only checks every 30 s whether cs2.exe is still alive, to keep the CPU free for the game.
    private func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let plan = PollCadence.plan(gameRunning: self.isGameRunning,
                                            performanceMode: self.settings.performanceMode)
                try? await Task.sleep(for: .seconds(plan.interval))
                guard !Task.isCancelled else { return }
                if plan.heavyWork {
                    self.refresh()
                    await self.refreshSteamRunning()
                }
                await self.refreshGameRunning()
            }
        }
    }

    func refreshGameRunning() async {
        var running = false
        if PollCadence.shouldCheckGame(steamRunning: isSteamRunning, gameRunning: isGameRunning) {
            running = await backend.isGameRunning()
        }
        if running != isGameRunning {
            isGameRunning = running
            log(running ? "CS2 запущена: фоновые проверки лаунчера замедлены" : "CS2 закрыта")
            if !running { refresh(); await refreshSteamRunning(); await refreshMemory() }
        }
        await applyThrottle()
    }

    func refreshSteamRunning() async {
        var alive = process?.isRunning ?? false
        if !alive { alive = await backend.isSteamRunning() }
        if alive != isSteamRunning { isSteamRunning = alive }
        if !alive && gameLaunched { gameLaunched = false }
    }

    /// Re-derives done-ness from the backend. Running/failed steps are left alone unless now satisfied.
    func refresh() {
        if let r = systemCheckResult { set(.systemCheck, r.blockingPassed ? .done : .failed(Self.describe(r))) }
        let version = backend.crossOverVersion()
        if version != crossOverVersion { crossOverVersion = version }
        derive(.rosetta, rosettaVerified || systemCheckResult?.rosettaInstalled == true || status(.steam).isDone)
        if engineKind == .free {
            derive(.engine, backend.isEngineInstalled())
            derive(.gptk, backend.isGPTKReady())
            derive(.prefix, backend.isFreePrefixReady())
        } else {
            derive(.crossOver, backend.isCrossOverInstalled())
            derive(.bottle, backend.isBottleReady())
        }
        derive(.steam, backend.isSteamInstalled())
        if engineKind == .free && status(.steam).isDone { _ = backend.ensureWebHelperPatched(log: makeLogger()) }
        let legacy = backend.isLegacyMigrationAvailable()
        if legacy != legacyMigrationAvailable { legacyMigrationAvailable = legacy }
        let cs2 = backend.cs2InstallState()
        if cs2 != cs2State { cs2State = cs2 }
        switch cs2 {
        case .installed: set(.cs2, .done)
        case .downloading(let p): set(.cs2, .running(p))
        case .notInstalled: set(.cs2, .pending)
        }
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
        if !r.macOSSupported { p.append("macOS \(r.macOSVersion) не поддерживается") }
        if !r.enoughDisk {
            let gb = Double(r.freeDiskBytes) / 1_073_741_824
            p.append(String(format: "мало места: %.0f ГБ свободно", gb))
        }
        return p.joined(separator: "; ")
    }

    // MARK: One-click setup

    /// Runs every automatic step that is not done yet. Calling it again after a failure resumes from the failed step.
    func installAll() {
        guard !isInstallingAll, !isLaunching,
              !steps.contains(where: { $0 != .cs2 && status($0).isRunning }) else { return }
        isInstallingAll = true
        setupFailure = nil
        setupTask = Task { @MainActor in
            await runInstallAll()
            isInstallingAll = false
            setupTask = nil
        }
    }

    private func runInstallAll() async {
        refresh()
        await refreshSteamRunning()
        let plan = SetupPlanner.plan(completed: completedStages(), engine: engineKind)
        setupPlan = plan
        setupIndex = 0
        guard !plan.isEmpty else { return }
        log("▶ Установить всё: \(plan.map(\.rawValue).joined(separator: " → "))")
        let result = await SetupPlanner.execute(
            plan: plan,
            onStart: { [self] i, _ in setupIndex = i },
            step: { [self] stage in await performStage(stage) })
        if let failed = result.failed {
            var msg = setupFailure?.message ?? ""
            if msg.isEmpty, let st = failed.step, case .failed(let m) = status(st) { msg = m }
            if msg.isEmpty { msg = "Не удалось выполнить шаг" }
            setupFailure = SetupFailure(stage: failed, message: msg)
            statusText = ""
            log("✘ Установка остановлена на шаге «\(failed.title)»")
        } else if !result.cancelled {
            setupIndex = plan.count
            log("✔ Установить всё: готово")
        }
    }

    private func performStage(_ stage: SetupStage) async -> Bool {
        switch stage {
        case .systemCheck:
            await runSystemCheck()
            return status(.systemCheck).isDone
        case .rosetta:
            return await performRosettaInstall()
        case .engine:
            return await performEngineInstall()
        case .gptk:
            return await performGPTKInstall(dmg: nil)
        case .prefix:
            return await performPrefixCreate()
        case .crossOver:
            return await performCrossOverInstall()
        case .bottle:
            return await performBottleCreate()
        case .steam:
            return await performSteamInstall()
        case .openSteam:
            do {
                try await performLaunch(game: false)
                return true
            } catch {
                log("✘ Запуск: \(error.localizedDescription)")
                statusText = "Ошибка: \(error.localizedDescription)"
                setupFailure = SetupFailure(stage: .openSteam, message: error.localizedDescription)
                return false
            }
        case .cs2:
            return true
        }
    }

    // MARK: Step actions

    func runSystemCheck() async {
        set(.systemCheck, .running(nil))
        let r = await backend.systemCheck()
        systemCheckResult = r
        log("Проверка системы: macOS \(r.macOSVersion), Rosetta \(r.rosettaInstalled ? "да" : "нет"), свободно \(r.freeDiskBytes / 1_073_741_824) ГБ")
        if !r.enoughDisk { log("Внимание: \(Self.describe(r)); для установки CS2 нужно от 45 ГБ") }
        set(.systemCheck, r.blockingPassed ? .done : .failed(Self.describe(r)))
    }

    /// Re-checks for CrossOver.app. Returns true when found.
    @discardableResult
    func checkCrossOver(reportingFailure: Bool = false) -> Bool {
        refresh()
        if backend.isCrossOverInstalled() {
            set(.crossOver, .done)
            return true
        }
        let msg = "CrossOver не найден в «Программы». Скачайте и установите его, затем нажмите «Проверить снова»."
        set(.crossOver, .failed(msg))
        if reportingFailure {
            log("✘ CrossOver не найден")
            setupFailure = SetupFailure(stage: .crossOver, message: msg)
        }
        return false
    }

    func recheckCrossOver() { checkCrossOver() }

    func downloadCrossOver() { NSWorkspace.shared.open(Self.crossOverDownloadURL) }

    private func performRosettaInstall() async -> Bool {
        if systemCheckResult?.rosettaInstalled == true || rosettaVerified {
            set(.rosetta, .done)
            return true
        }
        let ok = await performStep(.rosetta, "Установка Rosetta 2") { [backend] _, log in
            try await backend.installRosetta(log: log)
        }
        if ok { rosettaVerified = true }
        return ok
    }

    func installRosetta() { Task { _ = await performRosettaInstall() } }

    /// Installs CrossOver from codeweavers.com unless it is already there.
    private func performCrossOverInstall() async -> Bool {
        if backend.isCrossOverInstalled() { return checkCrossOver(reportingFailure: true) }
        return await performStep(.crossOver, "Установка CrossOver") { [backend] progress, log in
            try await backend.installCrossOver(progress: progress, log: log)
        }
    }

    func installCrossOver() { Task { _ = await performCrossOverInstall() } }

    // MARK: Free engine

    static let applePageURL = GPTKInstaller.downloadPage

    private func performEngineInstall() async -> Bool {
        if backend.isEngineInstalled() { set(.engine, .done); return true }
        return await performStep(.engine, "Установка движка Wine") { [backend] progress, log in
            try await backend.installEngine(progress: progress, log: log)
        }
    }

    func installEngine() { Task { _ = await performEngineInstall() } }

    /// Copies D3DMetal out of the toolkit image: `dmg` if given, otherwise the newest one in Downloads.
    /// Without an image the step stops with a hint and waits for the user.
    private func performGPTKInstall(dmg: URL?) async -> Bool {
        if backend.isGPTKReady() { set(.gptk, .done); return true }
        guard let image = dmg ?? backend.detectedGPTKDmg() else {
            let msg = EngineError.gptkNotFound.localizedDescription
            set(.gptk, .failed(msg))
            log("✘ D3DMetal: \(msg)")
            setupFailure = SetupFailure(stage: .gptk, message: msg)
            return false
        }
        return await performStep(.gptk, "Установка D3DMetal") { [backend] _, log in
            try await backend.installGPTK(dmg: image, log: log)
        }
    }

    func installGPTK() { Task { _ = await performGPTKInstall(dmg: nil) } }

    func openApplePage() { NSWorkspace.shared.open(Self.applePageURL) }

    func pickGPTKDmg() {
        let panel = NSOpenPanel()
        panel.title = "Game Porting Toolkit"
        panel.message = "Выберите Game_Porting_Toolkit*.dmg"
        panel.allowedContentTypes = [.diskImage]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { _ = await performGPTKInstall(dmg: url) }
    }

    private func performPrefixCreate() async -> Bool {
        guard backend.isEngineInstalled() else { return await performEngineInstall() }
        return await performStep(.prefix, "Создание префикса") { [backend] _, log in
            try await backend.createPrefix(log: log)
        }
    }

    func createPrefix() { Task { _ = await performPrefixCreate() } }

    /// Size of the main display in points (for the "native 16:10" mode).
    private var displaySize: (width: Int, height: Int)? {
        NSScreen.main.map { (Int($0.frame.width), Int($0.frame.height)) }
    }

    /// Writes the recommended CS2 video settings. Needs a Steam account folder, i.e. a finished first login.
    @discardableResult
    func applyRecommendedGraphics() -> Bool {
        let n = backend.applyRecommendedGraphics(settings: settings, displaySize: displaySize, log: makeLogger())
        if n > 0 {
            settings.recommendedGraphicsApplied = true
            log("Рекомендуемая графика записана (\(settings.nativeAspect ? "родное" : "\(settings.windowWidth)×\(settings.windowHeight)"))")
        } else {
            log("Рекомендуемая графика: аккаунт Steam ещё не найден, повторю при следующем запуске")
        }
        return n > 0
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func performBottleCreate() async -> Bool {
        guard backend.isCrossOverInstalled() else {
            return await performCrossOverInstall()
        }
        return await performStep(.bottle, "Создание бутылки") { [backend] _, log in
            try await backend.createBottle(log: log)
        }
    }

    func createBottle() {
        Task { _ = await performBottleCreate() }
    }

    func migrateLegacy() {
        guard !isBusy else { return }
        Task {
            statusText = "Перенос Steam и CS2…"
            log("▶ Перенос из старой установки")
            do {
                try await backend.migrateLegacy(log: makeLogger())
                log("✔ Перенос завершён")
            } catch {
                log("✘ Перенос: \(error.localizedDescription)")
                set(.steam, .failed(error.localizedDescription))
            }
            statusText = ""
            refresh()
        }
    }

    private func performSteamInstall() async -> Bool {
        await performStep(.steam, "Установка Steam") { [backend] progress, log in
            try await backend.installSteam(progress: progress, log: log)
        }
    }

    func installSteam() {
        Task { _ = await performSteamInstall() }
    }

    private func performStep(_ step: SetupStep, _ name: String,
                             _ work: @escaping @Sendable (@escaping @Sendable (Double) -> Void,
                                                          @escaping @Sendable (String) -> Void) async throws -> Void) async -> Bool {
        guard !status(step).isRunning else { return false }
        set(step, .running(nil))
        log("▶ \(name)")
        let progress: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                guard let self, self.status(step).isRunning else { return }
                self.set(step, .running(p))
            }
        }
        do {
            try await work(progress, makeLogger())
            log("✔ \(name): готово")
            set(step, .done)
            refresh()
            return true
        } catch {
            log("✘ \(name): \(error.localizedDescription)")
            set(step, .failed(error.localizedDescription))
            return false
        }
    }

    // MARK: Running

    func openSteam() { launch(game: false) }
    func play() {
        launch(game: true)
        Task { await refreshMemory() }
    }

    private func launch(game: Bool) {
        guard !isLaunching, !isInstallingAll else { return }
        isLaunching = true
        Task {
            do { try await performLaunch(game: game) }
            catch {
                log("✘ Запуск: \(error.localizedDescription)")
                statusText = "Ошибка: \(error.localizedDescription)"
            }
            isLaunching = false
            refresh()
        }
    }

    /// Starts Steam (optionally with `-applaunch 730`). If Steam is already running, the new steam.exe
    /// forwards the command to the running instance and exits, so a running Steam never blocks this.
    private func performLaunch(game: Bool) async throws {
        let s = settings
        let logger = makeLogger()
        await refreshSteamRunning()
        statusText = game ? "Запуск игры…" : "Запуск Steam…"
        backend.applyPerformanceTweaks(settings: s, steamRunning: isSteamRunning, log: logger)
        if game && engineKind == .free && !settings.recommendedGraphicsApplied { applyRecommendedGraphics() }
        let p = try backend.launch(settings: s, launchGame: game, log: logger)
        if process?.isRunning != true { process = p }
        isSteamRunning = true
        if game {
            gameLaunched = true
            settings.gameLaunchCount += 1
        }
        statusText = game ? "Игра запускается, окно появится через 20–60 с"
                          : "Steam запускается, окно появится через 20–60 с"
        Task { @MainActor [weak self] in
            let code = await p.waitUntilExit()
            guard let self else { return }
            self.log("Процесс завершён, код \(code)")
            if self.process === p { self.process = nil }
            self.statusText = code == 0 ? "" : "Процесс завершился с кодом \(code)"
            await self.refreshSteamRunning()
        }
    }

    /// Kills everything in the bottle (`wineserver -k`).
    func stop() {
        statusText = "Остановка…"
        process?.terminate()
        Task {
            await backend.stopAll()
            process = nil
            isSteamRunning = false
            gameLaunched = false
            isGameRunning = false
            _ = await backend.restoreBackground()
            statusText = ""
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
