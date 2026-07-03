import Foundation

/// Tiny JSON file cache so screens can paint the last-known data instantly on
/// launch while fresh data loads in the background (the Stocks-app pattern —
/// stale prices beat a spinner). Lives in Caches/, so the OS may purge it;
/// losing it only costs one slower first paint.
enum DiskCache {
    private static var dir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DataCache", isDirectory: true)
    }

    private static func fileURL(_ name: String) -> URL {
        dir.appendingPathComponent("\(name).json")
    }

    static func save<T: Encodable>(_ value: T, as name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL(name), options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: fileURL(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Wipe everything (on sign-out, so the next account never sees this one's data).
    static func clear() {
        try? FileManager.default.removeItem(at: dir)
    }
}
