//
//  BasicVolumeRendering.swift
//  MTK Examples
//
//  Minimal example showing basic volume rendering setup
//  Thales Matheus Mendonça Santos — November 2025
//
//  NOTE: This is example/documentation code showing minimal MTK API usage.
//  For complete implementation with UI controls, see MTK_Integration_Example.swift
//

import SwiftUI
import MTKCore
import MTKUI

// MARK: - Basic Volume Rendering View

/// Minimal SwiftUI view demonstrating basic volume rendering setup
///
/// This example shows the essential steps to display a volumetric dataset:
/// 1. Create a VolumetricSceneCoordinator
/// 2. Set up VolumetricDisplayContainer with optional overlays
/// 3. Create a VolumeDataset from voxel data
/// 4. Apply the dataset and configure window/preset
struct BasicVolumeRenderingView: View {

    @StateObject private var coordinator = VolumetricSceneCoordinator.shared

    var body: some View {
        VolumetricDisplayContainer(controller: coordinator.controller) {
            // Optional: Add overlay UI components
            OrientationOverlayView()
            CrosshairOverlayView()
        }
        .task {
            // Load and configure volume dataset on appear
            await setupVolume()
        }
    }

    // MARK: - Volume Setup

    private func setupVolume() async {
        // Step 1: Create voxel data buffer
        // In a real app, this would come from DICOM files or other medical imaging sources
        let width = 256
        let height = 256
        let depth = 128
        let voxelCount = width * height * depth

        // Create sample data (in real usage, load actual medical imaging data)
        let bytesPerVoxel = VolumePixelFormat.int16Signed.bytesPerVoxel
        let voxels = Data(repeating: 0, count: voxelCount * bytesPerVoxel)

        // Step 2: Build VolumeDataset with metadata
        let dataset = VolumeDataset(
            data: voxels,
            dimensions: VolumeDimensions(width: width, height: height, depth: depth),
            spacing: VolumeSpacing(x: 0.001, y: 0.001, z: 0.0015),  // meters per voxel
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071  // Typical CT Hounsfield units range
        )

        // Step 3: Apply dataset to coordinator
        coordinator.apply(dataset: dataset)

        // Step 4: Configure window/level for visualization
        // Typical soft tissue window in CT
        coordinator.applyHuWindow(min: -500, max: 1200)

        // Step 5: Apply transfer function preset
        // Available presets: .bone, .softTissue, .lung, .angio, etc.
        await coordinator.controller.setPreset(.softTissue)
    }
}

// MARK: - Loading from DICOM

/// Example showing how to load a DICOM dataset
///
/// Note: The demo uses DicomDecoderSeriesLoader as its canonical DICOM loader.
/// See MTK-Demo for the complete DICOM loading flow.
struct DicomLoadingExample: View {

    @StateObject private var coordinator = VolumetricSceneCoordinator.shared
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            if isLoading {
                ProgressView("Loading DICOM volume...")
            } else {
                VolumetricDisplayContainer(controller: coordinator.controller) {
                    OrientationOverlayView()
                }
            }
        }
        .task {
            // In a real app, get URL from file picker
            // await loadDicomVolume(from: dicomZipURL)
        }
    }

    private func loadDicomVolume(from url: URL) async {
        isLoading = true
        defer { isLoading = false }

        // DicomVolumeLoader requires a DicomSeriesLoading bridge implementation
        // See MTK-Demo/Source/Helper/DicomDecoderSeriesLoader.swift for reference

        /*
        let loader = DicomVolumeLoader()

        do {
            let dataset = try await loader.loadVolume(
                from: url,
                using: yourDicomSeriesLoader  // Implement DicomSeriesLoading protocol
            )

            coordinator.apply(dataset: dataset)
            await coordinator.controller.setPreset(.softTissue)

        } catch {
            errorMessage = "Failed to load DICOM: \(error.localizedDescription)"
        }
        */
    }
}

// MARK: - Runtime Availability Check

/// Example showing Metal availability check before rendering
struct AvailabilityCheckExample: View {

    @State private var metalAvailable = false

    var body: some View {
        Group {
            if metalAvailable {
                BasicVolumeRenderingView()
            } else {
                ContentUnavailableView(
                    "Metal Not Available",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This device does not support Metal rendering")
                )
            }
        }
        .onAppear {
            // Check Metal availability before creating rendering components
            metalAvailable = MetalRuntimeAvailability.isMetalAvailable
        }
    }
}

// MARK: - Usage Notes

/*
 ## Basic Usage

 Simply embed BasicVolumeRenderingView in your SwiftUI hierarchy:

 ```swift
 import SwiftUI
 import MTKCore
 import MTKUI

 @main
 struct MyApp: App {
     var body: some Scene {
         WindowGroup {
             BasicVolumeRenderingView()
         }
     }
 }
 ```

 ## Adding Gesture Support

 Enable user interaction with volumeGestures modifier:

 ```swift
 VolumetricDisplayContainer(controller: coordinator.controller) {
     OrientationOverlayView()
 }
 .volumeGestures(
     controller: coordinator.controller,
     state: .constant(.idle),
     configuration: VolumeGestureConfiguration()
 )
 ```

 ## Multi-Plane Reconstruction (MPR)

 For axial/coronal/sagittal review without a 3D pane, use TriplanarMPRComposer:

 ```swift
 TriplanarMPRComposer(
     axialController: coordinator.controller(for: .z),
     coronalController: coordinator.controller(for: .y),
     sagittalController: coordinator.controller(for: .x)
 )
 ```

 For the 2×2 layout with tri-planar MPR plus 3D context, use MPRGridComposer:

 ```swift
 MPRGridComposer(
     volumeController: coordinator.controller,
     axialController: coordinator.controller(for: .z),
     coronalController: coordinator.controller(for: .y),
     sagittalController: coordinator.controller(for: .x)
 )
 ```

 ## Available Transfer Function Presets

 - .bone — Optimized for bone/skeletal imaging
 - .softTissue — General soft tissue visualization
 - .lung — Lung parenchyma and airways
 - .angio — Vascular/angiography studies
 - .chest — Chest CT with contrast

 ## Next Steps

 - See MTK_Integration_Example.swift for complete UI controls
 - See MTK-Demo app for DICOM loading and advanced features
 - Consult MTK README.md for package setup and dependencies
 */
