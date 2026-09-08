# Mac Resource Monitor 应用图标探索

覆盖：重新设计 / 精绘 / 接入应用图标，或排查进程表 / Finder 仍显示旧图标（粉底黑叉）。不覆盖：菜单栏双环模板绘制（见菜单栏交互知识库）。

## 当前状态

- 正式主图已接入：`design/app-icon/AppIcon-1024.png` → 分层 `AppIcon.icon` + 兜底 `AppIcon.appiconset`。
- 菜单栏双环模板**独立**，不随 App icon 改动。
- 2026-08-30 前几轮九宫格 / 变种 / 黑白结构稿**未通过审美**，仅作失败参考，不得选格接入。

## 设计基线

- 产品名 **Mac Resource Monitor**；主符号一个，无文字 / 标签 / 设备框 / 预裁圆角 / 外投影。
- 方形、不透明、满画布；缩小到 48px / 24px 仍保留明确轮廓。
- App icon ≠ 菜单栏双环模板。
- 不做高饱和海报或被动监视器图表。

## 接入硬规则

- 流水线：方向板 → 精确裁格 → 独立 1024 → 小尺寸检查 → 用户确认 → 接入。禁止直接放大九宫格局部当主图。
- 正式接入必须**同时**更新 `AppIcon.icon` 与 `AppIcon.appiconset`。
- `AppIcon.icon/Assets/x-mark.svg` 是换图前废文件；看见粉底黑叉**不是**它又生效。
- **进程表仍显示粉底黑叉**：安装包 / Finder 已是新图后，名单仍可能缓存旧图。覆盖安装须先删整包再复制。不要重做母版、不要把 X 加回图层。权威见产品契约「应用图标」。

## 失败禁令（保留）

- 禁止写实芯片 / 晶圆纹理 / 金属玻璃 3D / 荧光 / 噪点当终稿来源。
- 禁止扫码器式同心方框 + 定位块构图。
- CPU 须为唯一主体，并有一个非对称「结束」记忆点；禁止完整 X / 骷髅当主焦点。

## 资产路径

- 正式主图：`design/app-icon/AppIcon-1024.png`
- 分层图层：`MacResourceMonitor/AppIcon.icon/Assets/chip-pressed-white.png`
- 探索稿目录：`design/app-icon/explorations/`（历史九宫格，勿当终稿）
- 裁格工具：`apple-app-icon-pack` → `extract_direction_cell.py`

<!-- 该文档整理/压缩于 2026-09-05 -->
