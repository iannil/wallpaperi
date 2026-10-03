import SwiftUI
import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notifications = NotificationDelegate()
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = notifications
        NSApp.setActivationPolicy(.regular)
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                print("Wallpaperi launch OK; windows=\(NSApp.windows.count)")
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.title == "Wallpaperi" })?.makeKeyAndOrderFront(nil) }
        return true
    }
}

@main
struct WallpaperiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Wallpaperi", id: "main") {
            MainView().environmentObject(model)
                .frame(minWidth: 780, minHeight: 620)
        }
        .defaultSize(width: 960, height: 740)
        .commands {
            CommandGroup(after: .newItem) {
                Button("立即更换壁纸") { model.changeNow() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.busy)
            }
        }
        MenuBarExtra("Wallpaperi", systemImage: "photo.on.rectangle.angled") {
            TrayView().environmentObject(model)
        }
    }
}

struct TrayView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.status)
        if let next = model.nextChange { Text("下次更换：\(next.formatted(date: .omitted, time: .shortened))") }
        Divider()
        Button(model.busy ? "正在更换…" : "立即更换壁纸") { model.changeNow() }.disabled(model.busy)
        Button(model.savedSettings.automatic ? "暂停自动轮换" : "开启自动轮换") { model.toggleAutomatic() }
        if model.busy { Button("取消本次更换") { model.cancelByUser() } }
        Divider()
        Button("打开 Wallpaperi") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("打开壁纸文件夹") { model.revealDirectory() }
        Divider()
        Button("退出 Wallpaperi") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
