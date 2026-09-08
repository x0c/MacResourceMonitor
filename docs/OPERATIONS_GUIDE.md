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

## 覆盖安装

产物：`build/DerivedData/Build/Products/Release/Mac Resource Monitor.app`

仅在「应用程序」可无交互写入时：

```bash
rm -rf '/Applications/Mac Resource Monitor.app'
ditto 'build/DerivedData/Build/Products/Release/Mac Resource Monitor.app' '/Applications/Mac Resource Monitor.app'
open '/Applications/Mac Resource Monitor.app'
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
| 右键菜单栏图标完全没反应 | 左键仍开表；拆双状态项后用手势识别右键 | 改回 `sendAction` 左右键抬起 + 临时挂菜单；见菜单栏知识库路径三排错结论 |

## 未替代的验收

签名、公证、DMG、GitHub Release、Homebrew、在线更新、真实结束进程 → 须按发行 / 领域流程另验。

<!-- 该文档整理/压缩于 2026-09-05 -->
