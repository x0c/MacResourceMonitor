import Foundation
import Observation

nonisolated enum ProcessSortColumn: String, Sendable {
    case cpu
    case memory
}

/// 名单只按当前列从高到低排；近乎空闲的行默认不占位置。
/// 悬停结束符号时把该行钉在原位，避免刷新换人误杀。
nonisolated enum ProcessTableRanking {
    static func visibleRows(
        from rows: [ProcessRow],
        sort: ProcessSortColumn,
        frozen: Bool = false,
        pinnedID: String? = nil,
        pinnedIndex: Int? = nil
    ) -> [ProcessRow] {
        let ranked: [ProcessRow]
        if frozen {
            ranked = rows
        } else {
            ranked = rows.sorted { lhs, rhs in
                let left = sort == .cpu ? lhs.cpuPercent : lhs.memoryPercent
                let right = sort == .cpu ? rhs.cpuPercent : rhs.memoryPercent
                if left != right {
                    return left > right
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }
        let busy = ranked.filter { $0.cpuPercent >= 0.1 || $0.memoryPercent >= 0.4 }
        let visible: [ProcessRow]
        if frozen {
            visible = ranked
        } else if busy.count >= 8 {
            visible = busy
        } else {
            visible = Array(ranked.prefix(12))
        }
        return TableRowPinning.pin(visible, onto: rows, pinnedID: pinnedID, pinnedIndex: pinnedIndex)
    }

    static func percentText(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}

@MainActor
@Observable
final class ProcessListModel {
    private(set) var rows: [ProcessRow] = []
    private(set) var latestRows: [ProcessRow] = []
    private(set) var lastError: String?
    private let endFailureBanner = TransientStatusMessage()
    private(set) var systemCPUPercent = 0.0
    private(set) var systemMemoryPercent = 0.0
    var sortColumn: ProcessSortColumn = .cpu
    private let sampler = ProcessSampler()
    private var listLoop: Task<Void, Never>?
    private var panelVisible = false
    private var networkSamplingRequired = false
    private var hasCPUReading = false
    private var isRefreshing = false
    private var pinnedRowID: String?
    private var pinnedIndex: Int?
    private var unpinTask: Task<Void, Never>?
    /// 进行中的结束行；防止连点或网络表与进程表重叠并发杀同一批 PID。
    private var endingRowIDs: Set<String> = []
    @ObservationIgnored private var latestSystemCPUPercent = 0.0
    @ObservationIgnored private var latestSystemMemoryPercent = 0.0
    @ObservationIgnored private var lastRefreshCollectedDetails = false
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var metricsObserver: ((Double, Double) -> Void)?

    var listFrozen: Bool = AppPreferences.listFrozenDefault {
        didSet {
            UserDefaults.standard.set(listFrozen, forKey: AppPreferences.listFrozenKey)
            if listFrozen {
                rows = ProcessTableRanking.visibleRows(
                    from: rows.isEmpty ? latestRows : rows,
                    sort: sortColumn,
                    frozen: false,
                    pinnedID: pinnedRowID,
                    pinnedIndex: pinnedIndex
                )
            }
        }
    }

    init() {
        listFrozen = AppPreferences.readListFrozen(
            key: AppPreferences.listFrozenKey,
            legacyKey: AppPreferences.legacyRefreshEnabledKey,
            defaultValue: AppPreferences.listFrozenDefault
        )
        start()
    }

    func setMetricsObserver(_ observer: @escaping (Double, Double) -> Void) {
        metricsObserver = observer
        notifyMetrics()
    }

    var visibleRows: [ProcessRow] {
        ProcessTableRanking.visibleRows(
            from: rows,
            sort: sortColumn,
            frozen: listFrozen,
            pinnedID: pinnedRowID,
            pinnedIndex: pinnedIndex
        )
    }

    /// Any open table asks for detailed rows: those passes also sample cross-UID CPU.
    private var detailDemand: Bool {
        panelVisible || networkSamplingRequired
    }

    var bulkEndCandidates: [ProcessRow] {
        ProcessTerminationSelection.bulkCandidates(
            from: rows,
            excludingPID: getpid(),
            whitelist: WhitelistStore.shared.entries
        )
    }

    func selectSort(_ column: ProcessSortColumn) {
        listFrozen = false
        sortColumn = column
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

    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        applyRunState()
        if visible {
            // Sync latest background totals immediately on open without mutating Observable while hidden.
            systemCPUPercent = latestSystemCPUPercent
            systemMemoryPercent = latestSystemMemoryPercent
            if rows.isEmpty, !latestRows.isEmpty {
                rows = latestRows
            }
            Task { await ensureDetailedRows() }
        } else {
            clearPin()
            clearEndFailure()
        }
    }

    func applyRunState() {
        start()
    }

    func setNetworkSamplingRequired(_ required: Bool) {
        networkSamplingRequired = required
        if required {
            Task { await ensureDetailedRows() }
        }
    }

    /// Guarantee at least one detailed refresh completes even if a hidden pass was mid-flight.
    func ensureDetailedRows() async {
        while isRefreshing {
            await withCheckedContinuation { continuation in
                refreshWaiters.append(continuation)
            }
        }
        if !lastRefreshCollectedDetails || latestRows.isEmpty {
            await refresh(forceDetails: true)
        } else if panelVisible {
            await refresh()
        }
    }

    func start() {
        guard listLoop == nil else { return }
        listLoop = Task { [weak self] in
            await self?.refresh()
            try? await Task.sleep(for: .milliseconds(350))
            await self?.refresh()
            while !Task.isCancelled {
                let interval = (self?.detailDemand ?? false)
                    ? AppPreferences.visibleRefreshInterval
                    : AppPreferences.refreshInterval
                try? await Task.sleep(for: .seconds(interval), tolerance: .milliseconds(150))
                await self?.refresh()
            }
        }
    }

    func stop() {
        listLoop?.cancel()
        listLoop = nil
    }

    func refresh(forceDetails: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            let waiters = refreshWaiters
            refreshWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters {
                waiter.resume()
            }
        }

        // Retain complete rows while hidden; network warmup/open also needs fresh identities.
        let collectDetails = forceDetails || panelVisible || networkSamplingRequired || latestRows.isEmpty
        let snapshot = await sampler.snapshot(
            collectDetails: collectDetails,
            includeForeignCPU: panelVisible
        )
        lastRefreshCollectedDetails = collectDetails
        if collectDetails {
            let memory = await sampler.memoryBytes
            latestRows = DisplayClassifier.rows(
                from: snapshot.records,
                currentUID: getuid(),
                physicalMemory: memory
            )
        }
        let updatedRows = latestRows
        if panelVisible {
            if rows.isEmpty {
                rows = updatedRows
            } else if listFrozen {
                // 冻结：顺序不动，数字用最新采样原位更新；已死行拿掉，不插新行。
                rows = TableRowPinning.mergePreservingOrder(existing: rows, fresh: updatedRows)
            } else {
                rows = updatedRows
            }
            if let pinnedRowID, !rows.contains(where: { $0.id == pinnedRowID }) {
                clearPin()
            }
        }
        if snapshot.cpuSampleReady {
            hasCPUReading = true
            latestSystemCPUPercent = snapshot.totalCPUPercent
            if panelVisible {
                systemCPUPercent = snapshot.totalCPUPercent
            }
        }
        if let memoryPercent = await sampler.memoryUsagePercent {
            latestSystemMemoryPercent = memoryPercent
            if panelVisible {
                systemMemoryPercent = memoryPercent
            }
        }
        notifyMetrics()
    }

    func end(_ row: ProcessRow) async {
        guard endingRowIDs.insert(row.id).inserted else { return }
        defer { endingRowIDs.remove(row.id) }
        clearEndFailure()
        let outcome = await ProcessTerminator.end(row)
        switch outcome {
        case .ended, .blocked:
            break
        case .failed(let message):
            showEndFailure(message)
        }
        await refresh()
    }

    func endAll(_ candidates: [ProcessRow]) async {
        clearEndFailure()
        switch await ProcessTerminator.endAll(candidates) {
        case .ended, .blocked:
            break
        case .failed:
            showEndFailure(String(localized: "table.endAll.failed"))
        }
        await refresh()
    }

    private func notifyMetrics() {
        guard hasCPUReading else { return }
        metricsObserver?(latestSystemCPUPercent, latestSystemMemoryPercent)
    }

    private func showEndFailure(_ message: String) {
        endFailureBanner.present(message) { [weak self] text in
            self?.lastError = text
        }
    }

    private func clearEndFailure() {
        endFailureBanner.cancel()
        lastError = nil
    }

    private func clearPin() {
        unpinTask?.cancel()
        unpinTask = nil
        pinnedRowID = nil
        pinnedIndex = nil
    }
}
