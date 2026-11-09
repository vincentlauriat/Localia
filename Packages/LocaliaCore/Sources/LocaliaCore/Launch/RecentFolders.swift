import Foundation

public protocol RecentFoldersStore: Sendable {
    func load() -> [String]
    func save(_ paths: [String])
}

/// Default store. Task 12 can swap it for SettingsStore.
public struct UserDefaultsRecentFoldersStore: RecentFoldersStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "recentFolders"
    public init(defaults: UserDefaults = UserDefaults(suiteName: "fr.vincentlauriat.localia") ?? .standard) {
        self.defaults = defaults
    }
    public func load() -> [String] { defaults.stringArray(forKey: key) ?? [] }
    public func save(_ paths: [String]) { defaults.set(paths, forKey: key) }
}

public struct RecentFolders: Sendable {
    public static let limit = 8
    private let store: RecentFoldersStore

    public init(store: RecentFoldersStore = UserDefaultsRecentFoldersStore()) { self.store = store }

    /// Most recent first, deduplicated on the standardized path, at most 8.
    public var items: [URL] { store.load().map { URL(fileURLWithPath: $0) } }

    public func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = store.load().filter { $0 != path }
        paths.insert(path, at: 0)
        store.save(Array(paths.prefix(Self.limit)))
    }
}
