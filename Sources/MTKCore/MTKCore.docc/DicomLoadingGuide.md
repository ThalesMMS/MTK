# DICOM Loading

Guide to loading DICOM volumes with ZIP extraction, progress tracking, and protocol-based series loading.

## Overview

MTKCore provides a DICOM loading pipeline that handles ZIP archives, sorts slices by spatial position, converts pixel values to Hounsfield Units, and computes recommended window/level settings. The architecture decouples DICOM parsing from volume construction through protocol abstraction, allowing pure-Swift implementations or native library bridges.

The DICOM loading system consists of three key components:

- **``DicomVolumeLoader``**: Orchestrates ZIP extraction, delegates parsing, performs HU conversion, and constructs ``VolumeDataset``
- **``DicomSeriesLoading``**: Protocol abstraction for DICOM parsing implementations (GDCM, DICOM-Decoder, custom parsers)
- **``DicomDecoderSeriesLoader``**: Default pure-Swift implementation backed by the DICOM-Decoder package

This separation enables testing without native dependencies, supports multiple parser backends, and provides incremental progress updates suitable for UI binding.

## Quick Start

Basic DICOM loading with default configuration:

```swift
import MTKCore

let loader = DicomVolumeLoader() // Uses DicomDecoderSeriesLoader by default

loader.loadVolume(from: folderURL, progress: { update in
    switch update {
    case .started(let totalSlices):
        print("Loading \(totalSlices) DICOM slices")
    case .reading(let fraction):
        progressBar.doubleValue = fraction * 100.0
    }
}, completion: { result in
    switch result {
    case .success(let importResult):
        applyDataset(importResult.dataset)
        print("Loaded: \(importResult.seriesDescription)")
    case .failure(let error):
        presentError(error)
    }
})
```

## Supported Input Formats

``DicomVolumeLoader`` accepts three input types:

### Directory of DICOM Files

```swift
// Load from directory containing *.dcm files
let directoryURL = URL(fileURLWithPath: "/path/to/dicom/series", isDirectory: true)
loader.loadVolume(from: directoryURL, progress: { _ in }, completion: { result in
    // Handle result
})
```

The loader recursively searches the directory for DICOM files (any extension recognized by the parser).

### ZIP Archive

```swift
// Load from ZIP archive containing DICOM files
let zipURL = URL(fileURLWithPath: "/path/to/series.zip")
loader.loadVolume(from: zipURL, progress: { _ in }, completion: { result in
    // Handle result
})
```

ZIP extraction includes:
- **Temporary directory creation**: Extracts to `NSTemporaryDirectory()` with UUID isolation
- **Path traversal validation**: Rejects malicious entries with ".." components or absolute paths
- **Nested directory handling**: Automatically dives into single-directory archives
- **Automatic cleanup**: Removes temporary files after loading completes or fails

### Single DICOM File

```swift
// Load from single file (uses parent directory)
let fileURL = URL(fileURLWithPath: "/path/to/series/slice001.dcm")
loader.loadVolume(from: fileURL, progress: { _ in }, completion: { result in
    // Handle result
})
```

When given a single file, the loader uses its parent directory and loads all DICOM files found.

## Loading Pipeline

The ``DicomVolumeLoader/loadVolume(from:progress:completion:)`` method executes the following pipeline on a background queue:

### 1. Prepare Directory

If the source is a ZIP archive, extract to temporary directory with security validation. Otherwise, use the directory path directly.

```swift
// ZIP extraction with path traversal protection
let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

for entry in archive {
    let sanitizedPath = try sanitizeZipEntryPath(entry.path) // Validates against ../
    let destinationURL = temporaryDirectory.appendingPathComponent(sanitizedPath)
    try archive.extract(entry, to: destinationURL)
}
```

### 2. Delegate Series Loading

Call the ``DicomSeriesLoading`` implementation's `loadSeries(at:progress:)` method, which:
- Parses DICOM files in the directory
- Sorts slices by Image Position Patient (IPP) projected onto slice normal
- Streams slice data incrementally via progress callbacks
- Returns a volume conforming to ``DICOMSeriesVolumeProtocol``

```swift
let volume = try loader.loadSeries(at: directoryURL, progress: { fraction, slicesLoaded, sliceData, partialVolume in
    // Progress callback for each slice
    guard let partialVolume = partialVolume as? any DICOMSeriesVolumeProtocol else { return }

    // Initialize buffer on first slice
    if convertedData == nil {
        dimensions = SIMD3(Int32(partialVolume.width), Int32(partialVolume.height), Int32(partialVolume.depth))
        spacing = SIMD3(Float(partialVolume.spacingX), Float(partialVolume.spacingY), Float(partialVolume.spacingZ))
        convertedData = Data(count: voxelCount * MemoryLayout<Int16>.size)
    }

    // Convert slice to HU
    // ...
})
```

### 3. Convert to Hounsfield Units

Transform pixel values using DICOM Rescale Slope/Intercept:

```
HU = slope × pixelValue + intercept
```

Supports both signed (`Int16`) and unsigned (`UInt16`) pixel representations. The conversion happens per-slice during streaming:

```swift
sliceData.withUnsafeBytes { rawBuffer in
    if isSigned {
        let source = rawBuffer.bindMemory(to: Int16.self)
        for index in 0..<sliceVoxelCount {
            let rawValue = Int32(source[index])
            let huDouble = Double(rawValue) * slope + intercept
            let huRounded = Int32(lround(huDouble))
            minHU = min(minHU, huRounded)
            maxHU = max(maxHU, huRounded)
            destPtr[offset + index] = clampHU(huRounded) // Clamp to [-1024, 3071]
        }
    } else {
        // UInt16 variant
    }
}
```

### 4. Compute Recommended Window

Optionally use GPU-accelerated histogram percentiles (2nd/98th) for auto-windowing:

```swift
histogramCalculator.computeHistogram(for: volumeTexture, channelCount: 1, voxelMin: minHU, voxelMax: maxHU) { histogramResult in
    statisticsCalculator.computePercentiles(from: histograms, percentiles: [0.02, 0.98]) { percentilesResult in
        // Convert percentile bins to HU values
        let minHU = binToHU(percentileBins[0])
        let maxHU = binToHU(percentileBins[1])
        dataset.recommendedWindow = minHU...maxHU
    }
}
```

If ``DicomVolumeLoader/histogramCalculator`` or ``DicomVolumeLoader/statisticsCalculator`` are `nil`, the recommended window defaults to the dataset's full intensity range.

### 5. Construct VolumeDataset

Create the final ``VolumeDataset`` with spatial metadata from DICOM Image Orientation/Position Patient:

```swift
let volumeDimensions = VolumeDimensions(width: width, height: height, depth: depth)
let volumeSpacing = VolumeSpacing(x: Double(spacing.x), y: Double(spacing.y), z: Double(spacing.z))
let orientation = VolumeOrientation(row: row, column: column, origin: origin)

return VolumeDataset(
    data: convertedData,
    dimensions: volumeDimensions,
    spacing: volumeSpacing,
    pixelFormat: .int16Signed,
    intensityRange: intensityRange,
    orientation: orientation,
    recommendedWindow: recommendedWindow
)
```

## Progress Tracking

``DicomVolumeLoader`` provides two progress update types:

### DicomVolumeProgress (Internal)

Emitted by the loader during parsing and conversion:

```swift
public enum DicomVolumeProgress {
    case started(totalSlices: Int)  // After first slice parsed
    case reading(Double)             // Fraction 0.0...1.0 for each slice
}
```

### DicomVolumeUIProgress (UI-Friendly)

Translated via ``DicomVolumeLoader/uiUpdate(from:)`` for SwiftUI/AppKit binding:

```swift
loader.loadVolume(from: url, progress: { internalProgress in
    let uiProgress = DicomVolumeLoader.uiUpdate(from: internalProgress)
    switch uiProgress {
    case .started(let totalSlices):
        statusLabel.stringValue = "Loading \(totalSlices) slices..."
    case .reading(let fraction):
        progressView.progress = fraction
    }
}, completion: { result in
    // Handle result
})
```

### SwiftUI Integration

Bind progress to `ProgressView`:

```swift
struct DicomImportView: View {
    @State private var isLoading = false
    @State private var loadingFraction = 0.0
    @State private var totalSlices = 0

    var body: some View {
        VStack {
            if isLoading {
                ProgressView("Loading \(totalSlices) slices...", value: loadingFraction, total: 1.0)
            }
            Button("Import DICOM") {
                importDicom()
            }
        }
    }

    func importDicom() {
        let loader = DicomVolumeLoader()
        isLoading = true

        loader.loadVolume(from: selectedURL, progress: { update in
            switch update {
            case .started(let total):
                totalSlices = total
            case .reading(let fraction):
                loadingFraction = fraction
            }
        }, completion: { result in
            isLoading = false
            // Handle result
        })
    }
}
```

## Protocol-Based Series Loading

The ``DicomSeriesLoading`` protocol decouples DICOM parsing from volume construction:

```swift
public protocol DicomSeriesLoading: AnyObject {
    func loadSeries(at url: URL,
                    progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any
}
```

Implementations must:
1. Parse DICOM files in the directory
2. Sort slices by Image Position Patient (IPP)
3. Call progress callback for each loaded slice with:
   - `fraction`: Completion fraction (0.0...1.0)
   - `slicesLoaded`: Number of slices loaded so far
   - `sliceData`: Raw pixel data for the slice (Int16/UInt16)
   - `partialVolume`: Partial volume conforming to ``DICOMSeriesVolumeProtocol``
4. Return final volume object

### Default Implementation: DicomDecoderSeriesLoader

Pure-Swift implementation backed by DICOM-Decoder package:

```swift
let loader = DicomDecoderSeriesLoader()
let volume = try loader.loadSeries(at: directoryURL, progress: { fraction, slices, sliceData, partialVolume in
    print("Loaded \(slices) slices (\(Int(fraction * 100))% complete)")
})
```

**Features:**
- No native library dependencies (pure Swift)
- Automatic IPP projection-based sorting
- Rescale Slope/Intercept extraction
- Signed/unsigned 16-bit pixel data support

### Custom Implementation Example

Implement ``DicomSeriesLoading`` to bridge GDCM, dcmtk, or proprietary parsers:

```swift
final class CustomDicomLoader: DicomSeriesLoading {
    func loadSeries(at url: URL,
                    progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any {
        // Parse DICOM files
        let slices = try parseDicomDirectory(url)
        var voxelBuffer = Data(count: totalVoxelCount * 2)

        for (index, slice) in slices.enumerated() {
            let sliceData = try slice.pixelData()
            // Copy slice into voxelBuffer at correct offset

            let fraction = Double(index + 1) / Double(slices.count)
            let volume = makePartialVolume(slicesLoaded: index + 1)
            progress?(fraction, UInt(index + 1), sliceData, volume)
        }

        return makeFinalVolume()
    }
}
```

The returned volume must conform to ``DICOMSeriesVolumeProtocol``:

```swift
public protocol DICOMSeriesVolumeProtocol {
    var bitsAllocated: Int { get }
    var width: Int { get }
    var height: Int { get }
    var depth: Int { get }
    var spacingX: Double { get }
    var spacingY: Double { get }
    var spacingZ: Double { get }
    var orientation: simd_float3x3 { get }
    var origin: SIMD3<Float> { get }
    var rescaleSlope: Double { get }
    var rescaleIntercept: Double { get }
    var isSignedPixel: Bool { get }
    var seriesDescription: String { get }
}
```

## Error Handling

``DicomVolumeLoaderError`` covers validation failures and parser exceptions:

```swift
public enum DicomVolumeLoaderError: Error {
    case securityScopeUnavailable     // App Sandbox access denied
    case unsupportedBitDepth          // Only 16-bit volumes supported
    case missingResult                // Parser returned nil/empty data
    case pathTraversal                // ZIP contains malicious paths
    case bridgeError(NSError)         // Wrapped parser exception
}
```

### Handling Errors

```swift
loader.loadVolume(from: url, progress: { _ in }, completion: { result in
    switch result {
    case .success(let importResult):
        applyDataset(importResult.dataset)

    case .failure(let error):
        if let loaderError = error as? DicomVolumeLoaderError {
            switch loaderError {
            case .unsupportedBitDepth:
                showAlert("Only 16-bit DICOM volumes are supported.")
            case .pathTraversal:
                showAlert("Archive contains unsafe file paths.")
            case .bridgeError(let nsError):
                showAlert("DICOM parsing failed: \(nsError.localizedDescription)")
            default:
                showAlert(error.localizedDescription)
            }
        } else {
            showAlert(error.localizedDescription)
        }
    }
})
```

## GPU-Accelerated Auto-Windowing

Enable histogram-based window recommendations by providing Metal resources:

```swift
import Metal

guard let device = MTLCreateSystemDefaultDevice(),
      let commandQueue = device.makeCommandQueue() else {
    fatalError("Metal unavailable")
}

let histogramCalculator = VolumeHistogramCalculator()
let statisticsCalculator = VolumeStatisticsCalculator()

let loader = DicomVolumeLoader(
    seriesLoader: DicomDecoderSeriesLoader(),
    device: device,
    commandQueue: commandQueue,
    histogramCalculator: histogramCalculator,
    statisticsCalculator: statisticsCalculator
)

loader.loadVolume(from: url, progress: { _ in }, completion: { result in
    if case .success(let importResult) = result {
        // dataset.recommendedWindow contains 2nd/98th percentile HU range
        if let window = importResult.dataset.recommendedWindow {
            print("Recommended window: [\(window.lowerBound), \(window.upperBound)] HU")
        }
    }
})
```

**Performance:** Histogram computation adds ~200-500ms overhead for typical 512×512×300 CT volumes on Apple Silicon.

## Best Practices

### 1. Use Background Queues

``DicomVolumeLoader`` already dispatches loading to `DispatchQueue.global(qos: .userInitiated)`. Progress and completion handlers are called on the main queue.

### 2. Cache DicomVolumeLoader

Reuse the same loader instance when loading multiple series:

```swift
class DicomImporter {
    private let loader: DicomVolumeLoader

    init(device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.loader = DicomVolumeLoader(
            seriesLoader: DicomDecoderSeriesLoader(),
            device: device,
            commandQueue: commandQueue,
            histogramCalculator: VolumeHistogramCalculator(),
            statisticsCalculator: VolumeStatisticsCalculator()
        )
    }

    func importSeries(from url: URL, completion: @escaping (Result<DicomImportResult, Error>) -> Void) {
        loader.loadVolume(from: url, progress: { _ in }, completion: completion)
    }
}
```

### 3. Validate Input Before Loading

Check file existence and accessibility before calling `loadVolume`:

```swift
guard FileManager.default.fileExists(atPath: url.path) else {
    showAlert("File not found")
    return
}

guard url.startAccessingSecurityScopedResource() else {
    showAlert("Cannot access file (App Sandbox restriction)")
    return
}
defer { url.stopAccessingSecurityScopedResource() }

loader.loadVolume(from: url, progress: { _ in }, completion: { result in
    // Handle result
})
```

### 4. Provide User Feedback

Always bind progress updates to UI indicators:

```swift
loader.loadVolume(from: url, progress: { update in
    switch update {
    case .started(let totalSlices):
        // Show indeterminate progress or total slice count
        statusLabel.text = "Loading \(totalSlices) slices..."
    case .reading(let fraction):
        // Update determinate progress bar
        progressView.progress = Float(fraction)
    }
}, completion: { result in
    // Hide progress UI
})
```

## See Also

- ``DicomVolumeLoader`` — Main DICOM loading orchestrator
- ``DicomSeriesLoading`` — Protocol for custom parser implementations
- ``DicomDecoderSeriesLoader`` — Default pure-Swift loader
- ``VolumeDataset`` — Loaded volume representation
- ``VolumeHistogramCalculator`` — GPU-accelerated histogram computation
