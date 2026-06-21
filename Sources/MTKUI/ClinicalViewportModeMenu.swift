import SwiftUI

public struct ClinicalViewportModeMenu: View {
    private let currentMode: ClinicalViewerMode
    private let onSelect: (ClinicalViewerMode) -> Void
    private let orderedModes: [ClinicalViewerMode] = [.stack2D, .clinical, .single3D]

    public init(currentMode: ClinicalViewerMode, onSelect: @escaping (ClinicalViewerMode) -> Void) {
        self.currentMode = currentMode
        self.onSelect = onSelect
    }

    public var body: some View {
        Menu {
            ForEach(orderedModes) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    Label(mode.displayName, systemImage: mode == currentMode ? "checkmark" : icon(for: mode))
                }
                .accessibilityIdentifier("ClinicalViewportModeMenu.option.\(mode.id)")
                .accessibilityLabel(Text(mode.displayName))
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentMode.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial.opacity(0.75), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ClinicalViewportModeMenu")
        .accessibilityLabel("Viewport mode")
        .accessibilityValue(currentMode.displayName)
    }

    private func icon(for mode: ClinicalViewerMode) -> String {
        switch mode {
        case .stack2D:
            return "rectangle"
        case .clinical:
            return "square.grid.2x2"
        case .single3D:
            return "cube.transparent"
        }
    }
}
