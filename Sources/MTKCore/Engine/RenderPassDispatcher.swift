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
        let labelmapOverlays: [MPRLabelmapOverlay]
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let volumeAdapter: MetalVolumeRenderingAdapter
    private let mprAdapter: MetalMPRAdapter
    private let surfaceMeshRendererProvider: SurfaceMeshRendererProvider
    private let volumeLayerCompositePassProvider: VolumeLayerCompositePassProvider
    private let resourceManager: VolumeResourceManager
    private let mprFrameCache: MPRFrameCache<ViewportID>
    private let volumeLayerResourceCache = VolumeLayerResourceCache()
    private let profiler: RenderProfiler

    init(device: any MTLDevice,
         commandQueue: any MTLCommandQueue,
         volumeAdapter: MetalVolumeRenderingAdapter,
         mprAdapter: MetalMPRAdapter,
         resourceManager: VolumeResourceManager,
         mprFrameCache: MPRFrameCache<ViewportID>,
         profiler: RenderProfiler) {
        self.device = device
        self.commandQueue = commandQueue
        self.volumeAdapter = volumeAdapter
        self.mprAdapter = mprAdapter
        self.surfaceMeshRendererProvider = SurfaceMeshRendererProvider(device: device,
                                                                       commandQueue: commandQueue)
        self.volumeLayerCompositePassProvider = VolumeLayerCompositePassProvider(device: device)
        self.resourceManager = resourceManager
        self.mprFrameCache = mprFrameCache
        self.profiler = profiler
    }

    func renderVolume(state: MTKRenderingEngine.ViewportState,
                      dataset: VolumeDataset,
                      volumeTexture: any MTLTexture,
                      surfaceMeshLayers: [SurfaceMeshLayer],
                      compositing: VolumeRenderRequest.Compositing,
                      debugPostAcquireRenderFailure: MetalVolumeRenderingAdapter.RenderingError?) async throws -> VolumeRenderFrameResult {
        let viewport = VolumetricMath.clampViewportSize(state.currentSize)
        let viewportSize = CGSize(width: viewport.width, height: viewport.height)
        let renderLayers = try makeRaycastLayers(state: state,
                                                 baseDataset: dataset,
                                                 baseVolumeTexture: volumeTexture)

        let outputTextureLease = try resourceManager.acquireOutputTextureWithLease(
            width: viewport.width,
            height: viewport.height,
            pixelFormat: .bgra8Unorm
        )
        var acquiredLeases: [OutputTextureLease] = [outputTextureLease]

        do {
            if let debugPostAcquireRenderFailure {
                throw debugPostAcquireRenderFailure
            }

            var currentLease = outputTextureLease
            _ = try await renderLayer(
                renderLayers[0],
                viewportSize: viewportSize,
                camera: state.camera,
                samplingDistance: state.samplingDistance,
                compositing: compositing,
                quality: state.quality,
                clipping: state.clipping,
                outputTexture: currentLease.texture
            )

            if renderLayers.count > 1 {
                let compositePass = try volumeLayerCompositePassProvider.pass()
                for layer in renderLayers.dropFirst() {
                    let layerLease = try resourceManager.acquireOutputTextureWithLease(
                        width: viewport.width,
                        height: viewport.height,
                        pixelFormat: .bgra8Unorm
                    )
                    acquiredLeases.append(layerLease)
                    _ = try await renderLayer(
                        layer,
                        viewportSize: viewportSize,
                        camera: state.camera,
                        samplingDistance: state.samplingDistance,
                        compositing: compositing,
                        quality: state.quality,
                        clipping: state.clipping,
                        outputTexture: layerLease.texture
                    )

                    let destinationLease = try resourceManager.acquireOutputTextureWithLease(
                        width: viewport.width,
                        height: viewport.height,
                        pixelFormat: .bgra8Unorm
                    )
                    acquiredLeases.append(destinationLease)
                    try await compositePass.composite(
                        baseTexture: currentLease.texture,
                        overlayTexture: layerLease.texture,
                        destinationTexture: destinationLease.texture,
                        overlayOpacity: layer.opacity,
                        blendMode: layer.blendMode,
                        commandQueue: commandQueue
                    )
                    currentLease = destinationLease
                }
                recordLayerFusionSample(layerCount: renderLayers.count,
                                        renderLayers: renderLayers,
                                        viewport: viewport,
                                        quality: state.quality,
                                        compositing: compositing)
            }

            if !surfaceMeshLayers.isEmpty {
                let surfaceMeshRenderer = try surfaceMeshRendererProvider.renderer()
                try await surfaceMeshRenderer.render(layers: surfaceMeshLayers,
                                                     dataset: dataset,
                                                     camera: state.camera,
                                                     targetTexture: currentLease.texture,
                                                     clipping: state.clipping)
            }
            release(acquiredLeases, except: currentLease)
            return VolumeRenderFrameResult(texture: currentLease.texture, lease: currentLease)
        } catch {
            release(acquiredLeases, except: nil)
            throw error
        }
    }

    private struct RaycastLayer {
        var id: String
        var dataset: VolumeDataset
        var volumeTexture: any MTLTexture
        var transferFunction: VolumeTransferFunction
        var opacity: Float
        var blendMode: VolumeLayerBlendMode

        var requestLayer: VolumeLayer {
            VolumeLayer(id: id,
                        dataset: dataset,
                        transferFunction: transferFunction,
                        opacity: opacity,
                        blendMode: blendMode)
        }
    }

    private func makeRaycastLayers(state: MTKRenderingEngine.ViewportState,
                                   baseDataset: VolumeDataset,
                                   baseVolumeTexture: any MTLTexture) throws -> [RaycastLayer] {
        var layers = [
            RaycastLayer(id: VolumeRenderRequest.primaryVolumeLayerID,
                         dataset: baseDataset,
                         volumeTexture: baseVolumeTexture,
                         transferFunction: state.transferFunction ?? VolumeTransferFunction.defaultGrayscale(for: baseDataset),
                         opacity: 1,
                         blendMode: .sourceOver)
        ]

        for layer in state.volumeLayers {
            guard layer.isVisible,
                  layer.clampedOpacity > 0,
                  let scalarVolume = layer.scalarVolume else {
                continue
            }
            guard let handle = state.volumeLayerResourceHandles[layer.id],
                  let layerTexture = resourceManager.texture(for: handle) else {
                throw MTKRenderingEngine.EngineError.volumeResourceUnavailable
            }
            layers.append(
                RaycastLayer(id: layer.id,
                             dataset: resourceManager.dataset(for: handle) ?? scalarVolume.dataset,
                             volumeTexture: layerTexture,
                             transferFunction: scalarVolume.transferFunction,
                             opacity: layer.clampedOpacity,
                             blendMode: layer.blendMode)
            )
        }
        return layers
    }

    private func renderLayer(_ layer: RaycastLayer,
                             viewportSize: CGSize,
                             camera: Camera,
                             samplingDistance: Float,
                             compositing: VolumeRenderRequest.Compositing,
                             quality: VolumeRenderRequest.Quality,
                             clipping: VolumeClippingState,
                             outputTexture: any MTLTexture) async throws -> VolumeRenderFrame {
        let window = layer.dataset.recommendedWindow ?? layer.dataset.intensityRange
        try await volumeAdapter.send(.setWindow(min: window.lowerBound, max: window.upperBound))

        let request = VolumeRenderRequest(
            dataset: layer.dataset,
            transferFunction: layer.transferFunction,
            viewportSize: viewportSize,
            camera: camera,
            samplingDistance: samplingDistance,
            compositing: compositing,
            quality: quality,
            clipping: clipping,
            layers: [layer.requestLayer]
        )
        return try await volumeAdapter.renderTexture(
            using: request,
            volumeTexture: layer.volumeTexture,
            outputTexture: outputTexture
        )
    }

    private func release(_ leases: [OutputTextureLease],
                         except retainedLease: OutputTextureLease?) {
        let retainedIdentifier = retainedLease.map { ObjectIdentifier($0 as AnyObject) }
        for lease in leases where ObjectIdentifier(lease as AnyObject) != retainedIdentifier {
            lease.release()
        }
    }

    private func recordLayerFusionSample(layerCount: Int,
                                         renderLayers: [RaycastLayer],
                                         viewport: (width: Int, height: Int),
                                         quality: VolumeRenderRequest.Quality,
                                         compositing: VolumeRenderRequest.Compositing) {
        let metrics = resourceManager.resourceMetrics()
        ClinicalProfiler.shared.recordSample(
            stage: .volumeRaycast,
            cpuTime: 0,
            memory: metrics.estimatedMemoryBytes,
            viewport: ProfilingViewportContext(
                width: viewport.width,
                height: viewport.height,
                viewportType: "volume3D",
                quality: quality,
                renderMode: compositing
            ),
            metadata: [
                "path": "RenderPassDispatcher.renderVolume.multiLayer",
                "layerCount": String(layerCount),
                "layerIDs": renderLayers.map(\.id).joined(separator: ","),
                "blendModes": renderLayers.map { $0.blendMode.profilingName }.joined(separator: ","),
                "volumeTextureCount": String(metrics.volumeTextureCount),
                "estimatedMemoryBytes": String(metrics.estimatedMemoryBytes)
            ],
            device: device
        )
    }

    func renderMPR(viewport: ViewportID,
                   state: MTKRenderingEngine.ViewportState,
                   axis: Axis,
                   dataset: VolumeDataset,
                   volumeTexture: any MTLTexture,
                   route: RenderRoute,
                   profilingOptions: ProfilingOptions) async throws -> MPRFrameResult {
        let basePlane = state.mprPlaneGeometry
            ?? MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                 axis: axis.mprPlaneAxis,
                                                 slicePosition: state.slicePosition)
        let plane = basePlane
            .sizedForOutput(state.currentSize)
        let signature = MPRFrameSignature(
            planeGeometry: plane,
            slabThickness: state.slabThickness,
            slabSteps: state.slabSteps,
            blend: state.mprBlend
        )

        if let cached = await mprFrameCache.cachedFrame(for: viewport, matching: signature) {
            let overlays = try await volumeLayerResourceCache.makeMPRLabelmapOverlays(
                for: state.volumeLayers,
                baseFrame: cached,
                device: device,
                commandQueue: commandQueue
            )
            return MPRFrameResult(frame: cached,
                                  labelmapOverlays: overlays)
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
        let overlays = try await volumeLayerResourceCache.makeMPRLabelmapOverlays(
            for: state.volumeLayers,
            baseFrame: frame,
            device: device,
            commandQueue: commandQueue
        )
        return MPRFrameResult(frame: frame,
                              labelmapOverlays: overlays)
    }
}

private final class SurfaceMeshRendererProvider {
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private var cachedRenderer: MetalSurfaceMeshRenderer?

    init(device: any MTLDevice,
         commandQueue: any MTLCommandQueue) {
        self.device = device
        self.commandQueue = commandQueue
    }

    func renderer() throws -> MetalSurfaceMeshRenderer {
        if let cachedRenderer {
            return cachedRenderer
        }
        let renderer = try MetalSurfaceMeshRenderer(device: device,
                                                    commandQueue: commandQueue)
        cachedRenderer = renderer
        return renderer
    }
}

private final class VolumeLayerCompositePassProvider {
    private let device: any MTLDevice
    private var cachedPass: VolumeLayerCompositePass?

    init(device: any MTLDevice) {
        self.device = device
    }

    func pass() throws -> VolumeLayerCompositePass {
        if let cachedPass {
            return cachedPass
        }
        let pass = try VolumeLayerCompositePass(device: device)
        cachedPass = pass
        return pass
    }
}

private extension VolumeLayerBlendMode {
    var profilingName: String {
        switch self {
        case .sourceOver:
            return "sourceOver"
        case .additive:
            return "additive"
        }
    }
}
