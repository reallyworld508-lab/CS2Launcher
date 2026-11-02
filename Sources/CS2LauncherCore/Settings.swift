import Foundation

/// Which Wine runs the game: the launcher's own free engine, or an installed CrossOver.
public enum EngineKind: String, Codable, CaseIterable, Sendable {
    case free, crossover
}

public struct Settings: Codable, Equatable, Sendable {
    public static let defaultGameArgs = "-novid -windowed -noborder -w 1024 -h 768"

    public var gameArgs: String = Settings.defaultGameArgs
    public var steamArgs: String = ""
    public var metalHUD: Bool = false
    public var fpsCap: Int? = nil
    public var performanceMode: Bool = true
    public var throttleBackgroundApps: Bool = true
    public var engine: EngineKind = .free
    /// Window size handed to the game; the 4:3 image is stretched over the whole window by D3DMetal.
    public var windowWidth: Int = 1024
    public var windowHeight: Int = 768
    /// "Native 16:10": no `-w/-h`, the video config uses the display's size.
    public var nativeAspect: Bool = false
    /// The recommended `cs2_video.txt` values were written once (or the user asked for them).
    public var recommendedGraphicsApplied: Bool = false
    /// How many times the game was started from the launcher (drives the shader-cache hint).
    public var gameLaunchCount: Int = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case gameArgs, steamArgs, engine, windowWidth, windowHeight, nativeAspect, recommendedGraphicsApplied, metalHUD, fpsCap, performanceMode, throttleBackgroundApps, gameLaunchCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()   // keys from older versions (retinaMode, msync, advertiseAVX) are ignored
        gameArgs = (try? c.decodeIfPresent(String.self, forKey: .gameArgs)) ?? d.gameArgs
        if gameArgs == "-novid" { gameArgs = d.gameArgs }  // old default
        engine = (try? c.decodeIfPresent(EngineKind.self, forKey: .engine)) ?? d.engine
        windowWidth = max(320, (try? c.decodeIfPresent(Int.self, forKey: .windowWidth)) ?? d.windowWidth)
        windowHeight = max(240, (try? c.decodeIfPresent(Int.self, forKey: .windowHeight)) ?? d.windowHeight)
        nativeAspect = (try? c.decodeIfPresent(Bool.self, forKey: .nativeAspect)) ?? d.nativeAspect
        recommendedGraphicsApplied = (try? c.decodeIfPresent(Bool.self, forKey: .recommendedGraphicsApplied)) ?? d.recommendedGraphicsApplied
        steamArgs = (try? c.decodeIfPresent(String.self, forKey: .steamArgs)) ?? d.steamArgs
        if steamArgs == "-cef-disable-gpu-compositing" { steamArgs = "" }  // obsolete old default
        metalHUD = (try? c.decodeIfPresent(Bool.self, forKey: .metalHUD)) ?? d.metalHUD
        fpsCap = (try? c.decodeIfPresent(Int.self, forKey: .fpsCap)) ?? d.fpsCap
        performanceMode = (try? c.decodeIfPresent(Bool.self, forKey: .performanceMode)) ?? d.performanceMode
        throttleBackgroundApps = (try? c.decodeIfPresent(Bool.self, forKey: .throttleBackgroundApps)) ?? d.throttleBackgroundApps
        gameLaunchCount = max(0, (try? c.decodeIfPresent(Int.self, forKey: .gameLaunchCount)) ?? d.gameLaunchCount)
    }

    public static func load(from url: URL) -> Settings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
