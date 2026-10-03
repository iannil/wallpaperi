import Foundation

/// All state updates replace one JSON file atomically. Legacy files remain untouched.
public struct LibraryStore {
    public let directory: URL
    public init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wallpaperi", isDirectory: true)) {
        self.directory = directory
    }
    private var archiveURL: URL { directory.appendingPathComponent("library.json") }
    private func key(_ name: String) -> String { (name as NSString).deletingPathExtension }

    public func read<T: Decodable>(_ name: String, as type: T.Type) throws -> T? {
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            let fields = try readArchive()
            guard let object = fields[key(name)] else { return nil }
            return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]))
        }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    public func save<T: Encodable>(_ value: T, name: String) throws {
        var fields = try readArchive()
        fields[key(name)] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
        try writeArchive(fields)
    }

    private func readArchive() throws -> [String: Any] {
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            guard let dictionary = try JSONSerialization.jsonObject(with: Data(contentsOf: archiveURL)) as? [String: Any] else {
                throw WallpaperError.message("资料库格式无效。请先从备份恢复 library.json，避免覆盖原数据。")
            }
            return dictionary
        }
        var fields: [String: Any] = [:]
        for name in ["settings", "history", "preferences", "folder-access"] {
            let file = directory.appendingPathComponent(name + ".json")
            if FileManager.default.fileExists(atPath: file.path) {
                fields[name] = try JSONSerialization.jsonObject(with: Data(contentsOf: file), options: [.fragmentsAllowed])
            }
        }
        return fields
    }

    private func writeArchive(_ fields: [String: Any]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: archiveURL, options: .atomic)
    }

    /// Caller must hold a user-selected directory's security scope during the import.
    /// Only known data files are decoded. No credential or bookmark is imported.
    public func importLibrary(from source: URL, fallbackSettings: Settings) throws -> ImportSummary {
        guard source.standardizedFileURL != directory.standardizedFileURL else {
            throw WallpaperError.message("请选择旧版资料目录，不要选择当前资料目录。")
        }
        let incoming = LibraryStore(directory: source)
        let importedSettings = try incoming.read("settings.json", as: Settings.self)
        let importedHistory = try incoming.read("history.json", as: [HistoryEntry].self)
        let importedPreferences = try incoming.read("preferences.json", as: Preferences.self)
        guard importedSettings != nil || importedHistory != nil || importedPreferences != nil else {
            throw WallpaperError.message("所选目录中没有可导入的 Wallpaperi 设置、历史或点赞记录。")
        }
        var settings = importedSettings ?? fallbackSettings
        settings.automatic = false
        guard settings.downloadDirectory.hasPrefix("/"), (5...1440).contains(settings.intervalMinutes),
              settings.general || settings.anime || settings.people else {
            throw WallpaperError.message("旧版设置无效；未修改当前数据。")
        }
        let currentHistory = try read("history.json", as: [HistoryEntry].self) ?? []
        var seen = Set<UUID>()
        let history = (currentHistory + (importedHistory ?? []))
            .sorted { $0.appliedAt > $1.appliedAt }.filter { seen.insert($0.id).inserted }
        var preferences = try read("preferences.json", as: Preferences.self) ?? Preferences()
        // Prefer current metadata for existing likes. Import new likes in their original order.
        for favorite in (importedPreferences?.favorites ?? []).reversed() { preferences.like(favorite) }
        if let importedPreferences { preferences.enabled = importedPreferences.enabled }
        var fields = try readArchive()
        let encoder = JSONEncoder()
        fields["settings"] = try JSONSerialization.jsonObject(with: encoder.encode(settings))
        fields["history"] = try JSONSerialization.jsonObject(with: encoder.encode(Array(history.prefix(300))))
        fields["preferences"] = try JSONSerialization.jsonObject(with: encoder.encode(preferences))
        // This backup is completed before the atomic commit, and is never overwritten.
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            let backup = directory.appendingPathComponent("library-before-import-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: archiveURL, to: backup)
        }
        try writeArchive(fields)
        return ImportSummary(historyCount: min(history.count, 300), favoriteCount: preferences.favorites.count)
    }
}

public struct ImportSummary {
    public let historyCount: Int
    public let favoriteCount: Int
}
