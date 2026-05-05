//
//  VolumeLayerCompositePass.swift
//  MTK
//
//  Composites already-raycast scalar volume layers into one output texture.
//

import CoreGraphics
import Foundation
@preconcurrency import Metal

enum VolumeLayerCompositePassError: Error, Equatable, LocalizedError {
    case commandQueueDeviceMismatch
    case shaderLibraryDeviceMismatch
    case pipelineUnavailable(String)
    case pipelineCreationFailed(String)
    case textureDeviceMismatch
    case textureSizeMismatch
    case textureFormatMismatch(MTLPixelFormat)
    case commandBufferCreationFailed
    case encoderCreationFailed
    case commandBufferExecutionFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandQueueDeviceMismatch:
            return "Volume layer composite command queue belongs to a different Metal device."
        case .shaderLibraryDeviceMismatch:
            return "Volume layer composite shader library belongs to a different Metal device."
        case .pipelineUnavailable(let name):
            return "Volume layer composite pipeline \(name) is unavailable."
        case .pipelineCreationFailed(let name):
            return "Volume layer composite pipeline \(name) could not be created."
        case .textureDeviceMismatch:
            return "Volume layer composite textures must belong to the same Metal device."
        case .textureSizeMismatch:
            return "Volume layer composite textures must have matching dimensions."
        case .textureFormatMismatch(let format):
            return "Volume layer composite requires bgra8Unorm textures, got \(format)."
        case .commandBufferCreationFailed:
            return "Failed to create a command buffer for volume layer compositing."
        case .encoderCreationFailed:
            return "Failed to create a compute encoder for volume layer compositing."
        case .commandBufferExecutionFailed(let description):
            return "Volume layer composite command buffer failed: \(description)."
        }
    }
}

final class VolumeLayerCompositePass: @unchecked Sendable {
    private struct Uniforms {
        var overlayOpacity: Float
        var blendMode: UInt32
        var padding: SIMD2<UInt32> = .zero
    }

    private let device: any MTLDevice
    private let pipeline: any MTLComputePipelineState

    init(device: any MTLDevice,
         library: (any MTLLibrary)? = nil) throws {
        let resolvedLibrary = try library ?? ShaderLibraryLoader.loadLibrary(for: device)
        guard resolvedLibrary.device === device else {
            throw VolumeLayerCompositePassError.shaderLibraryDeviceMismatch
        }
        guard let function = resolvedLibrary.makeFunction(name: "volume_layer_composite") else {
            throw VolumeLayerCompositePassError.pipelineUnavailable("volume_layer_composite")
        }
        do {
            self.pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw VolumeLayerCompositePassError.pipelineCreationFailed("volume_layer_composite")
        }
        self.device = device
    }

    func composite(baseTexture: any MTLTexture,
                   overlayTexture: any MTLTexture,
                   destinationTexture: any MTLTexture,
                   overlayOpacity: Float,
                   blendMode: VolumeLayerBlendMode,
                   commandQueue: any MTLCommandQueue) async throws {
        guard commandQueue.device === device else {
            throw VolumeLayerCompositePassError.commandQueueDeviceMismatch
        }
        try validate(baseTexture: baseTexture,
                     overlayTexture: overlayTexture,
                     destinationTexture: destinationTexture)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw VolumeLayerCompositePassError.commandBufferCreationFailed
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw VolumeLayerCompositePassError.encoderCreationFailed
        }

        var uniforms = Uniforms(overlayOpacity: Self.clamp01(overlayOpacity),
                                blendMode: blendMode.shaderValue)

        commandBuffer.label = "VolumeLayerCompositePass.Composite"
        encoder.label = "VolumeLayerCompositePass.CommandEncoder"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(baseTexture, index: 0)
        encoder.setTexture(overlayTexture, index: 1)
        encoder.setTexture(destinationTexture, index: 2)
        encoder.setBytes(&uniforms,
                         length: MemoryLayout<Uniforms>.stride,
                         index: 0)

        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (destinationTexture.width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
            height: (destinationTexture.height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            commandBuffer.addCompletedHandler { buffer in
                if let error = buffer.error {
                    continuation.resume(throwing: VolumeLayerCompositePassError.commandBufferExecutionFailed(
                        error.localizedDescription
                    ))
                    return
                }
                if buffer.status == .error {
                    continuation.resume(throwing: VolumeLayerCompositePassError.commandBufferExecutionFailed(
                        "Metal command buffer finished with error status but no error object"
                    ))
                    return
                }
                continuation.resume()
            }
            commandBuffer.commit()
        }
    }

    private func validate(baseTexture: any MTLTexture,
                          overlayTexture: any MTLTexture,
                          destinationTexture: any MTLTexture) throws {
        guard baseTexture.device === device,
              overlayTexture.device === device,
              destinationTexture.device === device else {
            throw VolumeLayerCompositePassError.textureDeviceMismatch
        }
        guard baseTexture.width == overlayTexture.width,
              baseTexture.width == destinationTexture.width,
              baseTexture.height == overlayTexture.height,
              baseTexture.height == destinationTexture.height else {
            throw VolumeLayerCompositePassError.textureSizeMismatch
        }
        for texture in [baseTexture, overlayTexture, destinationTexture] where texture.pixelFormat != .bgra8Unorm {
            throw VolumeLayerCompositePassError.textureFormatMismatch(texture.pixelFormat)
        }
    }

    private static func clamp01(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

private extension VolumeLayerBlendMode {
    var shaderValue: UInt32 {
        switch self {
        case .sourceOver:
            return 0
        case .additive:
            return 1
        }
    }
}
