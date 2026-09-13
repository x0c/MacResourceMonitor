import SwiftUI

struct BulkEndButton: View {
    let candidates: [ProcessRow]
    let onConfirm: ([ProcessRow]) -> Void

    @State private var pendingCandidates: [ProcessRow] = []
    @State private var isConfirming = false
    @State private var isHovering = false

    var body: some View {
        Button {
            pendingCandidates = candidates
            guard !pendingCandidates.isEmpty else { return }
            isConfirming = true
        } label: {
            EndButtonIcon(isHighlighted: isHovering && !candidates.isEmpty)
        }
        .buttonStyle(.plain)
        .disabled(candidates.isEmpty)
        .focusable(false)
        .focusEffectDisabled()
        .frame(width: AppPreferences.endColumnWidth, height: 22)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 && !candidates.isEmpty }
        .opacity(candidates.isEmpty ? 0.18 : isHovering ? 1 : 0.45)
        .help(String(localized: "table.endAll"))
        .accessibilityLabel(String(localized: "table.endAll"))
        .overlay(alignment: .topTrailing) {
            if isConfirming {
                confirmationCard
                    .offset(y: 26)
            }
        }
        .zIndex(isConfirming ? 10 : 0)
    }

    private var confirmationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                String(
                    format: String(localized: "table.endAll.confirmation.title"),
                    pendingCandidates.count
                )
            )
            .font(.headline)

            Text(String(localized: "table.endAll.confirmation.message"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Spacer()
                confirmationButton(String(localized: "common.cancel"), color: .secondary) {
                    pendingCandidates = []
                    isConfirming = false
                }
                confirmationButton(String(localized: "table.endAll.confirm"), color: .red) {
                    let confirmedCandidates = pendingCandidates
                    pendingCandidates = []
                    isConfirming = false
                    onConfirm(confirmedCandidates)
                }
            }
        }
        .padding(14)
        .frame(width: 310)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }

    private func confirmationButton(
        _ title: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
    }
}

struct EndButtonIcon: View {
    let isHighlighted: Bool

    var body: some View {
        Image(systemName: "xmark.circle.fill")
            .font(.system(size: 13))
            .foregroundStyle(isHighlighted ? Color.red : Color.secondary)
    }
}
