import Foundation

/// A lossless, order-preserving model of a Valve KeyValues text file (e.g. `localconfig.vdf`).
///
/// Unlike `KeyValues.parse` (a lowercasing, lookup-only reader), this keeps key case, duplicates, ordering and
/// `//` comment lines, so `parse` → `serialize` reproduces a file written in Valve's own style byte for byte:
/// tab indentation, `"key"\t\t"value"` pairs and `{ }` blocks on their own lines.
/// Input it cannot reproduce faithfully (unquoted tokens, raw control characters or unknown escapes inside
/// strings, unbalanced braces) is rejected by returning nil, so callers never rewrite a file they do not understand.
public struct KVDocument: Equatable, Sendable {
    public indirect enum Item: Equatable, Sendable {
        case comment(String)                       // text after `//`
        case string(key: String, value: String)
        case object(key: String, items: [Item])
    }

    public var items: [Item]
    var lineEnding = "\n"
    var hasBOM = false

    public init(items: [Item] = []) { self.items = items }

    // MARK: Lookup / mutation (keys are matched case-insensitively, first match wins)

    public func string(at path: [String]) -> String? {
        Self.lookup(items, path[...])
    }

    private static func lookup(_ items: [Item], _ path: ArraySlice<String>) -> String? {
        guard let head = path.first else { return nil }
        let rest = path.dropFirst()
        for item in items {
            switch item {
            case .string(let k, let v) where rest.isEmpty && k.caseInsensitiveCompare(head) == .orderedSame:
                return v
            case .object(let k, let sub) where !rest.isEmpty && k.caseInsensitiveCompare(head) == .orderedSame:
                return lookup(sub, rest)
            default: continue
            }
        }
        return nil
    }

    /// Sets the string at `path`, creating missing nested blocks. Returns false (and changes nothing) when a
    /// path component exists with the wrong kind (a string where a block is needed or vice versa).
    @discardableResult
    public mutating func setString(_ value: String, at path: [String]) -> Bool {
        guard !path.isEmpty else { return false }
        var copy = items
        guard Self.set(&copy, path[...], value) else { return false }
        items = copy
        return true
    }

    private static func set(_ items: inout [Item], _ path: ArraySlice<String>, _ value: String) -> Bool {
        let head = path.first!
        let rest = path.dropFirst()
        let match = items.firstIndex {
            switch $0 {
            case .string(let k, _), .object(let k, _): return k.caseInsensitiveCompare(head) == .orderedSame
            case .comment: return false
            }
        }
        if rest.isEmpty {
            if let i = match {
                guard case .string(let k, _) = items[i] else { return false }
                items[i] = .string(key: k, value: value)
            } else {
                items.append(.string(key: head, value: value))
            }
            return true
        }
        if let i = match {
            guard case .object(let k, var sub) = items[i] else { return false }
            guard set(&sub, rest, value) else { return false }
            items[i] = .object(key: k, items: sub)
        } else {
            var sub: [Item] = []
            _ = set(&sub, rest, value)
            items.append(.object(key: head, items: sub))
        }
        return true
    }

    // MARK: Parsing

    public static func parse(_ text: String) -> KVDocument? {
        var scalars = Array(text.unicodeScalars)
        var doc = KVDocument()
        if scalars.first == "\u{FEFF}" { doc.hasBOM = true; scalars.removeFirst() }
        if text.contains("\r\n") { doc.lineEnding = "\r\n" }
        var p = Parser(scalars)
        guard let items = p.parseItems(topLevel: true) else { return nil }
        doc.items = items
        return doc
    }

    private enum Token: Equatable { case string(String), comment(String), open, close }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        var failed = false
        init(_ s: [Unicode.Scalar]) { self.s = s }

        mutating func next() -> Token? {
            while i < s.count, s[i].properties.isWhitespace { i += 1 }
            guard i < s.count else { return nil }
            let c = s[i]
            if c == "{" { i += 1; return .open }
            if c == "}" { i += 1; return .close }
            if c == "/" {
                guard i + 1 < s.count, s[i + 1] == "/" else { failed = true; return nil }
                i += 2
                var out = String.UnicodeScalarView()
                while i < s.count, s[i] != "\n" { out.append(s[i]); i += 1 }
                var text = String(out)
                if text.hasSuffix("\r") { text.removeLast() }
                return .comment(text)
            }
            guard c == "\"" else { failed = true; return nil }   // unquoted tokens are not supported
            i += 1
            var out = String.UnicodeScalarView()
            while i < s.count {
                let ch = s[i]
                if ch == "\"" { i += 1; return .string(String(out)) }
                if ch.value < 0x20 { failed = true; return nil }
                if ch == "\\" {
                    guard i + 1 < s.count else { failed = true; return nil }
                    i += 1
                    switch s[i] {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\\": out.append("\\")
                    case "\"": out.append("\"")
                    default: failed = true; return nil
                    }
                    i += 1
                    continue
                }
                out.append(ch); i += 1
            }
            failed = true   // unterminated string
            return nil
        }

        mutating func parseItems(topLevel: Bool) -> [Item]? {
            var items: [Item] = []
            while true {
                guard let tok = next() else {
                    return (topLevel && !failed) ? items : nil
                }
                switch tok {
                case .comment(let t): items.append(.comment(t))
                case .close: return topLevel ? nil : items
                case .open: return nil
                case .string(let key):
                    var v = next()
                    while case .comment? = v { v = next() }   // comments between key and value are dropped
                    switch v {
                    case .string(let val)?: items.append(.string(key: key, value: val))
                    case .open?:
                        guard let sub = parseItems(topLevel: false) else { return nil }
                        items.append(.object(key: key, items: sub))
                    default: return nil
                    }
                }
            }
        }
    }

    // MARK: Serialising

    public func serialize() -> String {
        var out = hasBOM ? "\u{FEFF}" : ""
        Self.write(items, depth: 0, eol: lineEnding, into: &out)
        return out
    }

    private static func quote(_ s: String) -> String {
        var r = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\t": r += "\\t"
            default: r.unicodeScalars.append(ch)
            }
        }
        return r + "\""
    }

    private static func write(_ items: [Item], depth: Int, eol: String, into out: inout String) {
        let indent = String(repeating: "\t", count: depth)
        for item in items {
            switch item {
            case .comment(let t): out += "\(indent)//\(t)\(eol)"
            case .string(let k, let v): out += "\(indent)\(quote(k))\t\t\(quote(v))\(eol)"
            case .object(let k, let sub):
                out += "\(indent)\(quote(k))\(eol)\(indent){\(eol)"
                write(sub, depth: depth + 1, eol: eol, into: &out)
                out += "\(indent)}\(eol)"
            }
        }
    }
}
