import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String

    public init(status: Int32, stdout: Data, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ShellError: Error, Equatable {
    case timedOut(String)
}

/// Seam for running external processes; tests inject a fake.
public protocol ProcessRunning: Sendable {
    func run(_ exe: URL, _ args: [String], env: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult
}

public struct Shell: ProcessRunning {
    public static let shared = Shell()

    public init() {}

    /// Convenience that delegates to the shared instance.
    public static func run(_ exe: URL, _ args: [String], env: [String: String]? = nil,
                           timeout: TimeInterval = 30) async throws -> (status: Int32, stdout: Data, stderr: String) {
        let r = try await shared.run(exe, args, env: env, timeout: timeout)
        return (r.status, r.stdout, r.stderr)
    }

    public func run(_ exe: URL, _ args: [String], env: [String: String]? = nil,
                    timeout: TimeInterval = 30) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        if let env { process.environment = env }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let state = RunState()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
            // Drain both pipes concurrently so a chatty child never blocks on a full buffer.
            let group = DispatchGroup()
            let outBox = DataBox(), errBox = DataBox()
            for (pipe, box) in [(outPipe, outBox), (errPipe, errBox)] {
                group.enter()
                DispatchQueue.global().async {
                    box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
            }
            process.terminationHandler = { p in
                group.notify(queue: .global()) {
                    if state.didTimeOut {
                        cont.resume(throwing: ShellError.timedOut(exe.lastPathComponent))
                    } else {
                        cont.resume(returning: ProcessResult(
                            status: p.terminationStatus, stdout: outBox.data,
                            stderr: String(decoding: errBox.data, as: UTF8.self)))
                    }
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                cont.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    state.didTimeOut = true
                    process.terminate()
                    // Escalate if the child ignores SIGTERM.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
        }
    }
}

private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var _timedOut = false
    var didTimeOut: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _timedOut }
        set { lock.lock(); _timedOut = newValue; lock.unlock() }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
