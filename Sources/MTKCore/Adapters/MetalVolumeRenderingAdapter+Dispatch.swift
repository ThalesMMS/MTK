//
//  MetalVolumeRenderingAdapter+Dispatch.swift
//  MTK
//
//  Dispatch and output helpers for the Metal volume rendering adapter.
//
//  Thales Matheus Mendonça Santos — April 2026

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@preconcurrency import Metal
import simd

extension MetalVolumeRenderingAdapter {
    func resolveWindow(for dataset: VolumeDataset) throws -> ClosedRange<Int32> {
        if let window = extendedState.huWindow ?? overrides.window ?? dataset.recommendedWindow {
            return window
        }
        throw AdapterError.windowNotSpecified
    }

    func renderWithMetal(state: MetalState,
                         request: VolumeRenderRequest) async throws -> VolumeRenderResult {
        let viewport = VolumetricMath.clampViewportSize(request.viewportSize)
        guard viewport.width > 0, viewport.height > 0 else {
            throw RenderingError.outputTextureUnavailable
        }

        let datasetTexture = try prepareDatasetTexture(for: request.dataset, state: state)
        let transferTexture = try await prepareTransferTexture(for: request.transferFunction,
                                                               dataset: request.dataset,
                                                               state: state)

        var parameters = try buildRenderingParameters(for: request)
        var optionValue = computeOptionFlags()
        var targetViewSize = UInt16(clamping: max(viewport.width, viewport.height))
        var quaternion = SIMD4<Float>(0, 0, 0, 1)

        state.argumentManager.encodeTexture(datasetTexture, argumentIndex: .mainTexture)
        state.argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh1)
        state.argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh2)
        state.argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh3)
        state.argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh4)
        state.argumentManager.encodeSampler(filter: .linear)
        state.argumentManager.encode(&parameters, argumentIndex: .renderParams)
        state.argumentManager.encode(&optionValue, argumentIndex: .optionValue)
        state.argumentManager.encode(&quaternion, argumentIndex: .quaternion)
        state.argumentManager.encode(&targetViewSize, argumentIndex: .targetViewSize)
        state.argumentManager.encode(nil, argumentIndex: .toneBufferCh1)
        state.argumentManager.encode(nil, argumentIndex: .toneBufferCh2)
        state.argumentManager.encode(nil, argumentIndex: .toneBufferCh3)
        state.argumentManager.encode(nil, argumentIndex: .toneBufferCh4)

        let camera = try makeCameraUniforms(for: request,
                                            viewportSize: viewport,
                                            frameIndex: state.frameIndex)
        encodeCamera(camera, into: state)

        let outputTexture = try await dispatchCompute(state: state,
                                                      viewportSize: viewport)
        let image = try makeImage(from: outputTexture,
                                  width: viewport.width,
                                  height: viewport.height)
        state.frameIndex &+= 1

        let metadata = VolumeRenderResult.Metadata(
            viewportSize: CGSize(width: CGFloat(viewport.width),
                                 height: CGFloat(viewport.height)),
            samplingDistance: request.samplingDistance,
            compositing: request.compositing,
            quality: request.quality
        )
        return VolumeRenderResult(cgImage: image,
                                  metalTexture: outputTexture,
                                  metadata: metadata)
    }

    func dispatchCompute(state: MetalState,
                         viewportSize: (width: Int, height: Int)) async throws -> any MTLTexture {
        let outputTextureFits = state.argumentManager.outputTexture.map {
            $0.width == viewportSize.width && $0.height == viewportSize.height
        } ?? false

        if !outputTextureFits {
            state.argumentManager.encodeOutputTexture(width: viewportSize.width,
                                                      height: viewportSize.height)
        }

        guard let texture = state.argumentManager.outputTexture else {
            throw RenderingError.outputTextureUnavailable
        }

        guard let commandBuffer = state.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderingError.commandEncodingFailed
        }

        encoder.label = "VolumeCompute.CommandEncoder"
        encoder.setComputePipelineState(state.pipeline)
        encoder.setBuffer(state.argumentManager.argumentBuffer, offset: 0, index: 0)
        encoder.setBuffer(state.cameraBuffer, offset: 0, index: 1)

        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (viewportSize.width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
                             height: (viewportSize.height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
                             depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()

        return try await complete(commandBuffer: commandBuffer, texture: texture)
    }

    func complete(commandBuffer: any MTLCommandBuffer,
                  texture: any MTLTexture) async throws -> any MTLTexture {
        try await withCheckedThrowingContinuation { continuation in
            commandBuffer.addCompletedHandler { buffer in
                if let error = buffer.error {
                    let description = "\(String(describing: buffer.status)): \(error.localizedDescription)"
                    continuation.resume(throwing: RenderingError.commandBufferExecutionFailed(
                        underlyingDescription: description
                    ))
                } else if buffer.status == .error {
                    continuation.resume(throwing: RenderingError.commandBufferExecutionFailed(
                        underlyingDescription: "Metal command buffer finished with error status but no error object."
                    ))
                } else {
                    continuation.resume(returning: texture)
                }
            }
            commandBuffer.commit()
        }
    }

    func makeImage(from texture: any MTLTexture,
                   width: Int,
                   height: Int) throws -> CGImage? {
#if canImport(CoreGraphics)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { pointer in
            let region = MTLRegionMake2D(0, 0, width, height)
            texture.getBytes(pointer.baseAddress!,
                             bytesPerRow: bytesPerRow,
                             from: region,
                             mipmapLevel: 0)
        }

        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow,
                       space: colorSpace,
                       bitmapInfo: bitmapInfo,
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
#else
        return nil
#endif
    }
}