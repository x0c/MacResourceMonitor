# Changelog

Release notes are bilingual: English first, then complete Simplified Chinese.
Development adds entries under `## Unreleased`; at release time they become the
next version's section. A `Release: minor` or `Release: major` line requests a
larger version step; `Release: hold <reason>` keeps the changes unreleased until
the named acceptance is done.

## Unreleased

## 1.1.8 (2026-11-16)

### English

- **Whole-machine CPU & cross-UID visibility**: Header CPU and the menu-bar outer ring now use a short (~2–3 s) rolling window of kernel `HOST_CPU_LOAD_INFO` ticks instead of summing surviving same-UID rows. Cross-UID processes (`WindowServer`, root daemons) display real CPU while the table is open, and `kernel_task` appears as a read-only row bounded by unattributed kernel-space ticks.
- **Process grouping & workspaces**: `pi` and `Cursor Agent` rows carry their working folder (including parent/child disambiguation for generic folders such as `Corral/cli`) and fold build/test child processes (`tsc`, unit tests) while keeping `tmux`, terminals and desktop apps separate. Corral splits into `Corral`, per-instance `Corral TUI`, and `Corral Remote`, without absorbing `tmux` keep-alive or unrelated paths.
- **End whitelist**: Right-click any row to add or remove it from the protected whitelist and manage entries in Settings; whitelisted apps are skipped by row end, bulk end and `mrm doom`.
- **Lower idle CPU & faster Network table**: Bulk `KERN_PROC_ALL` sampling, hidden-panel `@Observable` gating, per-status-item render deduplication, and sub-second Network table opening with zero subprocesses while both tables are closed.

### 简体中文

- **整机 CPU 与跨用户进程可见性**：表头 CPU 与菜单栏外环改读内核 `HOST_CPU_LOAD_INFO` 短窗（约 2–3 秒）滑动拍数差，不再只把同用户进程相加；表打开时显示 `WindowServer`、root 守护等跨用户进程的真实 CPU，`kernel_task` 以受系统态余量约束的只读行展示，两张表收起时不派生任何子进程。
- **会话工作区与聚合修正**：`pi` / `Cursor Agent` 行保留工作目录标签（`cli`/`src` 等通用子目录自动拼接 `父/子`），并将拉起的构建/单测子进程（`tsc`、单测等）折进所属会话行，同时在终端、`tmux` 与桌面应用边界停止；Corral 拆分为 `Corral`、`Corral TUI` 与 `Corral Remote`，不再误吞 `tmux` 保活或路径含 `corral` 的无关进程。
- **结束白名单**：支持在列表右键将应用加入/移出白名单并在设置窗管理（含应用图标），单行结束、表头批量与 `mrm doom` 均自动跳过。
- **低后台功耗与亚秒级网络表**：改用单次 `KERN_PROC_ALL`、收起态 `@Observable` 门控、双状态项渲染去重，以及网络表亚秒级首帧就绪。
