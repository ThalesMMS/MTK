//
//  MetalRaycaster+DebugSliceImage.swift
//  MTK
//
//  Debug slice image utilities for MetalRaycaster.
//
//  Thales Matheus Mendonça Santos — October 2025

import simd
import OSLog
#if canImport(CoreGraphics)
import CoreGraphics
#endif

private let debugSliceLogger = Logger(subsystem: "com.mtk.volumerendering",
                                      category: "MetalRaycaster.DebugSlice")

extension MetalRaycaster {
    /// Generates a CPU-based grayscale slice image for debug and reference use.
    ///
    /// Creates a 2D image by extracting a single axial slice from the volume.
    /// Intensity values are normalized to the dataset's intensity range and mapped
    /// to 8-bit grayscale.
    ///
    /// - Parameters:
    ///   - dataset: The volume dataset containing voxel data, dimensions, pixel format, and intensity range.
    ///   - index: Optional axial slice index. If `nil`, the middle slice is used. The index is clamped to the valid slice range.
    ///
    /// - Returns: A device grayscale 8-bit `CGImage` for the selected axial slice, or `nil` if CoreGraphics is unavailable or the image could not be created.
    ///
    /// ## Performance
    ///
    /// Debug slice generation is CPU-based and relatively slow:
    /// - 256×256 slice: ~1-2ms
    /// - 512×512 slice: ~5-10ms
    /// - 1024×1024 slice: ~20-40ms
    ///
    /// For interactive rendering, use GPU-accelerated ``makeFragmentPipeline(colorPixelFormat:depthPixelFormat:sampleCount:label:)``
    /// or ``makeComputePipeline(for:label:)`` instead.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Generate middle slice
    /// if let preview = raycaster.makeDebugSliceImage(dataset: dataset) {
    ///     imageView.image = UIImage(cgImage: preview)
    /// }
    ///
    /// // Generate specific slice
    /// if let slice = raycaster.makeDebugSliceImage(dataset: dataset, slice: 100) {
    ///     imageView.image = UIImage(cgImage: slice)
    /// }
    /// ```
    public func makeDebugSliceImage(dataset: VolumeDataset,
                                    slice index: Int? = nil) -> CGImage? {
#if canImport(CoreGraphics)
        let width = dataset.dimensions.width
        let height = dataset.dimensions.height
        let depth = dataset.dimensions.depth
        guard width > 0, height > 0, depth > 0 else {
            debugSliceLogger.error("Cannot create debug slice: invalid dimensions \(width)x\(height)x\(depth)")
            return nil
        }

        let sliceSize = width.multipliedReportingOverflow(by: height)
        guard !sliceSize.overflow, sliceSize.partialValue > 0 else {
            debugSliceLogger.error("Cannot create debug slice: invalid slice voxel count for dimensions \(width)x\(height)")
            return nil
        }
        let voxelsPerSlice = sliceSize.partialValue

        let totalVoxels = voxelsPerSlice.multipliedReportingOverflow(by: depth)
        guard !totalVoxels.overflow,
              totalVoxels.partialValue == dataset.voxelCount else {
            debugSliceLogger.error("Cannot create debug slice: dimensions are inconsistent with dataset voxel count")
            return nil
        }
        let voxelCount = totalVoxels.partialValue

        let sliceIndex = max(0, min(index ?? depth / 2, depth - 1))
        let start = sliceIndex.multipliedReportingOverflow(by: voxelsPerSlice)
        guard !start.overflow, start.partialValue >= 0 else {
            debugSliceLogger.error("Cannot create debug slice: invalid start offset for slice \(sliceIndex)")
            return nil
        }
        let startOffset = start.partialValue

        let end = startOffset.addingReportingOverflow(voxelsPerSlice)
        guard !end.overflow,
              end.partialValue >= startOffset,
              end.partialValue <= voxelCount else {
            debugSliceLogger.error("Cannot create debug slice: slice range is outside dataset voxel count")
            return nil
        }

        let expectedBytes = voxelCount.multipliedReportingOverflow(by: dataset.pixelFormat.bytesPerVoxel)
        guard !expectedBytes.overflow,
              dataset.data.count >= expectedBytes.partialValue else {
            debugSliceLogger.error("Cannot create debug slice: voxel buffer is smaller than dataset dimensions require")
            return nil
        }

        return dataset.data.withUnsafeBytes { rawBuffer -> CGImage? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }

            var pixels = [UInt8](repeating: 0, count: voxelsPerSlice)
            let minValue = dataset.intensityRange.lowerBound
            let span = max(dataset.intensityRange.upperBound - minValue, 1)

            let readValue: (Int) -> Int32
            switch dataset.pixelFormat {
            case .int16Signed:
                let typed = baseAddress.bindMemory(to: Int16.self, capacity: voxelCount)
                readValue = { Int32(typed[startOffset + $0]) }
            case .int16Unsigned:
                let typed = baseAddress.bindMemory(to: UInt16.self, capacity: voxelCount)
                readValue = { Int32(typed[startOffset + $0]) }
            }

            for voxel in 0..<voxelsPerSlice {
                let normalized = Float(readValue(voxel) - minValue) / Float(span)
                pixels[voxel] = UInt8(clamping: Int(simd_clamp(normalized, 0, 1) * 255))
            }

            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(width: width,
                           height: height,
                           bitsPerComponent: 8,
                           bitsPerPixel: 8,
                           bytesPerRow: width,
                           space: CGColorSpaceCreateDeviceGray(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: provider,
                           decode: nil,
                           shouldInterpolate: false,
                           intent: .defaultIntent)
        }
#else
        return nil
#endif
    }
}
