//  MPRGridComposer.swift
//  MTK
//  Minimal SwiftUI container syncing orthogonal MPR panes.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI) && os(iOS)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public struct MPRGridComposer: View {
    private let controller: VolumetricSceneController
    private let style: any VolumetricUIStyle

    @State private var windowLevel = WindowLevelShift(window: 400, level: 40)
    @State private var slabThickness: Double = 3

    public init(controller: VolumetricSceneController,
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        self.controller = controller
        self.style = style
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                mprPane(axis: .axial)
                mprPane(axis: .coronal)
            }
            HStack(spacing: 12) {
                mprPane(axis: .sagittal)
                volumePane()
            }
            SlabThicknessControlView(thickness: $slabThickness, onCommit: commitSlab(thickness:))
            WindowLevelControlView(level: Binding(get: { windowLevel.level }, set: { windowLevel.level = $0 }),
                                   window: Binding(get: { windowLevel.window }, set: { windowLevel.window = $0 }),
                                   onCommit: commitWindowLevel)
        }
        .padding()
    }

    private func mprPane(axis: VolumeGestureAxis) -> some View {
        ZStack(alignment: .center) {
            Color.black.opacity(0.08)
                .aspectRatio(1, contentMode: .fit)
                .overlay(CrosshairOverlayView(style: style))
            OrientationOverlayView(labels: labels(for: axis), style: style)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            Task { await controller.setDisplayConfiguration(.mpr(axis: axis.toControllerAxis(), index: 0, blend: .single, slab: nil)) }
        }
    }

    private func volumePane() -> some View {
        ZStack {
            Color.black.opacity(0.08)
            Text("3D")
                .foregroundStyle(style.overlayForeground)
                .padding(4)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            Task { await controller.setDisplayConfiguration(.volume(method: .directVolumeRendering)) }
        }
    }

    private func commitSlab(thickness: Double) {
        Task {
            let snap = VolumetricSceneController.SlabConfiguration(thickness: Int(thickness), steps: 1)
            await controller.setMprSlab(thickness: snap.thickness, steps: snap.steps)
        }
    }

    private func commitWindowLevel() {
        Task {
            let min = Int32(windowLevel.level - windowLevel.window / 2)
            let max = Int32(windowLevel.level + windowLevel.window / 2)
            await controller.setMprHuWindow(min: min, max: max)
        }
    }

    private func labels(for axis: VolumeGestureAxis) -> (String, String, String, String) {
        switch axis {
        case .axial:
            return ("R", "L", "A", "P")
        case .coronal:
            return ("R", "L", "S", "I")
        case .sagittal:
            return ("P", "A", "S", "I")
        case .volume:
            return ("", "", "", "")
        }
    }
}

private extension VolumeGestureAxis {
    func toControllerAxis() -> VolumetricSceneController.Axis {
        switch self {
        case .sagittal:
            return .x
        case .coronal:
            return .y
        case .axial, .volume:
            return .z
        }
    }
}
#endif
