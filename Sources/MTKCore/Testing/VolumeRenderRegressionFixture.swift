import CoreGraphics
import Foundation
@preconcurrency import Metal
import simd

@_spi(Testing)
public enum VolumeRenderRegressionFixture {
    public struct PixelSummary: Sendable, Equatable {
        public let maxBlue: UInt8
        public let maxGreen: UInt8
        public let maxRed: UInt8
        public let maxAlpha: UInt8
    }

    public static let viewportSize = CGSize(width: 64, height: 64)
    public static let samplingDistance: Float = 1.0 / 64.0

    public static func dataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 8, height: 8, depth: 8)
        var voxels = [Int16]()
        voxels.reserveCapacity(dimensions.voxelCount)

        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    voxels.append(Int16(-1_000 + (x * 80) + (y * 60) + (z * 100)))
                }
            }
        }

        return VolumeDataset(
            data: voxels.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: -1_000...680,
            recommendedWindow: -1_000...680
        )
    }

    public static func camera() -> VolumeRenderRequest.Camera {
        VolumeRenderRequest.Camera(
            position: SIMD3<Float>(0.5, 0.5, 2.5),
            target: SIMD3<Float>(repeating: 0.5),
            up: SIMD3<Float>(0, 1, 0),
            fieldOfView: 45
        )
    }

    public static func volumeTransferFunction(for dataset: VolumeDataset) -> VolumeTransferFunction {
        let lower = Float(dataset.intensityRange.lowerBound)
        let upper = Float(dataset.intensityRange.upperBound)
        let midpoint = (lower + upper) * 0.5

        return VolumeTransferFunction(
            opacityPoints: [
                .init(intensity: lower, opacity: 0),
                .init(intensity: midpoint, opacity: 1),
                .init(intensity: upper, opacity: 0)
            ],
            colourPoints: [
                .init(intensity: lower, colour: SIMD4<Float>(1, 1, 1, 1)),
                .init(intensity: upper, colour: SIMD4<Float>(1, 1, 1, 1))
            ]
        )
    }

    public static func transferFunction(for dataset: VolumeDataset) -> TransferFunction {
        let lower = Float(dataset.intensityRange.lowerBound)
        let upper = Float(dataset.intensityRange.upperBound)
        let midpoint = (lower + upper) * 0.5

        var transfer = TransferFunction()
        transfer.name = "VolumeRenderRegressionFixture"
        transfer.minimumValue = lower
        transfer.maximumValue = upper
        transfer.colorSpace = .linear
        transfer.colourPoints = [
            .init(dataValue: lower, colourValue: .init(r: 1, g: 1, b: 1, a: 1)),
            .init(dataValue: upper, colourValue: .init(r: 1, g: 1, b: 1, a: 1))
        ]
        transfer.alphaPoints = [
            .init(dataValue: lower, alphaValue: 0),
            .init(dataValue: midpoint, alphaValue: 1),
            .init(dataValue: upper, alphaValue: 0)
        ]
        return transfer
    }

    @MainActor
    public static func transferTexture(for dataset: VolumeDataset,
                                       device: any MTLDevice) -> (any MTLTexture)? {
        TransferFunctions.texture(for: transferFunction(for: dataset), device: device)
    }

    public static func request(compositing: VolumeRenderRequest.Compositing = .frontToBack,
                               quality: VolumeRenderRequest.Quality = .interactive) -> VolumeRenderRequest {
        let dataset = dataset()
        return VolumeRenderRequest(
            dataset: dataset,
            transferFunction: volumeTransferFunction(for: dataset),
            viewportSize: viewportSize,
            camera: camera(),
            samplingDistance: samplingDistance,
            compositing: compositing,
            quality: quality
        )
    }

    public static func imagePixelSummary(_ image: CGImage) -> PixelSummary? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        guard let context = CGContext(data: &pixels,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo.rawValue) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var maxBlue: UInt8 = 0
        var maxGreen: UInt8 = 0
        var maxRed: UInt8 = 0
        var maxAlpha: UInt8 = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            maxBlue = max(maxBlue, pixels[index])
            maxGreen = max(maxGreen, pixels[index + 1])
            maxRed = max(maxRed, pixels[index + 2])
            maxAlpha = max(maxAlpha, pixels[index + 3])
        }
        return PixelSummary(maxBlue: maxBlue,
                            maxGreen: maxGreen,
                            maxRed: maxRed,
                            maxAlpha: maxAlpha)
    }

    public static func imageContainsVisiblePixels(_ image: CGImage) -> Bool {
        guard let summary = imagePixelSummary(image) else {
            return false
        }
        return summary.maxBlue > 0 || summary.maxGreen > 0 || summary.maxRed > 0
    }

    public static func texturePixelSummary(_ texture: any MTLTexture) throws -> PixelSummary? {
        try validateTextureForPixelSummary(texture)
        let readableTexture = try makeCPUReadableTexture(from: texture)
        let width = readableTexture.width
        let height = readableTexture.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        try pixels.withUnsafeMutableBytes { pointer in
            guard let baseAddress = pointer.baseAddress else {
                throw SnapshotExportError.readbackFailed(
                    "VolumeRenderRegressionFixture.texturePixelSummary could not access the pixel buffer base address."
                )
            }
            readableTexture.getBytes(baseAddress,
                                     bytesPerRow: bytesPerRow,
                                     from: MTLRegionMake2D(0, 0, width, height),
                                     mipmapLevel: 0)
        }

        var maxBlue: UInt8 = 0
        var maxGreen: UInt8 = 0
        var maxRed: UInt8 = 0
        var maxAlpha: UInt8 = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            maxBlue = max(maxBlue, pixels[index])
            maxGreen = max(maxGreen, pixels[index + 1])
            maxRed = max(maxRed, pixels[index + 2])
            maxAlpha = max(maxAlpha, pixels[index + 3])
        }
        return PixelSummary(maxBlue: maxBlue,
                            maxGreen: maxGreen,
                            maxRed: maxRed,
                            maxAlpha: maxAlpha)
    }

    public static func textureContainsVisiblePixels(_ texture: any MTLTexture) throws -> Bool {
        guard let summary = try texturePixelSummary(texture) else {
            return false
        }
        return summary.maxBlue > 0 || summary.maxGreen > 0 || summary.maxRed > 0
    }
}

private extension VolumeRenderRegressionFixture {
    static func validateTextureForPixelSummary(_ texture: any MTLTexture) throws {
        guard texture.textureType == .type2D else {
            throw SnapshotExportError.readbackFailed(
                "VolumeRenderRegressionFixture.texturePixelSummary only supports type2D BGRA textures; got textureType \(texture.textureType)."
            )
        }

        switch texture.pixelFormat {
        case .bgra8Unorm, .bgra8Unorm_srgb:
            break
        default:
            throw SnapshotExportError.readbackFailed(
                "VolumeRenderRegressionFixture.texturePixelSummary only supports bgra8Unorm and bgra8Unorm_srgb textures; got \(texture.pixelFormat)."
            )
        }
    }

    static func makeCPUReadableTexture(from texture: any MTLTexture) throws -> any MTLTexture {
        try TextureReadbackHelper.makeCPUReadableTexture(from: texture,
                                                        stagingLabel: "VolumeRenderRegressionFixture.ReadbackStaging")
    }
}
