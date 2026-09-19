import AppKit
import SwiftUI

struct ProcessTableView: View {
    @Bindable var model: ProcessListModel

    var body: some View {
        VStack(spacing: 0) {
              header
                  .zIndex(1)
              Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.visibleRows) { row in
                        ProcessRowView(
                            row: row,
                            onEnd: {
                                Task { await model.end(row) }
                            },
                            onEndHover: { hovering in
                                model.setEndHover(hovering, rowID: row.id)
                            }
                        )
                        if row.id != model.visibleRows.last?.id {
                            Divider()
                                .opacity(0.35)
                        }
                    }
                }
                .transaction { $0.animation = nil }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(6)
        .endFailureBanner(model.lastError)
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
            sortHeader(
                column: .cpu,
                title: String(
                    format: String(localized: "table.header.cpu"),
                    ProcessTableRanking.percentText(model.systemCPUPercent)
                ),
                accessibility: String(localized: "table.sort.cpu")
            )
            sortHeader(
                column: .memory,
                title: String(
                    format: String(localized: "table.header.memory"),
                    ProcessTableRanking.percentText(model.systemMemoryPercent)
                ),
                accessibility: String(localized: "table.sort.memory")
            )
            BulkEndButton(candidates: model.bulkEndCandidates) { candidates in
                Task { await model.endAll(candidates) }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
    }

    private func sortHeader(column: ProcessSortColumn, title: String, accessibility: String) -> some View {
        let selected = !model.listFrozen && model.sortColumn == column
        return Text(title)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(width: AppPreferences.metricColumnWidth, height: 22, alignment: .trailing)
            .contentShape(Rectangle())
            .onTapGesture {
                model.selectSort(column)
            }
            .pointerStyle(.link)
            .focusable(false)
            .focusEffectDisabled()
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel(accessibility)
            .accessibilityValue(title)
    }
}
