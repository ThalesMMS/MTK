//
//  MPRImageTilingPass.swift
//  MTKCore
//
//  Asynchronous BGRA atlas composition for tiled MPR presentation.
//

import Foundation
@preconcurrency import Metal

public struct MPRImageTilingPass {
    public enum Error: Swift.Error, LocalizedError {
        case commandQueueDeviceMismatch
        case commandBufferCreationFailed
        case commandEncoderCreationFailed
        case invalidGrid
        case invalidTextureCount(expected: Int, actual: Int)
        case textureCreationFailed
        case textureDeviceMismatch
        case textureFormatMismatch
        case textureSizeMismatch(cellIndex: Int)
        case commandBufferExecutionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .commandQueueDeviceMismatch:
                return "The image-tiling command queue belongs to a different Metal device."
            case .commandBufferCreationFailed:
                return "Unable to create the image-tiling command buffer."
            case .commandEncoderCreationFailed:
                return "Unable to create an image-tiling command encoder."
            case .invalidGrid:
                return "Image-tiling dimensions must fit within the output atlas."
            case let .invalidTextureCount(expected, actual):
                return "Image tiling expected \(expected) cells but received \(actual)."
            case .textureCreationFailed:
                return "Unable to allocate the image-tiling atlas texture."
            case .textureDeviceMismatch:
                return "An image-tiling source texture belongs to a different Metal device."
            case .textureFormatMismatch:
                return "Image-tiling source textures must use BGRA8Unorm."
            case let .textureSizeMismatch(cellIndex):
                return "Image-tiling source texture does not match cell \(cellIndex)."
            case let .commandBufferExecutionFailed(reason):
                return "Image-tiling composition failed: \(reason)"
            }
        }
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue

    public init(device: any MTLDevice,
                commandQueue: any MTLCommandQueue) throws {
        guard commandQueue.device === device else {
            throw Error.commandQueueDeviceMismatch
        }
        self.device = device
        self.commandQueue = commandQueue
    }

    public static func destinationRegions(width: Int,
                                          height: Int,
                                          rows: Int,
                                          columns: Int) -> [MTLRegion] {
        guard rows > 0,
              columns > 0,
              width >= columns,
              height >= rows else {
            return []
        }

        return (0..<(rows * columns)).map { cellIndex in
            let row = cellIndex / columns
            let column = cellIndex % columns
            let minX = column * width / columns
            let maxX = (column + 1) * width / columns
            let minY = row * height / rows
            let maxY = (row + 1) * height / rows
            return MTLRegion(
                origin: MTLOrigin(x: minX, y: minY, z: 0),
                size: MTLSize(width: maxX - minX,
                              height: maxY - minY,
                              depth: 1)
            )
        }
    }

    public func makeAtlas(textures: [(any MTLTexture)?],
                          width: Int,
                          height: Int,
                          rows: Int,
                          columns: Int) async throws -> any MTLTexture {
        let regions = Self.destinationRegions(width: width,
                                              height: height,
                                              rows: rows,
                                              columns: columns)
        guard !regions.isEmpty else {
            throw Error.invalidGrid
        }
        guard textures.count == regions.count else {
            throw Error.invalidTextureCount(expected: regions.count,
                                            actual: textures.count)
        }

        for (cellIndex, pair) in zip(textures.indices, zip(textures, regions)) {
            guard let texture = pair.0 else { continue }
            let region = pair.1
            guard texture.device === device else {
                throw Error.textureDeviceMismatch
            }
            guard texture.pixelFormat == .bgra8Unorm else {
                throw Error.textureFormatMismatch
            }
            guard texture.width == region.size.width,
                  texture.height == region.size.height else {
                throw Error.textureSizeMismatch(cellIndex: cellIndex)
            }
        }

        try Task.checkCancellation()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let atlas = device.makeTexture(descriptor: descriptor) else {
            throw Error.textureCreationFailed
        }
        atlas.label = "MPRImageTilingPass.Atlas"

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw Error.commandBufferCreationFailed
        }
        commandBuffer.label = "MPRImageTilingPass.Compose"

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = atlas
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 1
        )
        guard let clearEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            throw Error.commandEncoderCreationFailed
        }
        clearEncoder.label = "MPRImageTilingPass.Clear"
        clearEncoder.endEncoding()

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw Error.commandEncoderCreationFailed
        }
        blitEncoder.label = "MPRImageTilingPass.BlitCells"
        for (texture, region) in zip(textures, regions) {
            guard let texture else { continue }
            blitEncoder.copy(
                from: texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: region.size,
                to: atlas,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: region.origin
            )
        }
        blitEncoder.endEncoding()

        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Swift.Error>) in
            commandBuffer.addCompletedHandler { completed in
                if let reason = CommandBufferCompletion.reasonItDidNotRun(completed) {
                    continuation.resume(throwing: Error.commandBufferExecutionFailed(reason))
                    return
                }
                continuation.resume()
            }
            commandBuffer.commit()
        }
        try Task.checkCancellation()
        return atlas
    }
}
