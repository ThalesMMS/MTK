//
//  BasicVolumeRendering.swift
//  MTK Examples
//
//  Minimal engine-native volume rendering example.
//

import SwiftUI
import MTKCore
import MTKUI

/// Example purpose: minimal volume rendering setup and coordinator lifecycle.
///
/// ADR concepts demonstrated:
/// `VolumeDataset -> VolumeViewportCoordinator / VolumeViewportController ->
/// GPU upload -> MTKRenderingEngine render graph -> PresentationPass -> MTKView`.
/// See `MTK/Architecture/ClinicalRenderingADR.md`.
///
/// Interactive display stays Metal-native as `MTLTexture` all the way to
/// presentation. This example does not use SceneKit, and `CGImage` is never a
/// display surface. `CGImage` is allowed only at explicit export boundaries.
struct BasicVolumeRenderingView: View {
    @StateObject private var coordinator = VolumeViewportCoordinator.shared
    @State private var didConfigureExample = false

    var body: some View {
        Group {
            if let controller = coordinator.controller {
                VolumeViewportContainer(controller: controller) {
                    CrosshairOverlayView()
                }
            } else {
                ContentUnavailableView(
                    "Metal Not Available",
                    systemImage: "exclamationmark.triangle",
                    description: Text("MTK volume rendering requires a Metal-capable device.")
                )
            }
        }
        .task {
            await configureExampleIfNeeded()
        }
    }

    @MainActor
    private func configureExampleIfNeeded() async {
        guard coordinator.isMetalAvailable, !didConfigureExample else { return }
        didConfigureExample = true

        // ADR stage 1: create a VolumeDataset from voxel payload + geometry metadata.
        let dataset = makeSampleDataset()

        // ADR stage 2: hand the dataset to the viewport layer. The controller owns
        // the Metal-native presentation surface; the dataset is uploaded before the
        // render graph starts producing interactive frames for that MTKView.
        coordinator.apply(dataset: dataset)

        // ADR stage 3: configure visualization state that propagates to the active
        // volume viewport before rendering.
        coordinator.applyHuWindow(min: -160, max: 240)
        coordinator.apply(
            transferFunction: VolumeTransferFunctionLibrary.transferFunction(for: .ctSoftTissue)
        )

        // Camera state is configured through the controller API, not by manipulating
        // textures or attempting CGImage-based display shortcuts.
        if let controller = coordinator.controller {
            await controller.resetCamera()
            await controller.dollyCamera(delta: -0.15)
        }
    }

    private func makeSampleDataset() -> VolumeDataset {
        let width = 256
        let height = 256
        let depth = 160
        let voxelCount = width * height * depth
        let bytesPerVoxel = VolumePixelFormat.int16Signed.bytesPerVoxel
        let voxels = Data(repeating: 0, count: voxelCount * bytesPerVoxel)

        return VolumeDataset(
            data: voxels,
            dimensions: VolumeDimensions(width: width, height: height, depth: depth),
            spacing: VolumeSpacing(x: 0.0008, y: 0.0008, z: 0.0012),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071,
            recommendedWindow: -160...240
        )
    }
}

/// Companion example showing explicit runtime gating before creating rendering UI.
struct AvailabilityCheckExample: View {
    var body: some View {
        if MetalRuntimeAvailability.isAvailable() {
            BasicVolumeRenderingView()
        } else {
            ContentUnavailableView(
                "Metal Not Available",
                systemImage: "exclamationmark.triangle",
                description: Text("Metal GPU required for volume rendering.")
            )
        }
    }
}

/*
 ## Basic Usage

 ```swift
 @main
 struct MyApp: App {
     var body: some Scene {
         WindowGroup {
             BasicVolumeRenderingView()
         }
     }
 }
 ```

 ## Multi-Viewport Layouts

 Use `ClinicalViewportGrid` when the UI needs the standard 2x2 clinical layout
 with axial, coronal, sagittal, and 3D viewports sharing one dataset upload.

 Use `TriplanarMPRViewerExample` when the workflow is MPR-only and should keep
 the resource graph focused on axial/coronal/sagittal viewports.

 ## Snapshot / Export

 Keep interactive display on `MTKView`. For explicit readback or export:

 ```swift
 let snapshotExporter = TextureSnapshotExporter()
 let frame = try await coordinator.renderVolumeSnapshotFrame()
 try await snapshotExporter.writePNG(from: frame, to: url)
 ```

 If a caller explicitly needs `CGImage`, create it only at that export boundary:

 ```swift
 let image = try await snapshotExporter.makeCGImage(from: frame)
 ```
 */
