import Foundation

public struct DirectoryGrant: Codable, Equatable {
    public let originalPath: String
    public var bookmark: Data
    public init(originalPath: String, bookmark: Data) { self.originalPath = originalPath; self.bookmark = bookmark }
}

/// Keep this object alive for the full async download/application operation.
public final class FolderLease {
    public let url: URL
    private let scopedRoot: URL?
    init(url: URL, scopedRoot: URL? = nil) { self.url = url; self.scopedRoot = scopedRoot }
    deinit { scopedRoot?.stopAccessingSecurityScopedResource() }
}

@MainActor
public final class FolderAccess {
    private let store: LibraryStore
    private let sandboxed: Bool
    public private(set) var grants: [DirectoryGrant]
    public init(store: LibraryStore, sandboxed: Bool) throws {
        self.store = store; self.sandboxed = sandboxed
        grants = try store.read("folder-access.json", as: [DirectoryGrant].self) ?? []
    }

    nonisolated public static func relativePath(of file: URL, inside directory: URL) -> [String]? {
        let child = file.standardizedFileURL.pathComponents
        let parent = directory.standardizedFileURL.pathComponents
        guard child.starts(with: parent) else { return nil }
        return Array(child.dropFirst(parent.count))
    }

    /// Foundation may leave symlinks unresolved when the final file does not exist yet.
    /// Resolve the nearest existing ancestor before appending the future download path.
    nonisolated private static func canonical(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missing.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        return missing.reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }

    public func authorize(_ directory: URL) throws {
        let started = directory.startAccessingSecurityScopedResource()
        defer { if started { directory.stopAccessingSecurityScopedResource() } }
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw WallpaperError.message("请选择文件夹。")
        }
        let data = try directory.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        var updated = grants.filter { $0.originalPath != directory.standardizedFileURL.path }
        updated.append(DirectoryGrant(originalPath: directory.standardizedFileURL.path, bookmark: data))
        try store.save(updated, name: "folder-access.json")
        grants = updated
    }

    public func acquire(_ requested: URL) throws -> FolderLease {
        // The app's data subtree is private and needs no security scope. Resolve symlinks before trusting it.
        if Self.relativePath(of: Self.canonical(requested), inside: Self.canonical(store.directory)) != nil {
            return FolderLease(url: requested)
        }
        if !sandboxed { return FolderLease(url: requested) }
        for index in grants.indices.sorted(by: { grants[$0].originalPath.count > grants[$1].originalPath.count }) {
            var stale = false
            guard let root = try? URL(resolvingBookmarkData: grants[index].bookmark, options: [.withSecurityScope, .withoutUI],
                                      relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            let original = URL(fileURLWithPath: grants[index].originalPath)
            guard let relative = Self.relativePath(of: requested, inside: original) ?? Self.relativePath(of: requested, inside: root) else { continue }
            guard root.startAccessingSecurityScopedResource() else { continue }
            let target = relative.reduce(root) { $0.appendingPathComponent($1) }
            // A descendant symlink must not turn a directory grant into access to another location.
            guard Self.relativePath(of: Self.canonical(target), inside: Self.canonical(root)) != nil else {
                root.stopAccessingSecurityScopedResource()
                continue
            }
            if stale {
                do {
                    var updated = grants
                    updated[index].bookmark = try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                    try store.save(updated, name: "folder-access.json")
                    grants = updated
                } catch {
                    root.stopAccessingSecurityScopedResource()
                    throw WallpaperError.message("目录授权需要更新，请重新选择该文件夹。")
                }
            }
            return FolderLease(url: target, scopedRoot: root)
        }
        throw WallpaperError.message("此目录尚未授权或授权已失效。请在「下载与存储」重新选择文件夹：\(requested.path)")
    }
}
