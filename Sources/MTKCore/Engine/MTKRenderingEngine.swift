//
//  MTKRenderingEngine.swift
//  MTK
//
//  Central GPU-native rendering engine for shared volume resources and viewports.
//

import CoreGraphics
import Foundation
@preconcurrency import Metal
import OSLog
import simd

public typealias Camera = VolumeRenderRequest.Camera

@available(*, deprecated, message: "ProfilingOptions is kept for compatibility. Internally, MTKRenderingEngine uses RenderProfiler.")
public struct ProfilingOptions: Equatable, Sendable {
    public var measureUploadTime: Bool
    public var measureRenderTime: Bool
    public var measurePresentTime: Bool

    public init(measureUploadTime: Bool = false,
                measureRenderTime: Bool = false,
                measurePresentTime: Bool = false) {
        self.measureUploadTime = measureUploadTime
        self.measureRenderTime = measureRenderTime
        self.measurePresentTime = measurePresentTime
    }

    func isEnabled(stage: ProfilingStage) -> Bool {
        switch stage {
        case .dicomParse, .huConversion, .textureUpload, .texturePreparation:
            return measureUploadTime
        case .renderGraphRoute, .mprReslice, .volumeRaycast, .memorySnapshot:
            return measureRenderTime
        case .presentationPass, .snapshotReadback:
            return measurePresentTime
        }
    }
}

public actor MTKRenderingEngine {
    public enum EngineError: Error, Equatable, LocalizedError {
        case metalDeviceUnavailable
        case commandQueueCreationFailed
        case viewportNotFound(ViewportID)
        case volumeNotSet(ViewportID)
        case volumeResourceUnavailable
        case renderTextureUnavailable

        public var errorDescription: String? {
            switch self {
            case .metalDeviceUnavailable:
                return "Metal device unavailable"
            case .commandQueueCreationFailed:
                return "Metal command queue creation failed"
            case .viewportNotFound:
                return "Viewport not found"
            case .volumeNotSet:
                return "Viewport has no volume"
            case .volumeResourceUnavailable:
                return "Volume resource unavailable"
            case .renderTextureUnavailable:
                return "Render texture unavailable"
            }
        }
    }

    struct ViewportState {
        var descriptor: ViewportDescriptor
        var resourceHandle: VolumeResourceHandle?
        var currentSize: CGSize
        var camera: Camera
        var window: ClosedRange<Int32>?
        var slicePosition: Float
        var samplingDistance: Float
        var quality: VolumeRenderRequest.Quality
        var transferFunction: VolumeTransferFunction?
        var slabThickness: Int
        var slabSteps: Int
        var mprBlend: MPRBlendMode

        init(descriptor: ViewportDescriptor) {
            self.descriptor = descriptor
            self.resourceHandle = nil
            self.currentSize = descriptor.initialSize
            self.camera = Camera(
                position: SIMD3<Float>(0.5, 0.5, 2.0),
                target: SIMD3<Float>(repeating: 0.5),
                up: SIMD3<Float>(0, 1, 0),
                fieldOfView: 45,
                projectionType: .perspective
            )
            self.window = nil
            self.slicePosition = 0.5
            self.samplingDistance = 1.0 / 512.0
            self.quality = .production
            self.transferFunction = nil
            self.slabThickness = 1
            self.slabSteps = 1
            self.mprBlend = .single
        }
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let resourceManager: VolumeResourceManager
    private let volumeAdapter: MetalVolumeRenderingAdapter
    private let mprAdapter: MetalMPRAdapter
    private let renderGraph = ViewportRenderGraph()
    private var viewports: [ViewportID: ViewportState] = [:]
    private let mprFrameCache: MPRFrameCache<ViewportID>
    private var pendingOutputTextureLeases: [ViewportID: [ObjectIdentifier: WeakOutputTextureLeaseBox]] = [:]
    private var profilingOptions = ProfilingOptions()
    private var lastFrameTimings: FrameMetadata?
    private var debugPostAcquireRenderFailure: MetalVolumeRenderingAdapter.RenderingError?
    private let logger = os.Logger(subsystem: "com.mtk.volumerendering",
                                   category: "MTKRenderingEngine")
    private let viewportLifecycleController = ViewportLifecycleController()
    private let routeResolver = RenderRouteResolver()
    private let profiler = RenderProfiler()
    private let metadataBuilder = FrameMetadataBuilder()
    private let renderPassDispatcher: RenderPassDispatcher

    private final class WeakOutputTextureLeaseBox {
        weak var lease: OutputTextureLease?

        init(_ lease: OutputTextureLease) {
            self.lease = lease
        }
    }

    public init(device: (any MTLDevice)? = nil) async throws {
        let resolvedDevice: any MTLDevice
        if let device {
            resolvedDevice = device
        } else if let defaultDevice = MTLCreateSystemDefaultDevice() {
            resolvedDevice = defaultDevice
        } else {
            throw EngineError.metalDeviceUnavailable
        }

        guard let resolvedQueue = resolvedDevice.makeCommandQueue() else {
            throw EngineError.commandQueueCreationFailed
        }

        self.device = resolvedDevice
        self.commandQueue = resolvedQueue
        self.resourceManager = VolumeResourceManager(device: resolvedDevice,
                                                     commandQueue: resolvedQueue)
        self.volumeAdapter = try MetalVolumeRenderingAdapter(device: resolvedDevice,
                                                             commandQueue: resolvedQueue)
        self.mprAdapter = try MetalMPRAdapter(device: resolvedDevice,
                                              commandQueue: resolvedQueue)
        self.mprFrameCache = await MainActor.run { MPRFrameCache<ViewportID>() }
        self.renderPassDispatcher = RenderPassDispatcher(
            device: resolvedDevice,
            volumeAdapter: volumeAdapter,
            mprAdapter: mprAdapter,
            resourceManager: resourceManager,
            mprFrameCache: mprFrameCache,
            profiler: profiler
        )
    }

    public func createViewport(_ descriptor: ViewportDescriptor) async throws -> ViewportID {
        let id = ViewportID()
        viewports[id] = ViewportState(descriptor: descriptor)
        return id
    }

    /// Destroys a viewport and best-effort releases any tracked output texture
    /// leases still associated with it.
    ///
    /// Frames are transient render results. Callers that keep a `RenderFrame`
    /// alive across UI or export work should present it or release its
    /// `outputTextureLease` before destroying the viewport. The engine tracks
    /// leases for frames it produced and releases pending ones on destruction,
    /// but detached copies that no longer participate in the normal
    /// render/present lifecycle should still be closed explicitly by the owner.
    public func destroyViewport(_ viewport: ViewportID) async {
        guard let state = viewports.removeValue(forKey: viewport),
              let handle = state.resourceHandle
        else {
            await mprFrameCache.invalidate(viewport)
            releasePendingOutputTextureLeases(for: viewport)
            return
        }
        await mprFrameCache.invalidate(viewport)
        releasePendingOutputTextureLeases(for: viewport)
        resourceManager.release(handle: handle)
    }

    public func clearVolume(for viewports: [ViewportID]) async {
        var seenViewports = Set<ViewportID>()
        for viewport in viewports where seenViewports.insert(viewport).inserted {
            guard var state = self.viewports[viewport],
                  let handle = state.resourceHandle
            else {
                await mprFrameCache.invalidate(viewport)
                continue
            }
            state.resourceHandle = nil
            self.viewports[viewport] = state
            await mprFrameCache.invalidate(viewport)
            resourceManager.release(handle: handle)
        }
    }

    public func setVolume(_ dataset: VolumeDataset,
                          for viewport: ViewportID) async throws {
        guard let initialState = viewports[viewport] else {
            throw EngineError.viewportNotFound(viewport)
        }
        let previousHandle = initialState.resourceHandle

        let newHandle: VolumeResourceHandle
        if let oldHandle = previousHandle {
            newHandle = try await resourceManager.replaceDataset(oldHandle: oldHandle,
                                                                 newDataset: dataset)
        } else {
            newHandle = try await resourceManager.acquire(
                dataset: dataset,
                device: device,
                commandQueue: commandQueue
            )
        }

        guard var currentState = viewports[viewport] else {
            resourceManager.release(handle: newHandle)
            throw EngineError.viewportNotFound(viewport)
        }

        if currentState.resourceHandle != previousHandle,
           let currentHandle = currentState.resourceHandle {
            resourceManager.release(handle: currentHandle)
        }

        currentState.resourceHandle = newHandle
        viewports[viewport] = currentState
        await mprFrameCache.invalidate(viewport)
    }

    public func setVolume<S: AsyncSequence>(
        uploadDescriptor: VolumeUploadDescriptor,
        slices: S,
        for viewport: ViewportID,
        progress: ChunkedVolumeUploader.ProgressHandler? = nil
    ) async throws where S.Element == VolumeUploadSlice {
        guard let initialState = viewports[viewport] else {
            throw EngineError.viewportNotFound(viewport)
        }
        let previousHandle = initialState.resourceHandle

        let newHandle = try await resourceManager.acquireFromStream(
            descriptor: uploadDescriptor,
            slices: slices,
            progress: progress
        )

        guard var currentState = viewports[viewport] else {
            resourceManager.release(handle: newHandle)
            throw EngineError.viewportNotFound(viewport)
        }

        if currentState.resourceHandle != previousHandle {
            let currentHandle = currentState.resourceHandle
            if let currentHandle {
                resourceManager.release(handle: currentHandle)
            }
        } else if let previousHandle {
            resourceManager.release(handle: previousHandle)
        }

        currentState.resourceHandle = newHandle
        viewports[viewport] = currentState
        await mprFrameCache.invalidate(viewport)
    }

    @discardableResult
    public func setVolume(_ dataset: VolumeDataset,
                          for viewports: [ViewportID]) async throws -> VolumeResourceHandle? {
        var uniqueViewports: [ViewportID] = []
        var seenViewports = Set<ViewportID>()
        for viewport in viewports where seenViewports.insert(viewport).inserted {
            uniqueViewports.append(viewport)
        }

        guard !uniqueViewports.isEmpty else {
            return nil
        }
        for viewport in uniqueViewports {
            guard self.viewports[viewport] != nil else {
                throw EngineError.viewportNotFound(viewport)
            }
        }

        let sharedHandle = try await resourceManager.acquire(
            dataset: dataset,
            device: device,
            commandQueue: commandQueue
        )
        for _ in uniqueViewports.dropFirst() {
            resourceManager.retain(handle: sharedHandle)
        }
        var didCommitSharedHandle = false
        defer {
            if !didCommitSharedHandle {
                for _ in uniqueViewports {
                    resourceManager.release(handle: sharedHandle)
                }
            }
        }

        var previousHandles: [VolumeResourceHandle] = []
        var replacements: [(ViewportID, ViewportState)] = []
        for viewport in uniqueViewports {
            guard var state = self.viewports[viewport] else {
                throw EngineError.viewportNotFound(viewport)
            }
            if let previousHandle = state.resourceHandle {
                previousHandles.append(previousHandle)
            }
            state.resourceHandle = sharedHandle
            replacements.append((viewport, state))
        }

        for (viewport, state) in replacements {
            self.viewports[viewport] = state
            await mprFrameCache.invalidate(viewport)
        }

        for handle in previousHandles {
            resourceManager.release(handle: handle)
        }
        didCommitSharedHandle = true
        return sharedHandle
    }

    public func render(_ viewport: ViewportID) async throws -> RenderFrame {
        guard let state = viewports[viewport] else {
            throw EngineError.viewportNotFound(viewport)
        }

        let routeResolutionStartedAt = profilingOptions.measureRenderTime ? CFAbsoluteTimeGetCurrent() : nil
        let renderNode: ViewportRenderNode
        do {
            renderNode = try routeResolver.resolveNode(
                viewportID: viewport,
                viewportType: state.descriptor.type,
                resourceHandle: state.resourceHandle,
                using: renderGraph
            )
        } catch RenderGraphError.missingResourceHandle {
            throw EngineError.volumeNotSet(viewport)
        }

        guard let handle = renderNode.resourceHandle else {
            throw EngineError.volumeNotSet(viewport)
        }
        let dataset = resourceManager.dataset(for: handle)
        let volumeTexture = resourceManager.texture(for: handle)
        let transferTextureReady = dataset.map { isTransferTextureReady(for: state,
                                                                        dataset: $0,
                                                                        route: renderNode.resolvedRoute) } ?? false
        do {
            try routeResolver.validateRequirements(
                for: renderNode,
                datasetAvailable: dataset != nil,
                volumeTextureAvailable: volumeTexture != nil,
                surfaceAvailable: true,
                transferTextureAvailable: transferTextureReady,
                using: renderGraph
            )
        } catch RenderGraphError.missingDataset,
                RenderGraphError.missingVolumeTexture {
            throw EngineError.volumeResourceUnavailable
        } catch {
            throw error
        }
        guard let dataset else {
            throw EngineError.volumeResourceUnavailable
        }
        guard let volumeTexture else {
            throw EngineError.volumeResourceUnavailable
        }

        let route = renderNode.resolvedRoute
        profiler.recordRouteResolution(
            startedAt: routeResolutionStartedAt,
            route: route,
            viewportSize: state.currentSize,
            viewportID: viewport,
            viewportTypeName: route.viewportType.profilingName,
            qualityName: state.quality.profilingName,
            renderModeName: route.compositing?.profilingName ?? state.descriptor.type.renderModeName,
            options: profilingOptions,
            device: device
        )

        let profilingScope = profiler.makeScope(options: profilingOptions)
        let texture: any MTLTexture
        let outputTextureLease: OutputTextureLease?
        let isRaycastFrame: Bool
        let mprFrame: MPRTextureFrame?
        logger.info("Rendering viewport viewportID=\(String(describing: viewport)) route=\(route.profilingName) viewportType=\(route.viewportType.profilingName) viewportLabel=\(state.descriptor.label ?? "nil") viewportSize=\(Int(state.currentSize.width))x\(Int(state.currentSize.height)) pipeline=\(route.passPipelineName)")

        guard let primaryPass = route.primaryPass else {
            throw RenderGraphError.unmappedViewportRoute(route.viewportType)
        }

        switch primaryPass.kind {
        case .volumeRaycast:
            isRaycastFrame = true
            mprFrame = nil
            let volumeFrame: RenderPassDispatcher.VolumeRenderFrameResult
            do {
                defer {
                    debugPostAcquireRenderFailure = nil
                }
                volumeFrame = try await renderPassDispatcher.renderVolume(
                    state: state,
                    dataset: dataset,
                    volumeTexture: volumeTexture,
                    compositing: primaryPass.compositing ?? route.compositing ?? .frontToBack,
                    debugPostAcquireRenderFailure: debugPostAcquireRenderFailure
                )
            }
            texture = volumeFrame.texture
            outputTextureLease = volumeFrame.lease
            trackPendingOutputTextureLease(volumeFrame.lease, for: viewport)

        case .mprReslice:
            isRaycastFrame = false
            let mprResult = try await renderPassDispatcher.renderMPR(
                viewport: viewport,
                state: state,
                axis: primaryPass.axis ?? .axial,
                dataset: dataset,
                volumeTexture: volumeTexture,
                route: route,
                profilingOptions: profilingOptions
            )
            mprFrame = mprResult.frame
            texture = mprResult.frame.texture
            outputTextureLease = nil

        case .presentation, .mprPresentation, .overlay:
            throw RenderGraphError.invalidViewportConfiguration(
                viewport,
                reason: "Primary render pass cannot be \(primaryPass.kind.profilingName)."
            )
        }
        if texture.width == 0 || texture.height == 0 {
            throw RenderGraphError.passProducedNoFrame(viewport, primaryPass.kind)
        }

        profiler.recordMemorySnapshot(
            resourceManager: resourceManager,
            route: route,
            viewportSize: state.currentSize,
            viewportID: viewport,
            viewportTypeName: route.viewportType.profilingName,
            qualityName: state.quality.profilingName,
            renderModeName: route.compositing?.profilingName ?? state.descriptor.type.renderModeName,
            options: profilingOptions
        )

        let renderDuration = profilingScope.renderDuration()
        let inputs = FrameMetadataBuilder.Inputs(
            viewportID: viewport,
            viewportSize: state.currentSize,
            route: route,
            texture: texture,
            mprFrame: mprFrame,
            outputTextureLease: outputTextureLease,
            renderDuration: renderDuration,
            raycastDuration: isRaycastFrame ? renderDuration : nil,
            uploadDuration: profilingScope.measureUploadTime ? resourceManager.uploadTime(for: handle) : nil,
            presentDuration: nil
        )
        let frame = metadataBuilder.makeFrame(from: inputs)
        lastFrameTimings = frame.metadata
        try renderGraph.validateFrame(frame)
        return frame
    }

    public func resize(_ viewport: ViewportID,
                       to size: CGSize) async throws {
        guard var state = viewports[viewport] else {
            throw EngineError.viewportNotFound(viewport)
        }
        let snapshot = ViewportLifecycleController.ViewportStateSnapshot(
            descriptor: state.descriptor,
            currentSize: state.currentSize
        )
        let next = viewportLifecycleController.resized(snapshot, to: size)
        state.currentSize = next.currentSize
        viewports[viewport] = state
        await mprFrameCache.invalidate(viewport)
    }

    public func configure(_ viewport: ViewportID,
                          type: ViewportType,
                          label: String? = nil) async throws {
        guard var state = viewports[viewport] else {
            throw EngineError.viewportNotFound(viewport)
        }
        let snapshot = ViewportLifecycleController.ViewportStateSnapshot(
            descriptor: state.descriptor,
            currentSize: state.currentSize
        )
        let next = viewportLifecycleController.reconfigured(snapshot,
                                                           type: type,
                                                           label: label)
        guard state.descriptor != next.descriptor else {
            return
        }
        state.descriptor = next.descriptor
        viewports[viewport] = state
        await mprFrameCache.invalidate(viewport)
    }

    public func configure(_ viewport: ViewportID,
                          camera: Camera) async throws {
        guard var state = viewports[viewport] else {
            throw EngineError.viewportNotFound(viewport)
        }
        state.camera = camera
        viewports[viewport] = state
    }

    public func configure(_ viewport: ViewportID,
                          transferFunction: VolumeTransferFunction?) async throws {
        guard var state = viewports[viewport] else {
            throw EngineError.viewportNotFound(viewport)
        }
        state.transferFunction = transferFunction
        viewports[viewport] = state
    }

    public func configure(_ viewport: ViewportID,
                          slicePosition: Float,
                          window: ClosedRange<Int32>?) async throws {
        guard var state = viewports[viewport] else {
            throw EngineError.viewportNotFound(viewport)
        }
        let clampedSlicePosition = VolumetricMath.clampFloat(slicePosition, lower: 0, upper: 1)
        if state.slicePosition != clampedSlicePosition {
            await mprFrameCache.invalidate(viewport)
        }
        state.slicePosition = clampedSlicePosition
        state.window = window
        viewports[viewport] = state
    }

    public func configure(_ viewport: ViewportID,
                          window: ClosedRange<Int32>?) async throws {
        guard var state = viewports[viewport] else {
            throw EngineError.viewportNotFound(viewport)
        }
        state.window = window
        viewports[viewport] = state
    }

    public func configure(_ viewport: ViewportID,
                          slabThickness: Int,
                          slabSteps: Int,
                          blend: MPRBlendMode? = nil) async throws {
        guard var state = viewports[viewport] else {
            throw EngineError.viewportNotFound(viewport)
        }
        let sanitizedThickness = VolumetricMath.sanitizeThickness(slabThickness)
        let sanitizedSteps = VolumetricMath.sanitizeSteps(slabSteps)
        let resolvedBlend = blend ?? state.mprBlend
        if state.slabThickness != sanitizedThickness ||
            state.slabSteps != sanitizedSteps ||
            state.mprBlend != resolvedBlend {
            await mprFrameCache.invalidate(viewport)
        }
        state.slabThickness = sanitizedThickness
        state.slabSteps = sanitizedSteps
        state.mprBlend = resolvedBlend
        viewports[viewport] = state
    }

    public func configure(_ viewport: ViewportID,
                          samplingDistance: Float,
                          quality: VolumeRenderRequest.Quality) async throws {
        guard var state = viewports[viewport] else {
            throw EngineError.viewportNotFound(viewport)
        }
        state.samplingDistance = max(samplingDistance, Float.leastNonzeroMagnitude)
        state.quality = quality
        viewports[viewport] = state
    }

    public func setProfilingOptions(_ options: ProfilingOptions) async {
        profilingOptions = options
    }

    public var estimatedGPUMemoryBytes: Int {
        resourceManager.estimatedGPUMemoryBytes
    }

    public func resourceMetrics() async -> GPUResourceMetrics {
        resourceManager.resourceMetrics()
    }

    public func gpuResourceMetrics() async -> GPUResourceMetrics {
        await resourceMetrics()
    }

    public func lastFrameMetadata() async -> FrameMetadata? {
        lastFrameTimings
    }

    public func volumeTextureLabel(for viewport: ViewportID) async -> String? {
        guard let handle = viewports[viewport]?.resourceHandle,
              let texture = resourceManager.texture(for: handle) else {
            return nil
        }
        return texture.label
    }

    public func viewportType(for viewport: ViewportID) async throws -> ViewportType {
        guard let state = viewports[viewport] else {
            throw EngineError.viewportNotFound(viewport)
        }
        return state.descriptor.type
    }

#if DEBUG
    public func resourceSharingDiagnostics(for viewports: [ViewportID]) async -> [ViewportResourceDiagnostic] {
        viewports.compactMap { viewport in
            guard let handle = self.viewports[viewport]?.resourceHandle,
                  let textureIdentifier = resourceManager.debugTextureObjectIdentifier(for: handle)
            else {
                return nil
            }
            return ViewportResourceDiagnostic(viewportID: viewport,
                                              handle: handle,
                                              metadata: handle.metadata,
                                              textureObjectIdentifier: String(describing: textureIdentifier))
        }
    }
#endif
}

#if DEBUG
public struct ViewportResourceDiagnostic: Sendable, Equatable {
    public let viewportID: ViewportID
    public let handle: VolumeResourceHandle
    public let metadata: VolumeResourceHandle.Metadata
    public let textureObjectIdentifier: String

    public init(viewportID: ViewportID,
                handle: VolumeResourceHandle,
                metadata: VolumeResourceHandle.Metadata,
                textureObjectIdentifier: String) {
        self.viewportID = viewportID
        self.handle = handle
        self.metadata = metadata
        self.textureObjectIdentifier = textureObjectIdentifier
    }
}
#endif

private extension MTKRenderingEngine {
    func trackPendingOutputTextureLease(_ lease: OutputTextureLease,
                                        for viewport: ViewportID) {
        reapPendingOutputTextureLeases(for: viewport)

        let leaseID = ObjectIdentifier(lease as AnyObject)
        var leases = pendingOutputTextureLeases[viewport] ?? [:]
        leases[leaseID] = WeakOutputTextureLeaseBox(lease)
        pendingOutputTextureLeases[viewport] = leases
        logger.debug("Tracked output texture lease viewport=\(String(describing: viewport)) pendingLeaseCount=\(leases.count)")
    }

    func reapPendingOutputTextureLeases(for viewport: ViewportID) {
        guard let leases = pendingOutputTextureLeases[viewport] else {
            return
        }

        let liveLeases = leases.filter { _, box in
            guard let lease = box.lease else { return false }
            return !lease.isReleased
        }

        if liveLeases.isEmpty {
            pendingOutputTextureLeases[viewport] = nil
        } else {
            pendingOutputTextureLeases[viewport] = liveLeases
        }
    }

    func releasePendingOutputTextureLeases(for viewport: ViewportID) {
        reapPendingOutputTextureLeases(for: viewport)
        guard let leases = pendingOutputTextureLeases.removeValue(forKey: viewport) else {
            return
        }

        for box in leases.values {
            box.lease?.release()
        }
        logger.debug("Released pending output texture leases viewport=\(String(describing: viewport)) releasedLeaseCount=\(leases.count)")
    }

    func isTransferTextureReady(for state: ViewportState,
                                dataset: VolumeDataset,
                                route: RenderRoute) -> Bool {
        guard route.passPipeline.contains(where: { $0.kind == .volumeRaycast || $0.inputDependencies.contains(.transferTexture) }) else {
            return true
        }

        let transferFunction = state.transferFunction ?? .defaultGrayscale(for: dataset)
        return !transferFunction.colourPoints.isEmpty && !transferFunction.opacityPoints.isEmpty
    }
}

extension MTKRenderingEngine {
    @_spi(Testing)
    public var debugViewportCount: Int {
        viewports.count
    }

    @_spi(Testing)
    public var debugResourceTextureCount: Int {
        resourceManager.debugTextureCount
    }

    #if DEBUG
    @_spi(Testing)
    public var debugVolumeUploadCounts: (textureCreates: Int, cacheHits: Int) {
        (resourceManager.debugCounters.volumeTextureCreates,
         resourceManager.debugCounters.volumeCacheHits)
    }
    #endif

    @_spi(Testing)
    public var debugResourceReferenceCount: Int {
        resourceManager.debugTotalReferenceCount
    }

    @_spi(Testing)
    public var debugMemoryBreakdown: ResourceMemoryBreakdown {
        resourceManager.debugMemoryBreakdown
    }

    @_spi(Testing)
    public var debugOutputPoolTextureCount: Int {
        resourceManager.debugOutputPoolTextureCount
    }

    @_spi(Testing)
    public var debugOutputPoolInUseCount: Int {
        resourceManager.debugOutputPoolInUseCount
    }

    @_spi(Testing)
    public var debugOutputTextureLeaseAcquiredCount: Int {
        resourceManager.debugOutputTextureLeaseAcquiredCount
    }

    @_spi(Testing)
    public var debugOutputTextureLeasePresentedCount: Int {
        resourceManager.debugOutputTextureLeasePresentedCount
    }

    @_spi(Testing)
    public var debugOutputTextureLeaseReleasedCount: Int {
        resourceManager.debugOutputTextureLeaseReleasedCount
    }

    @_spi(Testing)
    public var debugOutputTextureLeasePendingCount: Int {
        resourceManager.debugOutputTextureLeasePendingCount
    }

    @_spi(Testing)
    public func debugAcquireOutputTextureIdentifier(width: Int,
                                                    height: Int,
                                                    pixelFormat: MTLPixelFormat,
                                                    releaseImmediately: Bool = false) throws -> ObjectIdentifier {
        let texture = try resourceManager.acquireOutputTexture(width: width,
                                                               height: height,
                                                               pixelFormat: pixelFormat)
        let identifier = ObjectIdentifier(texture as AnyObject)
        if releaseImmediately {
            resourceManager.releaseOutputTexture(texture)
        }
        return identifier
    }

    @_spi(Testing)
    public var debugLastFrameTimings: FrameMetadata? {
        lastFrameTimings
    }

    @_spi(Testing)
    public func debugDescriptor(for viewport: ViewportID) -> ViewportDescriptor? {
        viewports[viewport]?.descriptor
    }

    @_spi(Testing)
    public func debugCurrentSize(for viewport: ViewportID) -> CGSize? {
        viewports[viewport]?.currentSize
    }

    @_spi(Testing)
    public func debugTextureObjectIdentifier(for viewport: ViewportID) -> ObjectIdentifier? {
        guard let handle = viewports[viewport]?.resourceHandle else { return nil }
        return resourceManager.debugTextureObjectIdentifier(for: handle)
    }

    @_spi(Testing)
    public func debugMPRFrameTextureObjectIdentifier(for viewport: ViewportID) async -> ObjectIdentifier? {
        guard let texture = await mprFrameCache.storedFrame(for: viewport)?.texture else { return nil }
        return ObjectIdentifier(texture as AnyObject)
    }

    @_spi(Testing)
    public func debugResourceMetadata(for viewport: ViewportID) -> VolumeResourceHandle.Metadata? {
        guard let handle = viewports[viewport]?.resourceHandle else { return nil }
        return resourceManager.metadata(for: handle)
    }

    @_spi(Testing)
    public func debugResourceHandle(for viewport: ViewportID) -> VolumeResourceHandle? {
        viewports[viewport]?.resourceHandle
    }

    @_spi(Testing)
    public func debugWindow(for viewport: ViewportID) -> ClosedRange<Int32>? {
        viewports[viewport]?.window
    }

    @_spi(Testing)
    public func debugSlicePosition(for viewport: ViewportID) -> Float? {
        viewports[viewport]?.slicePosition
    }

    @_spi(Testing)
    public func debugSlabConfiguration(for viewport: ViewportID) -> (thickness: Int, steps: Int, blend: MPRBlendMode)? {
        guard let state = viewports[viewport] else { return nil }
        return (state.slabThickness, state.slabSteps, state.mprBlend)
    }

    @_spi(Testing)
    public func debugRenderQuality(for viewport: ViewportID) -> (samplingDistance: Float, quality: VolumeRenderRequest.Quality)? {
        guard let state = viewports[viewport] else { return nil }
        return (state.samplingDistance, state.quality)
    }

    @_spi(Testing)
    public func debugCamera(for viewport: ViewportID) -> Camera? {
        viewports[viewport]?.camera
    }

    @_spi(Testing)
    public func debugRenderRoute(for viewport: ViewportID) throws -> RenderRoute? {
        guard let state = viewports[viewport] else { return nil }
        return renderGraph.resolveRoute(for: state.descriptor.type)
    }

    @_spi(Testing)
    public func debugFailNextVolumeRenderAfterOutputLeaseAcquire(
        with error: MetalVolumeRenderingAdapter.RenderingError = .commandEncodingFailed
    ) {
        debugPostAcquireRenderFailure = error
    }
}
