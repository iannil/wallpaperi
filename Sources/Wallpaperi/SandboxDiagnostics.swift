import AppKit
import Security
import ServiceManagement
import ImageIO
import WallpaperCore

/// Opt-in diagnostics run inside the signed application, using a separate test data directory.
@MainActor
enum SandboxDiagnostics {
    private struct Skipped: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }
    struct Check: Codable {
        let name: String
        let outcome: String
        let detail: String
    }
    static func run() async {
        var checks: [Check] = []
        func record(_ name: String, _ outcome: String, _ detail: String) {
            checks.append(Check(name: name, outcome: outcome, detail: detail))
            print("[\(outcome)] \(name): \(detail)")
            fflush(stdout)
        }
        let base = LocalStore().directory.appendingPathComponent("SandboxChecks", isDirectory: true)
        let store = LibraryStore(directory: base)
        guard SandboxEnvironment.isEnabled else {
            record("sandbox", "FAIL", "App Sandbox entitlement is not active.")
            return
        }
        record("sandbox", "PASS", "App Sandbox entitlement is active.")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let testSettings = Settings(downloadDirectory: base.appendingPathComponent("Downloads").path)
            try store.save(testSettings, name: "settings.json")
            let restored = try store.read("settings.json", as: Settings.self)
            guard restored == testSettings else { throw WallpaperError.message("State did not round-trip.") }
            record("container-persistence", "PASS", "Isolated state saved and restored.")

            let access = try FolderAccess(store: store, sandboxed: true)
            if ProcessInfo.processInfo.arguments.contains("--select-test-folder") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                panel.prompt = "授权测试目录"
                panel.message = "请选择一个用于验证重启后读写权限的文件夹。仅创建并删除一个临时测试文件，不修改已有文件。"
                if panel.runModal() == .OK, let url = panel.url { try access.authorize(url) }
            }
            if let grant = access.grants.first {
                do {
                    let lease = try access.acquire(URL(fileURLWithPath: grant.originalPath))
                    defer { withExtendedLifetime(lease) {} }
                    let file = lease.url.appendingPathComponent(".wallpaperi-check-\(UUID().uuidString).txt")
                    defer { try? FileManager.default.removeItem(at: file) }
                    let data = Data("Wallpaperi sandbox bookmark check".utf8)
                    try data.write(to: file, options: .atomic)
                    guard try Data(contentsOf: file) == data else { throw WallpaperError.message("Read mismatch.") }
                    record("external-bookmark", "PASS", "Saved security-scoped bookmark resolved and external read/write succeeded.")
                } catch { record("external-bookmark", "FAIL", error.localizedDescription) }
            } else {
                record("external-bookmark", "SKIP", "No user-selected test folder. Run with --select-test-folder, then rerun without it to verify relaunch access.")
            }
            do {
                _ = try access.acquire(URL(fileURLWithPath: "/Users/Shared/wallpaperi-unapproved"))
                record("unapproved-folder", "FAIL", "Unexpected access lease.")
            } catch { record("unapproved-folder", "PASS", "Unapproved external directory was rejected.") }
            do {
                try keychainRoundTrip()
                record("keychain", "PASS", "Isolated test item created, read and deleted. User API key was not accessed.")
            } catch { record("keychain", "FAIL", error.localizedDescription) }

            let client = WallhavenClient()
            do {
                var config = testSettings; config.keywords = "nature"; config.anime = false; config.people = false
                let target = DisplayTarget(id: 0, name: "Network probe", width: 1920, height: 1080)
                let wallpaper = try await client.search(settings: config, display: target, apiKey: "", excluding: [])
                let lease = try access.acquire(URL(fileURLWithPath: config.downloadDirectory))
                defer { withExtendedLifetime(lease) {} }
                let file = try await client.download(wallpaper, directory: lease.url)
                guard CGImageSourceCreateWithURL(file as CFURL, nil) != nil else { throw WallpaperError.message("Invalid image.") }
                record("sandbox-network-download", "PASS", "Public SFW search and image download completed inside App Sandbox.")
            } catch {
                record("sandbox-network-download", "FAIL", error is URLError ? "Network request failed." : error.localizedDescription)
            }

            let displays = DesktopService.displays()
            record("display-detection", displays.isEmpty ? "FAIL" : "PASS", "Detected \(displays.count) display(s): \(displays.map(\.resolution).joined(separator: ", ")).")
            var fixtures: [(DisplayTarget, URL)] = []
            for target in displays {
                do {
                    let file = base.appendingPathComponent("display-\(target.id).png")
                    try makeFixture(file, target: target)
                    fixtures.append((target, file))
                    try applyAndRestore(file, target: target, access: access)
                    record("desktop-\(target.id)", "PASS", "Set a test wallpaper and restored the original using NSWorkspace.")
                } catch {
                    record("desktop-\(target.id)", error is Skipped ? "SKIP" : "FAIL", error.localizedDescription)
                }
            }
            if displays.count < 2 { record("multiple-displays", "SKIP", "Connect a second display to perform a real multi-display check.") }

            // The production ticker must keep firing with this process's window hidden.
            for window in NSApp.windows where window.title == "Wallpaperi" { window.orderOut(nil) }
            var ticks = 0
            let ticker = RotationTicker(intervalNanoseconds: 100_000_000) { ticks += 1 }
            try await Task.sleep(nanoseconds: 650_000_000)
            ticker.stop()
            record("background-ticker", ticks >= 2 ? "PASS" : "FAIL", "\(ticks) ticks while the main window was hidden; production uses the same ticker with a 10-second polling interval.")
            if let (target, file) = fixtures.first {
                do {
                    try applyAndRestore(file, target: target, access: access)
                    record("background-desktop", "PASS", "NSWorkspace wallpaper change/restore succeeded with the main window hidden.")
                } catch { record("background-desktop", error is Skipped ? "SKIP" : "FAIL", error.localizedDescription) }
            }
            do { record("login-item", "PASS", try loginRoundTrip()) }
            catch { record("login-item", "SKIP", error.localizedDescription) }
        } catch { record("diagnostics", "FAIL", error.localizedDescription) }
        do {
            let data = try JSONEncoder().encode(checks)
            try data.write(to: base.appendingPathComponent("report.json"), options: .atomic)
            print("Report: \(base.appendingPathComponent("report.json").path)")
        } catch { print("Unable to save diagnostic report: \(error.localizedDescription)") }
    }

    private static func keychainRoundTrip() throws {
        let account = "diagnostic-\(UUID().uuidString)"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "cc.wallpaperi.mac.sandbox-check", kSecAttrAccount as String: account]
        let secret = Data(UUID().uuidString.utf8)
        var create = query; create[kSecValueData as String] = secret
        let added = SecItemAdd(create as CFDictionary, nil)
        guard added == errSecSuccess else { throw WallpaperError.message("Keychain add failed (\(added)).") }
        defer { SecItemDelete(query as CFDictionary) }
        var read = query; read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        guard status == errSecSuccess, result as? Data == secret else { throw WallpaperError.message("Keychain read failed (\(status)).") }
        guard SecItemDelete(query as CFDictionary) == errSecSuccess else { throw WallpaperError.message("Keychain cleanup failed.") }
    }

    private static func makeFixture(_ file: URL, target: DisplayTarget) throws {
        guard let context = CGContext(data: nil, width: target.width, height: target.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw WallpaperError.message("Unable to create a test image.")
        }
        context.setFillColor(CGColor(red: 0.18, green: 0.29, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: target.width, height: target.height))
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw WallpaperError.message("Unable to encode a test image.")
        }
        try png.write(to: file, options: .atomic)
    }

    private static func applyAndRestore(_ file: URL, target: DisplayTarget, access: FolderAccess) throws {
        guard let screen = NSScreen.screens.first(where: { DesktopService.identifier($0) == target.id }),
              let originalURL = NSWorkspace.shared.desktopImageURL(for: screen) else {
            throw Skipped(reason: "Cannot determine the original wallpaper; no desktop changes made.")
        }
        let lease = try? access.acquire(originalURL)
        defer { withExtendedLifetime(lease) {} }
        let original = lease?.url ?? originalURL
        let scoped = original.startAccessingSecurityScopedResource()
        defer { if scoped { original.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: original.path) else {
            throw Skipped(reason: "Original wallpaper is not readable in the sandbox; skipped to ensure safe restoration.")
        }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        // Verify the original can be reapplied before making any visible test change.
        try NSWorkspace.shared.setDesktopImageURL(original, for: screen, options: options)
        do { try DesktopService.apply(file, to: target) }
        catch {
            try? NSWorkspace.shared.setDesktopImageURL(original, for: screen, options: options)
            throw error
        }
        try NSWorkspace.shared.setDesktopImageURL(original, for: screen, options: options)
    }

    private static func loginRoundTrip() throws -> String {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled: return "Existing login item is enabled; left unchanged."
        case .requiresApproval: throw WallpaperError.message("Existing login item requires user approval; left unchanged.")
        case .notFound: throw WallpaperError.message("Login item unavailable in this installation. Test an installed, appropriately signed build.")
        case .notRegistered: break
        @unknown default: throw WallpaperError.message("Unknown login-item status.")
        }
        try service.register()
        let registeredStatus = service.status
        do { try service.unregister() }
        catch { throw WallpaperError.message("Registration occurred but cleanup failed; check System Settings > Login Items. \(error.localizedDescription)") }
        guard service.status == .notRegistered else { throw WallpaperError.message("Login registration cleanup was not confirmed.") }
        guard registeredStatus == .enabled else { throw WallpaperError.message("Registration requires approval or signing; test entry was removed.") }
        return "Login item registered and unregistered successfully; actual logout/login was not performed."
    }
}
