//
//  TriplanarMPRViewer.swift
//  MTK Examples
//
//  Tri-planar-only Multi-Planar Reconstruction (MPR) examples without a 3D pane
//  Thales Matheus Mendonca Santos - April 2026
//
//  NOTE: This is example/documentation code demonstrating MTK's MPR-only
//  composition path. For complete implementation, see the MTK-Demo app.
//

import SwiftUI
import MTKCore
import MTKUI

// MARK: - Tri-Planar MPR Viewer

/// SwiftUI example demonstrating axial, coronal, and sagittal MPR without a 3D pane.
///
/// `TriplanarMPRViewerExample` uses ``VolumetricSceneCoordinator`` to provide one
/// controller for each anatomical MPR axis:
/// - `.z` for axial
/// - `.y` for coronal
/// - `.x` for sagittal
///
/// No volume controller is requested, loaded, or synchronized. This keeps the setup
/// focused on orthogonal MPR review and avoids provisioning the 3D render surface.
struct TriplanarMPRViewerExample: View {

    @ObservedObject private var coordinator = VolumetricSceneCoordinator.shared
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var axialController: VolumetricSceneController {
        coordinator.controller(for: .z)
    }

    private var coronalController: VolumetricSceneController {
        coordinator.controller(for: .y)
    }

    private var sagittalController: VolumetricSceneController {
        coordinator.controller(for: .x)
    }

    var body: some View {
        ZStack {
            if isLoading {
                ProgressView("Loading MPR volume...")
            } else {
                TriplanarMPRComposer(
                    axialController: axialController,
                    coronalController: coronalController,
                    sagittalController: sagittalController,
                    layout: .grid
                )
            }

            if let error = errorMessage {
                ContentUnavailableView(
                    "Failed to Load Volume",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            }
        }
        .task {
            await setupTriplanarVolume()
        }
    }

    /// Initializes a synthetic volume, applies it to the three MPR controllers, and configures their initial display state.
    /// 
    /// Creates a sample VolumeDataset, loads it into the axial, coronal, and sagittal MPR controllers only, sets each MPR plane's display/position, and applies a shared window/level and slab thickness.
    /// - Note: While running `isLoading` is set to `true` and reset when complete. On failure `errorMessage` is assigned the error's localized description.

    private func setupTriplanarVolume() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let dataset = try createSampleDataset()

            // Load the dataset into the three MPR controllers only.
            await TriplanarMPRExampleHelpers.applyDatasetToMPRControllers(
                dataset,
                axialController: axialController,
                coronalController: coronalController,
                sagittalController: sagittalController
            )

            // Configure initial MPR display state for each anatomical axis.
            TriplanarMPRExampleHelpers.configureMPRPlanes(coordinator: coordinator)
            await TriplanarMPRExampleHelpers.configureWindowLevel(
                min: -160,
                max: 240,
                axialController: axialController,
                coronalController: coronalController,
                sagittalController: sagittalController
            )
            await TriplanarMPRExampleHelpers.configureSlabThickness(
                thickness: 3,
                steps: 6,
                axialController: axialController,
                coronalController: coronalController,
                sagittalController: sagittalController
            )

        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Creates a synthetic volumetric dataset for the example.
    ///
    /// In a real application, this would come from DICOM files or another medical
    /// volume source.
    /// - Returns: A zero-filled `VolumeDataset` with CT-like dimensions, spacing,
    ///   pixel format, and intensity range.
    private func createSampleDataset() throws -> VolumeDataset {
        let width = 512
        let height = 512
        let depth = 300
        let voxelCount = width * height * depth
        let bytesPerVoxel = VolumePixelFormat.int16Signed.bytesPerVoxel
        let voxels = Data(repeating: 0, count: voxelCount * bytesPerVoxel)

        return VolumeDataset(
            data: voxels,
            dimensions: VolumeDimensions(width: width, height: height, depth: depth),
            spacing: VolumeSpacing(x: 0.0007, y: 0.0007, z: 0.001),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071
        )
    }

}

// MARK: - DICOM Loading with Tri-Planar MPR

/// Example showing DICOM loading into a tri-planar-only MPR viewer.
///
/// This variant uses ``DicomDecoderSeriesLoader`` with ``DicomVolumeLoader`` and
/// applies the resulting dataset to the three MPR controllers only.
struct DicomTriplanarExample: View {

    @ObservedObject private var coordinator = VolumetricSceneCoordinator.shared
    @State private var isLoading = false
    @State private var loadingProgress: Double = 0
    @State private var errorMessage: String?

    private var axialController: VolumetricSceneController {
        coordinator.controller(for: .z)
    }

    private var coronalController: VolumetricSceneController {
        coordinator.controller(for: .y)
    }

    private var sagittalController: VolumetricSceneController {
        coordinator.controller(for: .x)
    }

    var body: some View {
        VStack {
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView("Loading DICOM series...", value: loadingProgress, total: 1)
                        .progressViewStyle(.linear)
                    Text("\(Int(loadingProgress * 100))% complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                TriplanarMPRComposer(
                    axialController: axialController,
                    coronalController: coronalController,
                    sagittalController: sagittalController,
                    layout: .horizontal
                )
            }
        }
        .overlay {
            if let error = errorMessage {
                ContentUnavailableView(
                    "Failed to Load DICOM",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            }
        }
        .task {
            // In a real app, get this URL from a file picker or document browser.
            // await loadDicomSeries(from: dicomSeriesURL)
        }
    }

    /// Loads a DICOM series from the provided URL, applies the imported volume to the axial/coronal/sagittal MPR controllers, and configures MPR planes, shared window/level, and slab thickness.
    /// - Parameter url: File URL of the DICOM series to load.
    /// - Note: Updates `isLoading` and `loadingProgress` while running; on error sets `errorMessage` with a localized failure description.

    private func loadDicomSeries(from url: URL) async {
        errorMessage = nil
        isLoading = true
        loadingProgress = 0
        defer { isLoading = false }

        do {
            let loader = DicomVolumeLoader(seriesLoader: DicomDecoderSeriesLoader())
            let result = try await loadVolume(from: url, using: loader)
            let dataset = result.dataset

            await TriplanarMPRExampleHelpers.applyDatasetToMPRControllers(
                dataset,
                axialController: axialController,
                coronalController: coronalController,
                sagittalController: sagittalController
            )
            TriplanarMPRExampleHelpers.configureMPRPlanes(coordinator: coordinator)

            let window = dataset.recommendedWindow ?? dataset.intensityRange
            await TriplanarMPRExampleHelpers.configureWindowLevel(
                min: window.lowerBound,
                max: window.upperBound,
                axialController: axialController,
                coronalController: coronalController,
                sagittalController: sagittalController
            )
            await TriplanarMPRExampleHelpers.configureSlabThickness(
                thickness: 3,
                steps: 6,
                axialController: axialController,
                coronalController: coronalController,
                sagittalController: sagittalController
            )

        } catch {
            errorMessage = "Failed to load DICOM: \(error.localizedDescription)"
        }
    }

    /// Loads a DICOM volume from the given URL using the provided DICOM loader and returns the import result.
    /// - Parameters:
    ///   - url: The file URL of the DICOM series to import.
    ///   - loader: The `DicomVolumeLoader` instance used to perform the import; its progress callbacks update `loadingProgress`.
    /// - Returns: The `DicomImportResult` produced by the loader on successful import.
    /// - Throws: An error produced by the loader if the import fails.
    private func loadVolume(from url: URL,
                            using loader: DicomVolumeLoader) async throws -> DicomImportResult {
        try await withCheckedThrowingContinuation { continuation in
            loader.loadVolume(from: url, progress: { update in
                switch update {
                case .started(_):
                    loadingProgress = 0
                case .reading(let fraction):
                    loadingProgress = fraction
                }
            }, completion: { result in
                continuation.resume(with: result)
            })
        }
    }

}

// MARK: - Shared Tri-Planar Example Helpers

@MainActor
private enum TriplanarMPRExampleHelpers {
    /// Applies the dataset to axial, coronal, and sagittal controllers only.
    /// - Parameters:
    ///   - dataset: The dataset to apply to each MPR controller.
    ///   - axialController: The axial MPR controller.
    ///   - coronalController: The coronal MPR controller.
    ///   - sagittalController: The sagittal MPR controller.
    static func applyDatasetToMPRControllers(_ dataset: VolumeDataset,
                                             axialController: VolumetricSceneController,
                                             coronalController: VolumetricSceneController,
                                             sagittalController: VolumetricSceneController) async {
        await axialController.applyDataset(dataset)
        await coronalController.applyDataset(dataset)
        await sagittalController.applyDataset(dataset)
    }

    /// Configures the coordinator's cached MPR plane state for axial, coronal, and sagittal axes.
    static func configureMPRPlanes(coordinator: VolumetricSceneCoordinator) {
        coordinator.configureMPRDisplay(axis: .z, blend: .single, normalizedPosition: 0.5)
        coordinator.configureMPRDisplay(axis: .y, blend: .single, normalizedPosition: 0.5)
        coordinator.configureMPRDisplay(axis: .x, blend: .single, normalizedPosition: 0.5)
    }

    /// Sets the shared MPR Hounsfield unit (HU) window on the axial, coronal, and sagittal controllers.
    /// - Parameters:
    ///   - min: Lower bound of the HU window.
    ///   - max: Upper bound of the HU window.
    ///   - axialController: The axial MPR controller.
    ///   - coronalController: The coronal MPR controller.
    ///   - sagittalController: The sagittal MPR controller.
    static func configureWindowLevel(min: Int32,
                                     max: Int32,
                                     axialController: VolumetricSceneController,
                                     coronalController: VolumetricSceneController,
                                     sagittalController: VolumetricSceneController) async {
        await axialController.setMprHuWindow(min: min, max: max)
        await coronalController.setMprHuWindow(min: min, max: max)
        await sagittalController.setMprHuWindow(min: min, max: max)
    }

    /// Sets the MPR slab configuration for axial, coronal, and sagittal views.
    /// - Parameters:
    ///   - thickness: Number of slices included in the slab.
    ///   - steps: Number of sampling steps used when compositing the slab.
    ///   - axialController: The axial MPR controller.
    ///   - coronalController: The coronal MPR controller.
    ///   - sagittalController: The sagittal MPR controller.
    static func configureSlabThickness(thickness: Int,
                                       steps: Int,
                                       axialController: VolumetricSceneController,
                                       coronalController: VolumetricSceneController,
                                       sagittalController: VolumetricSceneController) async {
        await axialController.setMprSlab(thickness: thickness, steps: steps)
        await coronalController.setMprSlab(thickness: thickness, steps: steps)
        await sagittalController.setMprSlab(thickness: thickness, steps: steps)
    }
}

// MARK: - Usage Notes

/*
 ## Choosing an MPR Composer

 Use `TriplanarMPRComposer` when the workflow is axial/coronal/sagittal review and
 the interface does not need a 3D volume pane. It keeps controller setup smaller,
 avoids loading a volume controller, and makes MPR synchronization easier to reason
 about.

 Use `MPRGridComposer` when the user benefits from 3D anatomical context alongside
 the three orthogonal planes. That layout intentionally provisions four controllers:
 one volume controller plus axial, coronal, and sagittal MPR controllers.

 ## Controller Mapping

 ```swift
 let axialController = coordinator.controller(for: .z)
 let coronalController = coordinator.controller(for: .y)
 let sagittalController = coordinator.controller(for: .x)
 ```

 ## Dataset Loading

 For tri-planar-only MPR, load the dataset into those three controllers:

 ```swift
 await axialController.applyDataset(dataset)
 await coronalController.applyDataset(dataset)
 await sagittalController.applyDataset(dataset)
 ```

 Request `coordinator.controller` only when the UI includes a 3D pane.
 */
