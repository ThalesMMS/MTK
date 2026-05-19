//
//  DicomLoader.swift
//  MTK Examples
//
//  Canonical DICOM loading example for the engine-native rendering path.
//

import SwiftUI
import MTKCore
import MTKDicomBridge
import MTKUI

/// Example purpose: DICOM loading pipeline stages matching the ADR diagram.
///
/// ADR concepts demonstrated:
/// the example uses `DicomVolumeDatasetImporter.loadDataset(from:progress:completion:)`
/// to bridge a DICOM-Decoder result into `VolumeDataset`, then applies that
/// dataset through `ClinicalViewportSession.applyDataset(_:)`. That call routes the
/// dataset into the clinical grid implementation, which acquires a shared
/// `VolumeResourceHandle` through `VolumeResourceManager` before binding the
/// same GPU resource to the clinical viewports. See
/// `MTK/Architecture/ClinicalRenderingADR.md`.
///
/// Interactive display remains Metal-native as `MTLTexture` through
/// `PresentationPass`. This example does not use SceneKit, and it never uses
/// `CGImage` as a display surface.
struct BasicDicomLoaderExample: View {
    @State private var session: ClinicalViewportSession?
    @State private var isLoading = false
    @State private var loadingProgress = 0.0
    @State private var totalSlices = 0
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let session {
                ClinicalViewportGrid(session: session)
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
            let session = session
            Task {
                await session?.shutdown()
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

        let importer = DicomVolumeDatasetImporter()

        do {
            // DICOM -> VolumeDataset
            let importResult = try await importDicomVolume(from: url, using: importer)
            let dataset = importResult.dataset

            let session = try await resolvedSession()

            // VolumeDataset -> VolumeResourceManager -> shared GPU texture(s)
            // for all four clinical viewports via one session-level dataset load.
            try await session.applyDataset(dataset)

            // Use the recommended clinical window when available; otherwise fall
            // back to the dataset intensity range.
            let window = dataset.recommendedWindow ?? dataset.intensityRange
            let windowWidth = max(Double(window.upperBound - window.lowerBound), 1)
            let windowLevel = Double(window.lowerBound + window.upperBound) / 2
            await session.setMPRWindowLevel(window: windowWidth, level: windowLevel)

            try await session.setTransferFunction(
                VolumeTransferFunctionLibrary.transferFunction(for: .ctSoftTissue)
            )
        } catch {
            errorMessage = makeUserFacingMessage(for: error)
        }
    }

    @MainActor
    private func resolvedSession() async throws -> ClinicalViewportSession {
        if let session {
            return session
        }

        let session = try await ClinicalViewportSession.make()
        self.session = session
        return session
    }

    private func importDicomVolume(from url: URL,
                                   using importer: VolumeDatasetImporting) async throws -> DicomVolumeDatasetImportResult {
        try await withCheckedThrowingContinuation { continuation in
            importer.loadDataset(
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
    private func handle(_ progress: DicomVolumeDatasetImportProgress) {
        switch progress {
        case .started(let sliceCount):
            totalSlices = sliceCount
            loadingProgress = 0
        case .reading(let fraction, _):
            loadingProgress = fraction
        }
    }

    private func makeUserFacingMessage(for error: Error) -> String {
        error.localizedDescription
    }
}

/*
 `DICOM-Decoder` remains the canonical importer for directories, archives, and
 individual DICOM files. `MTKDicomBridge` only converts the decoded result:

 1. `DicomVolumeDatasetImporter` produces a `VolumeDataset`.
 2. `ClinicalViewportSession.applyDataset(_:)` forwards that dataset into the
    Metal-native clinical grid implementation.
 3. `VolumeResourceManager` acquires one shared GPU volume resource.
 4. `PresentationPass` displays interactive Metal frames through `MTKView`.

 Snapshot/export remains an explicit `TextureSnapshotExporter` workflow; the
 interactive display path never uses `CGImage`.
 */
