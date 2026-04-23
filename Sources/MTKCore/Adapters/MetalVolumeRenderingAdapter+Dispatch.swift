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
                         request: VolumeRenderRequest,
                         datasetTexture providedDatasetTexture: (any MTLTexture)? = nil,
                         outputTexture providedOutputTexture: (any MTLTexture)? = nil) async throws -> VolumeRenderFrame {
        let viewport = VolumetricMath.clampViewportSize(request.viewportSize)
        guard viewport.width > 0, viewport.height > 0 else {
            throw RenderingError.outputTextureUnavailable
        }

        let datasetTexture: any MTLTexture
        let preparationStartedAt = CFAbsoluteTimeGetCurrent()
        if let providedDatasetTexture {
            datasetTexture = prepareDatasetTexture(for: request.dataset,
                                                   texture: providedDatasetTexture,
                                                   state: state)
        } else {
            datasetTexture = try prepareDatasetTexture(for: request.dataset, state: state)
        }
        let transferTexture = try await prepareTransferTexture(for: request.transferFunction,
                                                               dataset: request.dataset,
                                                               state: state)
        let preparationMilliseconds = ClinicalProfiler.milliseconds(from: preparationStartedAt)

        let parameters = try buildRenderingParameters(for: request)
        let optionValue = computeOptionFlags()
        let targetViewSize = UInt16(clamping: max(viewport.width, viewport.height))
        let quaternion = SIMD4<Float>(0, 0, 0, 1)

        let camera = try makeCameraUniforms(for: request,
                                            viewportSize: viewport,
                                            frameIndex: state.frameIndex)
        let passRenderingParameters = VolumeRaycastPassRenderingParameters(
            quality: request.quality,
            samplingDistance: request.samplingDistance,
            compositingMode: request.compositing
        )
        let passInput = VolumeRaycastPassInput(
            volumeTexture: datasetTexture,
            transferFunctionTexture: transferTexture,
            cameraUniforms: camera,
            renderingParameters: passRenderingParameters,
            shaderParameters: parameters,
            viewportSize: CGSize(width: CGFloat(viewport.width), height: CGFloat(viewport.height)),
            optionValue: optionValue,
            targetViewSize: targetViewSize,
            quaternion: quaternion,
            outputTexture: try providedOutputTexture ?? makeStandaloneOutputTexture(width: viewport.width,
                                                                                   height: viewport.height,
                                                                                   device: state.device)
        )
        let passOutput = try await state.raycastPass.execute(input: passInput,
                                                             commandQueue: state.commandQueue)
        let outputTexture = passOutput.outputTexture
        state.frameIndex &+= 1

        ClinicalProfiler.shared.recordSample(
            stage: .texturePreparation,
            cpuTime: preparationMilliseconds,
            memory: ResourceMemoryEstimator.estimate(for: datasetTexture) + ResourceMemoryEstimator.estimate(for: transferTexture),
            viewport: ProfilingViewportContext(
                width: viewport.width,
                height: viewport.height,
                viewportType: "volume3D",
                quality: request.quality,
                renderMode: request.compositing
            ),
            metadata: [
                "datasetTexture": datasetTexture.label ?? "",
                "transferTexture": transferTexture.label ?? ""
            ],
            device: state.device
        )

        let metadata = VolumeRenderFrame.Metadata(
            viewportSize: CGSize(width: CGFloat(viewport.width),
                                 height: CGFloat(viewport.height)),
            samplingDistance: request.samplingDistance,
            compositing: request.compositing,
            quality: request.quality,
            pixelFormat: outputTexture.pixelFormat
        )
        return VolumeRenderFrame(texture: outputTexture,
                                 metadata: metadata)
    }

    func makeStandaloneOutputTexture(width: Int,
                                     height: Int,
                                     device: any MTLDevice) throws -> any MTLTexture {
        guard width > 0, height > 0 else {
            throw RenderingError.outputTextureUnavailable
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead, .pixelFormatView]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderingError.outputTextureUnavailable
        }
        texture.label = "VolumeCompute.Output"
        return texture
    }

    func renderTexture(using request: VolumeRenderRequest,
                       volumeTexture: any MTLTexture,
                       outputTexture: (any MTLTexture)? = nil) async throws -> VolumeRenderFrame {
        if diagnosticLoggingEnabled {
            logger.info("[DIAG] renderTexture called - viewport: \(request.viewportSize.width)x\(request.viewportSize.height), compositing: \(String(describing: request.compositing)), quality: \(String(describing: request.quality))")
        }

        var effectiveRequest = request

        if let compositing = overrides.compositing {
            effectiveRequest.compositing = compositing
        }
        if let samplingDistance = overrides.samplingDistance {
            effectiveRequest.samplingDistance = samplingDistance
        }

        let window = try resolveWindow(for: effectiveRequest.dataset)
        let frame = try await renderWithSharedVolumeTexture(using: effectiveRequest,
                                                            volumeTexture: volumeTexture,
                                                            outputTexture: outputTexture)
        lastSnapshot = RenderSnapshot(dataset: request.dataset,
                                      metadata: frame.metadata,
                                      window: window)
        return frame
    }

}
