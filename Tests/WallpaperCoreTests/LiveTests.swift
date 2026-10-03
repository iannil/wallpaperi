import XCTest
import ImageIO
@testable import WallpaperCore

final class LiveTests: XCTestCase {
    func testPublicSearchAndImageDownload() async throws {
        guard ProcessInfo.processInfo.environment["WALLPAPERI_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set WALLPAPERI_LIVE_TEST=1 to test the public Wallhaven service.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaperi-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var settings = Settings(downloadDirectory: folder.path)
        settings.keywords = "nature"
        settings.anime = false; settings.people = false
        let display = DisplayTarget(id: 1, name: "Integration test", width: 1920, height: 1080)
        let client = WallhavenClient()
        let wallpaper = try await client.search(settings: settings, display: display, apiKey: "", excluding: [])
        XCTAssertTrue(wallpaper.fits(display))
        XCTAssertEqual(wallpaper.purity, "sfw")
        let file = try await client.download(wallpaper, directory: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertGreaterThanOrEqual(props[kCGImagePropertyPixelWidth] as? Int ?? 0, display.width)
        XCTAssertGreaterThanOrEqual(props[kCGImagePropertyPixelHeight] as? Int ?? 0, display.height)
        let cached = try await client.download(wallpaper, directory: folder)
        XCTAssertEqual(cached, file)
        let details = try await client.details(id: wallpaper.id, apiKey: "")
        XCTAssertEqual(details.id, wallpaper.id)
        XCTAssertNotNil(details.tags)
        XCTAssertNotNil(details.category)
        var preferences = Preferences()
        preferences.like(Favorite(wallpaper: details, filePath: file.path, searchKeywords: settings.keywords))
        let recommendation = try await client.search(settings: settings, display: display, apiKey: "", excluding: [wallpaper.id],
                                                     preferences: preferences, recommendationDraw: 0)
        XCTAssertTrue(recommendation.fits(display))
        XCTAssertEqual(recommendation.purity, "sfw")
        XCTAssertNotEqual(recommendation.id, wallpaper.id)
    }
}
