import Foundation

/// 本地存储位置，对应桌面端的 `%APPDATA%\local.ph.desktop`。
enum Storage {

    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("PornhubMobile", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static var settingsURL: URL {
        rootDirectory.appendingPathComponent("settings.json")
    }

    static var mediaDirectory: URL {
        let dir = rootDirectory.appendingPathComponent("media-cache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL) else { return AppSettings() }
        guard let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return decoded.normalized()
    }

    static func saveSettings(_ settings: AppSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }
}

/// 观看历史与续播进度。对应桌面端存在 localStorage 里的两份数据。
enum HistoryStore {

    private static let historyKey = "ph.history.v1"
    private static let positionKey = "ph.pos."
    private static let limit = 120

    private static var defaults: UserDefaults { UserDefaults.standard }

    static func all() -> [HistoryEntry] {
        guard let data = defaults.data(forKey: historyKey) else { return [] }
        guard let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [HistoryEntry]) {
        let trimmed = Array(list.prefix(limit))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        defaults.set(data, forKey: historyKey)
    }

    static func push(_ entry: HistoryEntry) {
        guard !entry.vkey.isEmpty else { return }
        var list = all().filter { $0.vkey != entry.vkey }
        var value = entry
        value.at = Date().timeIntervalSince1970
        list.insert(value, at: 0)
        save(list)
    }

    static func updateProgress(vkey: String, position: Double, duration: Double) {
        guard !vkey.isEmpty, duration.isFinite, duration > 0 else { return }
        let payload: [String: Double] = [
            "t": position,
            "d": duration,
            "at": Date().timeIntervalSince1970
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            defaults.set(data, forKey: positionKey + vkey)
        }
        var list = all()
        if let index = list.firstIndex(where: { $0.vkey == vkey }) {
            list[index].position = position
            list[index].durationSec = duration
            list[index].at = Date().timeIntervalSince1970
            save(list)
        }
    }

    /// 返回上次播放位置（秒），小于 10 秒视为没有进度。
    static func progress(for vkey: String) -> Double? {
        guard let data = defaults.data(forKey: positionKey + vkey) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let object = json as? [String: Any] else { return nil }
        guard let value = object["t"] as? Double, value > 10 else { return nil }
        return value
    }

    static func removeProgress(for vkey: String) {
        defaults.removeObject(forKey: positionKey + vkey)
    }

    static func clear() {
        for entry in all() {
            defaults.removeObject(forKey: positionKey + entry.vkey)
        }
        defaults.removeObject(forKey: historyKey)
    }
}
