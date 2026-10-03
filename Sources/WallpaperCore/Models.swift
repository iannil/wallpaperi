import Foundation

public struct Settings: Codable, Equatable {
    public var keywords = ""
    public var general = true
    public var anime = true
    public var people = true
    public var sketchy = false
    public var nsfw = false
    public var allDisplays = true
    public var automatic = false
    public var intervalMinutes = 60
    public var notifications = false
    public var downloadDirectory: String

    public init(downloadDirectory: String) { self.downloadDirectory = downloadDirectory }
    public var categories: String { [general, anime, people].map { $0 ? "1" : "0" }.joined() }
    public var purity: String { "1" + (sketchy ? "1" : "0") + (nsfw ? "1" : "0") }

    public func validate(apiKey: String) throws {
        guard general || anime || people else { throw WallpaperError.message("请至少选择一个壁纸分类。") }
        guard !nsfw || !apiKey.isEmpty else {
            throw WallpaperError.message("开启 NSFW 前，请先在通用设置中保存 API Key。")
        }
        guard (5...1440).contains(intervalMinutes) else { throw WallpaperError.message("轮换间隔应在 5 至 1440 分钟之间。") }
        guard downloadDirectory.hasPrefix("/") else { throw WallpaperError.message("请选择有效的绝对保存路径。") }
    }
}

public struct DisplayTarget: Identifiable, Equatable {
    public let id: UInt32
    public let name: String
    public let width: Int
    public let height: Int
    public init(id: UInt32, name: String, width: Int, height: Int) {
        self.id = id; self.name = name; self.width = width; self.height = height
    }
    public var resolution: String { "\(width) × \(height)" }
}

public struct Wallpaper: Codable, Identifiable, Equatable {
    public let id: String
    public let dimension_x: Int
    public let dimension_y: Int
    public let path: String
    public let purity: String
    public let url: String
    public let category: String?
    public let tags: [WallpaperTag]?
    public var resolution: String { "\(dimension_x) × \(dimension_y)" }

    public init(id: String, width: Int, height: Int, path: String, purity: String, url: String, category: String? = nil, tags: [WallpaperTag]? = nil) {
        self.id = id; dimension_x = width; dimension_y = height
        self.path = path; self.purity = purity; self.url = url
        self.category = category; self.tags = tags
    }

    public func fits(_ display: DisplayTarget) -> Bool {
        guard display.width > 0, display.height > 0,
              dimension_x >= display.width, dimension_y >= display.height else { return false }
        let targetRatio = Double(display.width) / Double(display.height)
        let imageRatio = Double(dimension_x) / Double(dimension_y)
        return abs(imageRatio / targetRatio - 1) <= 0.06
    }

    public func allowed(by settings: Settings) -> Bool {
        purity == "sfw" || (purity == "sketchy" && settings.sketchy) || (purity == "nsfw" && settings.nsfw)
    }

    public func categoryAllowed(by settings: Settings) -> Bool {
        switch category {
        case "general": return settings.general
        case "anime": return settings.anime
        case "people": return settings.people
        case nil: return true // History from 1.0 did not store categories.
        default: return false
        }
    }

    public var downloadURL: URL? {
        guard let result = URL(string: path), result.scheme == "https", result.host == "w.wallhaven.cc",
              result.user == nil, result.password == nil, result.port == nil,
              ["jpg", "jpeg", "png"].contains(result.pathExtension.lowercased()),
              !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return result
    }
}

public struct SearchResponse: Decodable {
    public let data: [Wallpaper]
    public let meta: Meta
    public struct Meta: Decodable {
        public let current_page: Int
        public let last_page: Int
        public let seed: String?
    }
}

public struct HistoryEntry: Codable, Identifiable {
    public let id: UUID
    public let wallpaper: Wallpaper
    public let filePath: String
    public let displayName: String
    public let appliedAt: Date
    public let searchKeywords: String?
    public init(wallpaper: Wallpaper, filePath: String, displayName: String, searchKeywords: String? = nil) {
        id = UUID(); self.wallpaper = wallpaper; self.filePath = filePath
        self.displayName = displayName; appliedAt = Date()
        self.searchKeywords = searchKeywords
    }
}

public enum WallpaperError: LocalizedError {
    case message(String)
    case rateLimited
    public var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .rateLimited: return "Wallhaven 请求频率受限，请至少一分钟后重试。"
        }
    }
}

public enum SearchQuery {
    public static func url(settings: Settings, display: DisplayTarget, apiKey: String, page: Int = 1, seed: String? = nil) throws -> URL {
        try settings.validate(apiKey: apiKey)
        var parts = URLComponents(string: "https://wallhaven.cc/api/v1/search")!
        var items = [
            URLQueryItem(name: "q", value: settings.keywords),
            URLQueryItem(name: "categories", value: settings.categories),
            URLQueryItem(name: "purity", value: settings.purity),
            URLQueryItem(name: "atleast", value: "\(display.width)x\(display.height)"),
            URLQueryItem(name: "sorting", value: "random"),
            URLQueryItem(name: "page", value: String(page))
        ]
        if let seed { items.append(URLQueryItem(name: "seed", value: seed)) }
        parts.queryItems = items
        // Wallhaven uses form-style query parsing: a literal + must be escaped.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }

    public static func request(settings: Settings, display: DisplayTarget, apiKey: String, page: Int = 1, seed: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: try url(settings: settings, display: display, apiKey: apiKey, page: page, seed: seed), timeoutInterval: 30)
        request.setValue("Wallpaperi/1.0", forHTTPHeaderField: "User-Agent")
        if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "X-API-Key") }
        return request
    }

    public static func candidates(_ wallpapers: [Wallpaper], display: DisplayTarget, settings: Settings, excluding: Set<String>) -> [Wallpaper] {
        wallpapers.filter { $0.fits(display) && $0.allowed(by: settings) && $0.categoryAllowed(by: settings) && $0.downloadURL != nil && !excluding.contains($0.id) }
    }

    public static func checkStatus(_ code: Int) throws {
        switch code {
        case 200...299: return
        case 401, 403: throw WallpaperError.message("Wallhaven 拒绝访问，请检查 API Key、账户内容权限或网络访问限制。")
        case 429: throw WallpaperError.rateLimited
        default: throw WallpaperError.message("Wallhaven 服务返回 HTTP \(code)，请稍后重试。")
        }
    }
}
