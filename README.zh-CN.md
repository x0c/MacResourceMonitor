**语言：** [English](README.md) | 简体中文

<p align="center">
  <a href="https://github.com/x0c/MacResourceMonitor/releases/latest">
    <img src="docs/images/app-icon.png" width="128" height="128" alt="Mac Resource Monitor 应用图标：圆角 CPU 芯片">
  </a>
</p>

<p align="center">
  <a href="https://github.com/x0c/MacResourceMonitor/releases/latest"><img src="https://img.shields.io/github/v/release/x0c/MacResourceMonitor" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-blue" alt="需要 macOS 26 或更高">
  <img src="https://img.shields.io/badge/License-MIT-orange" alt="MIT 许可证">
</p>

# Mac Resource Monitor

**菜单栏里的 macOS CPU 监视。** 电脑卡住时看清是谁在吃 CPU，再从菜单栏结束那个进程。

它不是 Stats，也不是活动监视器。没有温度风扇、没有进程树。点菜单栏图标，看到占用高的那一行，结束它。图标就是唯一日常入口，不可隐藏。

**需要 macOS 26 或更高。** MIT 开源。数据只留在这台 Mac 上——没有账号，没有遥测。

<p align="center">
  <a href="https://github.com/x0c/MacResourceMonitor/releases/latest">
    <img src="docs/images/panel.png" width="480" alt="菜单栏表：哪些应用在用 CPU 和内存，每一行可以结束">
  </a>
</p>

## 支持的平台

- **macOS 26+**（Apple 芯片与 Intel）
- **不支持 Windows 或 Linux。** 本应用读取 macOS 进程身份、住在菜单栏、结束本机进程。这些能力在其他系统上不存在。

## 安装

### Homebrew（推荐）

```sh
brew tap x0c/tap
brew install --cask mac-resource-monitor
```

### 直接下载

从 [releases](https://github.com/x0c/MacResourceMonitor/releases/latest) 下载已签名并公证的 `Mac-Resource-Monitor-x.y.z.dmg`，把 Mac Resource Monitor 拖进「应用程序」。

Mac Resource Monitor 会自动检查更新（[Sparkle](https://sparkle-project.org)）。右键菜单栏图标可选「检查更新…」。

### 从源码构建

需要 Xcode 26+ 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```sh
git clone https://github.com/x0c/MacResourceMonitor.git
cd MacResourceMonitor
xcodegen generate
xcodebuild -project MacResourceMonitor.xcodeproj -scheme MacResourceMonitor -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData build
rm -rf "/Applications/Mac Resource Monitor.app"
ditto "build/DerivedData/Build/Products/Release/Mac Resource Monitor.app" "/Applications/Mac Resource Monitor.app"
open "/Applications/Mac Resource Monitor.app"
```

## 用法

1. 点菜单栏双环（外环 CPU、内环内存），表出现在图标正下方。
2. 每一行是人话名、整机 CPU%、物理内存%、结束。点 CPU 或内存表头按该列从高到低排。
3. 鼠标停在结束符号上时这一行钉住，刷新不会把你对准的行换掉。再点一下结束。
4. 点表外面关掉。右键图标可开机自启、显示网速、打开主窗口、设置、检查更新或退出。
5. 开机自启默认关。登录自启时静默，不弹设置窗。菜单栏图标不可隐藏。

如果它帮你解开过卡住的 Mac，给仓库点一颗星，能让后来的人更容易找到。

## 功能

- 平表，只显示有意义的行，人话名（ChatGPT 就是 ChatGPT，不是 `node`）
- 整机 CPU%（上限 100%）和物理内存%
- 一键结束当前用户的进程；系统进程只展示、不能杀
- 左上角冻结开关（英文 Freeze / 中文冻结，默认关）：稳住行顺序方便对准结束，占用数字仍继续刷；点列头排序会自动关掉冻结；悬停结束会钉住那一行
- 网络表后台预热，打开没有加载屏；暂时没流量的进程会留着显示 `0 KB/s`，不会秒级闪进闪出
- 收起表或冻结名单时，菜单栏双环仍继续更新

## 明确不做

Stats / iStat 那种只看传感器的菜单栏、程序坞图标、桌面进程表工作区、可展开进程树、Mac App Store、沙盒、辅助功能 / 完整磁盘访问、Windows / Linux 客户端。菜单栏图标不可隐藏；登录自启时静默，不弹设置窗。

## 许可证

[MIT](LICENSE)
