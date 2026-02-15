//
//  MPRViewer.swift
//  MTK Examples
//
//  Comprehensive example showing Multi-Planar Reconstruction (MPR) with synchronized tri-planar views
//  Thales Matheus Mendonça Santos — February 2026
//
//  NOTE: This is example/documentation code demonstrating MTK's MPR capabilities.
//  For complete implementation, see MTK-Demo app and MPRGuide.md documentation.
//

import SwiftUI
import MTKCore
import MTKUI

// MARK: - MPR Viewer with Synchronized Tri-Planar Views

/// Comprehensive SwiftUI view demonstrating multi-planar reconstruction (MPR)
///
/// This example shows how to set up synchronized axial, coronal, and sagittal views
/// alongside a 3D volumetric view using ``MPRGridComposer``. The grid automatically
/// synchronizes window/level and slab thickness settings across all MPR panes.
///
/// The 2×2 grid layout:
/// ```
/// ┌─────────┬─────────┐
/// │  Axial  │ Coronal │
/// ├─────────┼─────────┤
/// │Sagittal │   3D    │
/// └─────────┴─────────┘
/// ```
///
/// Each MPR pane displays:
/// - Crosshair overlay at the current slice intersection
/// - Anatomical orientation labels (R/L/A/P/S/I)
/// - Gesture support for slice scrolling and window/level adjustment
///
/// The 3D pane shows the full volumetric rendering with free rotation.
struct MPRViewerExample: View {

    // Four separate controllers for synchronized MPR views
    @StateObject private var volumeController = VolumetricSceneController()
    @StateObject private var axialController = VolumetricSceneController()
    @StateObject private var coronalController = VolumetricSceneController()
    @StateObject private var sagittalController = VolumetricSceneController()

    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            if isLoading {
                ProgressView("Loading volume data...")
            } else {
                MPRGridComposer(
                    volumeController: volumeController,
                    axialController: axialController,
                    coronalController: coronalController,
                    sagittalController: sagittalController
                )
            }

            // Error overlay
            if let error = errorMessage {
                VStack {
                    ContentUnavailableView(
                        "Failed to Load Volume",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                    Button("Retry") {
                        errorMessage = nil
                        Task { await setupMPRVolume() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .task {
            await setupMPRVolume()
        }
    }

    // MARK: - MPR Volume Setup

    private func setupMPRVolume() async {
        isLoading = true
        defer { isLoading = false }

        do {
            // Step 1: Create or load volumetric dataset
            let dataset = try createSampleDataset()

            // Step 2: Apply dataset to all four controllers
            // Important: All controllers must use the same dataset for proper synchronization
            await loadDatasetToAllControllers(dataset)

            // Step 3: Configure window/level for medical imaging
            // These settings are automatically synchronized across MPR views
            await configureWindowLevel()

            // Step 4: Set initial slab thickness
            await configureSlabThickness()

            // Step 5: Apply transfer function preset for 3D volumetric view
            await volumeController.setPreset(.softTissue)

        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Creates a sample volumetric dataset
    ///
    /// In a real application, this would load data from DICOM files using ``DicomVolumeLoader``.
    /// See the DICOM loading example below for implementation details.
    private func createSampleDataset() throws -> VolumeDataset {
        // Sample CT volume dimensions
        let width = 512
        let height = 512
        let depth = 300

        let voxelCount = width * height * depth
        let bytesPerVoxel = VolumePixelFormat.int16Signed.bytesPerVoxel

        // Create placeholder voxel data
        // In real usage, this would be actual medical imaging data from DICOM files
        let voxels = Data(repeating: 0, count: voxelCount * bytesPerVoxel)

        // Construct dataset with typical CT metadata
        return VolumeDataset(
            data: voxels,
            dimensions: VolumeDimensions(width: width, height: height, depth: depth),
            spacing: VolumeSpacing(x: 0.0007, y: 0.0007, z: 0.001),  // 0.7mm × 0.7mm × 1mm typical CT
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071  // Full CT Hounsfield unit range
        )
    }

    /// Applies the dataset to all four controllers
    private func loadDatasetToAllControllers(_ dataset: VolumeDataset) async {
        // Load to 3D volumetric controller
        await volumeController.loadDataset(dataset)

        // Load to all three MPR controllers
        await axialController.loadDataset(dataset)
        await coronalController.loadDataset(dataset)
        await sagittalController.loadDataset(dataset)
    }

    /// Configures synchronized window/level settings
    ///
    /// Window/level controls the intensity range displayed in MPR views.
    /// These settings are automatically synchronized by ``MPRGridComposer``.
    private func configureWindowLevel() async {
        // Typical soft tissue window for CT
        // Window = 400 HU, Level = 40 HU
        // Results in display range: -160 to 240 HU
        let min: Int32 = -160  // level - (window / 2)
        let max: Int32 = 240   // level + (window / 2)

        // Apply to all MPR controllers
        await axialController.setMprHuWindow(min: min, max: max)
        await coronalController.setMprHuWindow(min: min, max: max)
        await sagittalController.setMprHuWindow(min: min, max: max)

        // Note: The 3D volumetric view is not affected by window/level settings
    }

    /// Configures synchronized slab thickness
    ///
    /// Slab thickness controls how many slices are blended together for thick-slab
    /// MPR rendering. Useful for MIP/MinIP visualization techniques.
    private func configureSlabThickness() async {
        let thickness = 3  // 3mm slab thickness
        let steps = 6      // 6 samples for smooth blending

        // Apply to all MPR controllers
        await axialController.setMprSlab(thickness: thickness, steps: steps)
        await coronalController.setMprSlab(thickness: thickness, steps: steps)
        await sagittalController.setMprSlab(thickness: thickness, steps: steps)
    }
}

// MARK: - DICOM Loading with MPR

/// Example showing how to load a DICOM dataset and display it in MPR views
///
/// This example demonstrates the complete workflow for loading medical imaging
/// data from DICOM files and setting up synchronized multi-planar reconstruction.
struct DicomMPRViewerExample: View {

    @StateObject private var volumeController = VolumetricSceneController()
    @StateObject private var axialController = VolumetricSceneController()
    @StateObject private var coronalController = VolumetricSceneController()
    @StateObject private var sagittalController = VolumetricSceneController()

    @State private var isLoading = false
    @State private var loadingProgress: Double = 0.0
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView("Loading DICOM series...", value: loadingProgress, total: 1.0)
                        .progressViewStyle(.linear)
                        .padding()
                    Text("\(Int(loadingProgress * 100))% complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                MPRGridComposer(
                    volumeController: volumeController,
                    axialController: axialController,
                    coronalController: coronalController,
                    sagittalController: sagittalController
                )
            }
        }
        .task {
            // In a real app, get URL from file picker or document browser
            // await loadDicomSeries(from: dicomZipURL)
        }
    }

    /// Loads DICOM series and configures all MPR controllers
    ///
    /// - Parameter url: URL to DICOM ZIP file or directory
    ///
    /// This demonstrates the complete DICOM loading workflow:
    /// 1. Create DicomVolumeLoader with progress callback
    /// 2. Load dataset using DicomSeriesLoading implementation
    /// 3. Apply dataset to all controllers
    /// 4. Configure window/level and slab settings
    private func loadDicomSeries(from url: URL) async {
        isLoading = true
        loadingProgress = 0.0
        defer { isLoading = false }

        // DicomVolumeLoader requires a DicomSeriesLoading bridge implementation
        // See MTK-Demo/Source/Helper/DicomDecoderSeriesLoader.swift for reference

        /*
        let loader = DicomVolumeLoader()

        do {
            // Load volume with progress updates
            let dataset = try await loader.loadVolume(
                from: url,
                using: yourDicomSeriesLoader,  // Implement DicomSeriesLoading protocol
                onProgress: { progress in
                    // Update UI with loading progress
                    self.loadingProgress = progress.fractionCompleted
                }
            )

            // Apply dataset to all controllers
            await volumeController.loadDataset(dataset)
            await axialController.loadDataset(dataset)
            await coronalController.loadDataset(dataset)
            await sagittalController.loadDataset(dataset)

            // Configure default window/level based on modality
            if dataset.modality == .ct {
                // CT soft tissue window
                await configureWindowLevel(min: -160, max: 240)
            } else if dataset.modality == .mr {
                // MR auto-windowing based on intensity range
                let range = dataset.intensityRange
                await configureWindowLevel(
                    min: Int32(range.lowerBound),
                    max: Int32(range.upperBound)
                )
            }

            // Set initial slab thickness
            await configureSlabThickness(thickness: 3, steps: 6)

            // Apply appropriate transfer function preset
            await volumeController.setPreset(.softTissue)

        } catch {
            errorMessage = "Failed to load DICOM: \(error.localizedDescription)"
        }
        */
    }

    private func configureWindowLevel(min: Int32, max: Int32) async {
        await axialController.setMprHuWindow(min: min, max: max)
        await coronalController.setMprHuWindow(min: min, max: max)
        await sagittalController.setMprHuWindow(min: min, max: max)
    }

    private func configureSlabThickness(thickness: Int, steps: Int) async {
        await axialController.setMprSlab(thickness: thickness, steps: steps)
        await coronalController.setMprSlab(thickness: thickness, steps: steps)
        await sagittalController.setMprSlab(thickness: thickness, steps: steps)
    }
}

// MARK: - Advanced MPR Features

/// Example demonstrating advanced MPR features including blend modes and custom styling
struct AdvancedMPRExample: View {

    @StateObject private var volumeController = VolumetricSceneController()
    @StateObject private var axialController = VolumetricSceneController()
    @StateObject private var coronalController = VolumetricSceneController()
    @StateObject private var sagittalController = VolumetricSceneController()

    @State private var selectedBlendMode: MPRBlendMode = .single
    @State private var slabThickness: Int = 1

    var body: some View {
        VStack {
            // MPR Grid with custom styling
            MPRGridComposer(
                volumeController: volumeController,
                axialController: axialController,
                coronalController: coronalController,
                sagittalController: sagittalController,
                style: CustomMPRStyle()
            )

            // Blend mode selector
            Picker("Blend Mode", selection: $selectedBlendMode) {
                Text("Single Slice").tag(MPRBlendMode.single)
                Text("Maximum (MIP)").tag(MPRBlendMode.maximum)
                Text("Minimum (MinIP)").tag(MPRBlendMode.minimum)
                Text("Average").tag(MPRBlendMode.average)
            }
            .pickerStyle(.segmented)
            .padding()
            .onChange(of: selectedBlendMode) { _, newMode in
                Task { await updateBlendMode(newMode) }
            }

            // Slab thickness control
            VStack(alignment: .leading) {
                Text("Slab Thickness: \(slabThickness)mm")
                    .font(.caption)
                Slider(value: Binding(
                    get: { Double(slabThickness) },
                    set: { slabThickness = Int($0) }
                ), in: 1...20, step: 1)
                .onChange(of: slabThickness) { _, newThickness in
                    Task { await updateSlabThickness(newThickness) }
                }
            }
            .padding()
        }
    }

    private func updateBlendMode(_ mode: MPRBlendMode) async {
        // Update blend mode for all MPR controllers
        // This would require extending VolumetricSceneController with blend mode support
        // See MetalMPRAdapter.send(.setBlend(_:)) for the underlying API
    }

    private func updateSlabThickness(_ thickness: Int) async {
        let steps = max(thickness * 2, 6)  // More samples for thicker slabs
        await axialController.setMprSlab(thickness: thickness, steps: steps)
        await coronalController.setMprSlab(thickness: thickness, steps: steps)
        await sagittalController.setMprSlab(thickness: thickness, steps: steps)
    }
}

// MARK: - Custom UI Style

/// Custom styling for MPR overlays
struct CustomMPRStyle: VolumetricUIStyle {
    var crosshairColor: Color { .cyan }
    var crosshairLineWidth: CGFloat { 1.5 }
    var orientationLabelFont: Font { .system(.caption, design: .rounded, weight: .semibold) }
    var orientationLabelColor: Color { .white }
    var overlayBackground: Color { Color.black.opacity(0.7) }
    var overlayForeground: Color { .white }
}

// MARK: - Performance Considerations

/*
 ## MPR Performance Optimization

 ### Slice Generation Performance

 GPU-accelerated MPR provides real-time performance:
 - Single slice (512×512): 2-5ms on Apple Silicon
 - Thick slab MIP (512×512, 20 steps): 10-20ms on Apple Silicon
 - CPU fallback: 50-150ms depending on configuration

 ### Memory Usage

 MPR memory requirements:
 - Volume texture: width × height × depth × bytesPerVoxel (shared across all views)
 - Per-view output buffer: 512 × 512 × 2 bytes ≈ 524 KB

 Example for 512×512×300 CT volume:
 - Volume: ~157 MB (loaded once, shared by all four controllers)
 - Four view buffers: ~2 MB total
 - Total: ~159 MB

 ### Best Practices

 1. **Reuse controllers**: Don't recreate VolumetricSceneController instances unnecessarily
 2. **Batch updates**: Group window/level and slab thickness changes to avoid multiple regenerations
 3. **Optimize slab settings**: Use fewer steps for preview, more for final rendering
 4. **Monitor GPU memory**: Large volumes (>1024³) may require downsampling on older devices

 ## Blend Mode Use Cases

 ### Single Slice (`.single`)
 - Maximum spatial resolution
 - Reviewing fine anatomical detail
 - Minimizing reconstruction artifacts
 - Best performance (single sample per pixel)

 ### Maximum Intensity Projection (`.maximum`)
 - Vascular imaging (contrast-enhanced vessels)
 - Bone visualization
 - Calcifications and high-density structures
 - MR angiography

 ### Minimum Intensity Projection (`.minimum`)
 - Airway visualization (air = low HU)
 - Cystic structures
 - Dark-fluid MR sequences

 ### Average Intensity (`.average`)
 - Noise reduction in low-dose CT
 - Smooth thick-slab reformats
 - Simulating thicker slice acquisitions

 ## Window/Level Guidelines

 ### Common CT Presets

 - **Brain**: W=80, L=40 (min=-40, max=120)
 - **Soft Tissue**: W=400, L=40 (min=-160, max=240)
 - **Lung**: W=1500, L=-600 (min=-1350, max=150)
 - **Bone**: W=2000, L=300 (min=-700, max=1300)
 - **Liver**: W=150, L=30 (min=-45, max=105)

 ### Calculating Window/Level

 ```swift
 // Convert window/level to min/max
 let min = level - (window / 2)
 let max = level + (window / 2)

 // Convert min/max to window/level
 let window = max - min
 let level = (min + max) / 2
 ```

 ## Synchronization Architecture

 ``MPRGridComposer`` maintains synchronization through:

 1. **Shared window/level state**: Controlled by internal @State binding
 2. **Publisher observation**: Monitors axialController.statePublisher for changes
 3. **Broadcast updates**: Applies settings to all MPR controllers simultaneously
 4. **Async coordination**: Uses Task for thread-safe controller updates

 The 3D volumetric view is intentionally excluded from window/level synchronization
 to allow independent transfer function configuration.

 ## See Also

 - ``MPRGridComposer`` — Synchronized MPR grid layout
 - ``VolumetricSceneController`` — Scene controller API
 - ``MetalMPRAdapter`` — Low-level MPR rendering
 - ``MPRPlaneGeometry`` — Plane geometry definitions
 - ``MPRBlendMode`` — Slab blending modes
 - <doc:MPRGuide> — Complete MPR documentation
 - <doc:VolumeRenderingGuide> — Volume rendering techniques
 */
