//
//  ResourceMemoryEstimator.swift
//  MTK
//
//  Approximate GPU resource memory costs for diagnostics.
//

import CoreGraphics
import Foundation
@preconcurrency import Metal

public enum ResourceMemoryEstimator {
    public static func estimate(for texture: any MTLTexture) -> Int {
        guard let bytesPerPixel = texture.pixelFormat.bytesPerPixel else {
            return 0
        }

        let mipLevels = max(1, texture.mipmapLevelCount)
        let sampleCount = max(1, texture.sampleCount)
        let arrayLength = texture.textureType == .type3D ? 1 : max(1, texture.arrayLength)
        let effectiveArrayLength: Int
        switch texture.textureType {
        case .typeCube, .typeCubeArray:
            effectiveArrayLength = arrayLength * 6
        default:
            effectiveArrayLength = arrayLength
        }

        var totalBytes = 0
        for level in 0..<mipLevels {
            let width = max(1, texture.width >> level)
            let height = max(1, texture.height >> level)
            let depth = texture.textureType == .type3D ? max(1, texture.depth >> level) : max(1, texture.depth)
            totalBytes = saturatingAdd(
                totalBytes,
                saturatingProduct(width, height, depth, effectiveArrayLength, sampleCount, bytesPerPixel)
            )
        }

        return totalBytes
    }

    public static func estimate(for dataset: VolumeDataset) -> Int {
        dataset.dimensions.voxelCount * dataset.pixelFormat.bytesPerVoxel
    }

    public static func estimate(forOutputTexture size: CGSize,
                                pixelFormat: MTLPixelFormat) -> Int {
        guard size.width.isFinite, size.height.isFinite else {
            return 0
        }
        guard let bytesPerPixel = pixelFormat.bytesPerPixel else {
            return 0
        }

        let ceilWidth = min(max(ceil(Double(size.width)), 0), Double(Int.max))
        let ceilHeight = min(max(ceil(Double(size.height)), 0), Double(Int.max))
        let width = ceilWidth >= Double(Int.max) ? Int.max : Int(ceilWidth)
        let height = ceilHeight >= Double(Int.max) ? Int.max : Int(ceilHeight)
        return saturatingProduct(width, height, bytesPerPixel)
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }

    private static func saturatingProduct(_ values: Int...) -> Int {
        var result = 1
        for value in values {
            let product = result.multipliedReportingOverflow(by: value)
            if product.overflow {
                return Int.max
            }
            result = product.partialValue
        }
        return result
    }
}

private extension MTLPixelFormat {
    var bytesPerPixel: Int? {
        switch self {
        case .invalid:
            return nil

        case .a8Unorm,
             .r8Unorm, .r8Unorm_srgb, .r8Snorm, .r8Uint, .r8Sint,
             .stencil8:
            return MemoryLayout<UInt8>.size

        case .r16Unorm, .r16Snorm, .r16Uint, .r16Sint, .r16Float,
             .rg8Unorm, .rg8Unorm_srgb, .rg8Snorm, .rg8Uint, .rg8Sint:
            return MemoryLayout<UInt16>.size

        case .r32Uint, .r32Sint, .r32Float,
             .rg16Unorm, .rg16Snorm, .rg16Uint, .rg16Sint, .rg16Float,
             .rgba8Unorm, .rgba8Unorm_srgb, .rgba8Snorm, .rgba8Uint, .rgba8Sint,
             .bgra8Unorm, .bgra8Unorm_srgb,
             .rgb10a2Unorm, .rgb10a2Uint,
             .rg11b10Float, .rgb9e5Float,
             .bgr10a2Unorm,
             .depth32Float,
             .x24_stencil8:
            return MemoryLayout<UInt32>.size

        case .rg32Uint, .rg32Sint, .rg32Float,
             .rgba16Unorm, .rgba16Snorm, .rgba16Uint, .rgba16Sint, .rgba16Float,
             .depth32Float_stencil8,
             .x32_stencil8:
            return MemoryLayout<UInt64>.size

        case .rgba32Uint, .rgba32Sint, .rgba32Float:
            return SIMD4<Float>.stride

        default:
            return nil
        }
    }
}
