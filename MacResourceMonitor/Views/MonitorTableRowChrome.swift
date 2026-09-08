import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 进程表 / 网络表共用的行壳：图标、名称、指标槽、结束钮。
struct MonitorTableRowChrome<Metrics: View>: View {
    let displayName: String
    let iconPath: String?
    let bundlePath: String?
    let canEnd: Bool
    let isSystemProtected: Bool
    let isCurrentUser: Bool
    let onEnd: () -> Void
    let onEndHover: (Bool) -> Void
    let accessibilityText: String
    @ViewBuilder var metrics: () -> Metrics

    @State private var hoveringEnd = false
    @FocusState private var isEndFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: iconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
            Text(displayName)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(ProcessNamePresentation.minimumScaleFactor)
                .truncationMode(ProcessNamePresentation.truncationMode(for: displayName))
                .help(displayName)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            metrics()
            endButton
        }
        .font(.system(size: ProcessNamePresentation.bodySize))
        .padding(.horizontal, 6)
        .frame(height: 26)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var iconImage: NSImage {
        if let path = iconPath ?? bundlePath {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }

    @ViewBuilder
    private var endButton: some View {
        let enabled = canEnd
        Button(action: onEnd) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(enabled && hoveringEnd ? Color.red : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(helpText)
        .focused($isEndFocused)
        .focusEffectDisabled()
        .overlay {
            if isEndFocused, enabled {
                Circle()
                    .stroke(Color.primary.opacity(0.85), lineWidth: 1.5)
            }
        }
        .accessibilityLabel(String(localized: "table.end"))
        .accessibilityHint(helpText)
        .frame(width: AppPreferences.endColumnWidth, height: 22)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveringEnd = enabled && hovering
            onEndHover(hovering)
        }
        .opacity(enabled && hoveringEnd ? 1 : enabled ? 0.45 : 0.18)
    }

    private var helpText: String {
        if isSystemProtected {
            return String(localized: "table.end.disabled.system")
        }
        if !isCurrentUser {
            return String(localized: "table.end.disabled.otherUser")
        }
        return ""
    }
}
