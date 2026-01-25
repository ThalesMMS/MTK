//  MPRGridComposer.swift
//  MTK
//  Minimal SwiftUI container syncing orthogonal MPR panes.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI) && os(iOS)
import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

public struct MPRGridComposer: View {
    private let volumeController: VolumetricSceneController
    private let axialController: VolumetricSceneController
    private let coronalController: VolumetricSceneController
    private let sagittalController: VolumetricSceneController
    private let style: any VolumetricUIStyle

    @State private var windowLevel = WindowLevelShift(window: 400, level: 40)
    @State private var slabThickness: Double = 3

    public init(volumeController: VolumetricSceneController,
                axialController: VolumetricSceneController,
                coronalController: VolumetricSceneController,
                sagittalController: VolumetricSceneController,
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        self.volumeController = volumeController
        self.axialController = axialController
        self.coronalController = coronalController
        self.sagittalController = sagittalController
        self.style = style
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                mprPane(axis: .axial, controller: axialController)
                mprPane(axis: .coronal, controller: coronalController)
            }
            HStack(spacing: 12) {
                mprPane(axis: .sagittal, controller: sagittalController)
                volumePane()
            }
            SlabThicknessControlView(thickness: $slabThickness, onCommit: commitSlab(thickness:))
            WindowLevelControlView(level: Binding(get: { windowLevel.level }, set: { windowLevel.level = $0 }),
                                   window: Binding(get: { windowLevel.window }, set: { windowLevel.window = $0 }),
                                   onCommit: commitWindowLevel)
        }
        .padding()
        .onAppear {
            windowLevel = WindowLevelShift(window: axialController.windowLevelState.window,
                                           level: axialController.windowLevelState.level)
        }
        .onReceive(axialController.$windowLevelState) { state in
            windowLevel = WindowLevelShift(window: state.window, level: state.level)
        }
    }

    private func mprPane(axis: VolumeGestureAxis,
                         controller: VolumetricSceneController) -> some View {
        let gestureConfiguration = VolumeGestureConfiguration(translationAxis: axis)
        return VolumetricDisplayContainer(controller: controller) {
            ZStack {
                CrosshairOverlayView(style: style)
                OrientationOverlayView(labels: labels(for: axis), style: style)
                VolumetricGestureOverlay(controller: controller,
                                         configuration: gestureConfiguration)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }

    private func volumePane() -> some View {
        return VolumetricDisplayContainer(controller: volumeController) {
            ZStack {
                VStack {
                    Spacer()
                    HStack {
                        Text("3D")
                            .font(.caption.bold())
                            .padding(6)
                            .background(style.overlayBackground.cornerRadius(12))
                            .foregroundStyle(style.overlayForeground)
                            .padding(8)
                        Spacer()
                    }
                }
                VolumetricGestureOverlay(controller: volumeController)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }

    private func commitSlab(thickness: Double) {
        Task {
            let snap = VolumetricSceneController.SlabConfiguration(thickness: Int(thickness), steps: 1)
            for controller in mprControllers {
                await controller.setMprSlab(thickness: snap.thickness, steps: snap.steps)
            }
        }
    }

    private func commitWindowLevel() {
        Task {
            let min = Int32(windowLevel.level - windowLevel.window / 2)
            let max = Int32(windowLevel.level + windowLevel.window / 2)
            for controller in mprControllers {
                await controller.setMprHuWindow(min: min, max: max)
            }
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

    private var mprControllers: [VolumetricSceneController] {
        [axialController, coronalController, sagittalController]
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

private extension MPRGridComposer {
    func mprIndex(for axis: VolumeGestureAxis) -> Int {
        switch axis {
        case .axial:
            return 0
        case .coronal:
            return 1
        case .sagittal:
            return 2
        case .volume:
            return 3
        }
    }
}
#endif
