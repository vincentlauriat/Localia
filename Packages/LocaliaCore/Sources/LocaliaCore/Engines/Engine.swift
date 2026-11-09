import Foundation

public enum EngineID: String, Sendable, Codable, CaseIterable {
    case ollama, llamaCpp
}

public enum InstallState: Sendable, Equatable {
    case notInstalled
    case installed(String, managedByLocalia: Bool)
}

public struct InstalledModel: Sendable, Equatable {
    public let name: String
    public let sizeGB: Double
    public init(name: String, sizeGB: Double) { self.name = name; self.sizeGB = sizeGB }
}

public struct LoadedModel: Sendable, Equatable {
    public let name: String
    public let memoryGB: Double
    public init(name: String, memoryGB: Double) { self.name = name; self.memoryGB = memoryGB }
}

public enum EngineError: Error, Equatable {
    /// The server answered with an `{"error": ...}` line or body.
    case server(String)
    case http(Int)
    case notInstalled
    case serverDidNotStart
    case assetNotFound(String)
    case checksumNotFound(String)
}

public protocol Engine: Sendable {
    var id: EngineID { get }
    /// Server root; the Anthropic-compatible `/v1/messages` lives under it.
    var baseURL: URL { get }
    func installState() async -> InstallState
    func install(progress: @escaping @Sendable (Double) -> Void) async throws
    /// Only removes an install that Localia manages.
    func uninstall() async throws
    func isServing() async -> Bool
    /// No-op if a server already answers (the user's own server is reused).
    func startServing() async throws
    /// Only stops a server that Localia itself started.
    func stopServing() async throws
    func installedModels() async throws -> [InstalledModel]
    func loadedModels() async throws -> [LoadedModel]
    /// Downloads the model and returns the name to serve it under.
    func pull(_ c: ModelCandidate, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> String
    func delete(_ modelName: String) async throws
    /// Preloads the model so the first answer is warm.
    func load(_ modelName: String, contextTokens: Int) async throws
    func unload(_ modelName: String) async throws
}

/// Handle to a long-running server process that Localia started.
public protocol ServerHandle: Sendable {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    func terminate()
}

/// Seam for spawning a long-lived server; `Shell.run` waits for exit so it cannot be used for this.
public protocol ServerLauncher: Sendable {
    func launch(executable: URL, arguments: [String], environment: [String: String]) throws -> any ServerHandle
}

public struct ProcessServerLauncher: ServerLauncher {
    private let logFile: URL?
    public init(logFile: URL? = nil) { self.logFile = logFile }

    public func launch(executable: URL, arguments: [String], environment: [String: String]) throws -> any ServerHandle {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        var opened: FileHandle?
        if let logFile {
            let fm = FileManager.default
            try? fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: logFile.path) { fm.createFile(atPath: logFile.path, contents: nil) }
            // Append deliberately: keep earlier runs' output.
            if let h = try? FileHandle(forWritingTo: logFile) { _ = try? h.seekToEnd(); opened = h }
        }
        let log = opened
        process.standardOutput = log ?? FileHandle.nullDevice
        process.standardError = log ?? FileHandle.nullDevice
        process.terminationHandler = { _ in try? log?.close() }
        do { try process.run() } catch { try? log?.close(); throw error }
        return ProcessHandle(process)
    }
}

/// Seam over pid lookups so the own-server record can be tested without real processes.
public protocol ProcessInspecting: Sendable {
    func isAlive(_ pid: Int32) -> Bool
    func executablePath(_ pid: Int32) -> String?
    func signal(_ pid: Int32, _ sig: Int32)
}

public struct SystemProcessInspector: ProcessInspecting {
    public init() {}
    public func isAlive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }
    public func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    public func signal(_ pid: Int32, _ sig: Int32) { if pid > 0 { _ = kill(pid, sig) } }
}

private final class ProcessHandle: ServerHandle, @unchecked Sendable {
    private let process: Process
    init(_ p: Process) { process = p }
    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }
}
