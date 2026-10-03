import SwiftUI
import AppKit
import ImageIO
import ServiceManagement
import WallpaperCore

private let accent = Color(red: 0.20, green: 0.47, blue: 0.40)

struct MainView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "mountain.2.fill").font(.system(size: 26)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Wallpaperi").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("让桌面，常有新风景。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.savedSettings.automatic ? "自动轮换中" : "手动模式", systemImage: model.savedSettings.automatic ? "arrow.triangle.2.circlepath" : "pause.circle")
                    .font(.callout).foregroundStyle(accent)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(accent.opacity(0.09), in: Capsule())
            }.padding(.horizontal, 28).padding(.vertical, 20)

            TabView(selection: $model.selectedTab) {
                CurrentView().tabItem { Label("当前壁纸", systemImage: "photo") }.tag(0)
                FilterView().tabItem { Label("壁纸筛选", systemImage: "line.3.horizontal.decrease.circle") }.tag(1)
                DisplaySettingsView().tabItem { Label("显示与轮换", systemImage: "display") }.tag(2)
                StorageView().tabItem { Label("下载与存储", systemImage: "folder") }.tag(3)
                FavoritesView().tabItem { Label("我的喜好", systemImage: "heart") }.tag(5)
                GeneralView().tabItem { Label("通用设置", systemImage: "gearshape") }.tag(4)
            }.padding(.horizontal, 20).padding(.bottom, 16)

            Divider()
            HStack(spacing: 10) {
                if model.busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "leaf").foregroundStyle(accent) }
                Text(model.status).font(.caption).lineLimit(2)
                Spacer()
                if model.hasChanges {
                    Text("有未保存的设置").font(.caption).foregroundStyle(.secondary)
                    Button("还原") { model.settings = model.savedSettings }
                    Button("保存设置") { model.saveSettings() }.buttonStyle(.borderedProminent)
                }
            }.padding(.horizontal, 24).padding(.vertical, 12)
        }
        .tint(accent)
        .alert("操作提示", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LocalPreview: View {
    let path: String
    @EnvironmentObject var model: AppModel
    private var thumbnail: NSImage? { model.previewImage(path) }
    var body: some View {
        if let thumbnail {
            Image(nsImage: thumbnail).resizable().scaledToFit()
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo.badge.exclamationmark").font(.largeTitle)
                Text("预览不可用，文件可能需授权或已移动").font(.caption)
                Button("授权图片目录") { model.authorizeImageFolder(path) }.controlSize(.small)
            }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CurrentView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(title: "下一眼，新的风景", subtitle: "来自 Wallhaven，为你的显示器自动挑选合适的清晰度。")
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(accent.opacity(0.07))
                    if let entry = model.current {
                        LocalPreview(path: entry.filePath).padding(8)
                    } else {
                        VStack(spacing: 14) {
                            Image(systemName: "mountain.2").font(.system(size: 58, weight: .ultraLight)).foregroundStyle(accent)
                            Text("你的下一张壁纸，正在远方").font(.title3.weight(.medium))
                            Text("先设置喜欢的关键词，再点击「立即更换」。\n普通壁纸无需 API Key 即可尝试。")
                                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }.padding(30)
                    }
                }.frame(height: 290).clipShape(RoundedRectangle(cornerRadius: 16))
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let entry = model.current {
                            Text("最近应用 · \(entry.wallpaper.id)").font(.headline)
                            Text("\(entry.displayName) · \(entry.wallpaper.resolution) · \(entry.wallpaper.purity.uppercased())").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("已检测到 \(model.displays.count) 个显示器").font(.headline)
                            Text("匹配像素尺寸与宽高比，不放大小图。").font(.caption).foregroundStyle(.secondary)
                        }
                        if let date = model.nextChange {
                            Text("下次自动更换：\(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let entry = model.current { LikeButton(entry: entry) }
                    if model.busy { Button("取消") { model.cancelByUser() } }
                    Button { model.changeNow() } label: {
                        Label(model.busy ? "正在更换…" : "立即更换", systemImage: "arrow.triangle.2.circlepath")
                            .padding(.horizontal, 8).padding(.vertical, 4)
                    }.buttonStyle(.borderedProminent).disabled(model.busy)
                }
                if let entry = model.current, model.isLiked(entry.wallpaper.id) {
                    Text(model.preferenceStatus).font(.caption).foregroundStyle(.secondary)
                }
                if model.hasChanges {
                    Label("立即更换使用已保存的配置。请先保存刚刚修改的筛选条件。", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(22)
        }
    }
}

struct FilterView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section {
                PageHeading(title: "只看你喜欢的", subtitle: "筛选条件会用于手动更换与自动轮换。")
            }
            Section("关键词") {
                TextField("搜索", text: $model.settings.keywords, prompt: Text("例如 nature、mountains、+forest -city"))
                Text("支持 Wallhaven 搜索语法；留空则随机探索全部壁纸。").font(.caption).foregroundStyle(.secondary)
            }
            Section("壁纸分类 · 可多选") {
                Toggle("综合 / General", isOn: $model.settings.general)
                Toggle("动漫 / Anime", isOn: $model.settings.anime)
                Toggle("人物 / People", isOn: $model.settings.people)
            }
            Section("内容分级") {
                LabeledContent("SFW · 普通内容", value: "始终包含")
                Toggle("包含 Sketchy 内容", isOn: $model.settings.sketchy)
                Toggle("包含 NSFW 内容", isOn: $model.settings.nsfw)
                Label(model.hasAPIKey ? "API Key 已保存；内容访问仍取决于 Wallhaven 账户权限。" : "NSFW 需要在「通用设置」中添加 API Key。", systemImage: "key")
                    .font(.caption).foregroundStyle(.secondary)
                Text("关闭分级后，后续更换与应用内历史预览将排除该内容；当前系统桌面需再更换一次才会更新。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct DisplaySettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section { PageHeading(title: "清晰度，刚刚好", subtitle: "按每块显示器的像素分辨率和比例独立选择壁纸。") }
            Section("当前显示器") {
                ForEach(model.displays) { display in
                    HStack {
                        Image(systemName: "display").font(.title2).foregroundStyle(accent).frame(width: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(display.name)
                            Text(display.resolution + " 像素").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if display.id == model.displays.first?.id { Text("主显示器").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 3)
                }
                Picker("应用范围", selection: $model.settings.allDisplays) {
                    Text("所有显示器 · 分别匹配").tag(true)
                    Text("仅主显示器").tag(false)
                }
                Text("优先清晰度，图片宽高均不小于屏幕像素尺寸，比例偏差不超过 6%。无匹配结果时保留现有壁纸。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("自动轮换") {
                Toggle("按固定间隔更换", isOn: $model.settings.automatic)
                Picker("更换间隔", selection: $model.settings.intervalMinutes) {
                    Text("5 分钟").tag(5)
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                    Text("1 小时").tag(60)
                    Text("2 小时").tag(120)
                    Text("6 小时").tag(360)
                    Text("12 小时").tag(720)
                    Text("每天").tag(1440)
                }.disabled(!model.settings.automatic)
                Text("关闭窗口后继续在菜单栏运行。Mac 休眠时暂停，唤醒后补一次到期更换；退出应用后停止。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct StorageView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: "把喜欢的风景留下", subtitle: "原图保存在本地，换过的壁纸也能随时找到。")
            GroupBox {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill").font(.title2).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("壁纸保存目录").font(.headline)
                        Text(model.settings.downloadDirectory).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                    }
                    Spacer()
                    Button("选择目录…") { model.chooseDirectory() }
                    Button("在 Finder 中打开") { model.revealDirectory() }
                }.padding(10)
            }
            HStack {
                Label(model.sandboxed ? "App Sandbox 已启用" : "非沙盒运行", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("使用应用内目录") { model.usePrivateDirectory() }
                Button("导入旧版数据…") { model.importLegacyLibrary() }
            }
            if !model.storageStatus.isEmpty {
                Text(model.storageStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("修改目录后，新壁纸存入新位置，已有文件不移动、不自动删除。最近保留 300 条应用记录。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("更换记录").font(.headline)
                Spacer()
                Text("\(model.visibleHistory.count) 条").foregroundStyle(.secondary)
            }
            if model.visibleHistory.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.stack").font(.system(size: 32)).foregroundStyle(accent)
                    Text("还没有符合当前分级设置的更换记录").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.visibleHistory) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: "photo").foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(entry.wallpaper.id) · \(entry.wallpaper.resolution)").font(.headline)
                            Text("\(entry.displayName) · \(entry.appliedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        LikeButton(entry: entry)
                        Button("查看文件") { model.revealFile(entry.filePath) }
                        if let url = URL(string: entry.wallpaper.url), url.scheme == "https", url.host == "wallhaven.cc" {
                            Link("来源", destination: url)
                        }
                    }.padding(.vertical, 6)
                }.listStyle(.inset)
            }
        }.padding(22)
    }
}

struct GeneralView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section { PageHeading(title: "按你的习惯运行", subtitle: "安全保存凭据，让提醒和启动方式保持可控。") }
            Section("Wallhaven API Key") {
                HStack {
                    SecureField(model.hasAPIKey ? "输入新的 API Key 以替换" : "粘贴你的 API Key", text: $model.apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                    Button("保存 Key") { model.saveKey() }.disabled(model.apiKeyInput.isEmpty)
                }
                HStack {
                    Label(model.hasAPIKey ? "已保存到 macOS 钥匙串" : "尚未配置，普通壁纸可不填", systemImage: model.hasAPIKey ? "lock.shield" : "key")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.hasAPIKey { Button("移除 Key", role: .destructive) { model.removeKey() } }
                    Link("获取 API Key ↗", destination: URL(string: "https://wallhaven.cc/settings/account")!)
                }
                Text("Key 单独保存并立即生效，不写入普通配置或日志。保存后可用「立即更换」验证访问。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("通知") {
                Toggle("更换完成或失败时通知我", isOn: Binding(get: { model.settings.notifications }, set: { model.setNotifications($0) }))
                Text("首次开启会申请 macOS 通知权限；关闭后仍可在窗口查看状态。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("启动与后台") {
                Toggle("登录 Mac 时启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Text("启动项修改立即生效。请先将应用放入「应用程序」目录；关闭窗口后可从菜单栏重新打开。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.loginNeedsApproval {
                    Button("前往系统设置批准登录项") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Section("关于") {
                LabeledContent("Wallpaperi", value: "1.2.0 · macOS 原生")
                Link("Wallhaven API 文档 ↗", destination: URL(string: "https://wallhaven.cc/help/api")!)
            }
        }.formStyle(.grouped).onAppear { model.refreshLoginStatus() }
    }
}
