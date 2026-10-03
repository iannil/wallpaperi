import XCTest
@testable import WallpaperCore

final class RecommendationClientTests: XCTestCase {
    private let display = DisplayTarget(id: 1, name: "4K", width: 3840, height: 2160)
    private var settings: Settings {
        var result = Settings(downloadDirectory: "/tmp/Wallpaperi")
        result.keywords = "+forest -city"
        return result
    }
    private var preferences: Preferences {
        var result = Preferences()
        result.like(Favorite(wallpaper: RecommendationProtocol.image("liked", tags: [WallpaperTag(id: 77, name: "forest")]),
                             filePath: "/tmp/liked.jpg", searchKeywords: nil))
        return result
    }
    private func client() -> WallhavenClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecommendationProtocol.self]
        return WallhavenClient(session: URLSession(configuration: config))
    }

    func testPersonalizedSearchEnrichesAndRanksTagMatch() async throws {
        let result = try await client().search(settings: settings, display: display, apiKey: "", excluding: [], preferences: preferences, recommendationDraw: 0)
        XCTAssertEqual(result.id, "forest")
        XCTAssertEqual(result.tags?.first?.id, 77)
    }

    func testExplorationDoesNotFetchDetails() async throws {
        let result = try await client().search(settings: settings, display: display, apiKey: "", excluding: [], preferences: preferences, recommendationDraw: 0.9)
        XCTAssertNil(result.tags)
    }

    func testDisabledPersonalizationDoesNotFetchDetails() async throws {
        var prefs = preferences; prefs.enabled = false
        let result = try await client().search(settings: settings, display: display, apiKey: "", excluding: [], preferences: prefs, recommendationDraw: 0)
        XCTAssertNil(result.tags)
    }

    func testEmptyPreferredQueryFallsBackToOriginalFilters() async throws {
        var config = settings; config.keywords = ""
        let result = try await client().search(settings: config, display: display, apiKey: "", excluding: [], preferences: preferences, recommendationDraw: 0)
        XCTAssertEqual(result.id, "forest")
    }

    func testUnavailableDetailsDoNotPreventSelection() async throws {
        var config = settings; config.keywords = "broken"
        let result = try await client().search(settings: config, display: display, apiKey: "", excluding: [], preferences: preferences, recommendationDraw: 0)
        XCTAssertEqual(result.id, "broken")
    }

    func testChangedPurityInDetailsIsRejected() async throws {
        var config = settings; config.keywords = "changed"
        do {
            _ = try await client().search(settings: config, display: display, apiKey: "", excluding: [], preferences: preferences, recommendationDraw: 0)
            XCTFail("NSFW metadata must be rejected even when search claimed SFW")
        } catch { XCTAssertTrue(error.localizedDescription.contains("没有新的适配壁纸")) }
    }

    func testDetailsValidateIdentifierBeforeRequest() async {
        do {
            _ = try await client().details(id: "../bad", apiKey: "")
            XCTFail("Invalid ID accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("ID 无效")) }
    }
}

private final class RecommendationProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func image(_ id: String, tags: [WallpaperTag]? = nil, purity: String = "sfw") -> Wallpaper {
        Wallpaper(id: id, width: 3840, height: 2160, path: "https://w.wallhaven.cc/full/ab/wallhaven-\(id).jpg",
                  purity: purity, url: "https://wallhaven.cc/w/\(id)", category: "general", tags: tags)
    }
    override func startLoading() {
        let url = request.url!
        var code = 200
        let data: Data
        if url.path == "/api/v1/search" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
            let images: [Wallpaper]
            if query.hasPrefix("id:") { images = [] }
            else if query == "broken" || query == "changed" { images = [Self.image(query)] }
            else { images = [Self.image("city"), Self.image("forest")] }
            let array = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(images))
            data = try! JSONSerialization.data(withJSONObject: ["data": array, "meta": ["current_page": 1, "last_page": 1, "seed": "fixed"]])
        } else {
            let id = url.lastPathComponent
            if id == "broken" { code = 500 }
            let image = Self.image(id, tags: [WallpaperTag(id: id == "forest" ? 77 : 88, name: id)], purity: id == "changed" ? "nsfw" : "sfw")
            let object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(image))
            data = try! JSONSerialization.data(withJSONObject: ["data": object])
        }
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
