//
//  RenderPassDispatcher.swift
//  MTK
//
//  Focused render-pass dispatch service used by MTKRenderingEngine.render(_:)
//  for volume and MPR rendering.
//

import Foundation
@preconcurrency import Metal

/// Executes a resolved/validated render route against the concrete render backends.
///
/// Note: `MTKRenderingEngine.render(_:)` owns route resolution and frame assembly,
/// then delegates volume and MPR GPU dispatch to this service.
struct RenderPassDispatcher {
    struct VolumeRenderFrameResult {
        let texture: any MTLTexture
        let lease: OutputTextureLease
    }

    struct MPRFrameResult {
        let frame: MPRTextureFrame
    }

    private let device: any MTLDevice
    private let volumeAdapter: MetalVolumeRenderingAdapter
    private let mprAdapter: MetalMPRAdapter
    private let resourceManager: VolumeResourceManager
    private let mprFrameCache: MPRFrameCache<ViewportID>
    private let profiler: RenderProfiler

    init(device: any MTLDevice,
         volumeAdapter: MetalVolumeRenderingAdapter,
         mprAdapter: MetalMPRAdapter,
         resourceManager: VolumeResourceManager,
         mprFrameCache: MPRFrameCache<ViewportID>,
         profiler: RenderProfiler) {
        self.device = device
        self.volumeAdapter = volumeAdapter
        self.mprAdapter = mprAdapter
        self.resourceManager = resourceManager
        self.mprFrameCache = mprFrameCache
        self.profiler = profiler
    }

    func renderVolume(state: MTKRenderingEngine.ViewportState,
                      dataset: VolumeDataset,
                      volumeTexture: any MTLTexture,
                      compositing: VolumeRenderRequest.Compositing,
                      debugPostAcquireRenderFailure: MetalVolumeRenderingAdapter.RenderingError?) async throws -> VolumeRenderFrameResult {
        let window = state.window ?? dataset.recommendedWindow ?? dataset.intensityRange
        try await volumeAdapter.send(.setWindow(min: window.lowerBound, max: window.upperBound))

        let viewport = VolumetricMath.clampViewportSize(state.currentSize)
        let viewportSize = CGSize(width: viewport.width, height: viewport.height)
        let request = VolumeRenderRequest(
            dataset: dataset,
            transferFunction: state.transferFunction ?? VolumeTransferFunction.defaultGrayscale(for: dataset),
            viewportSize: viewportSize,
            camera: state.camera,
            samplingDistance: state.samplingDistance,
            compositing: compositing,
            quality: state.quality
        )

        let outputTextureLease = try resourceManager.acquireOutputTextureWithLease(
            width: viewport.width,
            height: viewport.height,
            pixelFormat: .bgra8Unorm
        )
        let outputTexture = outputTextureLease.texture

        do {
            if let debugPostAcquireRenderFailure {
                throw debugPostAcquireRenderFailure
            }

            let frame = try await volumeAdapter.renderTexture(
                using: request,
                volumeTexture: volumeTexture,
                outputTexture: outputTexture
            )
            return VolumeRenderFrameResult(texture: frame.texture, lease: outputTextureLease)
        } catch {
            resourceManager.releaseOutputTextureLease(outputTextureLease)
            throw error
        }
    }

    func renderMPR(viewport: ViewportID,
                   state: MTKRenderingEngine.ViewportState,
                   axis: Axis,
                   dataset: VolumeDataset,
                   volumeTexture: any MTLTexture,
                   route: RenderRoute,
                   profilingOptions: ProfilingOptions) async throws -> MPRFrameResult {
        let plane = MPRPlaneGeometryFactory
            .makePlane(for: dataset,
                       axis: axis.mprPlaneAxis,
                       slicePosition: state.slicePosition)
            .sizedForOutput(state.currentSize)
        let signature = MPRFrameSignature(
            planeGeometry: plane,
            slabThickness: state.slabThickness,
            slabSteps: state.slabSteps,
            blend: state.mprBlend
        )

        if let cached = await mprFrameCache.cachedFrame(for: viewport, matching: signature) {
            return MPRFrameResult(frame: cached)
        }

        let resliceStartedAt = CFAbsoluteTimeGetCurrent()
        let frame = try await mprAdapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: state.slabThickness,
            steps: state.slabSteps,
            blend: state.mprBlend
        )

        profiler.recordMPRReslice(
            startedAt: resliceStartedAt,
            frameTexture: frame.texture,
            viewportSize: state.currentSize,
            route: route,
            viewportID: viewport,
            viewportTypeName: route.viewportType.profilingName,
            qualityName: state.quality.profilingName,
            renderModeName: state.mprBlend.profilingName,
            slabThickness: state.slabThickness,
            slabSteps: state.slabSteps,
            path: "RenderPassDispatcher.renderMPR",
            options: profilingOptions,
            device: device
        )

        await mprFrameCache.store(frame, for: viewport, signature: signature)
        return MPRFrameResult(frame: frame)
    }
}
