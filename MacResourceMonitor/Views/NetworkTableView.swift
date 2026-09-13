import AppKit
import SwiftUI

struct NetworkTableView: View {
    @Bindable var model: NetworkListModel

    var body: some View {
        VStack(spacing: 0) {
              header
                  .zIndex(1)
              Divider()
            ScrollView {
                if model.visibleRows.isEmpty {
                    ContentUnavailableView(
                        String(localized: "network.empty"),
                        systemImage: "network"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 270)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleRows) { row in
                            NetworkRowView(
                                row: row,
                                onEnd: { Task { await model.end(row) } },
                                onEndHover: { model.setEndHover($0, rowID: row.id) }
                            )
                            if row.id != model.visibleRows.last?.id {
                                Divider().opacity(0.35)
                            }
                        }
                    }
                    .transaction { $0.animation = nil }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(6)
        .overlay(alignment: .bottom) {
            if let lastError = model.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.96))
            }
        }
        .ignoresSafeArea()
        .focusEffectDisabled()
        .environment(\.controlSize, .mini)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Toggle(isOn: $model.listFrozen) {
                Text(String(localized: "panel.freeze"))
                    .font(.caption2.weight(.semibold))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .focusable(false)
            .focusEffectDisabled()
            Spacer(minLength: 8)
            sortHeader(column: .upload, title: String(localized: "table.column.upload"))
            sortHeader(column: .download, title: String(localized: "table.column.download"))
            BulkEndButton(candidates: model.bulkEndCandidates) { candidates in
                Task { await model.endAll(candidates) }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
    }

    private func sortHeader(column: NetworkSortColumn, title: String) -> some View {
        let selected = !model.listFrozen && model.sortColumn == column
        return Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(width: AppPreferences.metricColumnWidth, height: 22, alignment: .trailing)
            .contentShape(Rectangle())
            .onTapGesture { model.selectSort(column) }
            .pointerStyle(.link)
            .focusable(false)
            .focusEffectDisabled()
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel(title)
    }
}
