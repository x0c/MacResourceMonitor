<!-- managed:inherited-agents:start -->
<!-- source: /Users/geraltgraham/Codes/MacResourceMonitor/AGENTS.md -->
# Mac Resource Monitor

通用工程规范：[Swift 规范](/Users/geraltgraham/Codes/_standards/swift.md)

Mac Resource Monitor 是本机极简资源表：一眼看到哪些应用占用整机 CPU、内存或网络，并可立即结束。

## 组件一览

| 目录 | 说明 | 状态 |
|---|---|---|
| `app-macos/` | macOS 客户端（独立 git 仓库） | 已交付，已公开开源 |

Remote：`app-macos` → GitHub 公开 [`x0c/MacResourceMonitor`](https://github.com/x0c/MacResourceMonitor)；Forgejo 私有镜像只留在本机 `git remote origin`，**禁止**把内网地址写进仓库。本产品文件夹不是 git 仓库。

**【裁定 2026-08-30】** 面向公众开源到 GitHub `x0c/MacResourceMonitor`。许可证 MIT。只支持 macOS（绑定本机进程身份、菜单栏与结束 API）。第一次公开发布就必须带齐签名公证安装包、应用内自更新、一键安装，不允许「先公开源码、发行以后再补」。更新清单和安装包发在源码仓自己的 Release，禁止另建更新仓。公开仓用当前树的干净快照历史，不要把私有开发史上的内网地址推上去。

## 钉死的体验

- **【裁定 2026-09-08 · 执行】正式产品名 Mac Resource Monitor**；身份、公开仓、一键安装与本机产品根目录的零残留映射见 [app-macos/docs/PRODUCT_CONTRACT.md](app-macos/docs/PRODUCT_CONTRACT.md)。
- 极简平表：图标、人话名、整机 CPU%、内存%、结束。不要进程树，不要展开孩子。
- **菜单栏应用**：程序坞没有图标，没有常驻桌面进程表工作区。左键打开点开结束的表，表出现在菜单栏图标正下方，点外面关；右键才是开机自启 / 打开主窗口 / 设置 / 检查更新 / 退出。**图标即主入口：禁止隐藏菜单栏图标**（菜单与设置都不得提供该项；启动强制图标可见）。禁止把菜单常挂在状态项上。禁止因拿不到图标坐标而掉到屏幕角落。设置窗仅作偏好与「打开主窗口」入口，**不是**藏图标后的恢复面。
- **【裁定 2026-09-05】登录项静默**：开机自启拉起时只后台就绪，禁止自动弹出设置窗 / 恢复窗；用 MacKit `LoginLaunchDetector.isLaunchedAsLoginItem` 传入 `MenuBarReopenPolicy`。
- 表顶有**冻结**开关（英文 Freeze / 中文冻结），默认关；打开后名单顺序尽量不动、数字仍刷新，点列头排序会自动关冻结。菜单栏双环继续刷新。CPU/内存表收起后面板名单不更新；网络表后台预热，打开不得出现加载屏。鼠标停在某一行的结束符号上时，这一行钉在原位，避免刷新跳动误杀。表头 CPU / 内存列写出整机汇总（如 `CPU 88.8%` `Mem 68.8%`），点对应列在两种从高到低之间切换，没有升序。表头不许留出大块空白。
- 开机自启默认关。不上 App Store。关沙盒。不要申请辅助功能或完整磁盘访问。
- 中英文案。无系统蓝框。分层应用图标 + 菜单栏模板图标。

人话名、整机占比、结束边界的权威说明见产品契约。

## 基线豁免

合法暂缓：

- **A2** 隐私清单：不收集、不上报用户数据。
- **A5** 桌面进程表工作区的位置记忆：不适用。设置窗（打开主窗口 / 偏好）仍须按基线保存并恢复位置与尺寸。
- **B2** 全局快捷键：唤出不是靠热键，不适用。
- **B3** 账号登录：纯本地工具，无账号。
- **B5** App Intents：第一波没有要交给快捷指令的无人值守动作。
- **B7** 离线优先：无网络数据。

**A1 不再豁免。** 公开仓库的 macOS 图形应用必须具备 Developer ID 签名、公证 dmg、Sparkle 应用内自更新、Homebrew 一键安装。发版走 `app-macos/scripts/publish-release.sh`。

**下列不是豁免，必须过：** A3 中英、A4 无蓝框、A7 分层图标与菜单栏模板、A8 版本双轨、B1 开机自启开关且默认关、关沙盒。禁止用「第一波能编译」覆盖立刻可见条款。禁止再加回桌面进程表工作区；禁止提供隐藏菜单栏图标。

## 明确不做

做成 Stats / iStat 那种只看温度没有结束的菜单栏；再加一个桌面进程表工作区或程序坞常驻图标；做成可展开进程树；做成第二个 Corral；上 Mac App Store；开沙盒；申请辅助功能 / 完整磁盘访问；用 Java；做 Windows / Linux 客户端；提供「隐藏菜单栏图标」。

## 文档导航

- [~/.config/agentsync/docs/MACOS_APP_DEVELOPMENT_GUIDE.md](~/.config/agentsync/docs/MACOS_APP_DEVELOPMENT_GUIDE.md)：改、评审或排查 Mac Resource Monitor 的菜单栏图标、开机自启动（含登录静默）、设置窗或检查更新前**必读**。不读会在登录时弹出设置窗，或误加回「隐藏菜单栏图标」。
- [app-macos/AGENTS.md](~/Codes/MacResourceMonitor/app-macos/AGENTS.md)：改、评审或排查 macOS 客户端工程、菜单栏浮层、进程表、结束、覆盖安装、公开开源或发版前**必读**。不读会加回桌面进程表工作区、把菜单挂到左键上、开沙盒导致进程表空，覆盖安装把签名装坏，或把内网地址推进公开仓。
- [app-macos/docs/PRODUCT_CONTRACT.md](~/Codes/MacResourceMonitor/app-macos/docs/PRODUCT_CONTRACT.md)：讨论、选择或执行产品命名/重命名，或改、评审、排查菜单栏图标/模板图、两行网速、网速左侧空白/刷新抖动、自动识别当前网卡、隐藏图标、恢复窗口、开机自启三态及任何其他用户可见行为（人话名折行、名字列过宽、长包名省略、Chrome 显示成 `Goog...rome`、长名字减小字体、前缀省略、中间省略、整机占比、刚开机内存六十多、表头汇总、点列名排序、表出现在图标下方、掉到屏幕角落、结束边界、菜单栏点开/点外面关、冻结开关 Freeze/冻结、表头顶空白、结束符号悬停钉行、检查更新入口、进程表仍显示旧图标/粉底黑叉、网络表字号色阶、网络表加载屏、网络表名单秒级闪烁/Chrome 进进出出）前**必读**。不读会沿用已经失真的旧名称、把已锁体验改掉、把网速算到错误网卡上、把开机六十当泄漏去改口径、把 ChatGPT/Cursor Agent/Corral 显示回 node/Python、把隐藏图标后的恢复面做成进程表、把系统还在吐旧图当成图标没装进去去重做、把防抖又预留四位数字导致左侧大空白，或把短暂无流量的网络行秒级踢出名单。
- [~/Codes/_standards/swift.md](~/Codes/_standards/swift.md)：新建、评审或改造本 macOS 应用前**必读**。不读会偏离 Swift 6 并发基线和覆盖安装闭环。
- [~/Codes/_standards/workspace-docs/swift-docs/macos-app-baseline.md](~/Codes/_standards/workspace-docs/swift-docs/macos-app-baseline.md)：脚手架、评审完整度、补分发/开机自启/设置窗前**必读**。不读会把「第一波能跑」当成完成，或把未对外发行的暂缓当成可以永久不做。
- [~/.config/agentsync/docs/MAC_PROCESS_IDENTITY_KNOWLEDGE_BASE.md](~/.config/agentsync/docs/MAC_PROCESS_IDENTITY_KNOWLEDGE_BASE.md)：改人话名、责任进程、整机 CPU%、折行规则前**必读**。不读会做成进程树或按 Unix 父进程建树。
- [app-macos/docs/PROCESS_MONITORING_AND_TERMINATION_KNOWLEDGE_BASE.md](~/Codes/MacResourceMonitor/app-macos/docs/PROCESS_MONITORING_AND_TERMINATION_KNOWLEDGE_BASE.md)：改、评审或排查实时占用、人话名、排序、刷新、结束权限或终止流程前**必读**。不读会把整机口径、平表聚合或安全结束边界改错。
- [app-macos/docs/MENU_BAR_INTERACTION_KNOWLEDGE_BASE.md](~/Codes/MacResourceMonitor/app-macos/docs/MENU_BAR_INTERACTION_KNOWLEDGE_BASE.md)：改、评审或排查菜单栏左右键、浮层锚定、网速、后台网络采样、`nettop` 高占用、风扇狂转、隐藏图标、恢复窗口、开机自启或退出前**必读**。不读会让左键误弹菜单、面板掉到角落、隐藏后无稳定入口，或把采样子进程的高 CPU 漏算成系统负载。
- [app-macos/docs/DISTRIBUTION_AND_UPDATE_KNOWLEDGE_BASE.md](~/Codes/MacResourceMonitor/app-macos/docs/DISTRIBUTION_AND_UPDATE_KNOWLEDGE_BASE.md)：改、评审或排查构建、签名、公证、应用内更新、GitHub Release、Homebrew，或公开仓 **GitHub About / Topics / README 门面检索**前**必读**。不读会把工程源、版本、签名链或公开发行边界改坏，或只改 README 却声称站内 SEO 已完成、用「进程表」当检索词、把近失当成搜不到去改名。
- [app-macos/docs/OPERATIONS_GUIDE.md](~/Codes/MacResourceMonitor/app-macos/docs/OPERATIONS_GUIDE.md)：构建、测试、启动、覆盖安装、浮层截图验收或排查本机开发环境前**必读**。不读会在错误仓根构建、误把测试通过当安装验收、覆盖错误版本，或因状态栏浮层截不到图而误判界面没出来。

## 领域地图（doc-init）

<!-- 覆盖度复核基线：2026-09-04 · 源码指纹 扫描 139 文件 / Swift 28 / 0 子模块 -->

| 领域 | 入口锚点 |
|------|---------|
| 实时占用与结束 | app-macos/MacResourceMonitor/Services/ · app-macos/MacResourceMonitor/Models/ · app-macos/MacResourceMonitor/Views/ProcessTableView.swift · app-macos/MacResourceMonitor/Views/ProcessRowView.swift · app-macos/MacResourceMonitorTests/ProcessTableRankingTests.swift |
| 菜单栏操作与恢复 | app-macos/MacResourceMonitor/AppDelegate.swift · app-macos/MacResourceMonitor/StatusItem/ · app-macos/MacResourceMonitor/App/ · app-macos/MacResourceMonitor/Views/SettingsView.swift |
| 安装、更新与公开发布 | app-macos/project.yml · app-macos/Configuration/Base.xcconfig · app-macos/scripts/publish-release.sh · app-macos/appcast.xml |

<!-- managed:inherited-agents:end -->

# Mac Resource Monitor（macOS）

本仓库是 Mac Resource Monitor 的 macOS 客户端。产品级约定见上级 [../AGENTS.md](../AGENTS.md)。用户可见行为以 [docs/PRODUCT_CONTRACT.md](docs/PRODUCT_CONTRACT.md) 为准。

## 本机状态（摘要）

当前覆盖安装以 `project.yml` / `Base.xcconfig` 版本为准。圆环与网速已拆成两个独立 `NSStatusItem`（先加网速项、后加圆环项 → 圆环在左、网速在右）；圆环项只进 CPU/内存表，读数项只进网络表；网络表默认 Download 降序。登录项拉起必须静默。细节权威在产品契约与菜单栏知识库，勿在本段堆发版流水。

## 工程源

- [`project.yml`](project.yml) 是 Xcode 工程唯一来源；改后 `xcodegen generate`。
- `Assets.xcassets` 与 `Localizable.xcstrings` 须进 sources 随编译打进包；字符串目录须 `"version": "1.0"`。
- Bundle ID：`top.caozc.MacResourceMonitor`。展示名：Mac Resource Monitor。版本双轨在 `Configuration/Base.xcconfig` 与 `project.yml`。
- 公开 GitHub：`x0c/MacResourceMonitor`（MIT）。Homebrew：`x0c/tap` 的 `mac-resource-monitor`。

## 钉死的实现约束

- **菜单栏应用**：`LSUIElement`；禁止桌面进程表工作区、程序坞常驻、隐藏菜单栏图标。设置窗独立；打开临时普通激活，关掉改回附件。
- **关窗不退出**：`applicationShouldTerminateAfterLastWindowClosed` = false。退出只走「退出」→ `requestTermination`。Sparkle 安装更新时必须放行终止。
- **关沙盒**（entitlements 空 dict）。禁止辅助功能 / 完整磁盘访问。
- **禁止把菜单挂到状态项**：左键开表；右键开机自启 / 显示网速 / 打开主窗口 / 设置 / 检查更新 / 退出。
- **浮层形态 1**：点外关；列表实底；表锚在图标正下方。图标坐标假（宽高 0 / 不在菜单栏带）→ 禁止用假位置，等一拍再开。
- **冻结开关**（Freeze / 冻结，默认关）稳住名单顺序与成员，数字仍刷；双环与表头汇总继续刷。点列头排序自动关冻结。CPU/内存表收起不刷可见名单；网络表后台预热，禁止加载屏。不要在 `ProcessTableView` 创建即开刷。
- **结束符号悬停钉行**；钉死只针对结束符号。
- **表头**：`CPU 88.8%` / `Mem 68.8%`；点列仅从高到低；CPU 行加总上限 100%；内存读系统级物理占用，禁止行相加。
- **平表**：禁止进程树。同一桌面应用下助手折进该行；Cursor.app 对外部命令按终端处理。
- **人话名**：优先启动参数；`dlsym("responsibility_get_pid_responsible_for_pid")`，失败退包路径。参数按 pid+启动时刻缓存。
- **CPU**：Δ(user+system)/(墙钟秒×逻辑核)×100，上限 100%。Apple Silicon 须乘 timebase。
- **内存**：物理占用账本/物理内存×100，不要 resident。
- **CPU 外环**：无效样本保留上一帧；真实 0% 仍空环。
- **结束**：单行与表头批量都直接 SIGKILL；表头 `×` 必须二次确认并排除本应用。只结束当前用户；系统进程禁止一键杀；每次发信号前仍按 PID+启动时刻与路径复核身份。WindowServer 等 argv0=短名禁止当具名工具放开。
- **无系统蓝框**；开机自启默认关（三态）；登录静默（`LoginLaunchDetector` + `MenuBarReopenPolicy`）。
- **公开仓脱敏**：禁止内网地址、本机绝对用户路径进 GitHub。

## 构建与覆盖安装

```bash
xcodegen generate
xcodebuild -project MacResourceMonitor.xcodeproj -scheme MacResourceMonitor -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build
rm -rf "/Applications/Mac Resource Monitor.app"
ditto "build/DerivedData/Build/Products/Release/Mac Resource Monitor.app" "/Applications/Mac Resource Monitor.app"
xattr -dr com.apple.quarantine "/Applications/Mac Resource Monitor.app" 2>/dev/null || true
open "/Applications/Mac Resource Monitor.app"
```

要管理员密码：免密失败立刻停。对外发版：`scripts/publish-release.sh`（发版前 `leakgate.py scan --profile public`）。首次安装：GitHub Release 公证 dmg 或 `brew tap x0c/tap && brew install --cask mac-resource-monitor`；更新源 `appcast.xml`。

## 基线豁免

见上级产品 `AGENTS.md`。A1 已具备。A3/A4/A7/A8/B1/关沙盒不是豁免。桌面进程表不适用 A5；设置窗仍须按 A5 记位置。

## 文档导航

- [docs/design/APP_ICON_EXPLORATION.md](docs/design/APP_ICON_EXPLORATION.md)：重绘/接入应用图标或排查粉底黑叉前必读。不读会把探索稿当终稿或误判缓存。
- [docs/PRODUCT_CONTRACT.md](docs/PRODUCT_CONTRACT.md)：改任何用户可见行为前必读。不读会改掉已锁体验。
- 本机 overlay / 玻璃 / 图标 / 本地化 / 设置项：`~/Codes/_standards/workspace-docs/swift-docs/`。
- 进程身份：`~/.config/agentsync/docs/MAC_PROCESS_IDENTITY_KNOWLEDGE_BASE.md`。
- [docs/PROCESS_MONITORING_AND_TERMINATION_KNOWLEDGE_BASE.md](docs/PROCESS_MONITORING_AND_TERMINATION_KNOWLEDGE_BASE.md)：改占用/人话名/结束前必读。
- [docs/MENU_BAR_INTERACTION_KNOWLEDGE_BASE.md](docs/MENU_BAR_INTERACTION_KNOWLEDGE_BASE.md)：改、评审或排查菜单栏、浮层、网速、后台网络采样、`nettop` 高占用或风扇狂转前**必读**。不读会把采样子进程的高 CPU 漏算成系统负载，或为了首开无加载屏而每秒启动高开销进程。
- [docs/DISTRIBUTION_AND_UPDATE_KNOWLEDGE_BASE.md](docs/DISTRIBUTION_AND_UPDATE_KNOWLEDGE_BASE.md)：改构建/签名/公证/更新，或改公开仓 **GitHub About / Topics / README 门面检索**前**必读**。不读会只改 README 却声称站内 SEO 已完成，或用「进程表」当检索词、把近失当成搜不到去改名。
- [docs/OPERATIONS_GUIDE.md](docs/OPERATIONS_GUIDE.md)：本地构建/覆盖安装/浮层截图排障前必读。

## 领域地图（doc-init）

<!-- 覆盖度复核基线：2026-09-04 · 源码指纹 扫描 137 文件 / Swift 28 / 0 子模块 · 基线提交 f2830e8 -->

| 领域 | 入口锚点 |
|------|---------|
| 实时占用与结束 | MacResourceMonitor/Services/ · MacResourceMonitor/Models/ · MacResourceMonitor/Views/ProcessTableView.swift · MacResourceMonitor/Views/ProcessRowView.swift · MacResourceMonitorTests/ProcessTableRankingTests.swift |
| 菜单栏操作与恢复 | MacResourceMonitor/AppDelegate.swift · MacResourceMonitor/StatusItem/ · MacResourceMonitor/App/ · MacResourceMonitor/Views/SettingsView.swift |
| 安装、更新与公开发布 | project.yml · Configuration/Base.xcconfig · scripts/publish-release.sh · appcast.xml |
