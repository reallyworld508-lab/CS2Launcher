import Foundation

/// The launcher's own Wine: `Engine/wine` (downloaded), `Engine/d3dmetal` (from Apple's GPTK) and `Engine/prefix`.
/// Layout and environment are the runtime contract of docs/engine.md.
public struct FreeEngine: Sendable, SteamLayout {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var wineDirectory: URL { root.appendingPathComponent("wine", isDirectory: true) }
    public var d3dmetalDirectory: URL { root.appendingPathComponent("d3dmetal", isDirectory: true) }
    public var prefix: URL { root.appendingPathComponent("prefix", isDirectory: true) }
    public var driveC: URL { prefix.appendingPathComponent("drive_c", isDirectory: true) }

    public var wineExecutable: URL { wineDirectory.appendingPathComponent("bin/wine") }
    public var wineserver: URL { wineDirectory.appendingPathComponent("bin/wineserver") }
    public var libd3dshared: URL { d3dmetalDirectory.appendingPathComponent("external/libd3dshared.dylib") }
    /// Written once `wineboot` and the registry tweak succeeded.
    public var prefixMarker: URL { prefix.appendingPathComponent(".cs2l-prefix-ready") }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    public var isEngineInstalled: Bool { exists(wineExecutable) && exists(wineserver) }

    public var isD3DMetalValid: Bool {
        exists(d3dmetalDirectory.appendingPathComponent("wine/x86_64-windows/d3d11.dll")) && exists(libd3dshared)
    }

    public var isPrefixReady: Bool { exists(prefixMarker) && exists(prefix.appendingPathComponent("system.reg")) }

    /// Environment for EVERY wine process. Without `WINEDLLPATH` nothing starts; `WINEMSYNC` is left alone.
    public func environment(metalHUD: Bool = false) -> [String: String] {
        let w = wineDirectory.path
        var env = [
            "WINEPREFIX": prefix.path,
            "WINEDLLPATH": ["\(w)/lib/wine/x86_64-windows", "\(w)/lib/wine/i386-windows", "\(w)/lib/wine"]
                .joined(separator: ":"),
            "CX_GRAPHICS_BACKEND": "d3dmetal",
            "CS2L_D3DMETAL_DIR": d3dmetalDirectory.path,
            "CX_APPLEGPTK_LIBD3DSHARED_PATH": libd3dshared.path,
            "ROSETTA_ADVERTISE_AVX": "1",
            "WINEDEBUG": "-all",
        ]
        if metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        return env
    }
}

/// Runs the free engine's `wine` (an x86_64 binary, started under Rosetta) in its prefix.
public struct FreeWineRunner: Sendable, WineRunning {
    /// Steam must not verify or repair its files, or it brings back the original web helper (black login window).
    public static let steamFlagList = ["-noverifyfiles", "-norepairfiles", "-nobootstrapupdate", "-skipinitialbootstrap"]

    public let engine: FreeEngine
    public let runner: ProcessRunning

    public init(engine: FreeEngine, runner: ProcessRunning) {
        self.engine = engine
        self.runner = runner
    }

    public var steamLayout: any SteamLayout { engine }
    /// A fresh Steam holds only its bootstrapper: it must be allowed to download the client (steamui.dll) once.
    public var steamFlags: [String] {
        FileManager.default.fileExists(atPath: engine.steamDirectory.appendingPathComponent("steamui.dll").path)
            ? Self.steamFlagList : []
    }

    private func env(_ extra: [String: String]) -> [String: String] {
        engine.environment().merging(extra) { _, new in new }
    }

    public func run(_ args: [String], extraEnvironment: [String: String] = [:],
                    onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Int32 {
        guard engine.isEngineInstalled else { throw EngineError.engineMissing }
        return try await runner.run(executable: engine.wineExecutable, arguments: args,
                                    environment: env(extraEnvironment), currentDirectory: nil, onOutput: onOutput)
    }

    public func start(_ args: [String], extraEnvironment: [String: String] = [:],
                      onOutput: @escaping @Sendable (String) -> Void = { _ in }) throws -> RunningProcess {
        guard engine.isEngineInstalled else { throw EngineError.engineMissing }
        return try runner.start(executable: engine.wineExecutable, arguments: args,
                                environment: env(extraEnvironment), currentDirectory: nil, onOutput: onOutput)
    }

    public func killAll() async {
        _ = try? await runner.run(executable: engine.wineserver, arguments: ["-k"],
                                  environment: env([:]), currentDirectory: nil, onOutput: { _ in })
    }
}

public enum EngineError: LocalizedError, Equatable {
    case engineMissing
    case gptkNotFound
    case mountFailed(String)
    case gptkContentMissing
    case gptkInvalid
    case commandFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .engineMissing: return "Движок Wine не установлен."
        case .gptkNotFound:
            return "Не найден Game_Porting_Toolkit*.dmg. Скачайте его на странице Apple (нужен вход с Apple ID) или выберите файл вручную."
        case .mountFailed(let n): return "Не удалось открыть образ «\(n)»."
        case .gptkContentMissing: return "В образе нет папки redist/lib. Это не Game Porting Toolkit?"
        case .gptkInvalid: return "После копирования в D3DMetal нет d3d11.dll или libd3dshared.dylib."
        case .commandFailed(let c, let code): return "Команда завершилась с ошибкой (\(code)): \(c)"
        }
    }
}

/// Takes D3DMetal out of Apple's Game Porting Toolkit disk image, which the user downloads themselves.
public struct GPTKInstaller: Sendable {
    public static let downloadPage = URL(string: "https://developer.apple.com/download/all/?q=game%20porting%20toolkit")!
    static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    static let innerPrefix = "Evaluation environment for Windows games"

    let runner: ProcessRunning
    let engine: FreeEngine
    let searchDirectory: URL
    let scratch: URL

    public init(runner: ProcessRunning, engine: FreeEngine,
                searchDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads", isDirectory: true),
                scratch: URL = FileManager.default.temporaryDirectory) {
        self.runner = runner
        self.engine = engine
        self.searchDirectory = searchDirectory
        self.scratch = scratch
    }

    /// Newest `Game_Porting_Toolkit*.dmg` in `directory`.
    public static func findDmg(in directory: URL) -> URL? {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let dmgs = names.filter { $0.hasPrefix("Game_Porting_Toolkit") && $0.lowercased().hasSuffix(".dmg") }
        func date(_ n: String) -> Date {
            (try? fm.attributesOfItem(atPath: directory.appendingPathComponent(n).path)[.modificationDate] as? Date)
                ?? .distantPast
        }
        return dmgs.max { date($0) < date($1) }.map { directory.appendingPathComponent($0) }
    }

    public var detectedDmg: URL? { Self.findDmg(in: searchDirectory) }

    func attach(_ dmg: URL, at mountpoint: URL, log: @escaping @Sendable (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: mountpoint, withIntermediateDirectories: true)
        let code = try await runner.run(
            executable: Self.hdiutil,
            arguments: ["attach", "-readonly", "-nobrowse", "-noverify", "-mountpoint", mountpoint.path, dmg.path],
            environment: [:], currentDirectory: nil, onOutput: log)
        guard code == 0 else { throw EngineError.mountFailed(dmg.lastPathComponent) }
    }

    func detach(_ mountpoint: URL) async {
        _ = try? await runner.run(executable: Self.hdiutil, arguments: ["detach", "-force", mountpoint.path],
                                  environment: [:], currentDirectory: nil, onOutput: { _ in })
        try? FileManager.default.removeItem(at: mountpoint)
    }

    /// Copies `redist/lib` of the toolkit into `Engine/d3dmetal`. Both images are detached on every path.
    public func install(dmg chosen: URL? = nil, log: @escaping @Sendable (String) -> Void) async throws {
        guard let dmg = chosen ?? detectedDmg else { throw EngineError.gptkNotFound }
        let fm = FileManager.default
        let work = scratch.appendingPathComponent("cs2l-gptk-\(UUID().uuidString)", isDirectory: true)
        let outer = work.appendingPathComponent("outer", isDirectory: true)
        let inner = work.appendingPathComponent("inner", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        var mounted: [URL] = []
        defer { try? fm.removeItem(at: work) }
        do {
            log("Открываю \(dmg.lastPathComponent)…")
            try await attach(dmg, at: outer, log: log)
            mounted.append(outer)
            var source = outer
            if !fm.fileExists(atPath: outer.appendingPathComponent("redist/lib").path) {
                let names = (try? fm.contentsOfDirectory(atPath: outer.path)) ?? []
                guard let evalName = names.sorted().first(where: {
                    $0.hasPrefix(Self.innerPrefix) && $0.lowercased().hasSuffix(".dmg")
                }) else { throw EngineError.gptkContentMissing }
                try await attach(outer.appendingPathComponent(evalName), at: inner, log: log)
                mounted.append(inner)
                source = inner
            }
            let lib = source.appendingPathComponent("redist/lib", isDirectory: true)
            guard fm.fileExists(atPath: lib.path) else { throw EngineError.gptkContentMissing }
            log("Копирование D3DMetal в движок…")
            try fm.createDirectory(at: engine.root, withIntermediateDirectories: true)
            let staging = engine.root.appendingPathComponent("d3dmetal.new", isDirectory: true)
            try? fm.removeItem(at: staging)
            let code = try await runner.run(executable: Self.ditto, arguments: [lib.path, staging.path],
                                            environment: [:], currentDirectory: nil, onOutput: log)
            guard code == 0 else { try? fm.removeItem(at: staging); throw EngineError.commandFailed("ditto", code) }
            try? fm.removeItem(at: engine.d3dmetalDirectory)
            try fm.moveItem(at: staging, to: engine.d3dmetalDirectory)
        } catch {
            for m in mounted.reversed() { await detach(m) }
            throw error
        }
        for m in mounted.reversed() { await detach(m) }
        guard engine.isD3DMetalValid else { throw EngineError.gptkInvalid }
        log("D3DMetal установлен.")
    }
}

/// Creates the Wine prefix of the free engine.
public struct FreePrefixManager: Sendable {
    /// DLLs that only exist in GPTK; Wine loads a GPTK-only builtin when the prefix holds a placeholder for it.
    static let placeholderDLLs = ["nvapi64.dll", "atidxx64.dll", "nvngx.dll"]

    let engine: FreeEngine
    let runner: ProcessRunning

    public init(engine: FreeEngine, runner: ProcessRunning) {
        self.engine = engine
        self.runner = runner
    }

    /// Arguments of the registry tweak that keeps winebus from crashing in SDL.
    public static let disableSDLArguments = ["reg", "add", "HKLM\\System\\CurrentControlSet\\Services\\winebus",
                                             "/v", "Enable SDL", "/t", "REG_DWORD", "/d", "0", "/f"]

    public func create(log: @escaping @Sendable (String) -> Void) async throws {
        guard engine.isEngineInstalled else { throw EngineError.engineMissing }
        let wine = FreeWineRunner(engine: engine, runner: runner)
        try FileManager.default.createDirectory(at: engine.prefix, withIntermediateDirectories: true)
        log("Создание префикса Wine (до минуты)…")
        var code = try await wine.run(["wineboot", "--init"], onOutput: log)
        guard code == 0 else { throw EngineError.commandFailed("wineboot --init", code) }
        code = try await wine.run(Self.disableSDLArguments, onOutput: log)
        guard code == 0 else { throw EngineError.commandFailed("reg add", code) }
        copyPlaceholders(log: log)
        _ = try? await runner.run(executable: engine.wineserver, arguments: ["-w"],
                                  environment: engine.environment(), currentDirectory: nil, onOutput: { _ in })
        try Data().write(to: engine.prefixMarker)
        log("Префикс готов.")
    }

    func copyPlaceholders(log: @escaping @Sendable (String) -> Void) {
        let fm = FileManager.default
        let system32 = engine.driveC.appendingPathComponent("windows/system32", isDirectory: true)
        let gptk = engine.d3dmetalDirectory.appendingPathComponent("wine/x86_64-windows", isDirectory: true)
        try? fm.createDirectory(at: system32, withIntermediateDirectories: true)
        for name in Self.placeholderDLLs {
            let src = gptk.appendingPathComponent(name), dst = system32.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            do { try fm.copyItem(at: src, to: dst) } catch { log("Не удалось скопировать \(name): \(error.localizedDescription)") }
        }
    }
}

/// Replaces Steam's `steamwebhelper.exe` with a tiny wrapper that starts the renamed original
/// (`steamwebhelper_real.exe`) with `--disable-gpu --single-process`, which fixes the black login window under Wine.
public struct SteamWebHelperPatch: Sendable {
    /// Valve's helper is tens of MB; the wrapper is a few KB.
    public static let originalMinimumSize = 1_048_576
    static let targetName = "steamwebhelper.exe"
    static let realName = "steamwebhelper_real.exe"

    public let steamDirectory: URL
    let wrapperData: Data

    public init(steamDirectory: URL, wrapperData: Data) {
        self.steamDirectory = steamDirectory
        self.wrapperData = wrapperData
    }

    public static func bundledWrapper() throws -> Data {
        guard let url = Bundle.module.url(forResource: "steamwebhelper-wrapper", withExtension: "exe") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    /// `bin/cef/cef.win*` folders that contain a steamwebhelper.exe.
    func cefDirectories() -> [URL] {
        let cef = steamDirectory.appendingPathComponent("bin/cef", isDirectory: true)
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: cef.path)) ?? [])
            .filter { $0.hasPrefix("cef.win") }.sorted()
        return items.map { cef.appendingPathComponent($0, isDirectory: true) }.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(Self.targetName).path)
        }
    }

    private func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }

    private func isOriginal(_ url: URL) -> Bool { size(url) > Self.originalMinimumSize }

    /// Every helper folder holds the wrapper next to a `_real` original.
    public var isApplied: Bool {
        let dirs = cefDirectories()
        return !dirs.isEmpty && dirs.allSatisfy {
            let target = $0.appendingPathComponent(Self.targetName)
            return !isOriginal(target) && FileManager.default.fileExists(atPath: $0.appendingPathComponent(Self.realName).path)
                && (try? Data(contentsOf: target)) == wrapperData
        }
    }

    /// Returns the folders that were changed. The original is only ever renamed, never deleted, unless Steam
    /// brought back a newer original next to an old `_real`.
    @discardableResult
    public func apply() throws -> [URL] {
        let fm = FileManager.default
        var changed: [URL] = []
        for dir in cefDirectories() {
            let target = dir.appendingPathComponent(Self.targetName)
            let real = dir.appendingPathComponent(Self.realName)
            if isOriginal(target) {
                if fm.fileExists(atPath: real.path) { try fm.removeItem(at: real) }
                try fm.moveItem(at: target, to: real)
                do { try wrapperData.write(to: target, options: .atomic) }
                catch { try? fm.moveItem(at: real, to: target); throw error }
                changed.append(dir)
            } else if fm.fileExists(atPath: real.path), (try? Data(contentsOf: target)) != wrapperData {
                try wrapperData.write(to: target, options: .atomic)
                changed.append(dir)
            }
        }
        return changed
    }
}

/// Writes the recommended CS2 video settings (`userdata/<accountid>/730/local/cfg/cs2_video.txt`).
public enum VideoConfig {
    public static let relativePath = "730/local/cfg/cs2_video.txt"
    static let defaultRoot = "video.cfg"

    /// `setting.*` values; 4:3 uses aspect mode 0, 16:10 mode 2.
    public static func settings(width: Int, height: Int, nativeAspect: Bool) -> [(String, String)] {
        [("setting.defaultres", String(width)),
         ("setting.defaultresheight", String(height)),
         ("setting.aspectratiomode", nativeAspect ? "2" : "0"),
         ("setting.mat_vsync", "1"),
         ("setting.msaa_samples", "0"),
         ("setting.r_csgo_cmaa_enable", "1"),
         ("setting.videocfg_ao_detail", "0"),
         ("setting.videocfg_shadow_quality", "1"),
         ("setting.videocfg_texture_detail", "1"),
         ("setting.videocfg_particle_detail", "1"),
         ("setting.videocfg_fsr_detail", "4"),
         ("setting.r_texturefilteringquality", "1"),
         ("setting.cpu_level", "2"),
         ("setting.gpu_level", "2"),
         ("setting.gpu_mem_level", "2")]
    }

    /// Numeric account folders of `userdata`.
    static func accountDirectories(_ userdata: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: userdata.path)) ?? [])
            .filter { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }.sorted()
            .map { userdata.appendingPathComponent($0, isDirectory: true) }
    }

    /// Returns `text` (nil: no file yet) with the recommended values set; nil when the file cannot be parsed.
    public static func updating(_ text: String?, width: Int, height: Int, nativeAspect: Bool) -> String? {
        var doc: KVDocument
        var root = defaultRoot
        if let text {
            guard let parsed = KVDocument.parse(text) else { return nil }
            doc = parsed
            if case .object(let key, _)? = doc.items.first(where: { if case .object = $0 { true } else { false } }) {
                root = key
            }
        } else {
            doc = KVDocument()
            doc.setString("1", at: [root, "Version"])
        }
        for (k, v) in settings(width: width, height: height, nativeAspect: nativeAspect) {
            guard doc.setString(v, at: [root, k]) else { return nil }
        }
        return doc.serialize()
    }

    /// Writes the values for every Steam account. Returns the files that were written (none while nobody logged in).
    @discardableResult
    public static func apply(userdata: URL, width: Int, height: Int, nativeAspect: Bool,
                             log: (String) -> Void = { _ in }) -> [URL] {
        let fm = FileManager.default
        var written: [URL] = []
        for account in accountDirectories(userdata) {
            let file = account.appendingPathComponent(relativePath)
            let current = try? String(contentsOf: file, encoding: .utf8)
            guard let updated = updating(current, width: width, height: height, nativeAspect: nativeAspect) else {
                log("cs2_video.txt не разобран, не трогаю")
                continue
            }
            do {
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                if updated != current { try updated.write(to: file, atomically: true, encoding: .utf8) }
                written.append(file)
            } catch {
                log("cs2_video.txt: \(error.localizedDescription)")
            }
        }
        return written
    }
}
