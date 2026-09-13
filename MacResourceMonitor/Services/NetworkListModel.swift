import Foundation
import Observation

nonisolated enum NetworkSortColumn: String, Sendable {
    case upload
    case download
}

nonisolated enum NetworkTableRanking {
    static func visibleRows(
        from rows: [NetworkProcessRow],
        sort: NetworkSortColumn,
        frozen: Bool = false,
        pinnedID: String? = nil,
        pinnedIndex: Int? = nil
    ) -> [NetworkProcessRow] {
        let ordered: [NetworkProcessRow]
        if frozen {
            // 冻结时保持快照顺序，不再按占用重排。
            ordered = rows
        } else {
            ordered = rows.sorted { lhs, rhs in
                let left = sort == .upload ? lhs.uploadBytesPerSecond : lhs.downloadBytesPerSecond
                let right = sort == .upload ? rhs.uploadBytesPerSecond : rhs.downloadBytesPerSecond
                if left != right { return left > right }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }
        let visible = Array(ordered.prefix(12))
        return TableRowPinning.pin(visible, onto: rows, pinnedID: pinnedID, pinnedIndex: pinnedIndex)
    }
}

/// 网络名单时间保持：刚有过流量的行短暂无包时仍留在表里，避免秒级闪烁。
/// 借鉴同类监视器的 “recently active hold”，不用频率迟滞。
nonisolated enum NetworkListPresence {
    static let holdDuration: TimeInterval = 15

    static func rows(
        processes: [ProcessRow],
        rates: [pid_t: ProcessNetworkRate],
        holdUntil: [String: Date],
        now: Date,
        holdDuration: TimeInterval = holdDuration
    ) -> (rows: [NetworkProcessRow], holdUntil: [String: Date]) {
        var nextHoldUntil: [String: Date] = [:]
        var rows: [NetworkProcessRow] = []
        let aliveIDs = Set(processes.map(\.id))

        for process in processes {
            let total = process.memberPIDs.reduce(
                into: ProcessNetworkRate(receivedBytesPerSecond: 0, sentBytesPerSecond: 0)
            ) { aggregate, pid in
                guard let rate = rates[pid] else { return }
                aggregate = ProcessNetworkRate(
                    receivedBytesPerSecond: aggregate.receivedBytesPerSecond + rate.receivedBytesPerSecond,
                    sentBytesPerSecond: aggregate.sentBytesPerSecond + rate.sentBytesPerSecond
                )
            }
            let active = total.receivedBytesPerSecond > 0 || total.sentBytesPerSecond > 0
            if active {
                nextHoldUntil[process.id] = now.addingTimeInterval(holdDuration)
                rows.append(
                    NetworkProcessRow(
                        process: process,
                        uploadBytesPerSecond: total.sentBytesPerSecond,
                        downloadBytesPerSecond: total.receivedBytesPerSecond
                    )
                )
                continue
            }
            guard let deadline = holdUntil[process.id], deadline > now else { continue }
            nextHoldUntil[process.id] = deadline
            rows.append(
                NetworkProcessRow(
                    process: process,
                    uploadBytesPerSecond: 0,
                    downloadBytesPerSecond: 0
                )
            )
        }

        // 只保留仍存活责任对象的保持期，避免幽灵行。
        nextHoldUntil = nextHoldUntil.filter { aliveIDs.contains($0.key) }
        return (rows, nextHoldUntil)
    }
}

/// 网络表与 CPU/内存表共享责任进程、图标和结束边界，只替换两列实时速率。
@MainActor
@Observable
final class NetworkListModel {
    static let defaultSortColumn: NetworkSortColumn = .download
    private(set) var rows: [NetworkProcessRow] = []
    private(set) var lastError: String?
    var sortColumn: NetworkSortColumn = defaultSortColumn
    private let sampler = ProcessNetworkSampler()
    private let processRows: @MainActor () -> [ProcessRow]
    private var listLoop: Task<Void, Never>?
    private var isRefreshing = false
    private var pinnedRowID: String?
    private var pinnedIndex: Int?
    private var unpinTask: Task<Void, Never>?
    private var holdUntil: [String: Date] = [:]

    var listFrozen: Bool = AppPreferences.networkListFrozenDefault {
        didSet {
            UserDefaults.standard.set(listFrozen, forKey: AppPreferences.networkListFrozenKey)
            if listFrozen {
                // 冻结当下可见顺序，避免开关一开又被排序打乱。
                rows = NetworkTableRanking.visibleRows(
                    from: rows,
                    sort: sortColumn,
                    frozen: false,
                    pinnedID: pinnedRowID,
                    pinnedIndex: pinnedIndex
                )
            }
        }
    }

    init(processRows: @escaping @MainActor () -> [ProcessRow]) {
        self.processRows = processRows
        listFrozen = AppPreferences.readListFrozen(
            key: AppPreferences.networkListFrozenKey,
            legacyKey: AppPreferences.legacyNetworkRefreshEnabledKey,
            defaultValue: AppPreferences.networkListFrozenDefault
        )
        start()
    }

    var visibleRows: [NetworkProcessRow] {
        NetworkTableRanking.visibleRows(
            from: rows,
            sort: sortColumn,
            frozen: listFrozen,
            pinnedID: pinnedRowID,
            pinnedIndex: pinnedIndex
        )
    }

    var bulkEndCandidates: [ProcessRow] {
        ProcessTerminationSelection.bulkCandidates(
            from: rows.map(\.process),
            excludingPID: getpid()
        )
    }

    func selectSort(_ column: NetworkSortColumn) {
        listFrozen = false
        sortColumn = column
    }

    func setPanelVisible(_ visible: Bool) {
        if !visible {
            clearPin()
        }
    }

    func setEndHover(_ hovering: Bool, rowID: String) {
        // 先读可见索引，再对钉位做 inout；避免 Observation 与独占借用叠在同一属性上闪退。
        let visibleIndex: Int? = {
            guard hovering, pinnedRowID != rowID else { return nil }
            return visibleRows.firstIndex { $0.id == rowID }
        }()
        PinnedEndHover.apply(
            hovering: hovering,
            rowID: rowID,
            pinnedRowID: &pinnedRowID,
            pinnedIndex: &pinnedIndex,
            unpinTask: &unpinTask,
            visibleIndex: visibleIndex,
            clearPin: { [weak self] in self?.clearPin() },
            currentPinnedID: { [weak self] in self?.pinnedRowID }
        )
    }

    func end(_ row: NetworkProcessRow) async {
        lastError = nil
        switch await ProcessTerminator.end(row.process) {
        case .ended, .blocked:
            break
        case .failed(let message):
            lastError = message
        }
        await refresh()
    }

    func endAll(_ candidates: [ProcessRow]) async {
        lastError = nil
        switch await ProcessTerminator.endAll(candidates) {
        case .ended, .blocked:
            break
        case .failed:
            lastError = String(localized: "table.endAll.failed")
        }
        await refresh()
    }

    private func start() {
        guard listLoop == nil else { return }
        listLoop = Task { [weak self] in
            while !Task.isCancelled {
                let deadline = ContinuousClock.now.advanced(by: .seconds(AppPreferences.networkRefreshInterval))
                await self?.refresh()
                guard !Task.isCancelled else { break }
                try? await Task.sleep(until: deadline, clock: .continuous)
            }
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let sampledRates = await sampler.sample()
        // 首帧的一秒采样结束后再取责任进程快照，避免刚启动时把尚未就绪的空名单当成无流量。
        let currentProcesses = processRows()

        let presence = NetworkListPresence.rows(
            processes: currentProcesses,
            rates: sampledRates,
            holdUntil: holdUntil,
            now: Date()
        )
        holdUntil = presence.holdUntil

        let nextRows = presence.rows
        if rows.isEmpty {
            rows = nextRows
        } else if listFrozen {
            // 冻结：顺序不动，速率原位更新；已死行拿掉，不插新行。
            rows = TableRowPinning.mergePreservingOrder(existing: rows, fresh: nextRows)
        } else {
            rows = nextRows
        }
        if let pinnedRowID, !rows.contains(where: { $0.id == pinnedRowID }) {
            clearPin()
        }
    }

    private func clearPin() {
        unpinTask?.cancel()
        unpinTask = nil
        pinnedRowID = nil
        pinnedIndex = nil
    }
}
