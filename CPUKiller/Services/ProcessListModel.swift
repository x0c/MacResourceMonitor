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
        pinnedID: String? = nil,
        pinnedIndex: Int? = nil
    ) -> [ProcessRow] {
        let ranked = rows.sorted { lhs, rhs in
            let left = sort == .cpu ? lhs.cpuPercent : lhs.memoryPercent
            let right = sort == .cpu ? rhs.cpuPercent : rhs.memoryPercent
            if left != right {
                return left > right
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        let busy = ranked.filter { $0.cpuPercent >= 0.1 || $0.memoryPercent >= 0.4 }
        let visible: [ProcessRow]
        if busy.count >= 8 {
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
    private(set) var systemCPUPercent = 0.0
    private(set) var systemMemoryPercent = 0.0
    var sortColumn: ProcessSortColumn = .cpu
    private let sampler = ProcessSampler()
    private var listLoop: Task<Void, Never>?
    private var panelVisible = false
    private var hasCPUReading = false
    private var isRefreshing = false
    private var pinnedRowID: String?
    private var pinnedIndex: Int?
    private var unpinTask: Task<Void, Never>?
    /// 进行中的结束行；防止连点或网络表与进程表重叠并发杀同一批 PID。
    private var endingRowIDs: Set<String> = []
    @ObservationIgnored private var metricsObserver: ((Double, Double) -> Void)?

    var refreshEnabled: Bool = AppPreferences.refreshEnabledDefault {
        didSet {
            UserDefaults.standard.set(refreshEnabled, forKey: AppPreferences.refreshEnabledKey)
            applyRunState()
        }
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: AppPreferences.refreshEnabledKey) == nil {
            refreshEnabled = AppPreferences.refreshEnabledDefault
        } else {
            refreshEnabled = defaults.bool(forKey: AppPreferences.refreshEnabledKey)
        }
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
            pinnedID: pinnedRowID,
            pinnedIndex: pinnedIndex
        )
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
            Task { await refresh() }
        } else {
            clearPin()
        }
    }

    func applyRunState() {
        start()
    }

    func start() {
        guard listLoop == nil else { return }
        listLoop = Task { [weak self] in
            await self?.refresh()
            try? await Task.sleep(for: .milliseconds(350))
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppPreferences.refreshInterval))
                await self?.refresh()
            }
        }
    }

    func stop() {
        listLoop?.cancel()
        listLoop = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let snapshot = await sampler.snapshot()
        let records = snapshot.records
        let memory = await sampler.memoryBytes
        let updatedRows = DisplayClassifier.rows(
            from: records,
            currentUID: getuid(),
            physicalMemory: memory
        )
        latestRows = updatedRows
        if panelVisible && (refreshEnabled || rows.isEmpty) {
            rows = updatedRows
            if let pinnedRowID, !updatedRows.contains(where: { $0.id == pinnedRowID }) {
                clearPin()
            }
        }
        let cpuPercent = updatedRows.reduce(0) { $0 + $1.cpuPercent }
        if snapshot.cpuSampleReady {
            hasCPUReading = true
            systemCPUPercent = min(max(cpuPercent, 0), 100)
        }
        if let memoryPercent = await sampler.memoryUsagePercent {
            systemMemoryPercent = memoryPercent
        }
        notifyMetrics()
    }

    func end(_ row: ProcessRow) async {
        guard endingRowIDs.insert(row.id).inserted else { return }
        defer { endingRowIDs.remove(row.id) }
        lastError = nil
        let outcome = await ProcessTerminator.end(row)
        switch outcome {
        case .ended, .blocked:
            break
        case .failed(let message):
            lastError = message
        }
        await refresh()
    }

    private func notifyMetrics() {
        guard hasCPUReading else { return }
        metricsObserver?(systemCPUPercent, systemMemoryPercent)
    }

    private func clearPin() {
        unpinTask?.cancel()
        unpinTask = nil
        pinnedRowID = nil
        pinnedIndex = nil
    }
}
