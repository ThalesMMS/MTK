//
//  VolumeDataReader.swift
//  MetalVolumetrics
//
//  Lightweight helper that exposes random-access and interpolated reads over
//  the volumetric dataset buffers used by the Metal adapters. The reader keeps
//  the raw pointer lifetime scoped to the caller, ensuring no unsafe escapes
//  while still offering trilinear sampling for MPR slabs and histogram
//  aggregation.
//

import Foundation
import simd
import DomainPorts

struct VolumeDataReader {
    let dataset: VolumeDataset
    private let baseAddress: UnsafeRawPointer
    private let voxelCount: Int

    let width: Int
    let height: Int
    let depth: Int

    init?(dataset: VolumeDataset, buffer: UnsafeRawBufferPointer) {
        guard let baseAddress = buffer.baseAddress else { return nil }
        self.dataset = dataset
        self.baseAddress = baseAddress
        self.width = dataset.dimensions.width
        self.height = dataset.dimensions.height
        self.depth = dataset.dimensions.depth
        self.voxelCount = dataset.voxelCount
    }

    func intensity(atLinearIndex index: Int) -> Float {
        precondition(index >= 0 && index < voxelCount, "Index out of bounds")
        switch dataset.pixelFormat {
        case .int16Signed:
            let pointer = baseAddress.assumingMemoryBound(to: Int16.self)
            return Float(pointer[index])
        case .int16Unsigned:
            let pointer = baseAddress.assumingMemoryBound(to: UInt16.self)
            return Float(pointer[index])
        }
    }

    func intensity(x: Int, y: Int, z: Int) -> Float {
        let clampedX = max(0, min(width - 1, x))
        let clampedY = max(0, min(height - 1, y))
        let clampedZ = max(0, min(depth - 1, z))
        let index = linearIndex(x: clampedX, y: clampedY, z: clampedZ)
        return intensity(atLinearIndex: index)
    }

    func intensity(at position: SIMD3<Float>) -> Float {
        if width == 0 || height == 0 || depth == 0 { return 0 }

        let clamped = clamp(position,
                            min: SIMD3<Float>(repeating: 0),
                            max: SIMD3<Float>(Float(width - 1),
                                               Float(height - 1),
                                               Float(depth - 1)))

        let x0 = Int(floor(clamped.x))
        let y0 = Int(floor(clamped.y))
        let z0 = Int(floor(clamped.z))
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let z1 = min(z0 + 1, depth - 1)

        let tx = clamped.x - Float(x0)
        let ty = clamped.y - Float(y0)
        let tz = clamped.z - Float(z0)

        let c000 = intensity(x: x0, y: y0, z: z0)
        let c100 = intensity(x: x1, y: y0, z: z0)
        let c010 = intensity(x: x0, y: y1, z: z0)
        let c110 = intensity(x: x1, y: y1, z: z0)
        let c001 = intensity(x: x0, y: y0, z: z1)
        let c101 = intensity(x: x1, y: y0, z: z1)
        let c011 = intensity(x: x0, y: y1, z: z1)
        let c111 = intensity(x: x1, y: y1, z: z1)

        let c00 = lerp(c000, c100, tx)
        let c01 = lerp(c001, c101, tx)
        let c10 = lerp(c010, c110, tx)
        let c11 = lerp(c011, c111, tx)

        let c0 = lerp(c00, c10, ty)
        let c1 = lerp(c01, c11, ty)
        return lerp(c0, c1, tz)
    }

    func forEachIntensity(_ body: (Float) -> Void) {
        switch dataset.pixelFormat {
        case .int16Signed:
            let pointer = baseAddress.assumingMemoryBound(to: Int16.self)
            for index in 0..<voxelCount {
                body(Float(pointer[index]))
            }
        case .int16Unsigned:
            let pointer = baseAddress.assumingMemoryBound(to: UInt16.self)
            for index in 0..<voxelCount {
                body(Float(pointer[index]))
            }
        }
    }
}

private extension VolumeDataReader {
    func linearIndex(x: Int, y: Int, z: Int) -> Int {
        z * width * height + y * width + x
    }

    func clamp(_ value: SIMD3<Float>, min lower: SIMD3<Float>, max upper: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            Swift.max(lower.x, Swift.min(upper.x, value.x)),
            Swift.max(lower.y, Swift.min(upper.y, value.y)),
            Swift.max(lower.z, Swift.min(upper.z, value.z))
        )
    }

    func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }
}
