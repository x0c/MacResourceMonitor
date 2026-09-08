import Foundation

/// 悬停「结束」时把行钉在原位；进程表与网络表共用同一插入规则。
nonisolated enum TableRowPinning {
    static func pin<Row: Identifiable>(
        _ visible: [Row],
        onto allRows: [Row],
        pinnedID: Row.ID?,
        pinnedIndex: Int?
    ) -> [Row] {
        guard let pinnedID, let pinnedIndex else { return visible }
        guard let pinned = allRows.first(where: { $0.id == pinnedID }) else {
            return visible
        }
        var result = visible.filter { $0.id != pinnedID }
        let index = min(max(pinnedIndex, 0), result.count)
        result.insert(pinned, at: index)
        return result
    }

    /// 冻结名单：保持原顺序，用最新采样替换仍存活的行；已消失的拿掉，不插入新行。
    static func mergePreservingOrder<Row: Identifiable>(
        existing: [Row],
        fresh: [Row]
    ) -> [Row] {
        let byID = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        return existing.compactMap { byID[$0.id] }
    }
}


/// 悬停结束钮时的钉行状态机；进程表与网络表行为一致。
///
/// `visibleIndex` 必须由调用方在拿到本函数的 `inout` 钉位引用**之前**算好。
/// 若在已独占 `pinnedRowID` 时再经 `@Observable` 读 `visibleRows`（内部再读钉位），
/// Swift 会报独占冲突并 SIGABRT（见 2026-09-06 网络表结束钮悬停闪退）。
@MainActor
enum PinnedEndHover {
    static func apply(
        hovering: Bool,
        rowID: String,
        pinnedRowID: inout String?,
        pinnedIndex: inout Int?,
        unpinTask: inout Task<Void, Never>?,
        visibleIndex: Int?,
        clearPin: @escaping () -> Void,
        currentPinnedID: @escaping () -> String?
    ) {
        if hovering {
            unpinTask?.cancel()
            unpinTask = nil
            if pinnedRowID != rowID {
                pinnedIndex = visibleIndex
                pinnedRowID = rowID
            }
            return
        }
        guard pinnedRowID == rowID else { return }
        unpinTask?.cancel()
        unpinTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, currentPinnedID() == rowID else { return }
            clearPin()
        }
    }
}
