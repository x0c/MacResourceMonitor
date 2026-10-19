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
