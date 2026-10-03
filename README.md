# Wallpaperi

**English** | [简体中文](README.zh-CN.md)

A native macOS wallpaper changer built with SwiftUI and AppKit, powered by [Wallhaven](https://wallhaven.cc/help/api). Version 1.2.0 requires macOS 13 or later and has no third-party dependencies.

The app interface is currently in Chinese. This repository provides documentation in English and Simplified Chinese.

## Getting started

1. Open `dist/Wallpaperi.app` after building it using the instructions below. To launch it at login, first copy it to your Applications folder.
2. In **General**, enter your API key and click **Save Key**. Public SFW searches work without a key; NSFW requires a valid key.
3. In **Filters**, enter keywords and choose categories and content ratings. SFW is always included; Sketchy and NSFW have separate toggles.
4. In **Downloads & Storage**, choose a folder. The sandbox build defaults to its private `Application Support/Wallpaperi/Wallpapers` directory. External folders must be selected in the system picker; permission is retained across launches.
5. Click **Save Settings**, then **Change Now** in **Current Wallpaper**.
6. Enable automatic rotation in **Displays & Rotation** and save. Intervals range from 5 minutes to 24 hours. Notifications can be enabled in General and require macOS permission.

The app has six separate tabs: Current Wallpaper, Filters, Displays & Rotation, Downloads & Storage, My Preferences, and General. Ordinary settings require saving; API keys, likes, the recommendation toggle, and login items take effect immediately.

Closing the window keeps the app running in the menu bar, where you can change wallpapers, pause rotation, or reopen the window. Quitting stops rotation. The timer starts from launch, pauses during sleep, and performs at most one overdue rotation after waking.

## Resolution and multiple displays

- Reads the pixel dimensions of each display's current mode, including Retina and portrait displays.
- Requires both image dimensions to meet or exceed the display dimensions, with an aspect-ratio difference of no more than 6%. Uses centered filling without upscaling small images.
- Supports either the primary display or all displays, searching and applying images separately for each.
- Regular searches inspect up to three pages per display. Personalized searches may first try one additional preference-based page. Images from the last 30 history entries are excluded. If no new match is found, the current wallpaper is retained.
- Uses `NSWorkspace` to set wallpapers on the current display desktops. Synchronization across every macOS Space or the lock screen is not guaranteed.
- Turning off NSFW excludes it from subsequent selections and in-app history previews. An image already on the desktop stays there until another wallpaper is applied.

## Likes and personalized recommendations

Click the heart on Current Wallpaper or a history entry to like or unlike an image. **My Preferences** shows your collection, learned tags, keywords and categories, and a toggle for personalized recommendations.

Likes are stored locally in the app’s `library.json` archive. They are not synchronized with your Wallhaven account and are independent of the 300-entry history limit. Liking the same image again does not increase its weight. Unliking rebuilds the profile from the remaining likes.

The app fetches tags and categories from the wallpaper details endpoint. New history entries also retain the search query used at the time. Only positive keywords are learned; exclusions, usernames, and query operators are ignored. Version 1.0 history has no search keywords, so those likes learn from actual tags and categories instead of assuming your current query was used.

When personalization is enabled and a usable profile exists:

- Each selection has an 80% probability of following preferences and a 20% probability of random exploration. This is not a fixed four-out-of-five schedule. With no usable likes or personalization disabled, selection stays random.
- The score is **tag similarity ×6 + keyword match ×3 + category preference ×1**. Tags and keywords use the strongest matching frequency, normalized against the profile's highest frequency; categories use their share of likes. Ties are randomized.
- An explicit search query is preserved. With an empty query, the app samples a liked tag or keyword by weight; if only category information is available, it prefers that category. If the preference search finds no match, it falls back to the original filters.
- Each candidate batch enriches at most six images with detail metadata before ranking. This can add several seconds. Details are cached in memory. The preference search checks one page, and the original search checks up to three pages.
- Resolution, content ratings, category filters, and recent-image exclusions continue to apply. Likes outside the currently enabled ratings or categories do not contribute to the profile. Collections with disabled content ratings are hidden.
- If fetching a liked image's details fails, the like is retained and can be retried. If candidate details are unavailable, ranking falls back to available category data. Requests share a rate limiter.

Changes to likes or the recommendation toggle apply when the next selection starts. A selection already in progress is not recalculated.

## Credentials and local files

API keys are stored in macOS Keychain under service `cc.wallpaperi.mac` and account `wallhaven-api-key`. Requests use the `X-API-Key` header and an ephemeral URLSession without a disk cache. Keys are not included in URLs, ordinary configuration files, or app logs.

Sandbox builds store settings, the latest 300 history entries, likes, and security-scoped folder bookmarks in `~/Library/Containers/cc.wallpaperi.mac/Data/Library/Application Support/Wallpaperi/library.json`. Updates replace this archive atomically. History and likes include local image paths, but not the API key.

Downloads use temporary files followed by an atomic move, with a 100 MB limit per image. Only HTTPS JPG/PNG downloads from the Wallhaven image host are accepted.

Changing the download folder does not move existing files. The app does not automatically delete downloaded images. Moving or deleting files in Finder may make their previews unavailable. Completed downloads may remain after cancellation or a partial multi-display failure.

## Upgrading to the sandbox build

In **Downloads & Storage**, choose **Import Legacy Data** and select `~/Library/Application Support/Wallpaperi` using the system picker (Command-Shift-G opens a path field). Import replaces settings, merges history and likes without duplicates, pauses rotation, and preserves the source files. An existing destination archive is backed up before replacement.

Select the old wallpaper download folder again to grant access, then save settings and re-enable rotation. Older image folders can also be authorized from their unavailable previews. Import does not transfer folder permissions or API keys. The Keychain service and account are unchanged; a signing identity change may require system approval or entering the key again.

## Development and builds

Use Xcode or a Swift 5.9+ development environment with the macOS SDK.

```sh
swift test
bash scripts/build-app.sh
open dist/Wallpaperi.app
```

You can also open `Package.swift` in Xcode. Verify notifications and login items using the packaged `.app`, rather than running the bare Swift executable.

Optional environment variables:

| Variable | Purpose |
| --- | --- |
| `WALLPAPERI_SANDBOX=0` | Explicitly build without App Sandbox for local development; packaged builds enable it by default. |
| `WALLPAPERI_BUILD_DIR` | Build cache directory; defaults to `.build`. |
| `WALLPAPERI_SIGN_IDENTITY` | Signing identity; defaults to `-` for local ad-hoc signing. Public distribution requires your own Developer ID signing and notarization. |
| `WALLPAPERI_DISABLE_BUILD_SANDBOX=1` | For environments where an outer sandbox prevents SwiftPM's nested build sandbox. |

The output targets the build machine's CPU architecture. The source can be rebuilt on an Intel Mac.

## Verification

```sh
# Offline tests; the live test is skipped by default
swift test

# Public SFW search, temporary downloads, metadata, and recommendation integration
# Does not change the desktop wallpaper
WALLPAPERI_LIVE_TEST=1 swift test

# Packaged app launch check; exits after approximately two seconds
dist/Wallpaperi.app/Contents/MacOS/Wallpaperi --smoke-test
```

Tests cover request encoding, API key headers, content ratings, landscape and portrait resolution matching, duplicate filtering, error handling, like persistence, unliking, legacy data compatibility, preference ranking, and recommendation fallback. The live test cleans up its temporary downloads.

Your environment still needs verification of API key and NSFW account permissions, actual wallpaper application, multiple displays, notification authorization, and login items. A fresh installation does not automatically change the wallpaper on first launch.

### Version 1.2 verification — October 3, 2026

All 40 tests passed, including live SFW integration and nine storage/migration tests. The sandboxed release build and signature verification passed. Packaged-app checks confirmed external folder read/write after a fresh process launch, network download, isolated Keychain operations, and wallpaper change/restore on a 5120×2880 display. The production ticker continued with its window hidden; a separate hidden-window wallpaper change/restore also passed.

Multiple-display hardware testing, installed/signed login startup, and access to an existing Keychain credential after a signing identity change remain unverified. This is a sandbox implementation, not a completed App Store submission. See [sandbox validation](docs/sandbox-validation.md) for repeatable checks and limitations.

## Image attribution

Images belong to their original creators. The **Source** link in history and favorites opens the original Wallhaven page.
