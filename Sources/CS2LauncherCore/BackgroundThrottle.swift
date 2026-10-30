import Foundation

/// One line of `ps -axo pid=,uid=,comm=`.
public struct ProcessEntry: Equatable, Sendable {
    public let pid: Int32
    public let uid: UInt32
    public let command: String
    public init(pid: Int32, uid: UInt32, command: String) {
        self.pid = pid
        self.uid = uid
        self.command = command
    }
}

/// Pure logic for pushing the user's chat/browser apps to the efficiency cores while the game runs.
public enum BackgroundThrottle {
    /// Application names (matched against the `.app` bundle name in the executable path).
    public static let defaultAllowList: [String] = [
        "Google Chrome", "Discord", "Telegram", "Swiftgram", "Spotify", "Slack", "Microsoft Teams",
        "zoom.us", "Yandex", "Opera", "Firefox", "Arc",
    ]

    /// Paths that are never touched, whatever the allow-list says.
    static let protectedFragments = ["steam", "wine", "crossover", "cs2launcher", "cs2.exe"]
    static let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/Library/Frameworks/"]

    public static func parsePS(_ lines: [String]) -> [ProcessEntry] {
        lines.compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let uid = UInt32(parts[1]) else { return nil }
            return ProcessEntry(pid: pid, uid: uid, command: String(parts[2]).trimmingCharacters(in: .whitespaces))
        }
    }

    /// Names of every `.app` bundle in an executable path, e.g. ["Google Chrome", "Google Chrome Helper"].
    static func appNames(in command: String) -> [String] {
        command.split(separator: "/").compactMap { c in
            c.hasSuffix(".app") ? String(c.dropLast(4)) : nil
        }
    }

    public static func matches(_ entry: ProcessEntry, allowList: [String]) -> Bool {
        let cmd = entry.command
        guard cmd.hasPrefix("/"), !systemPrefixes.contains(where: cmd.hasPrefix) else { return false }
        let lower = cmd.lowercased()
        if protectedFragments.contains(where: lower.contains) { return false }
        let wanted = allowList.map { $0.lowercased() }
        return appNames(in: cmd).contains { name in
            let n = name.lowercased()
            return wanted.contains { n == $0 || n.hasPrefix($0 + " ") }
        }
    }

    /// PIDs that may be demoted: the user's own processes from allowed apps.
    public static func candidates(in entries: [ProcessEntry], uid: UInt32, ownPID: Int32,
                                  allowList: [String] = defaultAllowList) -> Set<Int32> {
        Set(entries.filter { $0.uid == uid && $0.pid != ownPID && $0.pid > 1 && matches($0, allowList: allowList) }
            .map(\.pid))
    }

    /// PIDs not yet demoted.
    public static func toDemote(candidates: Set<Int32>, alreadyDemoted: Set<Int32>) -> Set<Int32> {
        candidates.subtracting(alreadyDemoted)
    }

    /// Demoted PIDs that are still alive and therefore need their priority back.
    public static func toRestore(demoted: Set<Int32>, alive: Set<Int32>) -> Set<Int32> {
        demoted.intersection(alive)
    }
}

final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func add(_ l: String) { lock.lock(); _lines.append(l); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
}

/// Applies `taskpolicy -b` / `-B` and remembers which PIDs it changed.
public final class BackgroundThrottler: @unchecked Sendable {
    static let taskpolicy = URL(fileURLWithPath: "/usr/bin/taskpolicy")
    static let ps = URL(fileURLWithPath: "/bin/ps")

    private let runner: ProcessRunning
    private let allowList: [String]
    private let uid: UInt32
    private let ownPID: Int32
    private let lock = NSLock()
    private var _demoted: Set<Int32> = []

    public var demoted: Set<Int32> { lock.lock(); defer { lock.unlock() }; return _demoted }

    public init(runner: ProcessRunning, allowList: [String] = BackgroundThrottle.defaultAllowList,
                uid: UInt32 = getuid(), ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.runner = runner
        self.allowList = allowList
        self.uid = uid
        self.ownPID = ownPID
    }

    private func markDemoted(_ pid: Int32) { lock.lock(); _demoted.insert(pid); lock.unlock() }
    private func clearDemoted() { lock.lock(); _demoted.removeAll(); lock.unlock() }

    private func listProcesses() async -> [ProcessEntry] {
        let box = OutputBox()
        let code = try? await runner.run(executable: Self.ps, arguments: ["-axo", "pid=,uid=,comm="],
                                         environment: [:], currentDirectory: nil, onOutput: { box.add($0) })
        guard code == 0 else { return [] }
        return BackgroundThrottle.parsePS(box.lines)
    }

    private func setPolicy(_ flag: String, pid: Int32) async -> Bool {
        let code = try? await runner.run(executable: Self.taskpolicy, arguments: [flag, "-p", String(pid)],
                                         environment: [:], currentDirectory: nil, onOutput: { _ in })
        return code == 0
    }

    /// Demotes allowed processes that have not been demoted yet. Returns how many were newly demoted.
    @discardableResult
    public func demoteNew() async -> Int {
        let entries = await listProcesses()
        let found = BackgroundThrottle.candidates(in: entries, uid: uid, ownPID: ownPID, allowList: allowList)
        let fresh = BackgroundThrottle.toDemote(candidates: found, alreadyDemoted: demoted)
        var done = 0
        for pid in fresh.sorted() where await setPolicy("-b", pid: pid) {
            markDemoted(pid)
            done += 1
        }
        return done
    }

    /// Gives still-running demoted processes their normal priority back. Returns how many were restored.
    @discardableResult
    public func restoreAll() async -> Int {
        let mine = demoted
        guard !mine.isEmpty else { return 0 }
        let alive = Set(await listProcesses().map(\.pid))
        var restored = 0
        for pid in BackgroundThrottle.toRestore(demoted: mine, alive: alive).sorted()
        where await setPolicy("-B", pid: pid) { restored += 1 }
        clearDemoted()
        return restored
    }

    /// For app termination: runs `restoreAll` off the calling thread and waits for it (at most 3 s).
    public func restoreAllBlocking() {
        guard !demoted.isEmpty else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached { [self] in
            await restoreAll()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3)
    }
}
