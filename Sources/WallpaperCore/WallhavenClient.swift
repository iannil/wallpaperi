import Foundation

public actor WallhavenClient {
    private let session: URLSession
    private var nextRequest = Date.distantPast
    public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    private func throttle() async throws {
        // Re-check after every suspension: likes and rotation share this actor and its 429 cooldown.
        while nextRequest > Date() {
            let delay = max(0, nextRequest.timeIntervalSinceNow)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        try Task.checkCancellation()
        nextRequest = Date().addingTimeInterval(1.5)
    }

    private var detailCache: [String: Wallpaper] = [:]

    private func fetch<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        try await throttle()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw WallpaperError.message("服务器响应无效。") }
        if http.statusCode == 429 { nextRequest = Date().addingTimeInterval(60) }
        try SearchQuery.checkStatus(http.statusCode)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw WallpaperError.message("Wallhaven 返回的数据格式无法读取。") }
    }

    public func details(id: String, apiKey: String) async throws -> Wallpaper {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw WallpaperError.message("壁纸 ID 无效。")
        }
        if let cached = detailCache[id] { return cached }
        var request = URLRequest(url: URL(string: "https://wallhaven.cc/api/v1/w/\(id)")!, timeoutInterval: 30)
        request.setValue("Wallpaperi/1.1", forHTTPHeaderField: "User-Agent")
        if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "X-API-Key") }
        let response = try await fetch(request, as: DetailResponse.self)
        guard response.data.id == id else { throw WallpaperError.message("壁纸详情与请求的图片不一致。") }
        if detailCache.count >= 300 { detailCache.removeAll() }
        detailCache[id] = response.data
        return response.data
    }

    public func search(settings: Settings, display: DisplayTarget, apiKey: String, excluding: Set<String>,
                       preferences: Preferences = Preferences(), recommendationDraw: Double = Double.random(in: 0..<1)) async throws -> Wallpaper {
        let profile = PreferenceProfile(favorites: preferences.favorites, settings: settings)
        let personalized = PreferenceProfile.shouldPersonalize(enabled: preferences.enabled, profile: profile, draw: recommendationDraw)
        let preferred = personalized ? profile.retrievalSettings(from: settings, draw: Double.random(in: 0..<1)) : settings
        // The preference query gets one page; if it is too narrow, use the user's original filters.
        let searches: [(Settings, Int)] = preferred != settings ? [(preferred, 1), (settings, 3)] : [(settings, 3)]
        for (querySettings, pages) in searches {
            var seed: String?
            for page in 1...pages {
                let request = try SearchQuery.request(settings: querySettings, display: display, apiKey: apiKey, page: page, seed: seed)
                let result = try await fetch(request, as: SearchResponse.self)
                let candidates = SearchQuery.candidates(result.data, display: display, settings: settings, excluding: excluding)
                if !candidates.isEmpty {
                    if !personalized { return candidates.randomElement()! }
                    // Wallhaven search omits tags. Bound detail requests to six candidates per batch.
                    var enriched: [Wallpaper] = []
                    for candidate in candidates.shuffled().prefix(6) {
                        try Task.checkCancellation()
                        var wallpaper = candidate
                        do { wallpaper = try await details(id: candidate.id, apiKey: apiKey) }
                        catch is CancellationError { throw CancellationError() }
                        catch let error as URLError where error.code == .cancelled { throw error }
                        catch WallpaperError.rateLimited {
                            // Keep already gathered metadata; defer further requests until the cooldown expires.
                            enriched.append(candidate)
                            break
                        }
                        catch { /* Category-only ranking remains available if metadata cannot be fetched. */ }
                        if !SearchQuery.candidates([wallpaper], display: display, settings: settings, excluding: excluding).isEmpty {
                            enriched.append(wallpaper)
                        }
                    }
                    let ranked = enriched.shuffled().sorted { profile.score($0) > profile.score($1) }
                    if let first = ranked.first { return first }
                }
                seed = result.meta.seed
                if page >= result.meta.last_page { break }
            }
        }
        throw WallpaperError.message("\(display.name)：没有新的适配壁纸（\(display.resolution)）。请放宽关键词或分类筛选。")
    }

    private struct DetailResponse: Decodable { let data: Wallpaper }

    public func download(_ wallpaper: Wallpaper, directory: URL) async throws -> URL {
        guard let remote = wallpaper.downloadURL else { throw WallpaperError.message("图片下载地址无效。") }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("wallhaven-\(wallpaper.id).\(remote.pathExtension.lowercased())")
        if manager.fileExists(atPath: destination.path) { return destination }
        let (temporary, response) = try await session.download(for: URLRequest(url: remote, timeoutInterval: 90))
        defer { try? manager.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == "https", http.url?.host == "w.wallhaven.cc" else {
            throw WallpaperError.message("下载服务器响应无效。")
        }
        try SearchQuery.checkStatus(http.statusCode)
        guard ["image/jpeg", "image/png"].contains(http.mimeType ?? "") else {
            throw WallpaperError.message("下载内容不是受支持的图片。")
        }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 100 * 1024 * 1024 else { throw WallpaperError.message("图片为空或超过 100 MB 限制。") }
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).download")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: temporary, to: staging)
        try Task.checkCancellation()
        try manager.moveItem(at: staging, to: destination)
        return destination
    }
}
