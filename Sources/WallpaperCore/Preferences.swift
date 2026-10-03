import Foundation

public struct WallpaperTag: Codable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let purity: String?
    public init(id: Int, name: String, purity: String? = nil) {
        self.id = id; self.name = name; self.purity = purity
    }
    public func allowed(by settings: Settings) -> Bool {
        purity == nil || purity == "sfw" || (purity == "sketchy" && settings.sketchy) || (purity == "nsfw" && settings.nsfw)
    }
}

public struct Favorite: Codable, Identifiable, Equatable {
    public var id: String { wallpaper.id }
    public let wallpaper: Wallpaper
    public let filePath: String
    public let searchKeywords: String?
    public let likedAt: Date

    public init(wallpaper: Wallpaper, filePath: String, searchKeywords: String?, likedAt: Date = Date()) {
        self.wallpaper = wallpaper; self.filePath = filePath
        self.searchKeywords = searchKeywords; self.likedAt = likedAt
    }

    public func enriched(with wallpaper: Wallpaper) -> Favorite {
        Favorite(wallpaper: wallpaper, filePath: filePath, searchKeywords: searchKeywords, likedAt: likedAt)
    }
}

/// The profile is rebuilt from these unique likes, so removing a like fully removes its contribution.
public struct Preferences: Codable, Equatable {
    public var enabled = true
    public private(set) var favorites: [Favorite] = []
    public init() {}

    public mutating func like(_ favorite: Favorite) {
        guard !favorites.contains(where: { $0.id == favorite.id }) else { return }
        favorites.insert(favorite, at: 0)
    }
    public mutating func unlike(_ id: String) { favorites.removeAll { $0.id == id } }
    public mutating func enrich(_ wallpaper: Wallpaper) {
        guard let index = favorites.firstIndex(where: { $0.id == wallpaper.id }) else { return }
        favorites[index] = favorites[index].enriched(with: wallpaper)
    }
}

public struct PreferenceSignal: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let count: Int
}

public struct PreferenceProfile {
    public private(set) var tags: [Int: Int] = [:]
    public private(set) var tagNames: [Int: String] = [:]
    public private(set) var keywords: [String: Int] = [:]
    public private(set) var categories: [String: Int] = [:]
    public var isEmpty: Bool { tags.isEmpty && keywords.isEmpty && categories.isEmpty }

    public init(favorites: [Favorite], settings: Settings) {
        var seen = Set<String>()
        for favorite in favorites where seen.insert(favorite.id).inserted {
            let wallpaper = favorite.wallpaper
            guard wallpaper.allowed(by: settings), wallpaper.categoryAllowed(by: settings) else { continue }
            var tagIDs = Set<Int>()
            for tag in wallpaper.tags ?? [] where tag.allowed(by: settings) && tagIDs.insert(tag.id).inserted {
                tags[tag.id, default: 0] += 1
                tagNames[tag.id] = tag.name
            }
            for word in Self.positiveKeywords(favorite.searchKeywords ?? "") {
                keywords[word, default: 0] += 1
            }
            if let category = wallpaper.category { categories[category, default: 0] += 1 }
        }
    }

    /// Learn only positive words. Exclusions, usernames, exact-tag and other query operators are not interests.
    public static func positiveKeywords(_ query: String) -> Set<String> {
        let pattern = #"[+-]?"[^"]*"|\S+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = query as NSString
        var words = Set<String>()
        for match in regex.matches(in: query, range: NSRange(location: 0, length: text.length)) {
            var token = text.substring(with: match.range).lowercased()
            guard !token.hasPrefix("-"), !token.hasPrefix("@"), !token.contains(":") else { continue }
            if token.hasPrefix("+") { token.removeFirst() }
            token = token.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !token.isEmpty, token.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) }) else { continue }
            words.insert(token)
        }
        return words
    }

    public var topTags: [PreferenceSignal] {
        tags.map { PreferenceSignal(id: String($0.key), name: tagNames[$0.key] ?? String($0.key), count: $0.value) }
            .sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
    }
    public var topKeywords: [PreferenceSignal] { signals(keywords) }
    public var topCategories: [PreferenceSignal] { signals(categories) }
    private func signals(_ dictionary: [String: Int]) -> [PreferenceSignal] {
        dictionary.map { PreferenceSignal(id: $0.key, name: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
    }

    /// Each component is normalized to 0...1; tags (6) outweigh keyword (3) and category (1) matches.
    public func score(_ wallpaper: Wallpaper) -> Double {
        let ids = Set((wallpaper.tags ?? []).map(\.id))
        let tagScore = Double(ids.map { tags[$0] ?? 0 }.max() ?? 0) / Double(max(1, tags.values.max() ?? 0))
        let names = (wallpaper.tags ?? []).map { $0.name.lowercased() }
        let keywordScore = Double(keywords.map { item in
            names.contains(where: { name in
                name == item.key || Self.positiveKeywords(name).contains(item.key)
            }) ? item.value : 0
        }.max() ?? 0) / Double(max(1, keywords.values.max() ?? 0))
        let categoryScore = Double(categories[wallpaper.category ?? ""] ?? 0) / Double(max(1, categories.values.reduce(0, +)))
        return 6 * tagScore + 3 * keywordScore + categoryScore
    }

    public static func shouldPersonalize(enabled: Bool, profile: PreferenceProfile, draw: Double) -> Bool {
        enabled && !profile.isEmpty && draw < 0.8
    }

    /// Bias retrieval only when the user has not specified a query. Explicit search syntax stays untouched.
    public func retrievalSettings(from settings: Settings, draw: Double) -> Settings {
        guard settings.keywords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return settings }
        var result = settings
        let options: [(String, Int)] = tags.sorted { $0.key < $1.key }.map { ("id:\($0.key)", $0.value * 6) }
            + keywords.sorted { $0.key < $1.key }.map { ($0.key, $0.value * 3) }
        if let query = weighted(options, draw: draw) { result.keywords = query }
        else if let category = weighted(categories.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, draw: draw) {
            result.general = settings.general && category == "general"
            result.anime = settings.anime && category == "anime"
            result.people = settings.people && category == "people"
        }
        return result
    }

    private func weighted(_ items: [(String, Int)], draw: Double) -> String? {
        let total = items.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        var cursor = min(max(draw, 0), 0.999999999) * Double(total)
        for (value, weight) in items {
            cursor -= Double(weight)
            if cursor < 0 { return value }
        }
        return items.last?.0
    }
}
