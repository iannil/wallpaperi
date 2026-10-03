# Wallpaperi Implementation Plan

**Goal:** 可运行的 macOS 原生多 Tab 自动壁纸应用。

**Architecture:** WallpaperCore 负责设置、API 请求和分辨率匹配；Wallpaperi 负责系统集成、调度和 SwiftUI 界面。核心通过 Swift Package 测试，脚本输出原生 .app。

**Tech Stack:** Swift 5.9、SwiftUI、AppKit、Security、UserNotifications、ServiceManagement。

**Spec:** docs/superpowers/specs/2026-10-03-wallpaperi-design.md

## Global Constraints
- macOS 13 及以上，无第三方依赖。
- 五个 Tab，NSFW 和通知默认关闭，API Key 仅存钥匙串。
- 每块显示器独立匹配，不放大小图，不自动删除文件。

## Tasks
- [x] 1. 核心数据与 API：Sources/WallpaperCore/Models.swift、WallhavenClient.swift；Tests/WallpaperCoreTests/CoreTests.swift 验证 URL 编码、权限门槛、横竖屏匹配、状态码和解码。使用 `swift test`。
- [x] 2. 系统集成：Sources/Wallpaperi/SystemServices.swift 实现钥匙串、显示器、配置持久化、通知及启动项；AppModel.swift 实现无重叠调度、取消、下载和桌面设置。使用 `swift build` 检查系统 API。
- [x] 3. 界面：WallpaperiApp.swift 和 Views.swift 实现五个 Tab、菜单栏、明确的空状态和失败反馈。构建 .app 并做启动检查。
- [x] 4. 交付：scripts/build-app.sh、Info.plist、README.md；运行测试和 release 构建，检查 bundle 元信息和签名。记录未完成的凭据联调与系统权限测试。

## 验证结果（2026-10-03）

- 12 项核心测试及 1 项真实 Wallhaven SFW 搜索、下载测试通过，0 失败。
- Release 构建成功，产物 dist/Wallpaperi.app，当前架构 arm64。
- Info.plist 校验和 codesign --verify --deep --strict 通过。
- 打包应用 --smoke-test 退出码 0，窗口创建成功。
- 未执行真实桌面切换；NSFW 凭据联调、通知授权、多屏实际更换和登录启动留待用户环境验证。
