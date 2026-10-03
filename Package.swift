// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Wallpaperi",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Wallpaperi", targets: ["Wallpaperi"])],
    targets: [
        .target(name: "WallpaperCore"),
        .executableTarget(name: "Wallpaperi", dependencies: ["WallpaperCore"]),
        .testTarget(name: "WallpaperCoreTests", dependencies: ["WallpaperCore"])
    ]
)
