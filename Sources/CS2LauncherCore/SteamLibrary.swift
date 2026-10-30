import Foundation

// MARK: - Valve KeyValues (text) reader

/// A value in a Valve KeyValues (VDF/ACF) document: a string or a nested object.
public indirect enum KVValue: Equatable, Sendable {
    case string(String)
    case object([String: KVValue])   // keys are lowercased (Valve keys are case-insensitive)

    public subscript(key: String) -> KVValue? {
        if case .object(let d) = self { return d[key.lowercased()] }
        return nil
    }
    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
}

/// Small, forgiving reader for Valve KeyValues text. Returns nil for structurally broken input
/// (unterminated string, unbalanced braces, key without value).
public enum KeyValues {
    public static func parse(_ text: String) -> KVValue? {
        var p = Parser(Array(text.unicodeScalars))
        guard let root = p.parseObject(topLevel: true) else { return nil }
        return .object(root)
    }

    private enum Token: Equatable { case string(String), open, close }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }

        mutating func skipTrivia() {
            while i < s.count {
                let c = s[i]
                if c.properties.isWhitespace || c == "\u{FEFF}" { i += 1 }
                else if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                    while i < s.count, s[i] != "\n" { i += 1 }
                } else { break }
            }
        }

        /// nil = end of input, throws-as-nil handled via `failed`.
        var failed = false

        mutating func next() -> Token? {
            skipTrivia()
            guard i < s.count else { return nil }
            let c = s[i]
            if c == "{" { i += 1; return .open }
            if c == "}" { i += 1; return .close }
            if c == "\"" {
                i += 1
                var out = String.UnicodeScalarView()
                while i < s.count {
                    let ch = s[i]
                    if ch == "\"" { i += 1; return .string(String(out)) }
                    if ch == "\\", i + 1 < s.count {
                        i += 1
                        switch s[i] {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        case "\\": out.append("\\")
                        case "\"": out.append("\"")
                        default: out.append("\\"); out.append(s[i])
                        }
                        i += 1
                        continue
                    }
                    out.append(ch); i += 1
                }
                failed = true   // unterminated string
                return nil
            }
            // Unquoted token
            var out = String.UnicodeScalarView()
            while i < s.count {
                let ch = s[i]
                if ch.properties.isWhitespace || ch == "{" || ch == "}" || ch == "\"" { break }
                out.append(ch); i += 1
            }
            return .string(String(out))
        }

        mutating func parseObject(topLevel: Bool) -> [String: KVValue]? {
            var dict: [String: KVValue] = [:]
            while true {
                guard let tok = next() else {
                    return (topLevel && !failed) ? dict : nil
                }
                switch tok {
                case .close:
                    return topLevel ? nil : dict
                case .open:
                    return nil
                case .string(let key):
                    guard let v = next() else { return nil }
                    switch v {
                    case .string(let val): dict[key.lowercased()] = .string(val)
                    case .open:
                        guard let sub = parseObject(topLevel: false) else { return nil }
                        dict[key.lowercased()] = .object(sub)
                    case .close: return nil
                    }
                }
            }
        }
    }
}

// MARK: - CS2 install state

public enum CS2InstallState: Equatable, Sendable {
    case notInstalled
    case downloading(progress: Double)
    case installed

    public var isInstalled: Bool { self == .installed }
}

public struct CS2Manifest: Equatable, Sendable {
    public var stateFlags: Int
    public var bytesDownloaded: Int64
    public var bytesToDownload: Int64
    public var sizeOnDisk: Int64

    public init(stateFlags: Int, bytesDownloaded: Int64 = 0, bytesToDownload: Int64 = 0, sizeOnDisk: Int64 = 0) {
        self.stateFlags = stateFlags
        self.bytesDownloaded = bytesDownloaded
        self.bytesToDownload = bytesToDownload
        self.sizeOnDisk = sizeOnDisk
    }

    /// Parses `appmanifest_730.acf` text. nil when malformed or when `StateFlags` is missing.
    public static func parse(_ text: String) -> CS2Manifest? {
        guard let root = KeyValues.parse(text),
              let state = root["AppState"],
              let flags = state["StateFlags"]?.stringValue.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) })
        else { return nil }
        func num(_ k: String) -> Int64 {
            state[k]?.stringValue.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        }
        return CS2Manifest(stateFlags: flags, bytesDownloaded: num("BytesDownloaded"),
                           bytesToDownload: num("BytesToDownload"), sizeOnDisk: num("SizeOnDisk"))
    }

    public static let fullyInstalledFlag = 4
    public var isFullyInstalled: Bool { stateFlags == Self.fullyInstalledFlag }

    /// 0...1; zero total yields 0.
    public var progress: Double {
        guard bytesToDownload > 0 else { return 0 }
        return max(0, min(1, Double(bytesDownloaded) / Double(bytesToDownload)))
    }
}

public struct SteamLibrary: Sendable {
    public static let cs2AppID = 730
    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    public var steamapps: URL {
        paths.prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps", isDirectory: true)
    }
    public var manifestURL: URL { steamapps.appendingPathComponent("appmanifest_\(Self.cs2AppID).acf") }
    public var cs2Executable: URL {
        steamapps.appendingPathComponent("common/Counter-Strike Global Offensive/game/bin/win64/cs2.exe")
    }

    public func cs2Manifest() -> CS2Manifest? {
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else { return nil }
        return CS2Manifest.parse(text)
    }

    public func cs2State() -> CS2InstallState {
        Self.state(manifest: cs2Manifest(),
                   executableExists: FileManager.default.fileExists(atPath: cs2Executable.path))
    }

    /// No (or unreadable/malformed) manifest -> notInstalled.
    public static func state(manifest: CS2Manifest?, executableExists: Bool) -> CS2InstallState {
        guard let m = manifest else { return .notInstalled }
        if m.isFullyInstalled && executableExists { return .installed }
        return .downloading(progress: m.progress)
    }
}
