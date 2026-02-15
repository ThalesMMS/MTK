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

    @MainActor
    public static func texture(for transferFunction: TransferFunction2D,
                               device: any MTLDevice,
                               options: TextureOptions = .default,
                               logger: Logger = Logger(subsystem: "com.mtk.volumerendering",
                                                       category: "Volumetric.TransferFunction")) -> (any MTLTexture)? {
        TransferFunctionTextureCache2D.shared.texture(
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

    // MARK: - 2D Transfer Function Support

    static func buildTexture2D(for transfer: TransferFunction2D,
                               options: TextureOptions,
                               device: any MTLDevice,
                               logger: Logger) -> (any MTLTexture)? {
        let width = max(1, options.resolution)
        let height = max(1, options.gradientResolution)

        let colourPoints = prepareColourPoints2D(for: transfer)
        let alphaPoints = prepareAlphaPoints2D(for: transfer)

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = width
        descriptor.height = height
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            logger.error("Failed to create 2D transfer function texture")
            return nil
        }
        texture.label = "TF2D.\(transfer.name)"

        var table = [SIMD4<Float>](repeating: SIMD4<Float>(repeating: 0), count: width * height)

        for y in 0..<height {
            let gradientT = height > 1 ? Float(y) / Float(height - 1) : 0
            let gradientValue = transfer.minimumGradient + (transfer.maximumGradient - transfer.minimumGradient) * gradientT

            for x in 0..<width {
                let intensityT = width > 1 ? Float(x) / Float(width - 1) : 0
                let intensityValue = transfer.minimumIntensity + (transfer.maximumIntensity - transfer.minimumIntensity) * intensityT

                let colour = interpolateColour2D(intensity: intensityValue,
                                                 gradient: gradientValue,
                                                 points: colourPoints)
                let alpha = interpolateAlpha2D(intensity: intensityValue,
                                               gradient: gradientValue,
                                               points: alphaPoints)
                let finalColour = SIMD4<Float>(colour.r, colour.g, colour.b, VolumetricMath.clampFloat(alpha, lower: 0, upper: 1))

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

    static func prepareColourPoints2D(for transfer: TransferFunction2D) -> [TransferFunction2D.ColorPoint2D] {
        var points = transfer.sanitizedColourPoints().map { point -> TransferFunction2D.ColorPoint2D in
            var shifted = point
            shifted.intensity += transfer.shift
            shifted.colourValue = linearize(colour: point.colourValue, colorSpace: transfer.colorSpace)
            return shifted
        }
        points.sort { ($0.intensity, $0.gradientMagnitude) < ($1.intensity, $1.gradientMagnitude) }
        return points
    }

    static func prepareAlphaPoints2D(for transfer: TransferFunction2D) -> [TransferFunction2D.AlphaPoint2D] {
        var points = transfer.sanitizedAlphaPoints().map { point -> TransferFunction2D.AlphaPoint2D in
            var shifted = point
            shifted.intensity += transfer.shift
            return shifted
        }
        points.sort { ($0.intensity, $0.gradientMagnitude) < ($1.intensity, $1.gradientMagnitude) }
        return points
    }

    static func interpolateColour2D(intensity: Float,
                                    gradient: Float,
                                    points: [TransferFunction2D.ColorPoint2D]) -> TransferFunction.RGBAColor {
        guard !points.isEmpty else {
            return TransferFunction.RGBAColor(r: 1, g: 1, b: 1, a: 1)
        }

        // Use inverse distance weighting (IDW) for 2D interpolation
        var weightedColor = TransferFunction.RGBAColor(r: 0, g: 0, b: 0, a: 0)
        var totalWeight: Float = 0

        for point in points {
            let dx = intensity - point.intensity
            let dy = gradient - point.gradientMagnitude
            let distanceSquared = dx * dx + dy * dy

            // If we're exactly at a control point, return its color directly
            if distanceSquared < Float.leastNonzeroMagnitude {
                return point.colourValue
            }

            // Inverse distance weighting with power=2
            let weight = 1.0 / distanceSquared
            weightedColor = weightedColor + point.colourValue * weight
            totalWeight += weight
        }

        if totalWeight > Float.leastNonzeroMagnitude {
            let invTotalWeight = 1.0 / totalWeight
            return weightedColor * invTotalWeight
        }

        // Fallback to first point if weighting fails
        return points[0].colourValue
    }

    static func interpolateAlpha2D(intensity: Float,
                                   gradient: Float,
                                   points: [TransferFunction2D.AlphaPoint2D]) -> Float {
        guard !points.isEmpty else {
            return 1.0
        }

        // Use inverse distance weighting (IDW) for 2D interpolation
        var weightedAlpha: Float = 0
        var totalWeight: Float = 0

        for point in points {
            let dx = intensity - point.intensity
            let dy = gradient - point.gradientMagnitude
            let distanceSquared = dx * dx + dy * dy

            // If we're exactly at a control point, return its alpha directly
            if distanceSquared < Float.leastNonzeroMagnitude {
                return point.alphaValue
            }

            // Inverse distance weighting with power=2
            let weight = 1.0 / distanceSquared
            weightedAlpha += point.alphaValue * weight
            totalWeight += weight
        }

        if totalWeight > Float.leastNonzeroMagnitude {
            return weightedAlpha / totalWeight
        }

        // Fallback to first point if weighting fails
        return points[0].alphaValue
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

@MainActor
private final class TransferFunctionTextureCache2D {
    static let shared = TransferFunctionTextureCache2D()

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

    func texture(for transfer: TransferFunction2D,
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

        guard let texture = TransferFunctions.buildTexture2D(for: transfer,
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

private extension TransferFunction2D {
    func textureSignature() -> Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(minimumIntensity)
        hasher.combine(maximumIntensity)
        hasher.combine(minimumGradient)
        hasher.combine(maximumGradient)
        hasher.combine(shift)
        hasher.combine(colorSpace.rawValue)
        hasher.combine(intensityResolution)
        hasher.combine(gradientResolution)
        hasher.combine(colourPoints.count)
        for point in colourPoints {
            hasher.combine(point.intensity)
            hasher.combine(point.gradientMagnitude)
            hasher.combine(point.colourValue.r)
            hasher.combine(point.colourValue.g)
            hasher.combine(point.colourValue.b)
            hasher.combine(point.colourValue.a)
        }
        hasher.combine(alphaPoints.count)
        for point in alphaPoints {
            hasher.combine(point.intensity)
            hasher.combine(point.gradientMagnitude)
            hasher.combine(point.alphaValue)
        }
        return hasher.finalize()
    }
}
