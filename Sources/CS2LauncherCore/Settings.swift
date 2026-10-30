import Foundation

public struct Settings: Codable, Equatable, Sendable {
    public var gameArgs: String = "-novid"
    public var steamArgs: String = ""
    public var metalHUD: Bool = false
    public var fpsCap: Int? = nil
    public var performanceMode: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case gameArgs, steamArgs, metalHUD, fpsCap, performanceMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()   // keys from older versions (retinaMode, msync, advertiseAVX) are ignored
        gameArgs = (try? c.decodeIfPresent(String.self, forKey: .gameArgs)) ?? d.gameArgs
        steamArgs = (try? c.decodeIfPresent(String.self, forKey: .steamArgs)) ?? d.steamArgs
        if steamArgs == "-cef-disable-gpu-compositing" { steamArgs = "" }  // obsolete old default
        metalHUD = (try? c.decodeIfPresent(Bool.self, forKey: .metalHUD)) ?? d.metalHUD
        fpsCap = (try? c.decodeIfPresent(Int.self, forKey: .fpsCap)) ?? d.fpsCap
        performanceMode = (try? c.decodeIfPresent(Bool.self, forKey: .performanceMode)) ?? d.performanceMode
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
