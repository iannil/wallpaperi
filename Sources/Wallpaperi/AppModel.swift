import AppKit
import Combine
import ServiceManagement
import WallpaperCore

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: Settings
    @Published private(set) var savedSettings: Settings
    @Published var apiKeyInput = ""
    @Published private(set) var hasAPIKey = false
    @Published private(set) var displays: [DisplayTarget] = []
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var preferences = Preferences()
    @Published private(set) var loadingLikes: Set<String> = []
    @Published private(set) var preferenceStatus = "点赞越多，越懂你的喜好"
    @Published private(set) var busy = false
    @Published private(set) var status = "准备好为桌面换个风景"
    @Published private(set) var nextChange: Date?
    @Published var errorMessage: String?
    @Published var selectedTab = 0
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginNeedsApproval = false
    private var apiKey = ""
    private let store = LocalStore()
    private let client = WallhavenClient()
    private var operation: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var generation = UUID()
    private var likeTasks: [String: Task<Void, Never>] = [:]
    private var likeGenerations: [String: UUID] = [:]

    var hasChanges: Bool { settings != savedSettings }
    var visibleHistory: [HistoryEntry] { history.filter { $0.wallpaper.allowed(by: savedSettings) } }
    var current: HistoryEntry? { visibleHistory.first }
    var visibleFavorites: [Favorite] { preferences.favorites.filter { $0.wallpaper.allowed(by: savedSettings) } }
    var preferenceProfile: PreferenceProfile { PreferenceProfile(favorites: preferences.favorites, settings: savedSettings) }
    func isLiked(_ id: String) -> Bool { preferences.favorites.contains { $0.id == id } }

    init() {
        let defaults = Settings(downloadDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Wallpaperi").path)
        var initial = defaults
        var loadError: String?
        do { initial = try store.read("settings.json", as: Settings.self) ?? defaults }
        catch { loadError = "设置文件无法读取，当前使用默认设置；保存后将覆盖损坏的设置文件。" }
        settings = initial
        savedSettings = initial
        do { history = try store.read("history.json", as: [HistoryEntry].self) ?? [] }
        catch { loadError = "历史记录无法读取，已下载的图片仍保留在原目录。" }
        do { preferences = try store.read("preferences.json", as: Preferences.self) ?? Preferences() }
        catch { loadError = "点赞记录无法读取，请检查 preferences.json 或从备份恢复。" }
        if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            do { apiKey = try KeychainStore.read(); hasAPIKey = !apiKey.isEmpty }
            catch { loadError = error.localizedDescription }
        }
        if ProcessInfo.processInfo.arguments.contains("--smoke-favorites") { selectedTab = 5 }
        displays = DesktopService.displays()
        refreshLoginStatus()
        if let loadError { errorMessage = loadError }
        if initial.automatic { nextChange = Date().addingTimeInterval(Double(initial.intervalMinutes) * 60) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays(); self?.tick() }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { break }
                self?.tick()
            }
        }
    }

    private func tick() {
        guard savedSettings.automatic, !busy, let nextChange, nextChange <= Date() else { return }
        changeNow()
    }

    func refreshDisplays() {
        let updated = DesktopService.displays()
        if displays != updated { cancel(); displays = updated; status = "显示器信息已更新" }
    }

    func saveSettings() {
        do {
            try settings.validate(apiKey: apiKey)
            try store.save(settings, name: "settings.json")
            cancel()
            savedSettings = settings
            nextChange = settings.automatic ? Date().addingTimeInterval(Double(settings.intervalMinutes) * 60) : nil
            status = "设置已保存"
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleAutomatic() {
        var updated = savedSettings
        updated.automatic.toggle()
        do {
            try updated.validate(apiKey: apiKey)
            try store.save(updated, name: "settings.json")
            cancel()
            savedSettings = updated
            settings.automatic = updated.automatic
            nextChange = updated.automatic ? Date().addingTimeInterval(Double(updated.intervalMinutes) * 60) : nil
            status = updated.automatic ? "自动轮换已开启" : "自动轮换已暂停"
        } catch { errorMessage = error.localizedDescription }
    }

    func saveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            errorMessage = "请输入有效的 API Key（仅包含英文字母和数字）。"; return
        }
        do {
            try KeychainStore.save(key)
            cancel(); apiKey = key; hasAPIKey = true; apiKeyInput = ""
            status = "API Key 已安全保存到钥匙串"
        } catch { errorMessage = error.localizedDescription }
    }

    func removeKey() {
        guard !settings.nsfw && !savedSettings.nsfw else {
            errorMessage = "请先关闭并保存 NSFW 设置，再移除 API Key。"; return
        }
        do {
            try KeychainStore.save("")
            cancel(); apiKey = ""; hasAPIKey = false; apiKeyInput = ""; status = "API Key 已移除"
        } catch { errorMessage = error.localizedDescription }
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "选择保存目录"
        panel.directoryURL = URL(fileURLWithPath: settings.downloadDirectory)
        if panel.runModal() == .OK, let url = panel.url { settings.downloadDirectory = url.path }
    }

    func revealDirectory() {
        let url = URL(fileURLWithPath: savedSettings.downloadDirectory)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch { errorMessage = "无法打开保存目录：\(error.localizedDescription)" }
    }

    func setNotifications(_ enabled: Bool) {
        if !enabled { settings.notifications = false; return }
        Task {
            do {
                let granted = try await NotificationService.authorize()
                settings.notifications = granted
                if !granted { errorMessage = "系统未允许通知，请前往系统设置 → 通知 → Wallpaperi 开启。" }
            } catch { errorMessage = "无法申请通知权限，请在系统设置中检查。" }
        }
    }

    func refreshLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            errorMessage = "无法更新登录启动项。请将 Wallpaperi.app 放入应用程序目录后重试。\n\(error.localizedDescription)"
        }
    }

    func cancel() {
        operation?.cancel(); operation = nil
        generation = UUID(); busy = false
    }

    func cancelByUser() {
        cancel(); status = "本次更换已取消"
        scheduleNext()
    }

    private func scheduleNext() {
        nextChange = savedSettings.automatic ? Date().addingTimeInterval(Double(savedSettings.intervalMinutes) * 60) : nil
    }

    func changeNow() {
        guard !busy else { return }
        do { try savedSettings.validate(apiKey: apiKey) }
        catch { errorMessage = error.localizedDescription; scheduleNext(); return }
        let targets = savedSettings.allDisplays ? displays : Array(displays.prefix(1))
        guard !targets.isEmpty else { errorMessage = "没有检测到可用显示器。"; scheduleNext(); return }
        busy = true
        let token = UUID(); generation = token
        let snapshot = savedSettings
        let key = apiKey
        operation = Task { [weak self] in
            guard let self else { return }
            var successes = 0
            var failures: [String] = []
            var excluded = Set(history.prefix(30).map { $0.wallpaper.id })
            for target in targets {
                do {
                    try Task.checkCancellation()
                    status = "正在为 \(target.name) 寻找 \(target.resolution) 壁纸…"
                    let wallpaper = try await client.search(settings: snapshot, display: target, apiKey: key, excluding: excluded, preferences: preferences)
                    try Task.checkCancellation()
                    status = "正在下载壁纸 \(wallpaper.id)…"
                    let file = try await client.download(wallpaper, directory: URL(fileURLWithPath: snapshot.downloadDirectory))
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    try DesktopService.apply(file, to: target)
                    let entry = HistoryEntry(wallpaper: wallpaper, filePath: file.path, displayName: target.name, searchKeywords: snapshot.keywords)
                    history.insert(entry, at: 0)
                    history = Array(history.prefix(300))
                    successes += 1
                    excluded.insert(wallpaper.id)
                    try store.save(history, name: "history.json")
                } catch is CancellationError { break }
                catch let error as URLError where error.code == .cancelled { break }
                catch {
                    let description: String
                    if error is URLError { description = "网络请求失败，请检查网络连接后重试。" }
                    else { description = error.localizedDescription }
                    failures.append("\(target.name)：\(description)")
                    if case WallpaperError.rateLimited = error { break }
                }
            }
            guard generation == token else { return }
            busy = false; operation = nil; scheduleNext()
            status = failures.isEmpty ? "已为 \(successes) 个显示器更换壁纸" : "已更换 \(successes) 个显示器，部分操作未完成"
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
            if snapshot.notifications { await NotificationService.send(status) }
        }
    }

    @discardableResult
    private func persistPreferences(_ updated: Preferences) -> Bool {
        do {
            try store.save(updated, name: "preferences.json")
            preferences = updated
            return true
        } catch {
            errorMessage = "无法保存喜好：\(error.localizedDescription)"
            return false
        }
    }

    func setPersonalization(_ enabled: Bool) {
        var updated = preferences; updated.enabled = enabled
        if persistPreferences(updated) {
            preferenceStatus = enabled ? "个性化推荐已开启，下次更换生效" : "已关闭个性化推荐，点赞记录继续保留"
        }
    }

    func toggleLike(_ entry: HistoryEntry) {
        if isLiked(entry.wallpaper.id) { unlike(entry.wallpaper.id); return }
        var updated = preferences
        updated.like(Favorite(wallpaper: entry.wallpaper, filePath: entry.filePath, searchKeywords: entry.searchKeywords))
        guard persistPreferences(updated) else { return }
        preferenceStatus = "已点赞，正在补充标签信息…"
        if entry.wallpaper.tags != nil { preferenceStatus = "已点赞，下次选图会参考这张壁纸的特征" }
        else { loadLikeDetails(entry.wallpaper.id) }
    }

    func unlike(_ id: String) {
        var updated = preferences; updated.unlike(id)
        guard persistPreferences(updated) else { return }
        likeTasks.removeValue(forKey: id)?.cancel()
        likeGenerations.removeValue(forKey: id)
        loadingLikes.remove(id)
        preferenceStatus = "已取消点赞，其偏好权重已移除"
    }

    func loadLikeDetails(_ id: String) {
        guard isLiked(id), !loadingLikes.contains(id) else { return }
        let token = UUID()
        likeGenerations[id] = token
        loadingLikes.insert(id)
        let key = apiKey
        likeTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if likeGenerations[id] == token {
                    loadingLikes.remove(id); likeTasks.removeValue(forKey: id); likeGenerations.removeValue(forKey: id)
                }
            }
            do {
                let wallpaper = try await client.details(id: id, apiKey: key)
                try Task.checkCancellation()
                guard likeGenerations[id] == token, isLiked(id) else { return }
                var updated = preferences; updated.enrich(wallpaper)
                if persistPreferences(updated) { preferenceStatus = "标签已更新，下次选图会参考你的喜好" }
            } catch {
                guard likeGenerations[id] == token, !Task.isCancelled else { return }
                preferenceStatus = "点赞已保留，标签暂未获取；可在「我的喜好」中重试"
            }
        }
    }
}
