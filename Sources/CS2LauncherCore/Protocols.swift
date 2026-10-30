import Foundation

public protocol ProcessRunning: Sendable {
    /// Runs to completion, streaming stdout+stderr lines to onOutput. Returns exit code.
    func run(executable: URL, arguments: [String], environment: [String: String],
             currentDirectory: URL?, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int32
    /// Starts without waiting; returns a handle.
    func start(executable: URL, arguments: [String], environment: [String: String],
               currentDirectory: URL?, onOutput: @escaping @Sendable (String) -> Void) throws -> RunningProcess
}

public protocol RunningProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    func terminate()
    func waitUntilExit() async -> Int32
}

public protocol Downloading: Sendable {
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

// MARK: - Real implementations

final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let emit: @Sendable (String) -> Void
    init(emit: @escaping @Sendable (String) -> Void) { self.emit = emit }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<idx]
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...idx)
        }
        lock.unlock()
        lines.forEach(emit)
    }

    func flush() {
        lock.lock()
        let rest = buffer
        buffer = Data()
        lock.unlock()
        if !rest.isEmpty { emit(String(decoding: rest, as: UTF8.self)) }
    }
}

public final class SystemRunningProcess: RunningProcess, @unchecked Sendable {
    let process: Process
    private let lock = NSLock()
    private var exitCode: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(process: Process) { self.process = process }

    func markExited(_ code: Int32) {
        lock.lock()
        exitCode = code
        let w = waiters
        waiters = []
        lock.unlock()
        w.forEach { $0.resume(returning: code) }
    }

    public var isRunning: Bool { process.isRunning }
    public func terminate() { if process.isRunning { process.terminate() } }

    public func waitUntilExit() async -> Int32 {
        await withCheckedContinuation { cont in
            lock.lock()
            if let code = exitCode {
                lock.unlock()
                cont.resume(returning: code)
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }
}

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    private func makeProcess(executable: URL, arguments: [String], environment: [String: String],
                             currentDirectory: URL?, onOutput: @escaping @Sendable (String) -> Void)
        -> (SystemRunningProcess, LineBuffer, Pipe) {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        p.currentDirectoryURL = currentDirectory
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let handle = SystemRunningProcess(process: p)
        let lb = LineBuffer(emit: onOutput)
        return (handle, lb, pipe)
    }

    public func start(executable: URL, arguments: [String], environment: [String: String],
                      currentDirectory: URL?, onOutput: @escaping @Sendable (String) -> Void) throws -> RunningProcess {
        let (handle, lb, pipe) = makeProcess(executable: executable, arguments: arguments,
            environment: environment, currentDirectory: currentDirectory, onOutput: onOutput)
        let readGroup = DispatchGroup()
        readGroup.enter()
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil
                readGroup.leave()
            } else {
                lb.append(data)
            }
        }
        handle.process.terminationHandler = { proc in
            let code = proc.terminationStatus
            // Wait for pipe EOF (bounded: child processes may hold the pipe open).
            DispatchQueue.global().async {
                _ = readGroup.wait(timeout: .now() + 2)
                pipe.fileHandleForReading.readabilityHandler = nil
                lb.flush()
                handle.markExited(code)
            }
        }
        do {
            try handle.process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        return handle
    }

    public func run(executable: URL, arguments: [String], environment: [String: String],
                    currentDirectory: URL?, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let h = try start(executable: executable, arguments: arguments, environment: environment,
                          currentDirectory: currentDirectory, onOutput: onOutput)
        return await withTaskCancellationHandler {
            await h.waitUntilExit()
        } onCancel: {
            h.terminate()
        }
    }
}

public final class URLSessionDownloader: NSObject, Downloading, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Job {
        var destination: URL
        var progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<Void, Error>
        var moveError: Error?
    }
    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    private var session: URLSession!

    public override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    public func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                jobs[task.taskIdentifier] = Job(destination: destination, progress: progress, continuation: cont)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock(); let job = jobs[downloadTask.taskIdentifier]; lock.unlock()
        job?.progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); let job = jobs[downloadTask.taskIdentifier]; lock.unlock()
        guard let job else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            setMoveError(downloadTask.taskIdentifier, URLError(.badServerResponse))
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: job.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: job.destination.path) { try fm.removeItem(at: job.destination) }
            try fm.moveItem(at: location, to: job.destination)
        } catch {
            setMoveError(downloadTask.taskIdentifier, error)
        }
    }

    private func setMoveError(_ id: Int, _ error: Error) {
        lock.lock(); jobs[id]?.moveError = error; lock.unlock()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let job = jobs.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let job else { return }
        if let error = error ?? job.moveError {
            job.continuation.resume(throwing: error)
        } else {
            job.progress(1)
            job.continuation.resume()
        }
    }
}
