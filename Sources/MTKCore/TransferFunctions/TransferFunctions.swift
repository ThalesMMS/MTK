//
//  TransferFunctions.swift
//  MTK
//
//  Central API for transfer function texture generation used by volumetric
//  materials (VolumeCube/MPRPlane). Loads presets from bundled .tf resources,
//  normalizes colors (sRGB/linear), applies shift, and provides a shared
//  texture cache to avoid redundant GPU allocations.
//
//  Thales Matheus Mendonça Santos — October 2025
//

import Foundation
import Metal
import simd

public enum TransferFunctions {
    public struct TextureOptions: Hashable {
        public var resolution: Int = 1024
        public var gradientResolution: Int = 1

        public static let `default` = TextureOptions()
    }

    public static func transferFunction(for preset: VolumeRenderingBuiltinPreset,
                                        logger: Logger = Logger(subsystem: "com.mtk.volumerendering",
                                                                category: "Volumetric.TransferFunction")) -> TransferFunction? {
        // Try loading from bundle resources first
        if let loaded = TransferFunctionPresetLoader.load(preset, logger: logger) {
            logger.debug("Loaded transfer function '\(preset.rawValue)' from bundle resource")
            return loaded
        }

        // Fallback to factory functions if resource loading fails
        logger.warning("Failed to load transfer function '\(preset.rawValue)' from resources, falling back to factory function")

        switch preset {
        case .ctEntire,
             .ctArteries,
             .ctLung,
             .ctBone,
             .ctCardiac,
             .ctLiverVasculature,
             .mrT2Brain,
             .ctChestContrast,
             .ctSoftTissue,
             .ctPulmonaryArteries,
             .ctFat,
             .mrAngio:
            return nil
        }
    }

    @MainActor
    public static func texture(for preset: VolumeRenderingBuiltinPreset,
                               device: any MTLDevice,
                               options: TextureOptions = .default,
                               logger: Logger = Logger(subsystem: "com.mtk.volumerendering",
                                                       category: "Volumetric.TransferFunction")) -> (any MTLTexture)? {
        guard let transfer = transferFunction(for: preset) else { return nil }
        return texture(for: transfer, device: device, options: options, logger: logger)
    }

    @MainActor
    public static func texture(for transferFunction: TransferFunction,
                               device: any MTLDevice,
                               options: TextureOptions = .default,
                               logger: Logger = Logger(subsystem: "com.mtk.volumerendering",
                                                       category: "Volumetric.TransferFunction")) -> (any MTLTexture)? {
        TransferFunctionTextureCache.shared.texture(
            for: transferFunction,
            options: options,
            device: device,
            logger: logger
        )
    }
}

private extension TransferFunctions {

    static func buildTexture(for transfer: TransferFunction,
                             options: TextureOptions,
                             device: any MTLDevice,
                             logger: Logger) -> (any MTLTexture)? {
        let width = max(1, options.resolution)
        let height = max(1, options.gradientResolution)

        let colourPoints = prepareColourPoints(for: transfer)
        let alphaPoints = prepareAlphaPoints(for: transfer)

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = width
        descriptor.height = height
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            logger.error("Failed to create transfer function texture")
            return nil
        }
        texture.label = "TF.\(transfer.name)"

        var table = [SIMD4<Float>](repeating: SIMD4<Float>(repeating: 0), count: width * height)

        for x in 0..<width {
            let t = width > 1 ? Float(x) / Float(width - 1) : 0
            let sampleValue = transfer.minimumValue + (transfer.maximumValue - transfer.minimumValue) * t

            let colour = interpolateColour(at: sampleValue, points: colourPoints)
            let alpha = interpolateAlpha(at: sampleValue, points: alphaPoints)
            let finalColour = SIMD4<Float>(colour.r, colour.g, colour.b, VolumetricMath.clampFloat(alpha, lower: 0, upper: 1))

            for y in 0..<height {
                table[x + y * width] = finalColour
            }
        }

        table.withUnsafeBytes { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: MemoryLayout<SIMD4<Float>>.stride * width
            )
        }

        return texture
    }

    static func prepareColourPoints(for transfer: TransferFunction) -> [TransferFunction.ColorPoint] {
        var points = transfer.sanitizedColourPoints().map { point -> TransferFunction.ColorPoint in
            var shifted = point
            shifted.dataValue += transfer.shift
            shifted.colourValue = linearize(colour: point.colourValue, colorSpace: transfer.colorSpace)
            return shifted
        }
        points.sort { $0.dataValue < $1.dataValue }
        return points
    }

    static func prepareAlphaPoints(for transfer: TransferFunction) -> [TransferFunction.AlphaPoint] {
        var points = transfer.sanitizedAlphaPoints().map { point -> TransferFunction.AlphaPoint in
            var shifted = point
            shifted.dataValue += transfer.shift
            return shifted
        }
        points.sort { $0.dataValue < $1.dataValue }
        return points
    }

    static func interpolateColour(at value: Float,
                                  points: [TransferFunction.ColorPoint]) -> TransferFunction.RGBAColor {
        guard let first = points.first else { return TransferFunction.RGBAColor(r: 1, g: 1, b: 1, a: 1) }
        if value <= first.dataValue {
            return first.colourValue
        }

        for index in 1..<points.count {
            let right = points[index]
            let left = points[index - 1]
            if value <= right.dataValue {
                let span = max(right.dataValue - left.dataValue, Float.leastNonzeroMagnitude)
                let t = (value - left.dataValue) / span
                return right.colourValue * t + left.colourValue * (1 - t)
            }
        }

        return points.last?.colourValue ?? first.colourValue
    }

    static func interpolateAlpha(at value: Float,
                                 points: [TransferFunction.AlphaPoint]) -> Float {
        guard let first = points.first else { return 1 }
        if value <= first.dataValue {
            return first.alphaValue
        }

        for index in 1..<points.count {
            let right = points[index]
            let left = points[index - 1]
            if value <= right.dataValue {
                let span = max(right.dataValue - left.dataValue, Float.leastNonzeroMagnitude)
                let t = (value - left.dataValue) / span
                return right.alphaValue * t + left.alphaValue * (1 - t)
            }
        }

        return points.last?.alphaValue ?? first.alphaValue
    }

    static func linearize(colour: TransferFunction.RGBAColor,
                          colorSpace: TransferFunction.ColorSpace) -> TransferFunction.RGBAColor {
        TransferFunction.RGBAColor(
            r: colorSpace.toLinear(colour.r),
            g: colorSpace.toLinear(colour.g),
            b: colorSpace.toLinear(colour.b),
            a: colour.a
        )
    }
}

@MainActor
private final class TransferFunctionTextureCache {
    static let shared = TransferFunctionTextureCache()

    private struct CacheKey: Hashable {
        let deviceID: UInt64
        let signature: Int
        let options: TransferFunctions.TextureOptions
    }

    private struct Entry {
        let texture: any MTLTexture
    }

    private let lock = NSLock()
    private var storage: [CacheKey: Entry] = [:]

    func texture(for transfer: TransferFunction,
                 options: TransferFunctions.TextureOptions,
                 device: any MTLDevice,
                 logger: Logger) -> (any MTLTexture)? {
        let signature = transfer.textureSignature()
        let deviceID = device.registryID
        let key = CacheKey(deviceID: deviceID, signature: signature, options: options)

        lock.lock()
        if let entry = storage[key] {
            let cached = entry.texture
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let texture = TransferFunctions.buildTexture(for: transfer,
                                                            options: options,
                                                            device: device,
                                                            logger: logger) else {
            return nil
        }

        lock.lock()
        storage[key] = Entry(texture: texture)
        lock.unlock()
        return texture
    }
}

private extension TransferFunction {
    func textureSignature() -> Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(minimumValue)
        hasher.combine(maximumValue)
        hasher.combine(shift)
        hasher.combine(colorSpace.rawValue)
        hasher.combine(colourPoints.count)
        for point in colourPoints {
            hasher.combine(point.dataValue)
            hasher.combine(point.colourValue.r)
            hasher.combine(point.colourValue.g)
            hasher.combine(point.colourValue.b)
            hasher.combine(point.colourValue.a)
        }
        hasher.combine(alphaPoints.count)
        for point in alphaPoints {
            hasher.combine(point.dataValue)
            hasher.combine(point.alphaValue)
        }
        return hasher.finalize()
    }
}
