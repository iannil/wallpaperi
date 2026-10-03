import AppKit
import ImageIO
import Security
import ServiceManagement
import UserNotifications
import WallpaperCore

enum KeychainStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "cc.wallpaperi.mac",
        kSecAttrAccount as String: "wallhaven-api-key"
    ]

    static func read() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw WallpaperError.message("无法读取钥匙串中的 API Key（\(status)）。")
        }
        return key
    }

    static func save(_ key: String) throws {
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw WallpaperError.message("无法移除 API Key（\(status)）。")
            }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query.merging(attributes) { _, new in new }
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw WallpaperError.message("无法保存 API Key 到钥匙串（\(status)）。") }
    }
}

typealias LocalStore = LibraryStore

enum SandboxEnvironment {
    static var isEnabled: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) as? Bool == true
    }
    static var legacyDirectory: URL {
        let home = FileManager.default.homeDirectory(forUser: NSUserName()) ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/Wallpaperi", isDirectory: true)
    }
}

@MainActor
enum DesktopService {
    static func identifier(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    static func displays() -> [DisplayTarget] {
        NSScreen.screens.map { screen in
            let id = identifier(screen)
            let mode = CGDisplayCopyDisplayMode(id)
            var width = mode?.pixelWidth ?? Int(screen.frame.width * screen.backingScaleFactor)
            var height = mode?.pixelHeight ?? Int(screen.frame.height * screen.backingScaleFactor)
            if (screen.frame.width > screen.frame.height) != (width > height) { swap(&width, &height) }
            return DisplayTarget(id: id, name: screen.localizedName,
                                 width: width, height: height)
        }
    }
    static func apply(_ file: URL, to target: DisplayTarget) throws {
        guard let screen = NSScreen.screens.first(where: { identifier($0) == target.id }) else {
            throw WallpaperError.message("显示器已断开连接。")
        }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width >= target.width, height >= target.height else {
            throw WallpaperError.message("本地图片无法读取或实际分辨率不足，请在 Finder 中检查该图片。")
        }
        let ratioDifference = abs((Double(width) / Double(height)) / (Double(target.width) / Double(target.height)) - 1)
        guard ratioDifference <= 0.06 else { throw WallpaperError.message("图片实际宽高比与显示器不匹配。") }
        try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true
        ])
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

enum NotificationService {
    static func authorize() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    static func send(_ text: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Wallpaperi"
        content.body = text
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
