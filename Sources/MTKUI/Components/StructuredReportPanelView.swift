import SwiftUI

public struct StructuredReportPanelView: View {
    @Binding private var state: StructuredReportViewerState

    public init(state: Binding<StructuredReportViewerState>) {
        self._state = state
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if !state.cadFindings.isEmpty {
                    findingsSection
                }
                if !state.measurements.isEmpty {
                    measurementsSection
                }
                treeSection
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("StructuredReportPanel")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(state.title)
                .font(.headline)
            if let subtitle = state.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var findingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Findings")
                .font(.subheadline.weight(.semibold))
            ForEach(state.cadFindings) { finding in
                Button {
                    state.selectFinding(id: finding.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.summaryText)
                            .font(.caption.weight(.semibold))
                        ForEach(finding.detailLines.dropFirst(), id: \.self) { line in
                            Text(line)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(rowBackground(for: finding),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("StructuredReportFinding.\(finding.id)")
            }
        }
    }

    private var measurementsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Measurements")
                .font(.subheadline.weight(.semibold))
            ForEach(state.measurements) { measurement in
                HStack {
                    Text(measurement.name)
                    Spacer(minLength: 8)
                    Text(measurement.displayText)
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
    }

    private var treeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Report Tree")
                .font(.subheadline.weight(.semibold))
            ForEach(treeRows(), id: \.node.id) { row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.node.valueType)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text(row.node.title)
                        .font(.caption)
                    if let subtitle = row.node.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, CGFloat(row.depth) * 10)
            }
        }
    }

    private func treeRows() -> [TreeDisplayRow] {
        treeRows(for: state.treeRoot, depth: 0)
    }

    private func treeRows(for node: StructuredReportTreeNode, depth: Int) -> [TreeDisplayRow] {
        [TreeDisplayRow(node: node, depth: depth)] +
            node.children.flatMap { treeRows(for: $0, depth: depth + 1) }
    }

    private func rowBackground(for finding: CADFindingOverlayItem) -> Color {
        state.isSelected(finding) ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)
    }
}

private struct TreeDisplayRow {
    var node: StructuredReportTreeNode
    var depth: Int
}
