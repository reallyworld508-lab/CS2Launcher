import Foundation

public struct Settings: Codable, Equatable, Sendable {
    public var gameArgs: String = "-novid"
    public var steamArgs: String = "-cef-disable-gpu-compositing"
    public var metalHUD: Bool = false
    public var retinaMode: Bool = false
    public var msync: Bool = true
    public var advertiseAVX: Bool = true
    public var fpsCap: Int? = nil

    public init() {}

    enum CodingKeys: String, CodingKey {
        case gameArgs, steamArgs, metalHUD, retinaMode, msync, advertiseAVX, fpsCap
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        gameArgs = (try? c.decodeIfPresent(String.self, forKey: .gameArgs)) ?? d.gameArgs
        steamArgs = (try? c.decodeIfPresent(String.self, forKey: .steamArgs)) ?? d.steamArgs
        metalHUD = (try? c.decodeIfPresent(Bool.self, forKey: .metalHUD)) ?? d.metalHUD
        retinaMode = (try? c.decodeIfPresent(Bool.self, forKey: .retinaMode)) ?? d.retinaMode
        msync = (try? c.decodeIfPresent(Bool.self, forKey: .msync)) ?? d.msync
        advertiseAVX = (try? c.decodeIfPresent(Bool.self, forKey: .advertiseAVX)) ?? d.advertiseAVX
        fpsCap = (try? c.decodeIfPresent(Int.self, forKey: .fpsCap)) ?? d.fpsCap
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
