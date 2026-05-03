//
//  SynchronizedMPRGrid.swift
//  MTK Examples
//
//  SwiftUI example demonstrating embedding a synchronized MPR 2×2 grid using MTKUI.
//

import SwiftUI
import MTKCore
import MTKUI

/// Copy‑pasteable example: embed a synchronized 2×2 MPR grid.
///
/// This example uses `MPRGridComposer`, which is the convenience SwiftUI view that
/// composes four `VolumeViewportController`s (axial/coronal/sagittal + 3D) into a
/// single 2×2 layout, and keeps window/level + slab thickness synchronized across
/// the three MPR panes.
///
/// If you need a more engine-native / clinically-oriented grid controller, also see:
/// `MPRViewerExample` (ClinicalViewportGrid + ClinicalViewportGridController).
struct SynchronizedMPRGridExample: View {
    @StateObject private var coordinator = VolumeViewportCoordinator.shared

    @State private var didLoad = false

    private var configuration: VolumeViewportConfiguration {
        var config = VolumeViewportConfiguration.default
        config.overlays.showsCrosshair = true
        config.overlays.showsOrientationLabels = true
        config.gestures.allowsTranslation = true
        config.gestures.allowsZoom = true
        config.gestures.allowsRotation = true
        config.gestures.allowsWindowLevel = true
        config.gestures.allowsSlabThickness = true
        config.windowLevel.defaultWindow = 400
        config.windowLevel.defaultLevel = 40
        return config
    }

    var body: some View {
        Group {
            if let volumeController = coordinator.controller,
               let axialController = try? coordinator.controller(for: .z),
               let coronalController = try? coordinator.controller(for: .y),
               let sagittalController = try? coordinator.controller(for: .x) {
                MPRGridComposer(
                    volumeController: volumeController,
                    axialController: axialController,
                    coronalController: coronalController,
                    sagittalController: sagittalController,
                    configuration: configuration
                )
            } else {
                ProgressView()
            }
        }
        .task {
            guard coordinator.isMetalAvailable, await beginLoadingIfNeeded() else { return }

            // Load your dataset (DICOM, NIfTI, etc.) and apply it to all four controllers.
            let dataset = makeSampleDataset()
            let transferFunction = VolumeTransferFunctionLibrary.transferFunction(for: .ctSoftTissue)

            applyToCoordinator(dataset: dataset, transferFunction: transferFunction)
        }
    }

    @MainActor
    private func applyToCoordinator(dataset: VolumeDataset, transferFunction: TransferFunction?) {
        coordinator.apply(dataset: dataset)
        coordinator.apply(transferFunction: transferFunction)
        coordinator.configureMPRDisplay(axis: .z, normalizedPosition: 0.5)
        coordinator.configureMPRDisplay(axis: .y, normalizedPosition: 0.5)
        coordinator.configureMPRDisplay(axis: .x, normalizedPosition: 0.5)
    }

    @MainActor
    private func beginLoadingIfNeeded() -> Bool {
        guard !didLoad else { return false }
        didLoad = true
        return true
    }

    private func makeSampleDataset() -> VolumeDataset {
        // Minimal in-memory sample. Replace with real data in your app.
        let width = 256
        let height = 256
        let depth = 160
        let voxelCount = width * height * depth
        let bytesPerVoxel = VolumePixelFormat.int16Signed.bytesPerVoxel
        let voxels = Data(repeating: 0, count: voxelCount * bytesPerVoxel)

        return VolumeDataset(
            data: voxels,
            dimensions: VolumeDimensions(width: width, height: height, depth: depth),
            // Demo spacing is expressed in millimeters.
            spacing: VolumeSpacing(x: 0.75, y: 0.75, z: 1.0),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071,
            recommendedWindow: -160...240
        )
    }
}
