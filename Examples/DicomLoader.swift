//
//  DicomLoader.swift
//  MTK Examples
//
//  Comprehensive example showing DICOM series loading with progress handling
//  Thales Matheus Mendonça Santos — February 2026
//
//  NOTE: This is example/documentation code demonstrating MTK's DICOM loading capabilities.
//  For production implementation, see MTK-Demo app and DicomVolumeLoader documentation.
//

import SwiftUI
import MTKCore
import MTKUI

// MARK: - Basic DICOM Loading Example

/// Basic SwiftUI view demonstrating DICOM series loading with progress tracking
///
/// This example shows the essential workflow for loading DICOM volumes:
/// 1. Create a ``DicomVolumeLoader`` with a ``DicomSeriesLoading`` implementation
/// 2. Load volume from directory, ZIP archive, or individual file
/// 3. Track progress with ``DicomVolumeProgress`` updates
/// 4. Apply loaded dataset to ``VolumetricSceneCoordinator``
/// 5. Handle errors gracefully
///
/// ## Supported Sources
///
/// - Directories containing DICOM files (*.dcm or any DICOM format)
/// - ZIP archives with DICOM files (nested directories supported)
/// - Individual DICOM files (loader will scan parent directory)
///
/// ## DICOM Requirements
///
/// - 16-bit scalar volumes (signed or unsigned pixel representation)
/// - Image Orientation Patient (0020,0037) and Image Position Patient (0020,0032) tags
/// - Rescale Slope/Intercept (0028,1053/0028,1052) for Hounsfield Unit conversion
struct BasicDicomLoaderExample: View {

    @StateObject private var coordinator = VolumetricSceneCoordinator.shared

    @State private var isLoading = false
    @State private var loadingProgress: Double = 0.0
    @State private var totalSlices: Int = 0
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            if isLoading {
                // Loading UI with progress indicator
                VStack(spacing: 16) {
                    ProgressView("Loading DICOM series...", value: loadingProgress, total: 1.0)
                        .progressViewStyle(.linear)
                        .padding()

                    if totalSlices > 0 {
                        Text("Processing \(Int(loadingProgress * Double(totalSlices))) of \(totalSlices) slices")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("\(Int(loadingProgress * 100))% complete")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.1))

            } else if let error = errorMessage {
                // Error state
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Failed to Load DICOM",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )

                    Button("Retry") {
                        errorMessage = nil
                        Task { await loadDicomVolume() }
                    }
                    .buttonStyle(.bordered)
                }

            } else {
                // Main rendering view after successful load
                VolumetricDisplayContainer(controller: coordinator.controller) {
                    OrientationOverlayView()
                    CrosshairOverlayView()
                }
            }
        }
        .task {
            // In a real app, get URL from file picker or document browser
            // await loadDicomVolume(from: selectedDicomURL)
        }
    }

    // MARK: - DICOM Loading

    /// Load DICOM volume from a URL with progress tracking
    ///
    /// Demonstrates the complete DICOM loading workflow:
    /// 1. Create ``DicomVolumeLoader`` with series loader implementation
    /// 2. Call ``loadVolume(from:progress:completion:)`` with progress callback
    /// 3. Update UI with ``DicomVolumeProgress`` events
    /// 4. Apply loaded dataset to coordinator
    /// 5. Configure window/level and transfer function
    ///
    /// - Parameter url: Source URL (directory, ZIP, or DICOM file)
    private func loadDicomVolume(from url: URL? = nil) async {
        guard let url else {
            // In a real app, this would come from NSOpenPanel or UIDocumentPickerViewController
            errorMessage = "No DICOM source selected"
            return
        }

        isLoading = true
        loadingProgress = 0.0
        totalSlices = 0
        defer { isLoading = false }

        // Step 1: Create loader with DicomSeriesLoading implementation
        // DicomVolumeLoader uses DicomDecoderSeriesLoader by default (pure Swift, no GDCM)
        let loader = DicomVolumeLoader()

        // Step 2: Load volume with progress tracking
        loader.loadVolume(from: url, progress: { progress in
            // Progress callback executed on main queue
            handleProgress(progress)
        }, completion: { result in
            // Completion handler executed on main queue
            handleLoadResult(result)
        })
    }

    /// Process DICOM loading progress updates
    ///
    /// Maps ``DicomVolumeProgress`` events to UI state updates for display
    /// in SwiftUI `ProgressView` and status labels.
    ///
    /// - Parameter progress: Progress update from ``DicomVolumeLoader``
    private func handleProgress(_ progress: DicomVolumeProgress) {
        switch progress {
        case .started(let sliceCount):
            // Loading started with known total slice count
            totalSlices = sliceCount
            loadingProgress = 0.0

        case .reading(let fraction):
            // Incremental progress during slice reading and HU conversion
            loadingProgress = fraction
        }
    }

    /// Handle DICOM loading completion or error
    ///
    /// On success:
    /// - Applies loaded dataset to volumetric coordinator
    /// - Configures default window/level settings
    /// - Applies appropriate transfer function preset
    ///
    /// On failure:
    /// - Displays localized error message
    /// - Offers retry option
    ///
    /// - Parameter result: Loading result with dataset or error
    private func handleLoadResult(_ result: Result<DicomImportResult, Error>) {
        switch result {
        case .success(let importResult):
            // Step 3: Apply loaded dataset
            coordinator.apply(dataset: importResult.dataset)

            // Step 4: Configure window/level
            // Use recommended window if available (computed from 2nd/98th percentile)
            if let recommendedWindow = importResult.dataset.recommendedWindow {
                coordinator.applyHuWindow(min: Int32(recommendedWindow.lowerBound),
                                         max: Int32(recommendedWindow.upperBound))
            } else {
                // Fallback to default soft tissue window
                coordinator.applyHuWindow(min: -160, max: 240)
            }

            // Step 5: Apply transfer function preset
            Task {
                await coordinator.controller.setPreset(.softTissue)
            }

            print("Successfully loaded: \(importResult.seriesDescription)")
            print("Source: \(importResult.sourceURL.lastPathComponent)")
            print("Dimensions: \(importResult.dataset.dimensions.description)")

        case .failure(let error):
            // Display localized error message
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Advanced DICOM Loading with Custom Implementation

/// Advanced example showing custom ``DicomSeriesLoading`` implementation pattern
///
/// This demonstrates how to create a custom DICOM loader bridge for third-party
/// parsing libraries (GDCM, dcmtk, or custom parsers). The example follows the
/// architecture used by ``DicomDecoderSeriesLoader``.
///
/// ## Implementation Requirements
///
/// Custom loaders must:
/// 1. Conform to ``DicomSeriesLoading`` protocol
/// 2. Return objects conforming to ``DICOMSeriesVolumeProtocol``
/// 3. Provide incremental progress callbacks with slice data
/// 4. Parse and sort slices by Image Position Patient
/// 5. Extract spatial metadata (spacing, orientation, origin)
/// 6. Extract rescale parameters for HU conversion
struct CustomDicomLoaderExample: View {

    @StateObject private var coordinator = VolumetricSceneCoordinator.shared
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            if isLoading {
                ProgressView("Loading with custom loader...")
            } else {
                VolumetricDisplayContainer(controller: coordinator.controller) {
                    OrientationOverlayView()
                }
            }
        }
        .task {
            // await loadWithCustomImplementation(from: dicomURL)
        }
    }

    /// Load DICOM volume using a custom series loader implementation
    ///
    /// Demonstrates injecting a custom ``DicomSeriesLoading`` implementation
    /// into ``DicomVolumeLoader`` for alternative DICOM parsing backends.
    ///
    /// - Parameter url: DICOM source URL
    private func loadWithCustomImplementation(from url: URL) async {
        isLoading = true
        defer { isLoading = false }

        // Create custom series loader implementation
        // See CustomDicomSeriesLoader below for implementation pattern
        let customSeriesLoader = CustomDicomSeriesLoader()

        // Initialize DicomVolumeLoader with custom implementation
        let loader = DicomVolumeLoader(seriesLoader: customSeriesLoader)

        loader.loadVolume(from: url, progress: { progress in
            if case .reading(let fraction) = progress {
                print("Custom loader progress: \(Int(fraction * 100))%")
            }
        }, completion: { result in
            switch result {
            case .success(let importResult):
                coordinator.apply(dataset: importResult.dataset)
                Task { await coordinator.controller.setPreset(.softTissue) }

            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        })
    }
}

// MARK: - Custom DicomSeriesLoading Implementation Pattern

/// Example custom DICOM series loader implementation
///
/// This demonstrates the pattern for bridging third-party DICOM libraries
/// (GDCM, dcmtk, or custom parsers) into MTK's loading pipeline.
///
/// ## Implementation Steps
///
/// 1. Parse DICOM files in directory
/// 2. Sort slices by Image Position Patient (IPP projection onto slice normal)
/// 3. Stream slice data via progress callbacks
/// 4. Return volume conforming to ``DICOMSeriesVolumeProtocol``
///
/// ## Reference Implementation
///
/// See `MTK/Sources/MTKCore/Loading/DicomDecoderSeriesLoader.swift` for a
/// production implementation backed by the DICOM-Decoder package.
final class CustomDicomSeriesLoader: DicomSeriesLoading {

    /// Load DICOM series from directory with incremental progress
    ///
    /// - Parameters:
    ///   - url: Directory containing DICOM files
    ///   - progress: Optional progress callback
    ///
    /// - Returns: Volume object conforming to ``DICOMSeriesVolumeProtocol``
    /// - Throws: Parser-specific errors for I/O failures or invalid DICOM data
    func loadSeries(at url: URL,
                    progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any {

        // Step 1: Discover and parse DICOM files
        let dicomFiles = try discoverDicomFiles(in: url)
        guard !dicomFiles.isEmpty else {
            throw NSError(domain: "CustomDicomLoader", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No DICOM files found"])
        }

        // Step 2: Parse first slice to determine dimensions and metadata
        let firstSlice = try parseDicomSlice(url: dicomFiles.first!)
        let width = firstSlice.width
        let height = firstSlice.height
        let depth = dicomFiles.count

        // Step 3: Allocate voxel buffer
        let voxelCount = width * height * depth
        let bytesPerVoxel = firstSlice.isSignedPixel ? MemoryLayout<Int16>.size : MemoryLayout<UInt16>.size
        var voxelBuffer = Data(count: voxelCount * bytesPerVoxel)

        // Step 4: Sort slices by Image Position Patient
        let sortedFiles = try sortSlicesByPosition(dicomFiles)

        // Step 5: Stream slice data with progress callbacks
        for (index, fileURL) in sortedFiles.enumerated() {
            let slice = try parseDicomSlice(url: fileURL)
            let sliceData = slice.pixelData

            // Copy slice into voxel buffer at correct depth position
            let sliceVoxelCount = width * height
            let offset = index * sliceVoxelCount * bytesPerVoxel
            voxelBuffer.replaceSubrange(offset..<(offset + sliceData.count), with: sliceData)

            // Report progress with partial volume
            let fraction = Double(index + 1) / Double(depth)
            let partialVolume = CustomDicomVolume(
                width: width,
                height: height,
                depth: depth,
                spacingX: firstSlice.spacingX,
                spacingY: firstSlice.spacingY,
                spacingZ: firstSlice.spacingZ,
                orientation: firstSlice.orientation,
                origin: firstSlice.origin,
                rescaleSlope: firstSlice.rescaleSlope,
                rescaleIntercept: firstSlice.rescaleIntercept,
                isSignedPixel: firstSlice.isSignedPixel,
                seriesDescription: firstSlice.seriesDescription,
                bitsAllocated: 16
            )

            progress?(fraction, UInt(index + 1), sliceData, partialVolume)
        }

        // Step 6: Return final volume
        return CustomDicomVolume(
            width: width,
            height: height,
            depth: depth,
            spacingX: firstSlice.spacingX,
            spacingY: firstSlice.spacingY,
            spacingZ: firstSlice.spacingZ,
            orientation: firstSlice.orientation,
            origin: firstSlice.origin,
            rescaleSlope: firstSlice.rescaleSlope,
            rescaleIntercept: firstSlice.rescaleIntercept,
            isSignedPixel: firstSlice.isSignedPixel,
            seriesDescription: firstSlice.seriesDescription,
            bitsAllocated: 16
        )
    }

    // MARK: - Helper Methods (Implementation Placeholders)

    private func discoverDicomFiles(in directory: URL) throws -> [URL] {
        // Implementation: Scan directory for .dcm files or parse all files for DICOM magic bytes
        // return FileManager.default.contentsOfDirectory(...)
        return []
    }

    private func parseDicomSlice(url: URL) throws -> ParsedSlice {
        // Implementation: Parse DICOM file and extract metadata + pixel data
        // Use GDCM, dcmtk, or custom parser
        throw NSError(domain: "CustomDicomLoader", code: 2,
                     userInfo: [NSLocalizedDescriptionKey: "Not implemented"])
    }

    private func sortSlicesByPosition(_ files: [URL]) throws -> [URL] {
        // Implementation: Sort by Image Position Patient (IPP) projected onto slice normal
        // See DicomDecoderSeriesLoader for IPP projection algorithm
        return files
    }

    private struct ParsedSlice {
        let width: Int
        let height: Int
        let spacingX: Double
        let spacingY: Double
        let spacingZ: Double
        let orientation: simd_float3x3
        let origin: SIMD3<Float>
        let rescaleSlope: Double
        let rescaleIntercept: Double
        let isSignedPixel: Bool
        let seriesDescription: String
        let pixelData: Data
    }
}

/// Custom volume wrapper conforming to ``DICOMSeriesVolumeProtocol``
///
/// Bridges custom DICOM parser output into MTK's expected protocol.
/// This pattern allows any DICOM library to integrate with ``DicomVolumeLoader``.
private struct CustomDicomVolume: DICOMSeriesVolumeProtocol {
    let width: Int
    let height: Int
    let depth: Int
    let spacingX: Double
    let spacingY: Double
    let spacingZ: Double
    let orientation: simd_float3x3
    let origin: SIMD3<Float>
    let rescaleSlope: Double
    let rescaleIntercept: Double
    let isSignedPixel: Bool
    let seriesDescription: String
    let bitsAllocated: Int
}

// MARK: - GPU-Accelerated Window Recommendations

/// Example showing GPU-accelerated auto-windowing via histogram percentiles
///
/// ``DicomVolumeLoader`` can compute recommended window/level settings using
/// Metal Performance Shaders to calculate 2nd/98th percentile from the volume
/// intensity histogram. This provides better default visualization than simple
/// min/max windowing.
struct DicomLoaderWithAutoWindowingExample: View {

    @StateObject private var coordinator = VolumetricSceneCoordinator.shared
    @State private var isLoading = false

    var body: some View {
        VolumetricDisplayContainer(controller: coordinator.controller) {
            OrientationOverlayView()
        }
        .task {
            // await loadWithAutoWindowing(from: dicomURL)
        }
    }

    /// Load DICOM volume with GPU-accelerated window recommendation
    ///
    /// Configures ``DicomVolumeLoader`` with histogram and statistics calculators
    /// to enable automatic window/level computation based on intensity percentiles.
    ///
    /// - Parameter url: DICOM source URL
    private func loadWithAutoWindowing(from url: URL) async {
        isLoading = true
        defer { isLoading = false }

        // Create Metal resources for GPU-accelerated statistics
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            print("Metal not available for auto-windowing")
            return
        }

        // Create histogram and statistics calculators
        let histogramCalculator = VolumeHistogramCalculator(
            device: device,
            commandQueue: commandQueue
        )

        let statisticsCalculator = VolumeStatisticsCalculator(
            device: device,
            commandQueue: commandQueue
        )

        // Initialize loader with GPU acceleration
        let loader = DicomVolumeLoader(
            seriesLoader: DicomDecoderSeriesLoader(),
            device: device,
            commandQueue: commandQueue,
            histogramCalculator: histogramCalculator,
            statisticsCalculator: statisticsCalculator
        )

        loader.loadVolume(from: url, progress: { _ in
            // Handle progress
        }, completion: { result in
            switch result {
            case .success(let importResult):
                coordinator.apply(dataset: importResult.dataset)

                // Use GPU-computed recommended window (2nd/98th percentile)
                if let recommendedWindow = importResult.dataset.recommendedWindow {
                    coordinator.applyHuWindow(
                        min: Int32(recommendedWindow.lowerBound),
                        max: Int32(recommendedWindow.upperBound)
                    )
                    print("Applied auto window: [\(recommendedWindow.lowerBound), \(recommendedWindow.upperBound)]")
                }

                Task { await coordinator.controller.setPreset(.softTissue) }

            case .failure(let error):
                print("Auto-windowing load failed: \(error.localizedDescription)")
            }
        })
    }
}

// MARK: - Progress UI Integration Patterns

/// Example demonstrating various SwiftUI progress UI patterns
///
/// Shows different approaches to integrating DICOM loading progress
/// into SwiftUI user interfaces with ``DicomVolumeProgress`` updates.
struct DicomProgressUIPatterns: View {

    @State private var loadingProgress: Double = 0.0
    @State private var totalSlices: Int = 0
    @State private var currentSlice: Int = 0
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 24) {
            // Pattern 1: Linear progress bar with percentage
            if isLoading {
                VStack(spacing: 8) {
                    ProgressView(value: loadingProgress, total: 1.0)
                        .progressViewStyle(.linear)

                    Text("\(Int(loadingProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }

            // Pattern 2: Circular progress with slice count
            if isLoading && totalSlices > 0 {
                VStack(spacing: 8) {
                    ProgressView(value: loadingProgress, total: 1.0)
                        .progressViewStyle(.circular)

                    Text("\(currentSlice) / \(totalSlices) slices")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Pattern 3: Detailed status with estimated time
            if isLoading {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Loading DICOM series...")
                            .font(.headline)
                        Spacer()
                        Text("\(Int(loadingProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: loadingProgress, total: 1.0)
                        .progressViewStyle(.linear)

                    if totalSlices > 0 {
                        Text("Slice \(currentSlice) of \(totalSlices)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color(white: 0.15))
                .cornerRadius(8)
            }
        }
        .padding()
    }

    /// Update UI state from DICOM loading progress
    ///
    /// - Parameter progress: Progress update from ``DicomVolumeLoader``
    func updateProgress(_ progress: DicomVolumeProgress) {
        switch progress {
        case .started(let slices):
            totalSlices = slices
            loadingProgress = 0.0
            currentSlice = 0

        case .reading(let fraction):
            loadingProgress = fraction
            currentSlice = Int(fraction * Double(totalSlices))
        }
    }
}

// MARK: - Error Handling Patterns

/// Example demonstrating comprehensive DICOM loading error handling
///
/// Shows how to handle different ``DicomVolumeLoaderError`` cases and
/// provide appropriate user feedback and recovery options.
struct DicomErrorHandlingExample: View {

    @State private var errorType: DicomVolumeLoaderError?
    @State private var showError = false

    var body: some View {
        VStack {
            if showError, let error = errorType {
                // Error-specific UI
                VStack(spacing: 16) {
                    errorIcon(for: error)

                    Text(errorTitle(for: error))
                        .font(.headline)

                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    recoveryActions(for: error)
                }
                .padding()
            }
        }
    }

    /// Provide error-specific icon
    private func errorIcon(for error: DicomVolumeLoaderError) -> some View {
        Group {
            switch error {
            case .securityScopeUnavailable:
                Image(systemName: "lock.fill")
            case .unsupportedBitDepth:
                Image(systemName: "exclamationmark.triangle.fill")
            case .missingResult:
                Image(systemName: "questionmark.folder.fill")
            case .pathTraversal:
                Image(systemName: "exclamationmark.shield.fill")
            case .bridgeError:
                Image(systemName: "exclamationmark.circle.fill")
            }
        }
        .font(.largeTitle)
        .foregroundStyle(.red)
    }

    /// Provide error-specific title
    private func errorTitle(for error: DicomVolumeLoaderError) -> String {
        switch error {
        case .securityScopeUnavailable:
            return "Access Denied"
        case .unsupportedBitDepth:
            return "Unsupported Format"
        case .missingResult:
            return "No Data Found"
        case .pathTraversal:
            return "Invalid Archive"
        case .bridgeError:
            return "Loading Failed"
        }
    }

    /// Provide error-specific recovery actions
    @ViewBuilder
    private func recoveryActions(for error: DicomVolumeLoaderError) -> some View {
        switch error {
        case .securityScopeUnavailable:
            Button("Choose File Again") {
                // Re-open file picker
            }
            .buttonStyle(.bordered)

        case .unsupportedBitDepth:
            VStack {
                Text("Only 16-bit DICOM volumes are supported")
                    .font(.caption2)
                Button("Select Different Series") {
                    // Open file picker
                }
                .buttonStyle(.bordered)
            }

        case .missingResult:
            Button("Select DICOM Directory") {
                // Open directory picker
            }
            .buttonStyle(.bordered)

        case .pathTraversal:
            Text("This archive contains invalid file paths")
                .font(.caption2)

        case .bridgeError:
            Button("Retry") {
                // Retry loading
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Usage Notes

/*
 ## Basic Usage

 Import a DICOM series from a directory or ZIP archive:

 ```swift
 let loader = DicomVolumeLoader()

 loader.loadVolume(from: selectedURL, progress: { progress in
     switch progress {
     case .started(let totalSlices):
         print("Loading \(totalSlices) slices")
     case .reading(let fraction):
         progressBar.doubleValue = fraction
     }
 }, completion: { result in
     switch result {
     case .success(let importResult):
         coordinator.apply(dataset: importResult.dataset)
         await coordinator.controller.setPreset(.softTissue)
     case .failure(let error):
         presentError(error)
     }
 })
 ```

 ## Default DICOM Loader

 ``DicomVolumeLoader()`` uses ``DicomDecoderSeriesLoader`` by default:
 - Pure Swift implementation (no GDCM or native dependencies)
 - Automatic IPP-based slice sorting
 - Support for standard CT/MR DICOM files

 ## Custom DICOM Loaders

 Implement ``DicomSeriesLoading`` to bridge alternative DICOM libraries:

 ```swift
 final class MyCustomLoader: DicomSeriesLoading {
     func loadSeries(at url: URL,
                     progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any {
         // Parse DICOM files with your library
         // Stream slice data via progress callback
         // Return DICOMSeriesVolumeProtocol-conforming volume
     }
 }

 let loader = DicomVolumeLoader(seriesLoader: MyCustomLoader())
 ```

 ## GPU-Accelerated Auto-Windowing

 Enable automatic window/level computation from histogram percentiles:

 ```swift
 let device = MTLCreateSystemDefaultDevice()!
 let queue = device.makeCommandQueue()!

 let loader = DicomVolumeLoader(
     seriesLoader: DicomDecoderSeriesLoader(),
     device: device,
     commandQueue: queue,
     histogramCalculator: VolumeHistogramCalculator(device: device, commandQueue: queue),
     statisticsCalculator: VolumeStatisticsCalculator(device: device, commandQueue: queue)
 )

 // dataset.recommendedWindow will contain 2nd/98th percentile range
 ```

 ## Progress Translation for UI

 Use ``DicomVolumeLoader.uiUpdate(from:)`` to map progress events to SwiftUI:

 ```swift
 loader.loadVolume(from: url, progress: { internalProgress in
     let uiProgress = DicomVolumeLoader.uiUpdate(from: internalProgress)
     switch uiProgress {
     case .started(let totalSlices):
         self.statusLabel = "Loading \(totalSlices) slices..."
     case .reading(let fraction):
         self.progressValue = fraction
     }
 }, completion: { result in
     // Handle result
 })
 ```

 ## Supported DICOM Formats

 - **Pixel Representation**: 16-bit signed or unsigned
 - **Photometric Interpretation**: MONOCHROME1, MONOCHROME2
 - **Transfer Syntax**: Uncompressed, JPEG Lossless, JPEG 2000 (depends on loader implementation)
 - **Modality**: CT, MR, PET, etc. (any with spatial metadata)

 ## Required DICOM Tags

 - (0020,0037) Image Orientation Patient — Defines row/column directions
 - (0020,0032) Image Position Patient — Defines slice position
 - (0028,0030) Pixel Spacing — In-plane spacing (X/Y)
 - (0018,0050) Slice Thickness — Z-spacing (or computed from IPP)
 - (0028,1053) Rescale Slope — For Hounsfield Unit conversion
 - (0028,1052) Rescale Intercept — For Hounsfield Unit conversion

 ## File Picker Integration

 ### iOS
 ```swift
 import UniformTypeIdentifiers

 @State private var showFilePicker = false

 var body: some View {
     VStack {
         Button("Import DICOM") {
             showFilePicker = true
         }
     }
     .fileImporter(
         isPresented: $showFilePicker,
         allowedContentTypes: [.folder, .zip],
         onCompletion: { result in
             switch result {
             case .success(let url):
                 Task { await loadDicomVolume(from: url) }
             case .failure(let error):
                 print("File picker error: \(error)")
             }
         }
     )
 }
 ```

 ### macOS
 ```swift
 import AppKit

 func selectDicomSource() {
     let panel = NSOpenPanel()
     panel.allowsMultipleSelection = false
     panel.canChooseDirectories = true
     panel.canChooseFiles = true
     panel.allowedContentTypes = [.folder, .zip]

     panel.begin { response in
         guard response == .OK, let url = panel.url else { return }
         Task { await loadDicomVolume(from: url) }
     }
 }
 ```

 ## Performance Characteristics

 ### Loading Performance

 Typical DICOM series loading performance on Apple Silicon:
 - **Small CT** (256×256×128): 1-2 seconds
 - **Medium CT** (512×512×300): 3-5 seconds
 - **Large CT** (1024×1024×512): 10-15 seconds

 Includes ZIP extraction, DICOM parsing, IPP sorting, and HU conversion.

 ### Memory Usage

 Peak memory during loading:
 - Source DICOM files in memory (if compressed)
 - Voxel buffer (width × height × depth × 2 bytes)
 - Temporary slice buffers during assembly

 Example for 512×512×300 CT:
 - Voxel buffer: ~157 MB
 - Peak memory: ~250-300 MB (including parser overhead)

 ## Error Handling

 ### Common Errors

 - ``DicomVolumeLoaderError/securityScopeUnavailable`` — File access denied (App Sandbox)
 - ``DicomVolumeLoaderError/unsupportedBitDepth`` — Only 16-bit volumes supported
 - ``DicomVolumeLoaderError/missingResult`` — Empty directory or all-invalid files
 - ``DicomVolumeLoaderError/pathTraversal`` — Malicious ZIP archive
 - ``DicomVolumeLoaderError/bridgeError(_:)`` — DICOM parser library error

 ### Security Considerations

 - ZIP archives are validated for path traversal attacks
 - Hidden files and parent directory references (.., .__MACOSX) are rejected
 - Temporary extraction directories are cleaned up automatically
 - Security-scoped bookmarks required for sandboxed file access

 ## Thread Safety

 - ``DicomVolumeLoader/loadVolume(from:progress:completion:)`` executes on background queue
 - Progress callbacks dispatched to main queue
 - Completion handler dispatched to main queue
 - Safe to update SwiftUI state directly in callbacks

 ## See Also

 - ``DicomVolumeLoader`` — Main DICOM loading orchestrator
 - ``DicomSeriesLoading`` — Protocol for custom DICOM loaders
 - ``DICOMSeriesVolumeProtocol`` — Protocol for volume metadata
 - ``DicomDecoderSeriesLoader`` — Default Swift-based DICOM loader
 - ``VolumeDataset`` — Loaded volume representation
 - ``VolumetricSceneCoordinator`` — Scene management
 - <doc:DicomLoadingGuide> — Complete DICOM loading guide
 */
