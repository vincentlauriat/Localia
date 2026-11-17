import Foundation

/// Read access to the usage database the proxy service writes.
public protocol UsageReading: Sendable {
    func dailyTotals(since: Date) throws -> [DailyTotal]
    func requests(since: Date, limit: Int) throws -> [RequestRecord]
    func content(for id: UUID) throws -> RecordedContent?
}

/// Reads `usage.sqlite` read-only. The store is opened lazily; while the file does not exist
/// (the service has not run yet) every read is empty and the open is retried on the next call.
public final class UsageStoreReader: UsageReading, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var store: UsageStore?

    public init(url: URL) { self.url = url }

    public static func live() -> UsageStoreReader {
        UsageStoreReader(url: Paths.proxy().appendingPathComponent("usage.sqlite"))
    }

    public func dailyTotals(since: Date) throws -> [DailyTotal] {
        try withStore { try $0.dailyTotals(since: since) } ?? []
    }

    public func requests(since: Date, limit: Int) throws -> [RequestRecord] {
        try withStore { try $0.requests(since: since, limit: limit) } ?? []
    }

    public func content(for id: UUID) throws -> RecordedContent? {
        try withStore { try $0.content(for: id) } ?? nil
    }

    /// Runs `body` on the lazily opened store, or returns nil when the file does not exist yet.
    private func withStore<T>(_ body: (UsageStore) throws -> T) throws -> T? {
        lock.lock()
        defer { lock.unlock() }
        if store == nil {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            store = try UsageStore(url: url, readOnly: true)
        }
        return try body(store!)
    }
}
