import XCTest
@testable import WallpaperCore

final class PreferenceTests: XCTestCase {
    private var settings: Settings { Settings(downloadDirectory: "/tmp/Wallpaperi") }
    private let forest = WallpaperTag(id: 77, name: "forest", purity: "sfw")
    private let city = WallpaperTag(id: 88, name: "city", purity: "sfw")
    private func wallpaper(_ id: String = "liked", category: String? = "general", tags: [WallpaperTag]? = nil, purity: String = "sfw") -> Wallpaper {
        Wallpaper(id: id, width: 3840, height: 2160, path: "https://w.wallhaven.cc/full/ab/wallhaven-\(id).jpg", purity: purity, url: "https://wallhaven.cc/w/\(id)", category: category, tags: tags)
    }
    private func favorite(_ wallpaper: Wallpaper, query: String? = nil) -> Favorite {
        Favorite(wallpaper: wallpaper, filePath: "/tmp/image.jpg", searchKeywords: query)
    }

    func testLikeIsUniqueAndUnlikeRemovesAllSignals() {
        var preferences = Preferences()
        let liked = favorite(wallpaper(tags: [forest]), query: "+nature -city")
        preferences.like(liked); preferences.like(liked)
        XCTAssertEqual(preferences.favorites.count, 1)
        var profile = PreferenceProfile(favorites: preferences.favorites, settings: settings)
        XCTAssertEqual(profile.tags[77], 1)
        XCTAssertEqual(profile.keywords["nature"], 1)
        preferences.unlike("liked")
        profile = PreferenceProfile(favorites: preferences.favorites, settings: settings)
        XCTAssertTrue(profile.isEmpty)
        preferences.enrich(wallpaper(tags: [forest]))
        XCTAssertTrue(preferences.favorites.isEmpty, "Late network responses must not resurrect an unliked image")
    }

    func testLikesPersistWithTheirOriginalSearchContextAndDate() throws {
        var preferences = Preferences()
        preferences.like(favorite(wallpaper(tags: [forest]), query: "+forest -city"))
        preferences.enabled = false
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored, preferences)
        XCTAssertEqual(restored.favorites.first?.searchKeywords, "+forest -city")
        XCTAssertFalse(restored.enabled)
    }

    func testEnrichmentKeepsOriginalLikeDateAndKeywords() {
        var preferences = Preferences()
        let original = favorite(wallpaper(tags: nil), query: "nature")
        preferences.like(original)
        preferences.enrich(wallpaper(tags: [forest]))
        XCTAssertEqual(preferences.favorites[0].likedAt, original.likedAt)
        XCTAssertEqual(preferences.favorites[0].searchKeywords, "nature")
        XCTAssertEqual(preferences.favorites[0].wallpaper.tags, [forest])
    }

    func testOldHistoryAndSettingsRemainReadable() throws {
        let legacy = #"{"id":"11111111-1111-1111-1111-111111111111","wallpaper":{"id":"abc123","dimension_x":3840,"dimension_y":2160,"path":"https://w.wallhaven.cc/full/ab/wallhaven-abc123.jpg","purity":"sfw","url":"https://wallhaven.cc/w/abc123"},"filePath":"/tmp/a.jpg","displayName":"Display","appliedAt":123}"#
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: Data(legacy.utf8))
        XCTAssertNil(entry.searchKeywords)
        XCTAssertNil(entry.wallpaper.category)
        XCTAssertNil(entry.wallpaper.tags)
        let oldSettings = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: oldSettings), settings)
    }

    func testPositiveKeywordsSkipExclusionsAndAdvancedOperators() {
        XCTAssertEqual(PreferenceProfile.positiveKeywords(#"+Forest forest -city -"dark sky" +"blue sky" @artist id:123 type:png like:abc & 雨"#), ["forest", "blue sky", "雨"])
    }

    func testTagsOutweighKeywordsAndCategories() {
        let profile = PreferenceProfile(favorites: [favorite(wallpaper(tags: [forest]), query: "city")], settings: settings)
        let tagMatch = wallpaper("tag", category: "anime", tags: [forest])
        let keywordMatch = wallpaper("keyword", tags: [city])
        let categoryMatch = wallpaper("category", tags: [])
        XCTAssertGreaterThan(profile.score(tagMatch), profile.score(keywordMatch))
        XCTAssertGreaterThan(profile.score(keywordMatch), profile.score(categoryMatch))
        XCTAssertEqual(profile.score(tagMatch), 6)
        XCTAssertEqual(profile.score(keywordMatch), 4)
    }

    func testRepeatedLikesAccumulateWithoutDuplicatedTags() {
        let profile = PreferenceProfile(favorites: [favorite(wallpaper("a", tags: [forest, forest])), favorite(wallpaper("b", tags: [forest]))], settings: settings)
        XCTAssertEqual(profile.tags[77], 2)
        XCTAssertEqual(profile.categories["general"], 2)
    }

    func testPurityAndCategoryConstraintsAlsoFilterLearnedSignals() {
        var config = settings; config.anime = false
        let adult = favorite(wallpaper("adult", tags: [city], purity: "nsfw"), query: "adultword")
        let anime = favorite(wallpaper("anime", category: "anime", tags: [city]), query: "animeword")
        let hiddenTag = WallpaperTag(id: 90, name: "hidden", purity: "nsfw")
        let normal = favorite(wallpaper(tags: [forest, hiddenTag]), query: "nature")
        let profile = PreferenceProfile(favorites: [adult, anime, normal], settings: config)
        XCTAssertEqual(profile.tags, [77: 1])
        XCTAssertEqual(profile.categories, ["general": 1])
        XCTAssertEqual(profile.keywords, ["nature": 1])
    }

    func testRecommendationSplitAndDisable() {
        let profile = PreferenceProfile(favorites: [favorite(wallpaper(tags: [forest]))], settings: settings)
        let recommendations = (0..<100).filter { PreferenceProfile.shouldPersonalize(enabled: true, profile: profile, draw: Double($0) / 100) }
        XCTAssertEqual(recommendations.count, 80)
        XCTAssertFalse(PreferenceProfile.shouldPersonalize(enabled: false, profile: profile, draw: 0))
        XCTAssertFalse(PreferenceProfile.shouldPersonalize(enabled: true, profile: PreferenceProfile(favorites: [], settings: settings), draw: 0))
    }

    func testRetrievalDoesNotOverrideExplicitQueryOrOtherFilters() {
        var config = settings; config.keywords = "+mountain -forest"; config.people = false
        let profile = PreferenceProfile(favorites: [favorite(wallpaper(tags: [forest]))], settings: config)
        XCTAssertEqual(profile.retrievalSettings(from: config, draw: 0), config)
        config.keywords = ""
        let biased = profile.retrievalSettings(from: config, draw: 0)
        XCTAssertEqual(biased.keywords, "id:77")
        XCTAssertEqual(biased.categories, config.categories)
        XCTAssertEqual(biased.purity, config.purity)
        XCTAssertEqual(biased.downloadDirectory, config.downloadDirectory)
    }

    func testOnlyEnabledCategoryCanBePreferred() {
        var config = settings; config.anime = false
        let profile = PreferenceProfile(favorites: [favorite(wallpaper("general")), favorite(wallpaper("anime", category: "anime"))], settings: config)
        XCTAssertEqual(profile.retrievalSettings(from: config, draw: 0).categories, "100")
        let target = DisplayTarget(id: 1, name: "4K", width: 3840, height: 2160)
        XCTAssertTrue(SearchQuery.candidates([wallpaper("anime", category: "anime")], display: target, settings: config, excluding: []).isEmpty)
    }
}
