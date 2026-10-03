# Sandbox validation / 沙盒验证

Version 1.2.0, tested October 3, 2026 on arm64 macOS with one 5120×2880 display.

## Reproduce

```sh
WALLPAPERI_LIVE_TEST=1 swift test
bash scripts/build-app.sh
codesign --verify --deep --strict dist/Wallpaperi.app
codesign -d --entitlements :- dist/Wallpaperi.app

# Authorize a test folder using the native picker.
open -n -W --stdout /tmp/wallpaperi-first.log dist/Wallpaperi.app --args --sandbox-check --select-test-folder

# A new process must resolve the saved bookmark without another picker.
open -n -W --stdout /tmp/wallpaperi-relaunch.log dist/Wallpaperi.app --args --sandbox-check
```

Diagnostics use `Application Support/Wallpaperi/SandboxChecks` inside the app container, separate from the real library. The report is saved as `report.json`; inspect individual PASS/FAIL/SKIP outcomes, not just the process exit code. The test folder receives one temporary file which is removed. Network downloads and generated test images remain in the isolated diagnostic directory. Test folder authorization applies to diagnostics only; select a production download folder separately in the app.

Wallpaper checks briefly change each detected display and restore its original image and options. They skip if the original cannot be read safely. Select a folder containing the current wallpaper to permit restoration. The Keychain check creates and deletes a random test item without reading the user's API key. The login-item check leaves existing registrations unchanged; otherwise it attempts registration and cleanup.

## Results

| Check | Result |
| --- | --- |
| Complete Swift suite, including live SFW integration | 40 passed, 0 failures |
| Migration, corrupt archive protection, duplicate merging, folder boundary checks | 9 storage tests passed within the suite |
| Packaged App Sandbox entitlement and release signature | Passed; local ad-hoc signature |
| Container state round trip | Passed |
| External bookmark read/write in first and fresh second process | Passed after native picker authorization |
| Unapproved folder | Rejected by the application's access guard |
| Public SFW search and image download inside sandbox | Passed |
| Isolated Keychain add/read/delete | Passed |
| Display detection and wallpaper change/restore | Passed on one 5120×2880 display |
| Hidden-window production ticker | Passed, 6 ticks at diagnostic 100 ms interval |
| Hidden-window wallpaper change/restore | Passed separately from the ticker |
| Two or more physical displays | Pending; only one display available |
| Login item | Skipped: SMAppService reported unavailable for this local installation |

The accelerated ticker and separate wallpaper check do not establish an unattended full 5-minute rotation, sleep/wake cycle, or reboot/login result. Those remain manual acceptance checks. Migration uses fixtures; the user's actual legacy library was not imported or altered by these tests.

## Remaining release checks

Install an appropriately signed build in Applications, then verify login registration and an actual logout/login. Test full automatic rotation, sleep/wake, and connecting/disconnecting a second display. Verify notification permission and a real account's required content access. With the final signing identity, verify the existing Keychain item or re-enter the key through General; no credential is exported during migration.

For migration acceptance, import a copy of a legacy data directory through Downloads & Storage, check settings/history/likes, authorize its wallpaper directory, save, quit, and reopen. Confirm previews and rotation work and source files remain intact. A stale or invalid folder authorization should request reselection rather than silently download elsewhere.

中文说明：已完成真实沙盒下的目录授权跨进程重启、联网、测试钥匙串、单屏壁纸更换与恢复验证。尚未实测多屏、真实登录启动、完整轮换/休眠周期及最终签名下的旧钥匙串访问。测试目录授权与正式下载目录授权分开保存；本次测试未迁移或修改用户真实设置、历史、点赞和 API Key。
