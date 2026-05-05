//
//  SynchronizedMPRGrid.swift
//  MTK Examples
//
//  SwiftUI example demonstrating a synchronized clinical 2x2 grid.
//

import SwiftUI
import MTKCore
import MTKUI

/// Copy-pasteable example: embed a synchronized 2x2 MPR grid.
///
/// The session owns axial, coronal, sagittal, and 3D viewports through the
/// public MTKUI contract. Window/level, crosshair, and slice changes are routed
/// through `ClinicalViewportSession`, not controller or render graph internals.
struct SynchronizedMPRGridExample: View {
    @State private var didLoad = false
    @State private var session: ClinicalViewportSession?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let session {
                VStack(spacing: 12) {
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
            await loadIfNeeded()
        }
        .onDisappear {
            let session = session
            Task { await session?.shutdown() }
        }
    }

    @ViewBuilder
    private func controls(for session: ClinicalViewportSession) -> some View {
        HStack(spacing: 12) {
            Button("Axial +") {
                Task { await session.scrollSlice(axis: .axial, deltaNormalized: 0.04) }
            }

            Button("Coronal +") {
                Task { await session.scrollSlice(axis: .coronal, deltaNormalized: 0.04) }
            }

            Button("Center") {
                Task {
                    await session.setCrosshair(
                        in: .axial,
                        normalizedPoint: CGPoint(x: 0.5, y: 0.5)
                    )
                    await session.setMPRWindowLevel(window: 400, level: 40)
                }
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
    }

    @MainActor
    private func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        errorMessage = nil

        do {
            let dataset = makeSampleDataset()
            let transferFunction = VolumeTransferFunctionLibrary.transferFunction(for: .ctSoftTissue)
            session = try await ClinicalViewportSession.make(
                dataset: dataset,
                transferFunction: transferFunction
            )
        } catch {
            didLoad = false
            session = nil
            errorMessage = error.localizedDescription
        }
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
            spacing: VolumeSpacing(x: 0.75, y: 0.75, z: 1.0),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071,
            recommendedWindow: -160...240
        )
    }
}
