//  MPRPanelView.swift
//  MTK
//  Minimal SwiftUI view that exposes a normalized slider for slice selection.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI)
import SwiftUI

/// A small SwiftUI control panel for navigating an MPR slice along a single axis.
///
/// `MPRPanelView` presents a normalized 0...1 slider that maps to the current MPR plane position
/// for the given axis. It calls ``VolumeViewportController/setMprPlane(axis:normalized:)`` as the
/// slider moves.
///
/// - Important: This view mutates the controller on the main actor.
@MainActor
public struct MPRPanelView: View {
    private let controller: VolumeViewportController
    private let axis: VolumeViewportController.Axis
    private let style: any VolumetricUIStyle
    @State private var normalizedPosition: Double

    public init(controller: VolumeViewportController,
                axis: VolumeViewportController.Axis,
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        self.controller = controller
        self.axis = axis
        self.style = style
        _normalizedPosition = State(initialValue: Double(controller.sliceState.normalizedPosition))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MPR — \(label)" )
                .font(.headline)
            Slider(value: $normalizedPosition, in: 0...1)
                .onChange(of: normalizedPosition) { _, newValue in
                    updateSlice(newValue)
                }
                .accessibilityIdentifier("MPRPanelViewSlider-\(label)")
            Text("Position: \(Int(normalizedPosition * 100))%")
                .font(.caption)
        }
        .padding(12)
        .background(style.overlayBackground)
        .foregroundColor(style.overlayForeground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func updateSlice(_ value: Double) {
        Task {
            await controller.setMprPlane(axis: axis, normalized: Float(value))
        }
    }

    private var label: String {
        switch axis {
        case .x: return "Axial"
        case .y: return "Coronal"
        case .z: return "Sagittal"
        }
    }
}
#endif
