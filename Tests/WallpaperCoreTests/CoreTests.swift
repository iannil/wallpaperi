import XCTest
@testable import WallpaperCore

final class CoreTests: XCTestCase {
    private let display = DisplayTarget(id: 1, name: "4K", width: 3840, height: 2160)
    private var settings: Settings { Settings(downloadDirectory: "/tmp/Wallpaperi") }
    private func wallpaper(_ id: String = "abc123", width: Int = 3840, height: Int = 2160, purity: String = "sfw", path: String = "https://w.wallhaven.cc/full/ab/wallhaven-abc123.jpg") -> Wallpaper {
        Wallpaper(id: id, width: width, height: height, path: path, purity: purity, url: "https://wallhaven.cc/w/\(id)")
    }

    func testDefaultsAreSFWAndManual() {
        XCTAssertEqual(settings.purity, "100")
        XCTAssertFalse(settings.automatic)
        XCTAssertFalse(settings.notifications)
    }

    func testQueryPreservesKeywordSyntaxAndKeepsKeyOutOfURL() throws {
        var config = settings
        config.keywords = "+forest -city & 雨"
        let url = try SearchQuery.url(settings: config, display: display, apiKey: "secret123", page: 2, seed: "abcdef")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let dictionary = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        XCTAssertEqual(dictionary["q"], config.keywords)
        XCTAssertEqual(dictionary["atleast"], "3840x2160")
        XCTAssertNil(dictionary["apikey"])
        XCTAssertFalse(url.absoluteString.contains("secret123"))
        let request = try SearchQuery.request(settings: config, display: display, apiKey: "secret123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "secret123")
        XCTAssertEqual(dictionary["page"], "2")
        XCTAssertEqual(dictionary["seed"], "abcdef")
        XCTAssertNil(dictionary["apiKey"])
        XCTAssertTrue(url.absoluteString.contains("%2Bforest"))
    }

    func testNSFWRequiresKeyAndMapsPurityBits() throws {
        var config = settings
        config.nsfw = true
        XCTAssertThrowsError(try config.validate(apiKey: ""))
        XCTAssertEqual(config.purity, "101")
        config.sketchy = true
        XCTAssertEqual(config.purity, "111")
        XCTAssertNoThrow(try config.validate(apiKey: "key"))
    }

    func testInvalidSettingsRejected() {
        var config = settings
        config.general = false; config.anime = false; config.people = false
        XCTAssertThrowsError(try config.validate(apiKey: ""))
        config.general = true; config.intervalMinutes = 0
        XCTAssertThrowsError(try config.validate(apiKey: ""))
        config.intervalMinutes = 60; config.downloadDirectory = "relative"
        XCTAssertThrowsError(try config.validate(apiKey: ""))
    }

    func testMatchingRejectsUpscalingAndWrongAspectRatio() {
        XCTAssertTrue(wallpaper().fits(display))
        XCTAssertTrue(wallpaper(width: 7680, height: 4320).fits(display))
        XCTAssertFalse(wallpaper(width: 1920, height: 1080).fits(display))
        XCTAssertFalse(wallpaper(width: 5000, height: 5000).fits(display))
        let portrait = DisplayTarget(id: 2, name: "Portrait", width: 2160, height: 3840)
        XCTAssertTrue(wallpaper(width: 2160, height: 3840).fits(portrait))
        XCTAssertFalse(wallpaper().fits(portrait))
    }

    func testCandidatesRecheckPurityAndExcludeRecentImages() {
        let images = [wallpaper("first"), wallpaper("second"), wallpaper("adult", purity: "nsfw"), wallpaper("unknown", purity: "other")]
        XCTAssertEqual(SearchQuery.candidates(images, display: display, settings: settings, excluding: ["first"]).map(\.id), ["second"])
        var config = settings; config.nsfw = true
        XCTAssertEqual(SearchQuery.candidates(images, display: display, settings: config, excluding: ["first", "second"]).map(\.id), ["adult"])
    }

    func testDownloadAddressValidation() {
        XCTAssertNotNil(wallpaper().downloadURL)
        XCTAssertNil(wallpaper(path: "http://w.wallhaven.cc/full/a.jpg").downloadURL)
        XCTAssertNil(wallpaper(path: "https://evil.example/a.jpg").downloadURL)
        XCTAssertNil(wallpaper(path: "https://w.wallhaven.cc/a.html").downloadURL)
        XCTAssertNil(wallpaper("../bad").downloadURL)
    }

    func testHTTPFailuresAreActionable() {
        XCTAssertNoThrow(try SearchQuery.checkStatus(200))
        XCTAssertThrowsError(try SearchQuery.checkStatus(403))
        XCTAssertThrowsError(try SearchQuery.checkStatus(429)) { error in
            guard case WallpaperError.rateLimited = error else { return XCTFail("Expected rate limit") }
        }
        XCTAssertThrowsError(try SearchQuery.checkStatus(500))
    }

    func testDecodesWallhavenResponseWithAdditionalFields() throws {
        let data = Data(Self.response.utf8)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        XCTAssertEqual(decoded.data.first?.dimension_x, 3840)
        XCTAssertEqual(decoded.meta.seed, "fixed")
    }

    func testSettingsPersistenceContainsNoCredentials() throws {
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data), settings)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).lowercased().contains("apikey"))
    }

    func testClientSearchUsesRealDecodeAndMatchingPipeline() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = WallhavenClient(session: URLSession(configuration: config))
        let result = try await client.search(settings: settings, display: display, apiKey: "", excluding: [])
        XCTAssertEqual(result.id, "abc123")
    }

    func testClientNoMatchProducesError() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = WallhavenClient(session: URLSession(configuration: config))
        do {
            _ = try await client.search(settings: settings, display: display, apiKey: "", excluding: ["abc123"])
            XCTFail("Expected no-match error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("没有新的适配壁纸")) }
    }

    static let response = """
    {"data":[{"id":"abc123","dimension_x":3840,"dimension_y":2160,"path":"https://w.wallhaven.cc/full/ab/wallhaven-abc123.jpg","purity":"sfw","url":"https://wallhaven.cc/w/abc123","views":42}],"meta":{"current_page":1,"last_page":1,"seed":"fixed","total":1}}
    """
}

private final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(CoreTests.response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
