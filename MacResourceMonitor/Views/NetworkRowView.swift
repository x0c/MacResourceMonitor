import AppKit
import SwiftUI

struct NetworkRowView: View {
    let row: NetworkProcessRow
    let onEnd: () -> Void
    let onEndHover: (Bool) -> Void

    var body: some View {
        MonitorTableRowChrome(
            displayName: row.displayName,
            iconPath: row.process.iconPath,
            bundlePath: row.process.bundlePath,
            canEnd: row.process.isCurrentUser && !row.process.isSystemProtected,
            isSystemProtected: row.process.isSystemProtected,
            isCurrentUser: row.process.isCurrentUser,
            onEnd: onEnd,
            onEndHover: onEndHover,
            accessibilityText: accessibilityText
        ) {
            rateCell(bytesPerSecond: row.uploadBytesPerSecond)
            rateCell(bytesPerSecond: row.downloadBytesPerSecond)
        }
    }

    private func rateCell(bytesPerSecond: Double?) -> some View {
        let parts = NetworkRateFormatter.parts(for: bytesPerSecond)
        let color = bytesPerSecond.map {
            TableMetricPresentation.color(for: $0, metric: .network)
        } ?? Color.secondary
        return HStack(spacing: 2) {
            Text(parts.value)
                .font(.system(size: ProcessNamePresentation.bodySize))
                .monospacedDigit()
            if let unit = parts.unit {
                Text(unit)
                    .font(.system(size: ProcessNamePresentation.unitSize))
            }
        }
        .foregroundStyle(color)
        .frame(width: AppPreferences.metricColumnWidth, alignment: .trailing)
    }

    private var accessibilityText: String {
        let upload = String(localized: "table.column.upload")
        let download = String(localized: "table.column.download")
        return "\(row.displayName), \(upload) \(NetworkRateFormatter.text(for: row.uploadBytesPerSecond)), \(download) \(NetworkRateFormatter.text(for: row.downloadBytesPerSecond))"
    }
}
