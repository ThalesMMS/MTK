//
//  MetalMPRAdapter.swift
//  MetalVolumetrics
//
//  Multi-planar reconstruction adapter with GPU acceleration and CPU fallback.
//  Leverages Metal compute shaders for high-performance slab generation when
//  available, while maintaining a robust CPU reference implementation for
//  compatibility and testing.
//
//  Thales Matheus Mendonça Santos — February 2026

import Foundation
import Metal
import OSLog
import simd

@preconcurrency
public actor MetalMPRAdapter: MPRReslicePort {
    public struct Overrides: Equatable {
        var blend: MPRBlendMode?
        var slabThickness: Int?
        var slabSteps: Int?
    }

    public struct SliceSnapshot: Equatable {
        var axis: MPRPlaneAxis
        var intensityRange: ClosedRange<Int32>
        var blend: MPRBlendMode
        var thickness: Int
        var steps: Int
    }

    private var overrides = Overrides()
    private var lastSnapshot: SliceSnapshot?

    // GPU acceleration
    private var gpuAdapter: MetalMPRComputeAdapter?
    private var forceCPU: Bool = false
    private let logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "MetalMPRAdapter")

    public init() {}

    /// Initialize with Metal device for GPU acceleration
    /// - Parameters:
    ///   - device: Metal device for GPU compute
    ///   - commandQueue: Optional command queue (will be created if nil)
    ///   - library: Optional Metal library (will be loaded if nil)
    ///   - debugOptions: Debug configuration options
    public init(device: any MTLDevice,
                commandQueue: (any MTLCommandQueue)? = nil,
                library: (any MTLLibrary)? = nil,
                debugOptions: VolumeRenderingDebugOptions = VolumeRenderingDebugOptions()) {
        let queue = commandQueue ?? device.makeCommandQueue()
        let lib = library ?? ShaderLibraryLoader.makeDefaultLibrary(on: device) { message in
            Logger(subsystem: "com.mtk.volumerendering", category: "ShaderLoader").info("\(message)")
        }

        if let queue = queue, let lib = lib {
            let featureFlags = FeatureFlags.evaluate(for: device)
            self.gpuAdapter = MetalMPRComputeAdapter(
                device: device,
                commandQueue: queue,
                library: lib,
                featureFlags: featureFlags,
                debugOptions: debugOptions
            )
            logger.info("MetalMPRAdapter initialized with GPU acceleration")
        } else {
            logger.warning("MetalMPRAdapter: Failed to initialize GPU adapter, using CPU fallback")
        }
    }

    public func makeSlab(dataset: VolumeDataset,
                         plane: MPRPlaneGeometry,
                         thickness: Int,
                         steps: Int,
                         blend: MPRBlendMode) async throws -> MPRSlice {
        let effectiveBlend = overrides.blend ?? blend
        let effectiveThickness = VolumetricMath.sanitizeThickness(overrides.slabThickness ?? thickness)
        let effectiveSteps = VolumetricMath.sanitizeSteps(overrides.slabSteps ?? steps)

        // Try GPU path first if available and not forced to CPU
        if shouldUseGPU(for: dataset) {
            let startTime = CFAbsoluteTimeGetCurrent()
            do {
                let slice = try await gpuAdapter!.makeSlab(
                    dataset: dataset,
                    plane: plane,
                    thickness: effectiveThickness,
                    steps: effectiveSteps,
                    blend: effectiveBlend
                )

                let duration = CFAbsoluteTimeGetCurrent() - startTime
                logger.info("MPR slab generation completed via GPU path: \(String(format: "%.2f", duration * 1000))ms blend=\(effectiveBlend) thickness=\(effectiveThickness) steps=\(effectiveSteps)")

                let axis = Self.dominantAxis(for: plane)
                lastSnapshot = SliceSnapshot(axis: axis,
                                             intensityRange: slice.intensityRange,
                                             blend: effectiveBlend,
                                             thickness: effectiveThickness,
                                             steps: effectiveSteps)

                overrides.blend = nil
                overrides.slabThickness = nil
                overrides.slabSteps = nil

                return slice
            } catch {
                let duration = CFAbsoluteTimeGetCurrent() - startTime
                logger.warning("GPU slab generation failed after \(String(format: "%.2f", duration * 1000))ms: \(error.localizedDescription), falling back to CPU")
            }
        }

        // CPU fallback path
        let startTime = CFAbsoluteTimeGetCurrent()
        let slice = try await makeSlabOnCPU(
            dataset: dataset,
            plane: plane,
            thickness: effectiveThickness,
            steps: effectiveSteps,
            blend: effectiveBlend
        )

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        logger.info("MPR slab generation completed via CPU path: \(String(format: "%.2f", duration * 1000))ms blend=\(effectiveBlend) thickness=\(effectiveThickness) steps=\(effectiveSteps)")

        let axis = Self.dominantAxis(for: plane)
        lastSnapshot = SliceSnapshot(axis: axis,
                                     intensityRange: slice.intensityRange,
                                     blend: effectiveBlend,
                                     thickness: effectiveThickness,
                                     steps: effectiveSteps)

        overrides.blend = nil
        overrides.slabThickness = nil
        overrides.slabSteps = nil

        return slice
    }

    public func send(_ command: MPRResliceCommand) async throws {
        // Forward to GPU adapter if available
        if let adapter = gpuAdapter {
            try await adapter.send(command)
        }

        // Also update local overrides for CPU fallback
        switch command {
        case .setBlend(let mode):
            overrides.blend = mode
        case .setSlab(let thickness, let steps):
            overrides.slabThickness = VolumetricMath.sanitizeThickness(thickness)
            overrides.slabSteps = VolumetricMath.sanitizeSteps(steps)
        }
    }

    /// Force CPU rendering path for testing or compatibility
    /// - Parameter force: If true, GPU acceleration will be disabled
    public func setForceCPU(_ force: Bool) {
        forceCPU = force
        if force {
            logger.info("Forcing CPU rendering path")
        } else if gpuAdapter != nil {
            logger.info("GPU rendering path enabled")
        }
    }
}

// MARK: - Testing SPI

extension MetalMPRAdapter {
    @_spi(Testing)
    public var debugOverrides: Overrides { overrides }

    @_spi(Testing)
    public var debugLastSnapshot: SliceSnapshot? { lastSnapshot }

    @_spi(Testing)
    public var debugGPUAvailable: Bool { gpuAdapter != nil }

    @_spi(Testing)
    public var debugForceCPU: Bool { forceCPU }
}

// MARK: - GPU/CPU Path Selection

private extension MetalMPRAdapter {
    /// Determines whether to use GPU compute path based on availability and configuration
    func shouldUseGPU(for dataset: VolumeDataset) -> Bool {
        guard !forceCPU else { return false }
        guard gpuAdapter != nil else { return false }
        return true
    }

    /// CPU-based slab generation (reference implementation)
    func makeSlabOnCPU(dataset: VolumeDataset,
                       plane: MPRPlaneGeometry,
                       thickness: Int,
                       steps: Int,
                       blend: MPRBlendMode) async throws -> MPRSlice {
        try await Task.detached(priority: .userInitiated) {
            dataset.data.withUnsafeBytes { buffer -> MPRSlice in
                guard let reader = VolumeDataReader(dataset: dataset, buffer: buffer) else {
                    return Self.emptySlice(dataset: dataset)
                }

                let (width, height) = Self.sliceDimensions(for: plane)
                let bytesPerPixel = dataset.pixelFormat.bytesPerVoxel
                var pixels = Data(count: width * height * bytesPerPixel)

                let normal = Self.normalVector(for: plane, dataset: dataset)
                let offsets = Self.sampleOffsets(thickness: thickness, steps: steps)

                pixels.withUnsafeMutableBytes { rawBuffer in
                    switch dataset.pixelFormat {
                    case .int16Signed:
                        let pointer = rawBuffer.bindMemory(to: Int16.self)
                        Self.populateSlice(into: pointer,
                                           width: width,
                                           height: height,
                                           reader: reader,
                                           plane: plane,
                                           normal: normal,
                                           offsets: offsets,
                                           blend: blend,
                                           intensityRange: dataset.intensityRange)
                    case .int16Unsigned:
                        let pointer = rawBuffer.bindMemory(to: UInt16.self)
                        Self.populateSlice(into: pointer,
                                           width: width,
                                           height: height,
                                           reader: reader,
                                           plane: plane,
                                           normal: normal,
                                           offsets: offsets,
                                           blend: blend,
                                           intensityRange: dataset.intensityRange)
                    }
                }

                let pixelSpacing = Self.pixelSpacing(for: plane,
                                                     width: width,
                                                     height: height,
                                                     dataset: dataset)
                let intensityRange = Self.intensityRange(in: pixels, pixelFormat: dataset.pixelFormat)
                    ?? dataset.intensityRange

                return MPRSlice(pixels: pixels,
                                width: width,
                                height: height,
                                bytesPerRow: width * bytesPerPixel,
                                pixelFormat: dataset.pixelFormat,
                                intensityRange: intensityRange,
                                pixelSpacing: pixelSpacing)
            }
        }.value
    }
}

// MARK: - Helpers

private extension MetalMPRAdapter {
    static func dominantAxis(for plane: MPRPlaneGeometry) -> MPRPlaneAxis {
        let normal = plane.normalWorld
        let components = [abs(normal.x), abs(normal.y), abs(normal.z)]
        let index = components.enumerated().max(by: { $0.element < $1.element })?.offset ?? 2
        return MPRPlaneAxis(rawValue: index) ?? .z
    }

    static func sliceDimensions(for plane: MPRPlaneGeometry) -> (width: Int, height: Int) {
        let width = max(1, Int(round(simd_length(plane.axisUVoxel))))
        let height = max(1, Int(round(simd_length(plane.axisVVoxel))))
        return (width, height)
    }

    static func normalVector(for plane: MPRPlaneGeometry, dataset: VolumeDataset) -> SIMD3<Float> {
        let cross = simd_cross(plane.axisUVoxel, plane.axisVVoxel)
        let length = simd_length(cross)
        if length > Float.ulpOfOne {
            return cross / length
        }

        let voxelToWorld = voxelToWorldMatrix(for: dataset)
        let worldToVoxel = simd_inverse(voxelToWorld)
        let worldNormal = plane.normalWorld
        let transformed = transformDirection(worldToVoxel, worldNormal)
        let transformedLength = simd_length(transformed)
        if transformedLength > Float.ulpOfOne {
            return transformed / transformedLength
        }
        return SIMD3<Float>(0, 0, 1)
    }

    static func sampleOffsets(thickness: Int, steps: Int) -> [Float] {
        let sanitizedSteps = max(1, steps)
        if sanitizedSteps == 1 { return [0] }

        let span = Float(max(0, thickness))
        if span == 0 {
            return Array(repeating: 0, count: sanitizedSteps)
        }

        let start = -span / 2
        let stepSize = span / Float(sanitizedSteps - 1)
        return (0..<sanitizedSteps).map { start + Float($0) * stepSize }
    }

    static func pixelSpacing(for plane: MPRPlaneGeometry,
                             width: Int,
                             height: Int,
                             dataset: VolumeDataset) -> SIMD2<Float>? {
        let uLength = simd_length(plane.axisUWorld)
        let vLength = simd_length(plane.axisVWorld)
        let spacingU = width > 1 ? uLength / Float(width - 1) : Float(dataset.spacing.x)
        let spacingV = height > 1 ? vLength / Float(height - 1) : Float(dataset.spacing.y)
        return SIMD2<Float>(spacingU, spacingV)
    }

    static func voxelToWorldMatrix(for dataset: VolumeDataset) -> simd_float4x4 {
        let orientation = dataset.orientation
        let spacing = dataset.spacing

        let row = orientation.row
        let column = orientation.column
        let normal = safeNormalize(simd_cross(row, column), fallback: SIMD3<Float>(0, 0, 1))

        let spacingX = Float(spacing.x)
        let spacingY = Float(spacing.y)
        let spacingZ = Float(spacing.z)

        return simd_float4x4(columns: (
            SIMD4<Float>(row.x * spacingX, row.y * spacingX, row.z * spacingX, 0),
            SIMD4<Float>(column.x * spacingY, column.y * spacingY, column.z * spacingY, 0),
            SIMD4<Float>(normal.x * spacingZ, normal.y * spacingZ, normal.z * spacingZ, 0),
            SIMD4<Float>(orientation.origin.x, orientation.origin.y, orientation.origin.z, 1)
        ))
    }

    static func transformDirection(_ matrix: simd_float4x4, _ direction: SIMD3<Float>) -> SIMD3<Float> {
        let vector = matrix * SIMD4<Float>(direction, 0)
        return SIMD3<Float>(vector.x, vector.y, vector.z)
    }

    static func safeNormalize(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        if length <= Float.ulpOfOne {
            return fallback
        }
        return vector / length
    }

    static func emptySlice(dataset: VolumeDataset) -> MPRSlice {
        MPRSlice(pixels: Data(),
                 width: 0,
                 height: 0,
                 bytesPerRow: 0,
                 pixelFormat: dataset.pixelFormat,
                 intensityRange: dataset.intensityRange,
                 pixelSpacing: nil)
    }

    static func populateSlice(into buffer: UnsafeMutableBufferPointer<Int16>,
                              width: Int,
                              height: Int,
                              reader: VolumeDataReader,
                              plane: MPRPlaneGeometry,
                              normal: SIMD3<Float>,
                              offsets: [Float],
                              blend: MPRBlendMode,
                              intensityRange: ClosedRange<Int32>) {
        guard let baseAddress = buffer.baseAddress else { return }
        let uVector = plane.axisUVoxel
        let vVector = plane.axisVVoxel
        let origin = plane.originVoxel
        let lower = Float(intensityRange.lowerBound)
        let upper = Float(intensityRange.upperBound)

        let uDenominator = max(1, width - 1)
        let vDenominator = max(1, height - 1)

        for v in 0..<height {
            let vRatio = height > 1 ? Float(v) / Float(vDenominator) : 0
            for u in 0..<width {
                let uRatio = width > 1 ? Float(u) / Float(uDenominator) : 0
                let basePoint = origin + uVector * uRatio + vVector * vRatio
                let intensity = sampleIntensity(reader: reader,
                                                basePoint: basePoint,
                                                normal: normal,
                                                offsets: offsets,
                                                blend: blend,
                                                intensityRange: intensityRange)
                let clamped = min(max(intensity, lower), upper)
                baseAddress[v * width + u] = Int16(clamping: Int(round(clamped)))
            }
        }
    }

    static func populateSlice(into buffer: UnsafeMutableBufferPointer<UInt16>,
                              width: Int,
                              height: Int,
                              reader: VolumeDataReader,
                              plane: MPRPlaneGeometry,
                              normal: SIMD3<Float>,
                              offsets: [Float],
                              blend: MPRBlendMode,
                              intensityRange: ClosedRange<Int32>) {
        guard let baseAddress = buffer.baseAddress else { return }
        let uVector = plane.axisUVoxel
        let vVector = plane.axisVVoxel
        let origin = plane.originVoxel
        let lower = Float(intensityRange.lowerBound)
        let upper = Float(intensityRange.upperBound)

        let uDenominator = max(1, width - 1)
        let vDenominator = max(1, height - 1)

        for v in 0..<height {
            let vRatio = height > 1 ? Float(v) / Float(vDenominator) : 0
            for u in 0..<width {
                let uRatio = width > 1 ? Float(u) / Float(uDenominator) : 0
                let basePoint = origin + uVector * uRatio + vVector * vRatio
                let intensity = sampleIntensity(reader: reader,
                                                basePoint: basePoint,
                                                normal: normal,
                                                offsets: offsets,
                                                blend: blend,
                                                intensityRange: intensityRange)
                let clamped = min(max(intensity, lower), upper)
                baseAddress[v * width + u] = UInt16(clamping: Int(round(clamped)))
            }
        }
    }

    static func sampleIntensity(reader: VolumeDataReader,
                                basePoint: SIMD3<Float>,
                                normal: SIMD3<Float>,
                                offsets: [Float],
                                blend: MPRBlendMode,
                                intensityRange: ClosedRange<Int32>) -> Float {
        let defaultValue = Float(intensityRange.lowerBound)

        switch blend {
        case .single:
            guard !offsets.isEmpty else { return defaultValue }
            let middleIndex = offsets.count / 2
            let position = basePoint + normal * offsets[middleIndex]
            return reader.intensity(at: position)
        case .maximum:
            var hasSample = false
            var maxSample = defaultValue
            for offset in offsets {
                let position = basePoint + normal * offset
                let intensity = reader.intensity(at: position)
                if !hasSample || intensity > maxSample {
                    maxSample = intensity
                    hasSample = true
                }
            }
            return hasSample ? maxSample : defaultValue
        case .minimum:
            var hasSample = false
            var minSample = Float(intensityRange.upperBound)
            for offset in offsets {
                let position = basePoint + normal * offset
                let intensity = reader.intensity(at: position)
                if !hasSample || intensity < minSample {
                    minSample = intensity
                    hasSample = true
                }
            }
            return hasSample ? minSample : defaultValue
        case .average:
            var total: Float = 0
            var count: Float = 0
            for offset in offsets {
                let position = basePoint + normal * offset
                total += reader.intensity(at: position)
                count += 1
            }
            return count > 0 ? total / count : defaultValue
        @unknown default:
            guard !offsets.isEmpty else { return defaultValue }
            let middleIndex = offsets.count / 2
            let position = basePoint + normal * offsets[middleIndex]
            return reader.intensity(at: position)
        }
    }

    static func intensityRange(in pixels: Data, pixelFormat: VolumePixelFormat) -> ClosedRange<Int32>? {
        guard !pixels.isEmpty else { return nil }

        return pixels.withUnsafeBytes { rawBuffer -> ClosedRange<Int32>? in
            switch pixelFormat {
            case .int16Signed:
                let count = rawBuffer.count / MemoryLayout<Int16>.size
                guard count > 0 else { return nil }
                var minValue = Int32(Int16.max)
                var maxValue = Int32(Int16.min)
                let pointer = rawBuffer.bindMemory(to: Int16.self)
                for index in 0..<count {
                    let value = Int32(pointer[index])
                    minValue = min(minValue, value)
                    maxValue = max(maxValue, value)
                }
                return minValue...maxValue
            case .int16Unsigned:
                let count = rawBuffer.count / MemoryLayout<UInt16>.size
                guard count > 0 else { return nil }
                var minValue = Int32.max
                var maxValue = Int32.min
                let pointer = rawBuffer.bindMemory(to: UInt16.self)
                for index in 0..<count {
                    let value = Int32(pointer[index])
                    minValue = min(minValue, value)
                    maxValue = max(maxValue, value)
                }
                return minValue...maxValue
            }
        }
    }
}
