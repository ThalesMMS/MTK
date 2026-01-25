//  VolumetricHUD.swift
//  MTK
//  Simple HUD showing controller state and toggles.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public struct VolumetricHUD: View {
    @ObservedObject private var controller: VolumetricSceneController
    private let style: any VolumetricUIStyle

    public init(controller: VolumetricSceneController,
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        self.controller = controller
        self.style = style
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Camera z: \(controller.cameraState.position.z, specifier: "%.2f")")
            Text("Slice: \(controller.sliceState.axisLabel) @ \(Int(controller.sliceState.normalizedPosition * 100))%")
            Text("Window/Level: \(Int(controller.windowLevelState.window)) / \(Int(controller.windowLevelState.level))")
            Toggle("Adaptive Sampling", isOn: Binding(get: { controller.adaptiveSamplingEnabled },
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
#endif
