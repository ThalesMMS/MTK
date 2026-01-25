//
//  TransferFunctions.swift
//  MTK
//
//  Biblioteca centralizada de curvas HU e geração de texturas 1D
//  reutilizada pelos materiais volumétricos (VolumeCube/MPRPlane).
//  Concentra presets, normaliza cores (sRGB/linear), aplica shift e
//  disponibiliza cache compartilhado para evitar recriação de texturas.
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

    public static func transferFunction(for preset: VolumeRenderingBuiltinPreset) -> TransferFunction? {
        switch preset {
        case .ctEntire:
            return makeTransferFunction(
                name: "ct_entire",
                red: vrmusclesbonesRed,
                green: vrmusclesbonesGreen,
                blue: vrmusclesbonesBlue,
                alphaStrategy: .logarithmicInverse,
                colorSpace: .sRGB
            )
        case .ctArteries:
            return makeTransferFunction(
                name: "ct_arteries",
                red: vrredvesselsRed,
                green: vrredvesselsGreen,
                blue: vrredvesselsBlue,
                alphaStrategy: .logarithmicInverse,
                colorSpace: .sRGB
            )
        case .ctLung:
            return makeLungTransferFunction()
        case .ctBone:
            return makeCtBoneTransferFunction()
        case .ctCardiac:
            return makeCtCardiacTransferFunction()
        case .ctLiverVasculature:
            return makeCtLiverVasculatureTransferFunction()
        case .mrT2Brain:
            return makeMrT2BrainTransferFunction()
        case .ctChestContrast:
            return makeCtChestContrastTransferFunction()
        case .ctSoftTissue:
            return makeCtSoftTissueTransferFunction()
        case .ctPulmonaryArteries:
            return makeCtPulmonaryArteriesTransferFunction()
        case .ctFat:
            return makeCtFatTransferFunction()
        case .mrAngio:
            return makeMrAngioTransferFunction()
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
    enum AlphaStrategy {
        case logarithmicInverse
    }

    static let minimumValue: Float = -1024
    static let maximumValue: Float = 3071

    static func makeTransferFunction(name: String,
                                     red: [UInt8],
                                     green: [UInt8],
                                     blue: [UInt8],
                                     alphaStrategy: AlphaStrategy,
                                     colorSpace: TransferFunction.ColorSpace) -> TransferFunction? {
        guard red.count == green.count, red.count == blue.count else { return nil }

        var transfer = baseTransferFunction(named: name, colorSpace: colorSpace)
        transfer.colourPoints = colourPoints(from: red, green: green, blue: blue)
        transfer.alphaPoints = alphaPoints(strategy: alphaStrategy)
        return transfer
    }

    static func makeLungTransferFunction() -> TransferFunction? {
        var transfer = baseTransferFunction(named: "ct_lung", colorSpace: .sRGB)

        let baseColour = TransferFunction.RGBAColor(
            r: lungBaseColour.red,
            g: lungBaseColour.green,
            b: lungBaseColour.blue,
            a: 1.0
        )

        var points: [TransferFunction.ColorPoint] = [
            TransferFunction.ColorPoint(dataValue: minimumValue, colourValue: baseColour),
            TransferFunction.ColorPoint(dataValue: maximumValue, colourValue: baseColour)
        ]

        for entry in airwaysCurvePoints {
            let colour = TransferFunction.RGBAColor(
                r: lungBaseColour.red,
                g: lungBaseColour.green,
                b: lungBaseColour.blue,
                a: 1.0
            )
            points.append(TransferFunction.ColorPoint(dataValue: entry, colourValue: colour))
        }

        transfer.colourPoints = points.sorted { $0.dataValue < $1.dataValue }
        transfer.alphaPoints = alphaPoints(strategy: .logarithmicInverse)
        return transfer
    }

    static func makeCtBoneTransferFunction() -> TransferFunction? {
        var transfer = TransferFunction()
        transfer.name = "ct_bone"
        transfer.minimumValue = -3024
        transfer.maximumValue = 3071
        transfer.shift = 0
        transfer.colorSpace = .sRGB

        transfer.colourPoints = [
            TransferFunction.ColorPoint(dataValue: -3024, colourValue: TransferFunction.RGBAColor(r: 0.0, g: 0.0, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: -16.4458, colourValue: TransferFunction.RGBAColor(r: 0.729412, g: 0.254902, b: 0.301961, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 641.385, colourValue: TransferFunction.RGBAColor(r: 0.905882, g: 0.815686, b: 0.552941, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 3071, colourValue: TransferFunction.RGBAColor(r: 1.0, g: 1.0, b: 1.0, a: 1.0))
        ]

        transfer.alphaPoints = [
            TransferFunction.AlphaPoint(dataValue: -3024, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: -16.4458, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: 641.385, alphaValue: 0.715686),
            TransferFunction.AlphaPoint(dataValue: 3071, alphaValue: 0.705882)
        ]

        return transfer
    }

    static func makeCtCardiacTransferFunction() -> TransferFunction? {
        var transfer = TransferFunction()
        transfer.name = "ct_cardiac"
        transfer.minimumValue = -3024
        transfer.maximumValue = 3071
        transfer.shift = 0
        transfer.colorSpace = .sRGB

        transfer.colourPoints = [
            TransferFunction.ColorPoint(dataValue: -3024, colourValue: TransferFunction.RGBAColor(r: 0.0, g: 0.0, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: -77.6875, colourValue: TransferFunction.RGBAColor(r: 0.54902, g: 0.25098, b: 0.14902, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 94.9518, colourValue: TransferFunction.RGBAColor(r: 0.882353, g: 0.603922, b: 0.290196, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 179.052, colourValue: TransferFunction.RGBAColor(r: 1.0, g: 0.937033, b: 0.954531, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 260.439, colourValue: TransferFunction.RGBAColor(r: 0.615686, g: 0.0, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 3071, colourValue: TransferFunction.RGBAColor(r: 0.827451, g: 0.658824, b: 1.0, a: 1.0))
        ]

        transfer.alphaPoints = [
            TransferFunction.AlphaPoint(dataValue: -3024, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: -77.6875, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: 94.9518, alphaValue: 0.285714),
            TransferFunction.AlphaPoint(dataValue: 179.052, alphaValue: 0.553571),
            TransferFunction.AlphaPoint(dataValue: 260.439, alphaValue: 0.848214),
            TransferFunction.AlphaPoint(dataValue: 3071, alphaValue: 0.875)
        ]

        return transfer
    }

    static func makeCtLiverVasculatureTransferFunction() -> TransferFunction? {
        var transfer = TransferFunction()
        transfer.name = "ct_liver_vasculature"
        transfer.minimumValue = -2048
        transfer.maximumValue = 3661
        transfer.shift = 0
        transfer.colorSpace = .sRGB

        transfer.colourPoints = [
            TransferFunction.ColorPoint(dataValue: -2048, colourValue: TransferFunction.RGBAColor(r: 0.0, g: 0.0, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 149.113, colourValue: TransferFunction.RGBAColor(r: 0.0, g: 0.0, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 157.884, colourValue: TransferFunction.RGBAColor(r: 0.501961, g: 0.25098, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 339.96, colourValue: TransferFunction.RGBAColor(r: 0.695386, g: 0.59603, b: 0.36886, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 388.526, colourValue: TransferFunction.RGBAColor(r: 0.854902, g: 0.85098, b: 0.827451, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 1197.95, colourValue: TransferFunction.RGBAColor(r: 1.0, g: 1.0, b: 1.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 3661, colourValue: TransferFunction.RGBAColor(r: 1.0, g: 1.0, b: 1.0, a: 1.0))
        ]

        transfer.alphaPoints = [
            TransferFunction.AlphaPoint(dataValue: -2048, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: 149.113, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: 157.884, alphaValue: 0.482143),
            TransferFunction.AlphaPoint(dataValue: 339.96, alphaValue: 0.660714),
            TransferFunction.AlphaPoint(dataValue: 388.526, alphaValue: 0.830357),
            TransferFunction.AlphaPoint(dataValue: 1197.95, alphaValue: 0.839286),
            TransferFunction.AlphaPoint(dataValue: 3661, alphaValue: 0.848214)
        ]

        return transfer
    }

    static func makeMrT2BrainTransferFunction() -> TransferFunction? {
        var transfer = TransferFunction()
        transfer.name = "mr_t2_brain"
        transfer.minimumValue = 0
        transfer.maximumValue = 641
        transfer.shift = 0
        transfer.colorSpace = .sRGB

        transfer.colourPoints = [
            TransferFunction.ColorPoint(dataValue: 0, colourValue: TransferFunction.RGBAColor(r: 0.0, g: 0.0, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 98.7223, colourValue: TransferFunction.RGBAColor(r: 0.956863, g: 0.839216, b: 0.192157, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 412.406, colourValue: TransferFunction.RGBAColor(r: 0.0, g: 0.592157, b: 0.807843, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 641, colourValue: TransferFunction.RGBAColor(r: 1.0, g: 1.0, b: 1.0, a: 1.0))
        ]

        transfer.alphaPoints = [
            TransferFunction.AlphaPoint(dataValue: 0, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: 36.05, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: 218.302, alphaValue: 0.171429),
            TransferFunction.AlphaPoint(dataValue: 412.406, alphaValue: 1.0),
            TransferFunction.AlphaPoint(dataValue: 641, alphaValue: 1.0)
        ]

        return transfer
    }

    static func makeCtChestContrastTransferFunction() -> TransferFunction? {
        var transfer = TransferFunction()
        transfer.name = "ct_chest_contrast"
        transfer.minimumValue = -3024
        transfer.maximumValue = 3071
        transfer.shift = 0
        transfer.colorSpace = .sRGB

        transfer.colourPoints = [
            TransferFunction.ColorPoint(dataValue: -3024, colourValue: TransferFunction.RGBAColor(r: 0.0, g: 0.0, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 67.0106, colourValue: TransferFunction.RGBAColor(r: 0.54902, g: 0.25098, b: 0.14902, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 251.105, colourValue: TransferFunction.RGBAColor(r: 0.882353, g: 0.603922, b: 0.290196, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 439.291, colourValue: TransferFunction.RGBAColor(r: 1.0, g: 0.937033, b: 0.954531, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 3071, colourValue: TransferFunction.RGBAColor(r: 0.827451, g: 0.658824, b: 1.0, a: 1.0))
        ]

        transfer.alphaPoints = [
            TransferFunction.AlphaPoint(dataValue: -3024, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: 67.0106, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: 251.105, alphaValue: 0.446429),
            TransferFunction.AlphaPoint(dataValue: 439.291, alphaValue: 0.625),
            TransferFunction.AlphaPoint(dataValue: 3071, alphaValue: 0.616071)
        ]

        return transfer
    }

    static func makeCtSoftTissueTransferFunction() -> TransferFunction? {
        var transfer = TransferFunction()
        transfer.name = "ct_soft_tissue"
        transfer.minimumValue = -2048
        transfer.maximumValue = 3661
        transfer.shift = 0
        transfer.colorSpace = .sRGB

        transfer.colourPoints = [
            TransferFunction.ColorPoint(dataValue: -2048, colourValue: TransferFunction.RGBAColor(r: 0.0, g: 0.0, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: -167.01, colourValue: TransferFunction.RGBAColor(r: 0.0, g: 0.0, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: -160, colourValue: TransferFunction.RGBAColor(r: 0.055636, g: 0.055636, b: 0.055636, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 240, colourValue: TransferFunction.RGBAColor(r: 1.0, g: 1.0, b: 1.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 3661, colourValue: TransferFunction.RGBAColor(r: 1.0, g: 1.0, b: 1.0, a: 1.0))
        ]

        transfer.alphaPoints = [
            TransferFunction.AlphaPoint(dataValue: -2048, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: -167.01, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: -160, alphaValue: 1.0),
            TransferFunction.AlphaPoint(dataValue: 240, alphaValue: 1.0),
            TransferFunction.AlphaPoint(dataValue: 3661, alphaValue: 1.0)
        ]

        return transfer
    }

    static func makeCtPulmonaryArteriesTransferFunction() -> TransferFunction? {
        var transfer = TransferFunction()
        transfer.name = "ct_pulmonary_arteries"
        transfer.minimumValue = -2048
        transfer.maximumValue = 3592.73
        transfer.shift = 0
        transfer.colorSpace = .sRGB

        transfer.colourPoints = [
            TransferFunction.ColorPoint(dataValue: -2048, colourValue: TransferFunction.RGBAColor(r: 0.0, g: 0.0, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: -568.625, colourValue: TransferFunction.RGBAColor(r: 0.0, g: 0.0, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: -364.081, colourValue: TransferFunction.RGBAColor(r: 0.396078, g: 0.301961, b: 0.180392, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: -244.813, colourValue: TransferFunction.RGBAColor(r: 0.611765, g: 0.352941, b: 0.070588, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 18.2775, colourValue: TransferFunction.RGBAColor(r: 0.843137, g: 0.015686, b: 0.156863, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 447.798, colourValue: TransferFunction.RGBAColor(r: 0.752941, g: 0.752941, b: 0.752941, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 3592.73, colourValue: TransferFunction.RGBAColor(r: 1.0, g: 1.0, b: 1.0, a: 1.0))
        ]

        transfer.alphaPoints = [
            TransferFunction.AlphaPoint(dataValue: -2048, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: -568.625, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: -364.081, alphaValue: 0.071429),
            TransferFunction.AlphaPoint(dataValue: -244.813, alphaValue: 0.401786),
            TransferFunction.AlphaPoint(dataValue: 18.2775, alphaValue: 0.607143),
            TransferFunction.AlphaPoint(dataValue: 447.798, alphaValue: 0.830357),
            TransferFunction.AlphaPoint(dataValue: 3592.73, alphaValue: 0.839286)
        ]

        return transfer
    }

    static func makeCtFatTransferFunction() -> TransferFunction? {
        var transfer = TransferFunction()
        transfer.name = "ct_fat"
        transfer.minimumValue = -1000
        transfer.maximumValue = 2952
        transfer.shift = 0
        transfer.colorSpace = .sRGB

        transfer.colourPoints = [
            TransferFunction.ColorPoint(dataValue: -1000, colourValue: TransferFunction.RGBAColor(r: 0.3, g: 0.3, b: 1.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: -497.5, colourValue: TransferFunction.RGBAColor(r: 0.3, g: 1.0, b: 0.3, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: -99, colourValue: TransferFunction.RGBAColor(r: 0.0, g: 0.0, b: 1.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: -76.946, colourValue: TransferFunction.RGBAColor(r: 0.0, g: 1.0, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: -65.481, colourValue: TransferFunction.RGBAColor(r: 0.835431, g: 0.888889, b: 0.016539, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 83.89, colourValue: TransferFunction.RGBAColor(r: 1.0, g: 0.0, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 463.28, colourValue: TransferFunction.RGBAColor(r: 1.0, g: 0.0, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 659.15, colourValue: TransferFunction.RGBAColor(r: 1.0, g: 0.912535, b: 0.037485, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 2952, colourValue: TransferFunction.RGBAColor(r: 1.0, g: 0.300267, b: 0.299886, a: 1.0))
        ]

        transfer.alphaPoints = [
            TransferFunction.AlphaPoint(dataValue: -1000, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: -100, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: -99, alphaValue: 0.15),
            TransferFunction.AlphaPoint(dataValue: -60, alphaValue: 0.15),
            TransferFunction.AlphaPoint(dataValue: -59, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: 101.2, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: 952, alphaValue: 0.0)
        ]

        return transfer
    }

    static func makeMrAngioTransferFunction() -> TransferFunction? {
        var transfer = TransferFunction()
        transfer.name = "mr_angio"
        transfer.minimumValue = -2048
        transfer.maximumValue = 3661
        transfer.shift = 0
        transfer.colorSpace = .sRGB

        transfer.colourPoints = [
            TransferFunction.ColorPoint(dataValue: -2048, colourValue: TransferFunction.RGBAColor(r: 0.0, g: 0.0, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 151.354, colourValue: TransferFunction.RGBAColor(r: 0.0, g: 0.0, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 158.279, colourValue: TransferFunction.RGBAColor(r: 0.74902, g: 0.376471, b: 0.0, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 190.112, colourValue: TransferFunction.RGBAColor(r: 1.0, g: 0.866667, b: 0.733333, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 200.873, colourValue: TransferFunction.RGBAColor(r: 0.937255, g: 0.937255, b: 0.937255, a: 1.0)),
            TransferFunction.ColorPoint(dataValue: 3661, colourValue: TransferFunction.RGBAColor(r: 1.0, g: 1.0, b: 1.0, a: 1.0))
        ]

        transfer.alphaPoints = [
            TransferFunction.AlphaPoint(dataValue: -2048, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: 151.354, alphaValue: 0.0),
            TransferFunction.AlphaPoint(dataValue: 158.279, alphaValue: 0.4375),
            TransferFunction.AlphaPoint(dataValue: 190.112, alphaValue: 0.580357),
            TransferFunction.AlphaPoint(dataValue: 200.873, alphaValue: 0.732143),
            TransferFunction.AlphaPoint(dataValue: 3661, alphaValue: 0.741071)
        ]

        return transfer
    }

    static func baseTransferFunction(named name: String,
                                     colorSpace: TransferFunction.ColorSpace) -> TransferFunction {
        var transfer = TransferFunction()
        transfer.name = name
        transfer.minimumValue = minimumValue
        transfer.maximumValue = maximumValue
        transfer.shift = 0
        transfer.colorSpace = colorSpace
        return transfer
    }

    static func colourPoints(from red: [UInt8],
                              green: [UInt8],
                              blue: [UInt8]) -> [TransferFunction.ColorPoint] {
        let total = red.count
        let span = maximumValue - minimumValue
        return (0..<total).map { index in
            let fraction = total > 1 ? Float(index) / Float(total - 1) : 0
            let value = minimumValue + span * fraction
            let colour = TransferFunction.RGBAColor(
                r: Float(red[index]) / 255.0,
                g: Float(green[index]) / 255.0,
                b: Float(blue[index]) / 255.0,
                a: 1.0
            )
            return TransferFunction.ColorPoint(dataValue: value, colourValue: colour)
        }
    }

    static func alphaPoints(strategy: AlphaStrategy) -> [TransferFunction.AlphaPoint] {
        switch strategy {
        case .logarithmicInverse:
            return logarithmicInverseAlphaPoints()
        }
    }

    static func logarithmicInverseAlphaPoints() -> [TransferFunction.AlphaPoint] {
        let span = maximumValue - minimumValue
        return (0...255).map { rawIndex in
            let fraction = Float(rawIndex) / 255.0
            let value = minimumValue + span * fraction
            let complement = Float(255 - rawIndex) / 255.0
            let alpha = max(0, min(1, 1 - log10(1 + complement * 9)))
            return TransferFunction.AlphaPoint(dataValue: value, alphaValue: alpha)
        }
    }

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
            let finalColour = SIMD4<Float>(colour.r, colour.g, colour.b, clamp(alpha, lower: 0, upper: 1))

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

    static func clamp(_ value: Float, lower: Float, upper: Float) -> Float {
        max(lower, min(value, upper))
    }

    static let lungBaseColour = (red: Float(0.0), green: Float(0.6053711772), blue: Float(0.7057755589))

    static let airwaysCurvePoints: [Float] = [
        -643.78107,
        -584.6589,
        -382.65924,
        -235.15527
    ]

    static let vrmusclesbonesRed: [UInt8] = [
        0, 2, 5, 8, 10, 13, 16, 18, 21, 24, 26, 29, 32, 34, 37, 40,
        42, 45, 48, 51, 53, 56, 59, 61, 64, 67, 69, 72, 75, 77, 80, 83,
        85, 88, 91, 93, 96, 99, 102, 104, 107, 110, 112, 115, 118, 120, 123, 126,
        128, 131, 134, 136, 139, 142, 144, 147, 150, 153, 155, 158, 161, 163, 166, 169,
        171, 174, 177, 179, 182, 185, 187, 190, 193, 195, 198, 201, 204, 206, 209, 212,
        214, 217, 220, 222, 225, 228, 230, 233, 236, 238, 241, 244, 246, 249, 252, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255
    ]

    static let vrmusclesbonesGreen: [UInt8] = [
        0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3,
        3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 6, 7,
        7, 7, 7, 8, 8, 8, 8, 9, 9, 9, 9, 9, 10, 10, 10, 10,
        11, 11, 11, 11, 12, 12, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14,
        14, 15, 15, 15, 15, 15, 16, 16, 16, 16, 17, 17, 17, 17, 18, 18,
        18, 18, 18, 19, 19, 19, 19, 20, 20, 20, 20, 21, 21, 21, 21, 21,
        24, 27, 30, 33, 36, 39, 42, 45, 48, 51, 54, 57, 60, 63, 66, 69,
        72, 75, 78, 81, 84, 87, 90, 93, 96, 99, 102, 105, 108, 111, 114, 117,
        120, 123, 126, 129, 131, 134, 137, 140, 143, 146, 149, 152, 155, 158, 161, 164,
        167, 170, 173, 176, 177, 179, 180, 181, 182, 183, 185, 186, 187, 188, 189, 191,
        192, 193, 194, 195, 197, 198, 199, 200, 201, 203, 204, 205, 206, 207, 209, 210,
        211, 212, 213, 215, 216, 217, 218, 220, 221, 222, 223, 224, 226, 227, 228, 229,
        230, 232, 233, 234, 235, 236, 238, 239, 240, 241, 241, 242, 242, 242, 242, 243,
        243, 243, 243, 244, 244, 244, 244, 245, 245, 245, 245, 246, 246, 246, 246, 247,
        247, 247, 247, 248, 248, 248, 248, 248, 249, 249, 249, 249, 250, 250, 250, 250,
        251, 251, 251, 251, 252, 252, 252, 252, 253, 253, 253, 253, 254, 254, 254, 254
    ]

    static let vrmusclesbonesBlue: [UInt8] = [
        0, 0, 0, 0, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 4, 4,
        4, 5, 5, 5, 5, 6, 6, 6, 7, 7, 7, 7, 8, 8, 8, 9,
        9, 9, 10, 10, 10, 10, 11, 11, 11, 12, 12, 12, 12, 13, 13, 13,
        14, 14, 14, 15, 15, 15, 15, 16, 16, 16, 17, 17, 17, 17, 18, 18,
        18, 19, 19, 19, 20, 20, 20, 20, 21, 21, 21, 22, 22, 22, 22, 23,
        23, 23, 24, 24, 24, 25, 25, 25, 25, 26, 26, 26, 27, 27, 27, 27,
        27, 27, 26, 26, 26, 25, 25, 25, 24, 24, 24, 23, 23, 22, 22, 22,
        21, 21, 21, 20, 20, 20, 19, 19, 19, 18, 18, 18, 17, 17, 16, 16,
        16, 15, 15, 15, 14, 14, 14, 13, 13, 13, 12, 12, 11, 11, 11, 10,
        10, 10, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 15, 15, 16,
        16, 17, 17, 18, 18, 19, 19, 20, 21, 21, 22, 22, 23, 23, 24, 24,
        25, 26, 26, 27, 27, 28, 28, 29, 29, 30, 31, 31, 32, 32, 33, 33,
        34, 34, 35, 36, 36, 37, 37, 38, 38, 39, 43, 47, 51, 55, 58, 62,
        66, 70, 74, 78, 82, 86, 90, 94, 98, 102, 105, 109, 113, 117, 121, 125,
        129, 133, 137, 141, 145, 149, 153, 156, 160, 164, 168, 172, 176, 180, 184, 188,
        192, 196, 200, 204, 207, 211, 215, 219, 223, 227, 231, 235, 239, 243, 247, 251
    ]

    static let vrredvesselsRed: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ]

    static let vrredvesselsGreen: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ]

    static let vrredvesselsBlue: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ]
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
