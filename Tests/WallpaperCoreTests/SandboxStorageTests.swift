import XCTest
@testable import WallpaperCore

final class SandboxStorageTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaperi-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private var settings: Settings { Settings(downloadDirectory: "/Users/example/Pictures/Wallpaperi") }
    private func wallpaper(_ id: String) -> Wallpaper {
        Wallpaper(id: id, width: 3840, height: 2160, path: "https://w.wallhaven.cc/full/ab/\(id).jpg", purity: "sfw", url: "https://wallhaven.cc/w/\(id)")
    }
    private func write<T: Encodable>(_ value: T, to folder: URL, name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: folder.appendingPathComponent(name))
    }

    func testFirstSaveUpgradesLegacyFilesWithoutDeletingThem() throws {
        let store = LibraryStore(directory: root)
        try write(settings, to: root, name: "settings.json")
        var preferences = Preferences()
        preferences.like(Favorite(wallpaper: wallpaper("abc"), filePath: "/legacy/a.jpg", searchKeywords: "forest"))
        try write(preferences, to: root, name: "preferences.json")
        var updated = settings; updated.keywords = "mountains"
        try store.save(updated, name: "settings.json")
        XCTAssertEqual(try store.read("preferences.json", as: Preferences.self), preferences)
        XCTAssertEqual(try store.read("settings.json", as: Settings.self), updated)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data(contentsOf: root.appendingPathComponent("settings.json"))), settings)
    }

    func testImportMergesLikesAndHistoryAndPausesRotation() throws {
        let source = root.appendingPathComponent("source")
        let target = LibraryStore(directory: root.appendingPathComponent("target"))
        var imported = settings; imported.automatic = true
        let entry = HistoryEntry(wallpaper: wallpaper("abc"), filePath: "/legacy/a.jpg", displayName: "Legacy")
        var incomingLikes = Preferences()
        incomingLikes.like(Favorite(wallpaper: wallpaper("abc"), filePath: "/legacy/a.jpg", searchKeywords: "forest"))
        var existingLikes = Preferences()
        existingLikes.like(Favorite(wallpaper: wallpaper("local"), filePath: "/local/b.jpg", searchKeywords: "city"))
        try write(imported, to: source, name: "settings.json")
        try write([entry], to: source, name: "history.json")
        try write(incomingLikes, to: source, name: "preferences.json")
        try target.save(existingLikes, name: "preferences.json")
        try target.save([entry], name: "history.json")
        let result = try target.importLibrary(from: source, fallbackSettings: settings)
        XCTAssertEqual(result.historyCount, 1)
        XCTAssertEqual(result.favoriteCount, 2)
        XCTAssertEqual(try target.read("settings.json", as: Settings.self)?.automatic, false)
        XCTAssertEqual(try target.read("settings.json", as: Settings.self)?.downloadDirectory, imported.downloadDirectory)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data(contentsOf: source.appendingPathComponent("settings.json"))).automatic, true)
        let again = try target.importLibrary(from: source, fallbackSettings: settings)
        XCTAssertEqual(again.favoriteCount, 2)
        XCTAssertEqual(again.historyCount, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.directory.path).contains { $0.hasPrefix("library-before-import-") })
    }

    func testMalformedImportDoesNotPartiallyWriteAnything() throws {
        let source = root.appendingPathComponent("source")
        let target = LibraryStore(directory: root.appendingPathComponent("target"))
        try target.save(settings, name: "settings.json")
        let before = try Data(contentsOf: target.directory.appendingPathComponent("library.json"))
        var different = settings; different.keywords = "do not apply"
        try write(different, to: source, name: "settings.json")
        try Data("broken json".utf8).write(to: source.appendingPathComponent("history.json"))
        XCTAssertThrowsError(try target.importLibrary(from: source, fallbackSettings: settings))
        XCTAssertEqual(try Data(contentsOf: target.directory.appendingPathComponent("library.json")), before)
    }

    func testImportCannotTransferAnotherAppsFolderPermissions() throws {
        let source = LibraryStore(directory: root.appendingPathComponent("source"))
        let target = LibraryStore(directory: root.appendingPathComponent("target"))
        let grant = DirectoryGrant(originalPath: "/external", bookmark: Data([1, 2, 3]))
        try source.save(settings, name: "settings.json")
        try source.save([grant], name: "folder-access.json")
        _ = try target.importLibrary(from: source.directory, fallbackSettings: settings)
        XCTAssertNil(try target.read("folder-access.json", as: [DirectoryGrant].self))
    }

    func testCorruptArchiveIsNotOverwrittenOnSave() throws {
        let store = LibraryStore(directory: root)
        let data = Data("corrupt".utf8)
        try data.write(to: root.appendingPathComponent("library.json"))
        XCTAssertThrowsError(try store.save(settings, name: "settings.json"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), data)
    }

    @MainActor
    func testContainerAccessAndExternalDenial() async throws {
        let store = LibraryStore(directory: root.appendingPathComponent("container"))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let access = try FolderAccess(store: store, sandboxed: true)
        let local = store.directory.appendingPathComponent("Wallpapers/a.jpg")
        XCTAssertEqual(try access.acquire(local).url, local)
        XCTAssertThrowsError(try access.acquire(root.appendingPathComponent("external.jpg")))
        let escape = store.directory.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: root)
        XCTAssertThrowsError(try access.acquire(escape.appendingPathComponent("external.jpg")))
    }

    @MainActor
    func testInvalidBookmarkRequiresReauthorization() async throws {
        let store = LibraryStore(directory: root.appendingPathComponent("container"))
        try store.save([DirectoryGrant(originalPath: "/external", bookmark: Data([0]))], name: "folder-access.json")
        let access = try FolderAccess(store: store, sandboxed: true)
        XCTAssertThrowsError(try access.acquire(URL(fileURLWithPath: "/external/image.jpg")))
    }

    func testDirectoryBoundaryIsNotAStringPrefix() {
        let folder = URL(fileURLWithPath: "/Users/example/Pictures")
        XCTAssertEqual(FolderAccess.relativePath(of: folder.appendingPathComponent("a.jpg"), inside: folder), ["a.jpg"])
        XCTAssertNil(FolderAccess.relativePath(of: URL(fileURLWithPath: "/Users/example/Pictures-private/a.jpg"), inside: folder))
        XCTAssertNil(FolderAccess.relativePath(of: folder.appendingPathComponent("../Secrets/a.jpg"), inside: folder))
    }

    func testRotationDoesNotOverlapAndHandlesWake() {
        let now = Date()
        XCTAssertTrue(RotationDecision.isDue(automatic: true, busy: false, nextChange: now.addingTimeInterval(-1000), now: now))
        XCTAssertFalse(RotationDecision.isDue(automatic: true, busy: true, nextChange: now, now: now))
        XCTAssertFalse(RotationDecision.isDue(automatic: false, busy: false, nextChange: now, now: now))
        XCTAssertFalse(RotationDecision.isDue(automatic: true, busy: false, nextChange: now.addingTimeInterval(60), now: now))
    }
}
