//
//  MetalMPRAdapter.swift
//  MetalVolumetrics
//
//  CPU reference implementation of the multi-planar reconstruction adapter.
//  It operates on raw voxel buffers and supports blend modes to validate the
//  domain contract without depending on GPU availability.
//

import Foundation
import simd
import DomainPorts

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

    public init() {}

    public func makeSlab(dataset: VolumeDataset,
                         plane: MPRPlaneGeometry,
                         thickness: Int,
                         steps: Int,
                         blend: MPRBlendMode) async throws -> MPRSlice {
        let effectiveBlend = overrides.blend ?? blend
        let effectiveThickness = Self.sanitizeThickness(overrides.slabThickness ?? thickness)
        let effectiveSteps = Self.sanitizeSteps(overrides.slabSteps ?? steps)

        let slice = try await Task.detached(priority: .userInitiated) {
            dataset.data.withUnsafeBytes { buffer -> MPRSlice in
                guard let reader = VolumeDataReader(dataset: dataset, buffer: buffer) else {
                    return Self.emptySlice(dataset: dataset)
                }

                let (width, height) = Self.sliceDimensions(for: plane)
                let bytesPerPixel = dataset.pixelFormat.bytesPerVoxel
                var pixels = Data(count: width * height * bytesPerPixel)

                let normal = Self.normalVector(for: plane, dataset: dataset)
                let offsets = Self.sampleOffsets(thickness: effectiveThickness, steps: effectiveSteps)

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
                                           blend: effectiveBlend,
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
                                           blend: effectiveBlend,
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
        switch command {
        case .setBlend(let mode):
            overrides.blend = mode
        case .setSlab(let thickness, let steps):
            overrides.slabThickness = max(0, thickness)
            overrides.slabSteps = max(1, steps)
        }
    }
}

// MARK: - Testing SPI

extension MetalMPRAdapter {
    @_spi(Testing)
    public var debugOverrides: Overrides { overrides }

    @_spi(Testing)
    public var debugLastSnapshot: SliceSnapshot? { lastSnapshot }
}

// MARK: - Helpers

private extension MetalMPRAdapter {
    static func sanitizeThickness(_ value: Int) -> Int {
        max(0, value)
    }

    static func sanitizeSteps(_ value: Int) -> Int {
        max(1, value)
    }

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
