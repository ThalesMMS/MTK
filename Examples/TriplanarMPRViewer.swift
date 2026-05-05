//
//  TriplanarMPRViewer.swift
//  MTK Examples
//
//  MPR-only example using public VolumeViewport contracts.
//

import SwiftUI
import MTKCore
import MTKUI

/// Example purpose: triplanar MPR setup through the public MPR viewport contract.
///
/// ADR concepts demonstrated:
/// `VolumeDataset -> VolumeViewport -> MetalViewportView` for axial, coronal,
/// and sagittal review. Use `ClinicalViewportSession` when the UI needs the
/// reference shared 2x2 clinical layout.
///
/// Interactive MPR presentation remains Metal-native as `MTLTexture` until
/// `PresentationPass` presents into `MTKView`. This example does not use
/// SceneKit or `CGImage` for display.
struct TriplanarMPRViewerExample: View {
    @State private var axialViewport: VolumeViewport?
    @State private var coronalViewport: VolumeViewport?
    @State private var sagittalViewport: VolumeViewport?
    @State private var didConfigureExample = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let axialViewport, let coronalViewport, let sagittalViewport {
                TriplanarMPRContent(
                    axialViewport: axialViewport,
                    coronalViewport: coronalViewport,
                    sagittalViewport: sagittalViewport
                )
            } else if let errorMessage {
                ContentUnavailableView(
                    "Failed to Prepare Triplanar Viewer",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Preparing triplanar MPR viewports...")
            }
        }
        .task {
            await configureExampleIfNeeded()
        }
    }

    @MainActor
    private func configureExampleIfNeeded() async {
        guard !didConfigureExample else { return }
        didConfigureExample = true
        errorMessage = nil

        do {
            let dataset = makeSampleDataset()
            let axial = try VolumeViewport(axis: .axial, normalizedSlicePosition: 0.35)
            let coronal = try VolumeViewport(axis: .coronal, normalizedSlicePosition: 0.50)
            let sagittal = try VolumeViewport(axis: .sagittal, normalizedSlicePosition: 0.65)

            for viewport in [axial, coronal, sagittal] {
                await viewport.applyDataset(dataset)
                await viewport.setWindowLevel(window: 400, level: 40)
            }

            axialViewport = axial
            coronalViewport = coronal
            sagittalViewport = sagittal
        } catch {
            axialViewport = nil
            coronalViewport = nil
            sagittalViewport = nil
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

@MainActor
private struct TriplanarMPRContent: View {
    @ObservedObject var axialViewport: VolumeViewport
    @ObservedObject var coronalViewport: VolumeViewport
    @ObservedObject var sagittalViewport: VolumeViewport

    var body: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                TriplanarMPRPane(title: "Axial", viewport: axialViewport)
                TriplanarMPRPane(title: "Coronal", viewport: coronalViewport)
                TriplanarMPRPane(title: "Sagittal", viewport: sagittalViewport)
            }
            .padding(.horizontal)

            sliceControls
        }
    }

    private var sliceControls: some View {
        VStack(spacing: 12) {
            slider(title: "Axial Slice", viewport: axialViewport)
            slider(title: "Coronal Slice", viewport: coronalViewport)
            slider(title: "Sagittal Slice", viewport: sagittalViewport)
        }
        .padding(.horizontal)
    }

    private func slider(title: String, viewport: VolumeViewport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            Slider(
                value: Binding(
                    get: { Double(viewport.normalizedSlicePosition) },
                    set: { newValue in
                        Task { await viewport.setSlicePosition(Float(newValue)) }
                    }
                ),
                in: 0...1
            )
        }
    }
}

@MainActor
private struct TriplanarMPRPane: View {
    let title: String
    @ObservedObject var viewport: VolumeViewport

    var body: some View {
        ZStack(alignment: .topLeading) {
            MetalViewportView(surface: viewport.surface)
            Text(title)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
                .padding(8)
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/*
 This example is intentionally MPR-only. It does not create a 3D pane, does not
 use SceneKit, and does not instantiate render graph or engine internals.
 `CGImage` remains export-only and is not part of the interactive display path.
 */
