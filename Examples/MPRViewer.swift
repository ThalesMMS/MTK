//
//  MPRViewer.swift
//  MTK Examples
//
//  Clinical 2x2 MPR + volume example using the public clinical viewport session.
//

import SwiftUI
import MTKCore
import MTKUI

/// Example purpose: `ClinicalViewportGrid` as the canonical clinical layout component.
///
/// ADR concepts demonstrated:
/// `ClinicalViewportGrid` owns the canonical 2x2 layout:
/// axial, coronal, sagittal, and 3D. The associated
/// `ClinicalViewportSession` keeps crosshairs, orientation overlays,
/// window/level, and slab state synchronized while a single shared dataset
/// upload backs all four panes through internal `VolumeResourceHandle`
/// management. See `MTK/Architecture/ClinicalRenderingADR.md`.
///
/// Interactive presentation remains `MTLTexture -> PresentationPass -> MTKView`.
/// This example does not use SceneKit, and it does not use `CGImage` for
/// display.
struct MPRViewerExample: View {
    @State private var session: ClinicalViewportSession?
    @State private var didConfigureExample = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let session {
                VStack(spacing: 16) {
                    ClinicalViewportGrid(session: session)
                    controls(for: session)
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "Failed to Prepare Clinical Grid",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Preparing clinical viewport grid...")
            }
        }
        .task {
            await configureExampleIfNeeded()
        }
        .onDisappear {
            let session = session
            Task {
                await session?.shutdown()
                self.session = nil
                didConfigureExample = false
            }
        }
    }

    @ViewBuilder
    private func controls(for session: ClinicalViewportSession) -> some View {
        HStack(spacing: 12) {
            Button("Scroll Axial") {
                Task { await session.scrollSlice(axis: .axial, deltaNormalized: 0.08) }
            }

            Button("Soft Tissue WW/L") {
                Task { await session.setMPRWindowLevel(window: 400, level: 40) }
            }

            Button("Center Crosshair") {
                Task {
                    await session.setCrosshair(
                        in: .axial,
                        normalizedPoint: CGPoint(x: 0.5, y: 0.5)
                    )
                }
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
    }

    @MainActor
    private func configureExampleIfNeeded() async {
        guard !didConfigureExample else { return }
        didConfigureExample = true
        errorMessage = nil

        do {
            let dataset = makeSampleDataset()
            let transferFunction = VolumeTransferFunctionLibrary.transferFunction(for: .ctSoftTissue)

            // This call performs one dataset load for the full clinical layout.
            // The session then binds the same shared GPU resource handle to
            // axial, coronal, sagittal, and volume viewports.
            let session = try await ClinicalViewportSession.make(
                dataset: dataset,
                transferFunction: transferFunction
            )

            self.session = session

            // `make(dataset:transferFunction:)` already applied the dataset,
            // recommended window, and default slab thickness. Keep one
            // deliberate non-default interaction here to show post-load API use.
            await session.scrollSlice(axis: .coronal, deltaNormalized: 0.05)
        } catch {
            self.session = nil
            didConfigureExample = false
            errorMessage = error.localizedDescription
        }
    }

    private func makeSampleDataset() -> VolumeDataset {
        let width = 384
        let height = 384
        let depth = 220
        let voxelCount = width * height * depth
        let bytesPerVoxel = VolumePixelFormat.int16Signed.bytesPerVoxel
        let voxels = Data(repeating: 0, count: voxelCount * bytesPerVoxel)

        return VolumeDataset(
            data: voxels,
            dimensions: VolumeDimensions(width: width, height: height, depth: depth),
            spacing: VolumeSpacing(x: 0.00075, y: 0.00075, z: 0.0010),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071,
            recommendedWindow: -160...240
        )
    }
}

/*
 `ClinicalViewportSession.make()` creates one public clinical session and
 one shared `VolumeResourceHandle` for all four panes. The grid then drives:

 - `scrollSlice(axis:deltaNormalized:)` for slice navigation
 - `setMPRWindowLevel(window:level:)` for synchronized MPR WW/L
 - `setCrosshair(in:normalizedPoint:)` for crosshair-driven slice coupling

 No example path here uses SceneKit or `CGImage` for interactive display.
 */
