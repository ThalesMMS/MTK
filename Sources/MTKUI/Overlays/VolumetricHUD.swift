//  VolumetricHUD.swift
//  MTK
//  Simple HUD showing controller state and toggles.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI)
import MTKCore
import SwiftUI

@MainActor
public struct VolumetricHUD: View {
    @ObservedObject private var controller: VolumeViewportController
    @ObservedObject private var statePublisher: VolumetricStatePublisher
    private let style: any VolumetricUIStyle

    public init(controller: VolumeViewportController,
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        self.controller = controller
        self.statePublisher = controller.statePublisher
        self.style = style
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Camera z: \(statePublisher.cameraState.position.z, specifier: "%.2f")")
            Text("Slice: \(statePublisher.sliceState.axisLabel) @ \(Int(statePublisher.sliceState.normalizedPosition * 100))%")
            Text("Window/Level: \(Int(statePublisher.windowLevelState.window)) / \(Int(statePublisher.windowLevelState.level))")
            Text("Quality: \(statePublisher.qualityState.hudLabel)")
                .accessibilityIdentifier("VolumetricHUDQuality")
            Toggle("Adaptive Sampling", isOn: Binding(get: { statePublisher.adaptiveSamplingEnabled },
                                                     set: { newValue in
                                                         Task { await controller.setAdaptiveSampling(newValue) }
                                                     }))
                .toggleStyle(.switch)
        }
        .padding(12)
        .background(style.overlayBackground)
        .foregroundColor(style.overlayForeground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("VolumetricHUD")
    }
}

private extension VolumetricSliceState {
    var axisLabel: String {
        switch axis {
        case .x: return "Axial"
        case .y: return "Coronal"
        case .z: return "Sagittal"
        }
    }
}

private extension RenderQualityState {
    var hudLabel: String {
        switch self {
        case .interacting:
            return "Preview"
        case .settling:
            return "Refining..."
        case .settled:
            return "Final"
        }
    }
}
#endif
