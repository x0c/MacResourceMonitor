import AppKit
import SwiftUI

struct ProcessRowView: View {
    let row: ProcessRow
    let onEnd: () -> Void
    let onEndHover: (Bool) -> Void

    var body: some View {
        MonitorTableRowChrome(
            displayName: row.displayName,
            iconPath: row.iconPath,
            bundlePath: row.bundlePath,
            canEnd: row.isCurrentUser && !row.isSystemProtected,
            isSystemProtected: row.isSystemProtected,
            isCurrentUser: row.isCurrentUser,
            onEnd: onEnd,
            onEndHover: onEndHover,
            accessibilityText: accessibilityText
        ) {
            Text(ProcessTableRanking.percentText(row.cpuPercent))
                .font(.system(size: ProcessNamePresentation.bodySize))
                .monospacedDigit()
                .foregroundStyle(TableMetricPresentation.color(for: row.cpuPercent, metric: .cpu))
                .frame(width: AppPreferences.metricColumnWidth, alignment: .trailing)
            Text(ProcessTableRanking.percentText(row.memoryPercent))
                .font(.system(size: ProcessNamePresentation.bodySize))
                .monospacedDigit()
                .foregroundStyle(TableMetricPresentation.color(for: row.memoryPercent, metric: .memory))
                .frame(width: AppPreferences.metricColumnWidth, alignment: .trailing)
        }
    }

    private var accessibilityText: String {
        "\(row.displayName), CPU \(ProcessTableRanking.percentText(row.cpuPercent)), \(String(localized: "table.column.memory")) \(ProcessTableRanking.percentText(row.memoryPercent))"
    }
}

nonisolated enum ProcessNamePresentation {
    static let bodySize: CGFloat = 12
    /// 网络表单位专用：比正文小一号，避免大写 `KB/s` 把速率格撑得比百分比更大。
    static let unitSize: CGFloat = 10
    static let minimumScaleFactor: CGFloat = 0.85

    static func truncationMode(for displayName: String) -> Text.TruncationMode {
        looksLikeReverseDNS(displayName) ? .head : .tail
    }

    static func looksLikeReverseDNS(_ displayName: String) -> Bool {
        displayName.contains(".") && !displayName.contains(" ")
    }
}

nonisolated enum TableMetricPresentation {
    enum Metric {
        case cpu
        case memory
        case network
    }

    enum Level: Equatable {
        case quiet
        case normal
        case elevated
        case critical
    }

    static func color(for value: Double, metric: Metric) -> Color {
        switch level(for: value, metric: metric) {
        case .quiet:
            return .secondary
        case .normal:
            return .primary
        case .elevated:
            return .orange
        case .critical:
            return .red
        }
    }

    static func level(for value: Double, metric: Metric) -> Level {
        switch metric {
        case .cpu:
            return heatLevel(value, normalAt: 1, elevatedAt: 5, criticalAt: 15)
        case .memory:
            return value >= 8 ? .normal : .quiet
        case .network:
            let kilobyte = 1_024.0
            let megabyte = kilobyte * 1_024
            return heatLevel(value, normalAt: kilobyte, elevatedAt: megabyte, criticalAt: megabyte * 10)
        }
    }

    private static func heatLevel(
        _ value: Double,
        normalAt: Double,
        elevatedAt: Double,
        criticalAt: Double
    ) -> Level {
        if value >= criticalAt { return .critical }
        if value >= elevatedAt { return .elevated }
        if value >= normalAt { return .normal }
        return .quiet
    }
}
