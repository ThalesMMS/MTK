//
//  DicomLoader.swift
//  MTK Examples
//
//  Canonical DICOM loading example for the engine-native rendering path.
//

import SwiftUI
import MTKCore
import MTKUI

/// Example purpose: DICOM loading pipeline stages matching the ADR diagram.
///
/// ADR concepts demonstrated:
/// the example uses `DicomVolumeLoader.loadVolume(from:progress:completion:)`
/// as the canonical import path, then applies the resulting `VolumeDataset`
/// through `ClinicalViewportGridController.applyDataset(_:)`. That call routes
/// the dataset into `MTKRenderingEngine`, which acquires a shared
/// `VolumeResourceHandle` through `VolumeResourceManager` before binding the
/// same GPU resource to the clinical viewports. See
/// `MTK/Architecture/ClinicalRenderingADR.md`.
///
/// Interactive display remains Metal-native as `MTLTexture` through
/// `PresentationPass`. This example does not use SceneKit, and it never uses
/// `CGImage` as a display surface.
struct BasicDicomLoaderExample: View {
    @State private var controller: ClinicalViewportGridController?
    @State private var isLoading = false
    @State private var loadingProgress = 0.0
    @State private var totalSlices = 0
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let controller {
                ClinicalViewportGrid(controller: controller)
            } else if isLoading {
                loadingState
            } else if let errorMessage {
                ContentUnavailableView(
                    "Failed to Load DICOM",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ContentUnavailableView(
                    "No DICOM Source Selected",
                    systemImage: "folder",
                    description: Text("Pass a directory, ZIP archive, or DICOM file URL to load the dataset.")
                )
            }
        }
        .task {
            // In a real app, pass a user-selected URL:
            // await loadDicomVolume(from: selectedURL)
        }
        .onDisappear {
            let controller = controller
            Task {
                await controller?.shutdown()
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView("Loading DICOM series...", value: loadingProgress, total: 1)
                .progressViewStyle(.linear)

            if totalSlices > 0 {
                Text("Processing \(Int(loadingProgress * Double(totalSlices))) of \(totalSlices) slices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    @MainActor
    private func loadDicomVolume(from url: URL) async {
        isLoading = true
        loadingProgress = 0
        totalSlices = 0
        errorMessage = nil
        defer { isLoading = false }

        let loader = DicomVolumeLoader()

        do {
            // DICOM -> VolumeDataset
            let importResult = try await importDicomVolume(from: url, using: loader)
            let dataset = importResult.dataset

            let controller = try await resolvedController()

            // VolumeDataset -> VolumeResourceManager -> shared GPU texture(s)
            // for all four clinical viewports via one controller-level dataset load.
            try await controller.applyDataset(dataset)

            // Use the recommended clinical window when available; otherwise fall
            // back to the dataset intensity range.
            let window = dataset.recommendedWindow ?? dataset.intensityRange
            let windowWidth = max(Double(window.upperBound - window.lowerBound), 1)
            let windowLevel = Double(window.lowerBound + window.upperBound) / 2
            await controller.setMPRWindowLevel(window: windowWidth, level: windowLevel)

            try await controller.setTransferFunction(
                VolumeTransferFunctionLibrary.transferFunction(for: .ctSoftTissue)
            )
        } catch {
            errorMessage = makeUserFacingMessage(for: error)
        }
    }

    @MainActor
    private func resolvedController() async throws -> ClinicalViewportGridController {
        if let controller {
            return controller
        }

        let controller = try await ClinicalViewportGridController.make()
        self.controller = controller
        return controller
    }

    private func importDicomVolume(from url: URL,
                                   using loader: DicomVolumeLoader) async throws -> DicomImportResult {
        try await withCheckedThrowingContinuation { continuation in
            loader.loadVolume(
                from: url,
                progress: { progress in
                    Task { @MainActor in
                        handle(progress)
                    }
                },
                completion: { result in
                    continuation.resume(with: result)
                }
            )
        }
    }

    @MainActor
    private func handle(_ progress: DicomVolumeProgress) {
        switch progress {
        case .started(let sliceCount):
            totalSlices = sliceCount
            loadingProgress = 0
        case .reading(let fraction):
            loadingProgress = fraction
        }
    }

    private func makeUserFacingMessage(for error: Error) -> String {
        guard let loaderError = error as? DicomVolumeLoaderError else {
            return error.localizedDescription
        }

        switch loaderError {
        case .securityScopeUnavailable:
            return "The selected files could not be accessed."
        case .unsupportedBitDepth:
            return "Only 16-bit scalar DICOM series are currently supported."
        case .missingResult:
            return "The DICOM loader did not return a volume dataset."
        case .pathTraversal:
            return "The selected archive contains invalid paths and was rejected."
        case .bridgeError(let nsError):
            return nsError.localizedDescription
        }
    }
}

/*
 `DicomVolumeLoader` remains the canonical importer for directories, archives,
 and individual DICOM files. After loading:

 1. `DicomVolumeLoader` produces a `VolumeDataset`.
 2. `ClinicalViewportGridController.applyDataset(_:)` forwards that dataset into
    `MTKRenderingEngine`.
 3. `VolumeResourceManager` acquires one shared GPU volume resource.
 4. `PresentationPass` displays interactive Metal frames through `MTKView`.

 Snapshot/export remains an explicit `TextureSnapshotExporter` workflow; the
 interactive display path never uses `CGImage`.
 */
