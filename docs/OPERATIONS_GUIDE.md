# 本地构建与验证 Guide

覆盖：本地工程生成、构建、测试、覆盖安装与基础运行确认。不覆盖：进程识别、菜单栏交互、发布渠道（见对应知识库与产品契约）。

## 本地启动前检查

- Git 仓是 `app-macos/`；外层 MacResourceMonitor 目录不是 Git 工作树。
- `project.yml` 是 Xcode 工程唯一来源；改源文件清单 / 资源 / 构建设置后须 `xcodegen generate`。
- 构建依赖 Sparkle 与 MacKit；无缓存时需可用包下载环境。
- 版本 / 签名 / 公开发行见 [DISTRIBUTION_AND_UPDATE_KNOWLEDGE_BASE.md](DISTRIBUTION_AND_UPDATE_KNOWLEDGE_BASE.md)。

## 构建与测试

在 `app-macos/`：

```bash
xcodegen generate
xcodebuild -project MacResourceMonitor.xcodeproj -scheme MacResourceMonitor -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData build
```

回归测试用独立派生目录：

```bash
xcodebuild -project MacResourceMonitor.xcodeproj -scheme MacResourceMonitor \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/mac-resource-monitor-derived-data test
```

改菜单栏 / 进程表 / 网速后，仍要跑受影响的完整测试组。自动测试通过 ≠ 安装版菜单栏 / 结束 / 签名验收。

**保留警告（2026-10-19 评估）**：`appintentsmetadataprocessor … Metadata extraction skipped, no AppIntents.framework dependency found` 来自 Xcode 构建步骤，不是源码诊断。来源：本应用不链接 App Intents（基线 B5 豁免）。风险：无。后续：只有真的接入 App Intents 时这条才会消失，不要为了消警告去加空依赖。其余 Swift 编译警告应为零。

## 覆盖安装

Official install artifact: `build/Export/Mac Resource Monitor.app`, produced by `scripts/publish-release.sh` through universal archive and Developer ID export. The ordinary development build path above is not the installable distribution artifact. Commit source before replacement; verify the export signature and installed version after copying.

仅在「应用程序」可无交互写入时：

```bash
rm -rf '/Applications/Mac Resource Monitor.app'
ditto 'build/Export/Mac Resource Monitor.app' '/Applications/Mac Resource Monitor.app'
open '/Applications/Mac Resource Monitor.app'
sleep 1; ~/.local/bin/mrm version # 应用启动时已把包内 mrm 链到 ~/.local/bin
```

要管理员授权 → 立刻停，禁止弹图形授权。禁止用 Debug / 临时签名覆盖 Developer ID 安装版。

## 存活与用户可见验证

- 启动后：菜单栏双环；左键 → 图标正下方进程表；右键 → 设置 / 开机自启 / 检查更新 / 退出（无隐藏图标）。
- 视觉、真实结束、覆盖安装版本与更新链路按相关知识库实测。
- **【排错】菜单栏浮层截图**：权威见全局 [macOS 应用开发指南 · 交付前专项验收第 8 条](~/.config/agentsync/docs/MACOS_APP_DEVELOPMENT_GUIDE.md) 与 skill `macos-window-screenshot`。本产品浮层是状态项左键面板；不要因 winshot 列不出而误判没显示，也不要为迁就截图改窗口层级。

## 常见失败

| 现象 | 优先检查 | 下一步 |
|---|---|---|
| 工程与源码不同步 | 改过 `project.yml` 未 regenerate | `xcodegen generate` 后重建 |
| 陈旧中间产物 | 派生目录与并行构建共用 | 独立 `-derivedDataPath` |
| 安装后旧图标 / 旧版本 | 未整包替换 | 删旧应用后完整复制再启动 |
| 菜单栏应用「消失」 | 图标被藏、恢复窗未出 | 从应用程序 / Spotlight 再开，确认恢复窗 |
| 悬停结束符号瞬间闪退 | 崩溃报告 `SIGABRT` + `_swift_reportExclusivityConflict`，栈在钉位悬停 | 先算可见索引再改钉位；见进程监控知识库 §2.5 与 `_standards/.../macos-appkit-gotchas.md` |
| 收起网络表 / 预热结束瞬间闪退 | 崩溃报告 `EXC_BREAKPOINT` + `Index out of range`，栈顶 `NettopStreamSampler.handleChunk` 第 124 行（`fd_monitoring` 队列） | 长驻 nettop 流的缓冲必须全程持锁，`stop()` 的 `closeFile()` 移锁外；见菜单栏知识库【排坑 2026-09-13】 |
| 进程表顶上两行黑图标名叫「0」、各约 17% CPU、内存 0 | 本应用留下的按进程网速采样已脱离，参数 `0` 被当成名字 | 先停掉无主采样；退出必须同步停采；启动清残留；见菜单栏知识库【排坑 2026-09-19】 |
| 右键菜单栏图标完全没反应 | 左键仍开表；拆双状态项后用手势识别右键 | 改回 `sendAction` 左右键抬起 + 临时挂菜单；见菜单栏知识库路径三排错结论 |

## 未替代的验收

签名、公证、DMG、GitHub Release、Homebrew、在线更新、真实结束进程 → 须按发行 / 领域流程另验。

<!-- 该文档整理/压缩于 2026-09-05 -->

## Native Settings acceptance (2026-10-19)

The primary inspected all four actual Debug Settings windows: English/Chinese in light/dark, 480 × 234, without scrolling, clipping or custom focus frames. The full app name, version, both native switches and update/quit buttons fit. Dark inspection uses the Debug-only public application appearance override, not a system appearance change; Release omits that flag. Explicit application reopen exercised the native Settings presenter. The Debug build, static analysis and all 80 existing tests pass with complete diagnostics at `/tmp/mac-resource-monitor-settings-validation-final.log`; the only warning is the App Intents tooling notice assessed above. This is static layout evidence under lock: physical keyboard/Escape/VoiceOver, real pending-login approval and live toggle behavior remain unverified. Neither login nor network preferences were changed for capture.

Universal Release 1.1.7 (43), built from `aa13e01390c17e0708389fb7540f736ac58d4a40`, passed archive/export and individual Developer ID, timestamp, hardened-runtime and debug-entitlement checks, including the embedded `mrm`. The archive's only warning is the assessed App Intents tooling notice. The final stapled app was installed and both English/Chinese light Settings inspected again at 480 × 234. Its CLI returns `mrm 1.1.7 (43)`; strict signature and stapled-ticket validation pass. Release dark remains represented by the Debug evidence, not a claimed installed-dark pass.

The public [1.1.7 release](https://github.com/x0c/MacResourceMonitor/releases/tag/v1.1.7) contains both notarized DMG and signed update ZIP. Complete anonymous downloads match the local artifacts (DMG SHA256 `e35d59ba83e92c17a5a1789a663a7d715ec883ee1a0789975620a458311a8f64`, ZIP `012b74d95fde26e0e5fe24d1fddc5eac7f99d18973bfa4346c40d79c22945d3d`). The live signed feed serves build 43 and Homebrew cask 1.1.7 matches that DMG. Upload returned HTTP 422 / `ReleaseAsset.name already exists` even though both assets had completed; recovery verified the public bytes before continuing the cask/feed checks, without rebuilding or resubmitting notarization. Detached receipt: `build/settings-release-1.1.7/receipt-post-upload.json`.

## Local CPU optimization acceptance (2026-11-12)

Source `a3fea3a` passed all 91 native Debug tests and the arm64/x86_64 Release
archive/export. All seven exported Mach-O components have the existing Developer
ID team, a secure timestamp and hardened runtime; installed strict signature
verification passes. The only build warning is the assessed App Intents tooling
notice above. This local source build retains version 1.1.7 (43); identify it by
the source commit and executable hashes in the private receipt, not version alone.

Fresh installed CPU-table captures show changing readings and membership. Fresh
network-table captures show changing nonzero rates; reopening retains a populated
table, and explicit collapse stops its nettop child within two seconds. More than
60 seconds after collapse there is no nettop process. Acceptance did not exercise
row/bulk termination or change preferences.

Thirty-second unsampled process-time observations measured 13.73% of one core in
the previous hidden app, 6.67% in the new hidden app, and 15.45% with its CPU table
open. Concurrent system activity changed, so these are field observations, not a
controlled whole-process reduction. A separate 45,000-construction URL probe
measured 0.1433 s CPU with implicit directory detection versus 0.0414 s with the
explicit file type. This is one operation's cost, not total application CPU.

Full logs, installed executable hashes and original-size captures are retained
privately at `~/.config/top.caozc.MacResourceMonitor/development/cpu-20261112/`.
The previous signed application is retained there as `previous-installed.app` for
rollback. The install uses `build/CPUExport/Mac Resource Monitor.app`, an Xcode
Developer ID export from `build/CPUOptimization.xcarchive` with the same export
options as the release procedure. It is a local signed build; public release
assets and the update feed retain the previously published artifact.

## Local background CPU & network-table latency acceptance (2026-11-15)

Source `23f8c5b` passed all 97 native Debug tests (`testFirstLiveNetworkFrameArrivesSubSecond`
in 0.407 s) and the universal `arm64`/`x86_64` Release archive/export (`build/Export/Mac Resource Monitor.app`).
Strict signature, Developer ID team, secure timestamp, hardened runtime, and
debug-entitlement checks passed across the app bundle and all five nested Mach-O
components (`Mac Resource Monitor` SHA256 `d92b0a8f93d7f62f81a9d5c494a0a42deef2dc0333522dffb3bd492783b9dea8`,
`mrm` SHA256 `2185df68bec62e1dddc237b34b8c0cd7382bacda6f788baedff0b2c3735f970e`).
The only build warning is the assessed App Intents tooling notice above.

Installed `mrm version` returns `mrm 1.1.7 (43)` and `mrm doctor` completes across
782 PIDs in 26 ms; no Settings or recovery window opened on launch. Unsampled
hidden-process CPU dropped from 6.35% of one core (108.35 s / 1705 s pre-fix) to
3.795% over 59.72 s immediately post-launch on a three-display setup (`OF27UT Pro`,
`Color LCD`, `Sidecar Display`) during active multi-MB/s background traffic (`ps`
settling around 1.1%–2.5%). Five-second stack sampling confirmed `__proc_info` leaf
samples fell from 89 to 7 and hidden `ProcessTableView` SwiftUI layout samples fell
from 25 to 0; remaining active samples sit in AppKit's three-display
`-[NSStatusItem _updateReplicantsUnlessMenuIsTracking:]` when live network text changes.

Noninterfering `AXPress` verification confirmed sequential live updates on the CPU
table (`17.8%` → `18.1%`), populated live per-process rates (including root daemons
`mihomo` and `zerotier-one`) on a cold Network table open within 465 ms with no
loading screen, continued 1 s streaming updates (`network-panel-1500ms.png`), and
`nettop` child termination within 500 ms of collapse. Logs, rollback bundle
(`previous-installed.app`) and unresized captures are retained privately at
`~/.config/top.caozc.MacResourceMonitor/development/cpu-20261115/`.

## Local whole-machine CPU visibility acceptance (2026-11-16)

The whole-machine CPU header, cross-UID sampling, `kernel_task` remainder row,
Corral splitting and `pi (<workspace>)` rows passed all 107 native Debug tests and
the universal `arm64`/`x86_64` Release archive/export (`build/Export/Mac Resource Monitor.app`).
The only build warning is the assessed App Intents tooling notice. Strict signature
verification passes on the installed bundle; the installed app binary SHA256
`3dbdc86bc3ef283d6166dcb39dbb2596f8643b5042402d28651dc1b18c5698df` and `mrm`
SHA256 `02ab7665cf9a49a726b6963f8a6d7858830acfb27c889db2e5e6e45f23adcb8a`
match the export.

Installed 1.1.7 (43) from this tree, dark CPU-panel captures: one frame read
`CPU 100.0%` while `top -l 2` reported 0% idle (72.80% user + 27.19% sys) on the
same build; another read `CPU 40.0%` against 42.3% busy sampled two seconds later.
Frames show `kernel_task`, `WindowServer`, `spindump`, `sysmond` and `coreaudiod` as
locked system rows, `Corral`, `Corral TUI`, `Corral Remote`, `tmux`, `pi (NeatMark)`
and `pi (MacResourceMonitor)` as separate rows, and numbers differed between
successive captures. While the CPU table was open the app spawned `/bin/ps` three
times in a three-second poll at 26 ms per run on ~770 processes; with both tables
closed it spawned none in three seconds and used 0.37 s CPU over 12 s (3.1% of one
core). An earlier eight-second sample on this source used 11% of one core with the
CPU table open; a repeat on the final build was lost because another process closed
the panel mid-measurement.

Row/bulk termination, hover pinning and the network table were not exercised again;
their code paths are unchanged. Captures, logs and the export are retained privately
at `~/.config/top.caozc.MacResourceMonitor/development/cpu-20261116/`.

Follow-up refinement on this tree (2026-11-16): added a 3-sample (~2–3 s) rolling
`HOST_CPU_LOAD_INFO` window for header/ring stability, aligned `hostLoad` and
same-UID `PROC_PIDTASKINFO` after `/bin/ps` on monotonic `systemUptime`, capped
`kernel_task` at the unattributed system-space ceiling (`hostSystem - ownedSystem`),
preserved `pi` / `Cursor Agent` workspace labels from session-owner members when a
folded child leads CPU, and disambiguated generic subdirectory leaves (`Corral/cli`).
All 110 native Debug tests pass (zero Swift warnings; only the assessed App Intents
tooling notice). Universal Release `arm64`/`x86_64` archive/export (`Mac Resource Monitor`
SHA256 `a94c209542bcd440170edcbd4355afa0bc0e009c7e2241d22be833e74e26b2c7`, `mrm`
SHA256 `70672112b5282007ab34761ed08e7b0b56098bf5860354057044fb8d3aac6983`) passed strict
Developer ID signature verification and was overwrite-installed. Live panel captures
showed `CPU 52.0%` → `47.3%` with `kernel_task` (`6.2%`), `WindowServer` (`4.8%`),
`Corral`, `Corral Remote`, `pi (NeatMark)`, `pi (Codes)` and `Mac Resource Monitor`;
relaunching with panels closed recorded 0 `ps` spawns over 2 s.
