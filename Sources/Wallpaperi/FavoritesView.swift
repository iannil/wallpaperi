import SwiftUI
import AppKit
import WallpaperCore

struct LikeButton: View {
    @EnvironmentObject var model: AppModel
    let entry: HistoryEntry
    var body: some View {
        Button { model.toggleLike(entry) } label: {
            Label(model.isLiked(entry.wallpaper.id) ? "已点赞" : "点赞",
                  systemImage: model.isLiked(entry.wallpaper.id) ? "heart.fill" : "heart")
        }
        .tint(model.isLiked(entry.wallpaper.id) ? .pink : .secondary)
        .help(model.isLiked(entry.wallpaper.id) ? "取消点赞并撤销对应偏好" : "喜欢这张，让以后更懂你")
        .accessibilityIdentifier("like-\(entry.wallpaper.id)")
    }
}

struct FavoritesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(title: "好风景，值得偏爱", subtitle: "每一个点赞，都让下一次相遇更合心意。")
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("根据我的点赞推荐壁纸", isOn: Binding(get: { model.preferences.enabled }, set: { model.setPersonalization($0) }))
                            .font(.headline)
                        Text("开启后，约 80% 按喜好选择、20% 随机探索。标签最重要，其次是关键词和分类；始终遵守你当前的筛选和分辨率设置。")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(model.preferenceStatus).font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
                if !model.preferenceProfile.isEmpty {
                    GroupBox("你的偏好 · 当前筛选范围内") {
                        VStack(alignment: .leading, spacing: 10) {
                            signalRow("标签", signals: model.preferenceProfile.topTags)
                            signalRow("关键词", signals: model.preferenceProfile.topKeywords)
                            signalRow("分类", signals: model.preferenceProfile.topCategories)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack {
                    Text("点赞收藏").font(.headline)
                    Spacer()
                    Text("\(model.visibleFavorites.count) 张可见 · 共 \(model.preferences.favorites.count) 张")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("点赞和开关立即保存，仅存本机。取消点赞会撤销其偏好权重；关闭推荐会保留收藏。已关闭的内容分级会隐藏对应收藏。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.visibleFavorites.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "heart.text.square").font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
                        Text("从一张喜欢的壁纸开始").font(.headline)
                        Text("在「当前壁纸」或「下载与存储」中点赞，\n这里会留下收藏，并逐渐形成你的偏好。")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                        ForEach(model.visibleFavorites) { favorite in
                            FavoriteCard(favorite: favorite)
                        }
                    }
                }
            }.padding(22)
        }
    }

    private func signalRow(_ title: String, signals: [PreferenceSignal]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(.caption.weight(.semibold)).frame(width: 46, alignment: .leading)
            Text(signals.isEmpty ? "暂未积累" : signals.prefix(8).map { "\($0.name) ×\($0.count)" }.joined(separator: "   ·   "))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FavoriteCard: View {
    @EnvironmentObject var model: AppModel
    let favorite: Favorite
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                LocalPreview(path: favorite.filePath)
                    .frame(height: 150).frame(maxWidth: .infinity)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Text(favorite.id).font(.headline)
                    Spacer()
                    Button { model.unlike(favorite.id) } label: { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                        .help("取消点赞").accessibilityLabel("取消点赞 \(favorite.id)")
                }
                Text("\(favorite.wallpaper.resolution) · \(favorite.wallpaper.category ?? "分类待获取")")
                    .font(.caption).foregroundStyle(.secondary)
                if let tags = favorite.wallpaper.tags {
                    let visibleTags = tags.filter { $0.allowed(by: model.savedSettings) }
                    Text(visibleTags.isEmpty ? "没有可用标签" : visibleTags.prefix(8).map(\.name).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    HStack {
                        if model.loadingLikes.contains(favorite.id) {
                            ProgressView().controlSize(.small)
                            Text("正在获取标签…").font(.caption)
                        } else {
                            Text("标签尚未获取").font(.caption).foregroundStyle(.secondary)
                            Button("重试") { model.loadLikeDetails(favorite.id) }.controlSize(.small)
                        }
                    }
                }
                Text(keywordDescription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    Button("查看文件") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: favorite.filePath)]) }
                    Spacer()
                    if let url = URL(string: favorite.wallpaper.url), url.scheme == "https", url.host == "wallhaven.cc" {
                        Link("来源 ↗", destination: url)
                    }
                }.controlSize(.small)
            }.padding(8)
        }
    }

    private var keywordDescription: String {
        guard let query = favorite.searchKeywords else { return "旧记录未保存搜索关键词；按标签和分类学习。" }
        let words = PreferenceProfile.positiveKeywords(query).sorted()
        return words.isEmpty ? "未使用正向搜索关键词" : "搜索偏好：" + words.joined(separator: "、")
    }
}
