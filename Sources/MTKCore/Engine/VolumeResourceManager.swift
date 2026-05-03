//
//  VolumeResourceManager.swift
//  MTK
//
//  Shared volume texture cache for MTKRenderingEngine.
//

import Foundation
import os.log
@preconcurrency import Metal

public struct VolumeResourceHandle: Hashable, Sendable {
    public struct Metadata: Equatable, Sendable {
        public enum ResourceType: Equatable, Sendable {
            case volume
            case transferFunction
            case outputTexture
        }

        public struct Dimensions: Equatable, Sendable {
            public let width: Int
            public let height: Int
            public let depth: Int

            public init(width: Int, height: Int, depth: Int) {
                self.width = width
                self.height = height
                self.depth = depth
            }
        }

        public let resourceType: ResourceType
        public let debugLabel: String?
        public let estimatedBytes: Int
        public let pixelFormat: MTLPixelFormat
        public let storageMode: MTLStorageMode
        public let dimensions: Dimensions

        public init(resourceType: ResourceType,
                    debugLabel: String?,
                    estimatedBytes: Int,
                    pixelFormat: MTLPixelFormat,
                    storageMode: MTLStorageMode,
                    dimensions: Dimensions) {
            self.resourceType = resourceType
            self.debugLabel = debugLabel
            self.estimatedBytes = estimatedBytes
            self.pixelFormat = pixelFormat
            self.storageMode = storageMode
            self.dimensions = dimensions
        }
    }

    private let rawValue: UUID
    public let metadata: Metadata

    init(rawValue: UUID = UUID(), metadata: Metadata) {
        self.rawValue = rawValue
        self.metadata = metadata
    }

    public static func == (lhs: VolumeResourceHandle, rhs: VolumeResourceHandle) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}

final class VolumeResourceManager {
    enum OutputTextureError: Error, Equatable {
        case textureLeased
    }

    #if DEBUG
    struct DebugCounters: Equatable, Sendable {
        var volumeTextureCreates: Int = 0
        var volumeCacheHits: Int = 0
    }

    private(set) var debugCounters = DebugCounters()
    #endif

    private struct DatasetIdentity: Hashable, Sendable {
        let count: Int
        let dimensions: VolumeDimensions
        let pixelFormat: VolumePixelFormat
        let contentFingerprint: UInt64

        init(dataset: VolumeDataset) {
            self.count = dataset.data.count
            self.dimensions = dataset.dimensions
            self.pixelFormat = dataset.pixelFormat
            self.contentFingerprint = DatasetContentFingerprint.make(for: dataset.data)
        }

        static func == (lhs: DatasetIdentity, rhs: DatasetIdentity) -> Bool {
            lhs.count == rhs.count &&
                lhs.dimensions == rhs.dimensions &&
                lhs.pixelFormat == rhs.pixelFormat &&
                lhs.contentFingerprint == rhs.contentFingerprint
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(count)
            hasher.combine(dimensions.width)
            hasher.combine(dimensions.height)
            hasher.combine(dimensions.depth)
            hasher.combine(pixelFormat.hashKey)
            hasher.combine(contentFingerprint)
        }
    }

    private struct StreamIdentity: Hashable, Sendable {
        let dimensions: VolumeDimensions
        let spacing: VolumeSpacing
        let sourcePixelFormat: VolumePixelFormat
        let intensityRange: ClosedRange<Int32>
        let orientation: VolumeOrientation
        let recommendedWindow: ClosedRange<Int32>?
        let contentFingerprint: UInt64

        init(descriptor: VolumeUploadDescriptor,
             contentFingerprint: UInt64) {
            self.dimensions = descriptor.dimensions
            self.spacing = descriptor.spacing
            self.sourcePixelFormat = descriptor.sourcePixelFormat
            self.intensityRange = descriptor.intensityRange
            self.orientation = descriptor.orientation
            self.recommendedWindow = descriptor.recommendedWindow
            self.contentFingerprint = contentFingerprint
        }

        static func == (lhs: StreamIdentity, rhs: StreamIdentity) -> Bool {
            lhs.dimensions == rhs.dimensions &&
                lhs.spacing == rhs.spacing &&
                lhs.sourcePixelFormat == rhs.sourcePixelFormat
                && lhs.intensityRange == rhs.intensityRange
                && lhs.orientation == rhs.orientation
                && lhs.recommendedWindow == rhs.recommendedWindow
                && lhs.contentFingerprint == rhs.contentFingerprint
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(dimensions.width)
            hasher.combine(dimensions.height)
            hasher.combine(dimensions.depth)
            hasher.combine(spacing.x.bitPattern)
            hasher.combine(spacing.y.bitPattern)
            hasher.combine(spacing.z.bitPattern)
            hasher.combine(sourcePixelFormat.hashKey)
            hasher.combine(intensityRange.lowerBound)
            hasher.combine(intensityRange.upperBound)
            combine(vector: orientation.row, into: &hasher)
            combine(vector: orientation.column, into: &hasher)
            combine(vector: orientation.origin, into: &hasher)
            if let recommendedWindow {
                hasher.combine(true)
                hasher.combine(recommendedWindow.lowerBound)
                hasher.combine(recommendedWindow.upperBound)
            } else {
                hasher.combine(false)
            }
            hasher.combine(contentFingerprint)
        }

        private func combine(vector: SIMD3<Float>, into hasher: inout Hasher) {
            hasher.combine(vector.x.bitPattern)
            hasher.combine(vector.y.bitPattern)
            hasher.combine(vector.z.bitPattern)
        }
    }

    private enum ResourceIdentity: Hashable, Sendable {
        case dataset(DatasetIdentity)
        case stream(StreamIdentity)
    }

    internal struct CachedResource {
        var dataset: VolumeDataset
        var texture: any MTLTexture
        var referenceCount: Int
        var uploadTime: CFAbsoluteTime?
        var peakMemoryBytes: Int?
        var storageMode: MTLStorageMode
        var pixelFormat: MTLPixelFormat
        var dimensions: VolumeResourceHandle.Metadata.Dimensions
        var estimatedBytes: Int
        var debugLabel: String?

        var metadata: VolumeResourceHandle.Metadata {
            VolumeResourceHandle.Metadata(
                resourceType: .volume,
                debugLabel: debugLabel,
                estimatedBytes: estimatedBytes,
                pixelFormat: pixelFormat,
                storageMode: storageMode,
                dimensions: dimensions
            )
        }
    }


    private var textureCache: [ResourceIdentity: CachedResource] = [:]
    private var handleMap: [VolumeResourceHandle: ResourceIdentity] = [:]
    private var handleReferenceCounts: [VolumeResourceHandle: Int] = [:]
    private let transferFunctionCache = TransferFunctionCache()
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let textureUploader: VolumeTextureUploader
    private let featureFlags: FeatureFlags
    private let textureLeasePool: TextureLeasePool
    private let lifecycleLogger = os.Logger(subsystem: "com.mtk.volumerendering",
                                            category: "ResourceLifecycle")

    init(device: any MTLDevice,
         commandQueue: any MTLCommandQueue,
         featureFlags: FeatureFlags? = nil) {
        self.device = device
        self.commandQueue = commandQueue
        self.textureUploader = VolumeTextureUploader(device: device, commandQueue: commandQueue)
        self.featureFlags = featureFlags ?? FeatureFlags.evaluate(for: device)
        self.textureLeasePool = TextureLeasePool(featureFlags: self.featureFlags)
    }

    /// Acquires a volume resource and mutates `textureCache` and `handleMap`.
    ///
    /// Each call returns a new stable handle, even when the underlying dataset
    /// texture is reused from `textureCache`. Viewports that move to a different
    /// dataset must release their old handle; `release(handle:)` decrements the
    /// cached resource ref-count and evicts the GPU texture when it reaches zero.
    /// Prefer `replaceDataset(oldHandle:newDataset:)` when swapping datasets so
    /// the acquire/release transition stays paired in one manager operation.
    ///
    /// `VolumeResourceManager.acquire(dataset:device:commandQueue:)` relies on
    /// `MTKRenderingEngine` actor isolation for thread-safety. Do not instantiate
    /// or call `VolumeResourceManager` directly from non-actor contexts; route all
    /// access through the engine actor so cache and handle mutations stay serialized.
    func acquire(dataset: VolumeDataset,
                 device: any MTLDevice,
                 commandQueue: any MTLCommandQueue) async throws -> VolumeResourceHandle {
        let identity = ResourceIdentity.dataset(DatasetIdentity(dataset: dataset))

        if var cached = textureCache[identity] {
            cached.referenceCount += 1
            textureCache[identity] = cached
            let handle = VolumeResourceHandle(metadata: cached.metadata)
            handleMap[handle] = identity
            handleReferenceCounts[handle] = 1
            #if DEBUG
            debugCounters.volumeCacheHits += 1
            #endif
            logLifecycle(resourceType: "volume",
                         action: "acquired",
                         estimatedBytes: cached.estimatedBytes)
            return handle
        }

        let uploadResult = try await textureUploader.upload(dataset: dataset)
        let texture = uploadResult.texture
        texture.label = "MTKRenderingEngine.VolumeTexture3D"
        #if DEBUG
        debugCounters.volumeTextureCreates += 1
        #endif

        let cached = CachedResource(
            dataset: dataset,
            texture: texture,
            referenceCount: 1,
            uploadTime: uploadResult.uploadTime,
            peakMemoryBytes: uploadResult.peakMemoryBytes,
            storageMode: texture.storageMode,
            pixelFormat: texture.pixelFormat,
            dimensions: VolumeResourceHandle.Metadata.Dimensions(
                width: texture.width,
                height: texture.height,
                depth: texture.depth
            ),
            estimatedBytes: ResourceMemoryEstimator.estimate(for: texture),
            debugLabel: texture.label
        )
        let handle = VolumeResourceHandle(metadata: cached.metadata)
        textureCache[identity] = cached
        handleMap[handle] = identity
        handleReferenceCounts[handle] = 1
        logLifecycle(resourceType: "volume",
                     action: "acquired",
                     estimatedBytes: cached.estimatedBytes)
        return handle
    }

    func acquireFromStream<S: AsyncSequence>(
        descriptor: VolumeUploadDescriptor,
        slices: S,
        progress: ChunkedVolumeUploader.ProgressHandler? = nil
    ) async throws -> VolumeResourceHandle where S.Element == VolumeUploadSlice {
        let upload = try await textureUploader.upload(
            descriptor: descriptor,
            slices: slices,
            progress: progress
        )
        let texture = upload.result.texture
        texture.label = "MTKRenderingEngine.VolumeTexture3D"
        #if DEBUG
        debugCounters.volumeTextureCreates += 1
        #endif
        let identity = ResourceIdentity.stream(
            StreamIdentity(descriptor: descriptor,
                           contentFingerprint: upload.contentFingerprint)
        )

        if var cached = textureCache[identity] {
            cached.referenceCount += 1
            textureCache[identity] = cached
            let handle = VolumeResourceHandle(metadata: cached.metadata)
            handleMap[handle] = identity
            handleReferenceCounts[handle] = 1
            #if DEBUG
            debugCounters.volumeCacheHits += 1
            #endif
            logLifecycle(resourceType: "volume",
                         action: "acquired",
                         estimatedBytes: cached.estimatedBytes)
            return handle
        }

        let cached = CachedResource(
            dataset: makeReferenceDataset(from: descriptor),
            texture: texture,
            referenceCount: 1,
            uploadTime: upload.result.uploadTime,
            peakMemoryBytes: upload.result.peakMemoryBytes,
            storageMode: texture.storageMode,
            pixelFormat: texture.pixelFormat,
            dimensions: VolumeResourceHandle.Metadata.Dimensions(
                width: texture.width,
                height: texture.height,
                depth: texture.depth
            ),
            estimatedBytes: ResourceMemoryEstimator.estimate(for: texture),
            debugLabel: texture.label
        )
        let handle = VolumeResourceHandle(metadata: cached.metadata)
        textureCache[identity] = cached
        handleMap[handle] = identity
        handleReferenceCounts[handle] = 1
        logLifecycle(resourceType: "volume",
                     action: "acquired",
                     estimatedBytes: cached.estimatedBytes)
        return handle
    }

    func acquireFromStream<S: AsyncSequence>(
        sliceStream: S,
        metadata: VolumeUploadDescriptor,
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        progress: VolumeUploadProgressHandler? = nil
    ) async throws -> VolumeResourceHandle where S.Element == SliceData {
        let upload = try await textureUploader.upload(
            sliceStream: sliceStream,
            metadata: metadata,
            progress: progress
        )

        let texture = upload.result.texture
        texture.label = "MTKRenderingEngine.VolumeTexture3D"
        #if DEBUG
        debugCounters.volumeTextureCreates += 1
        #endif

        let identity = ResourceIdentity.stream(
            StreamIdentity(descriptor: metadata,
                           contentFingerprint: upload.contentFingerprint)
        )

        if var cached = textureCache[identity] {
            cached.referenceCount += 1
            textureCache[identity] = cached
            let handle = VolumeResourceHandle(metadata: cached.metadata)
            handleMap[handle] = identity
            handleReferenceCounts[handle] = 1
            #if DEBUG
            debugCounters.volumeCacheHits += 1
            #endif
            logLifecycle(resourceType: "volume",
                         action: "acquired",
                         estimatedBytes: cached.estimatedBytes)
            return handle
        }

        let cached = CachedResource(
            dataset: makeReferenceDataset(from: metadata),
            texture: texture,
            referenceCount: 1,
            uploadTime: upload.result.uploadTime,
            peakMemoryBytes: upload.result.peakMemoryBytes,
            storageMode: texture.storageMode,
            pixelFormat: texture.pixelFormat,
            dimensions: VolumeResourceHandle.Metadata.Dimensions(
                width: texture.width,
                height: texture.height,
                depth: texture.depth
            ),
            estimatedBytes: ResourceMemoryEstimator.estimate(for: texture),
            debugLabel: texture.label
        )
        let handle = VolumeResourceHandle(metadata: cached.metadata)
        textureCache[identity] = cached
        handleMap[handle] = identity
        handleReferenceCounts[handle] = 1
        logLifecycle(resourceType: "volume",
                     action: "acquired",
                     estimatedBytes: cached.estimatedBytes)
        return handle
    }

    func retain(handle: VolumeResourceHandle) {
        guard let identity = handleMap[handle],
              var cached = textureCache[identity]
        else {
            lifecycleLogger.warning("Unable to retain volume handle; handle not found or already released: \(String(describing: handle), privacy: .public)")
            return
        }

        cached.referenceCount += 1
        textureCache[identity] = cached
        handleReferenceCounts[handle, default: 0] += 1
        logLifecycle(resourceType: "volume",
                     action: "retained",
                     estimatedBytes: cached.estimatedBytes)
    }

    func replaceDataset(oldHandle: VolumeResourceHandle,
                        newDataset: VolumeDataset) async throws -> VolumeResourceHandle {
        let newHandle = try await acquire(dataset: newDataset,
                                          device: device,
                                          commandQueue: commandQueue)
        release(handle: oldHandle)
        return newHandle
    }

    func release(handle: VolumeResourceHandle) {
        guard let identity = handleMap[handle],
              var cached = textureCache[identity]
        else {
            return
        }

        let remainingHandleReferences = max((handleReferenceCounts[handle] ?? 1) - 1, 0)
        if remainingHandleReferences > 0 {
            handleReferenceCounts[handle] = remainingHandleReferences
        } else {
            handleReferenceCounts[handle] = nil
            handleMap[handle] = nil
        }

        cached.referenceCount -= 1
        if cached.referenceCount > 0 {
            textureCache[identity] = cached
            logLifecycle(resourceType: "volume",
                         action: "released",
                         estimatedBytes: cached.estimatedBytes)
        } else {
            textureCache.removeValue(forKey: identity)
            logLifecycle(resourceType: "volume",
                         action: "evicted",
                         estimatedBytes: cached.estimatedBytes)
        }
    }

    func texture(for handle: VolumeResourceHandle) -> (any MTLTexture)? {
        guard let identity = handleMap[handle] else { return nil }
        return textureCache[identity]?.texture
    }

    func dataset(for handle: VolumeResourceHandle) -> VolumeDataset? {
        guard let identity = handleMap[handle] else { return nil }
        return textureCache[identity]?.dataset
    }

    func uploadTime(for handle: VolumeResourceHandle) -> CFAbsoluteTime? {
        guard let identity = handleMap[handle] else { return nil }
        return textureCache[identity]?.uploadTime
    }

    func peakUploadMemoryBytes(for handle: VolumeResourceHandle) -> Int? {
        guard let identity = handleMap[handle] else { return nil }
        return textureCache[identity]?.peakMemoryBytes
    }

    func metadata(for handle: VolumeResourceHandle) -> VolumeResourceHandle.Metadata? {
        guard let identity = handleMap[handle] else { return nil }
        return textureCache[identity]?.metadata
    }

    private let memoryMetrics = ResourceMemoryMetrics()

    var estimatedGPUMemoryBytes: Int {
        memoryBreakdown().total
    }

    func memoryBreakdown() -> ResourceMemoryBreakdown {
        let snapshot = memoryMetrics.snapshot(
            volumeTextures: textureCache.values,
            transferFunctionCache: transferFunctionCache,
            textureLeasePool: textureLeasePool
        )
        return snapshot.breakdown
    }

    func resourceMetrics() -> GPUResourceMetrics {
        memoryMetrics.snapshot(
            volumeTextures: textureCache.values,
            transferFunctionCache: transferFunctionCache,
            textureLeasePool: textureLeasePool
        ).asGPUResourceMetrics()
    }

    func gpuResourceMetrics() -> GPUResourceMetrics {
        resourceMetrics()
    }

    func acquireOutputTexture(width: Int,
                              height: Int,
                              pixelFormat: MTLPixelFormat) throws -> any MTLTexture {
        try textureLeasePool.acquire(width: width,
                                    height: height,
                                    pixelFormat: pixelFormat,
                               device: device)
    }

    func acquireOutputTextureWithLease(width: Int,
                                       height: Int,
                                       pixelFormat: MTLPixelFormat) throws -> OutputTextureLease {
        try textureLeasePool.acquireWithLease(width: width,
                                             height: height,
                                             pixelFormat: pixelFormat,
                                        device: device)
    }

    func releaseOutputTexture(_ texture: any MTLTexture) {
        textureLeasePool.release(texture: texture)
    }

    func releaseOutputTextureLease(_ lease: OutputTextureLease) {
        textureLeasePool.release(lease)
    }

    func resizeOutputTexture(from texture: any MTLTexture,
                             toWidth width: Int,
                             toHeight height: Int) throws -> any MTLTexture {
        // Resize is kept for legacy/manual output management paths. Pooled
        // textures that are currently owned by an OutputTextureLease should be
        // released through that lease instead of being resized in-place.
        if textureLeasePool.hasLease(for: texture) {
            throw OutputTextureError.textureLeased
        }

        return try textureLeasePool.resize(from: texture,
                                           toWidth: width,
                                           toHeight: height,
                                     device: device)
    }

    @MainActor
    func transferTexture(for preset: VolumeRenderingBuiltinPreset,
                         device: any MTLDevice) -> (any MTLTexture)? {
        let texture = transferFunctionCache.texture(for: preset, device: device)
        if let texture {
            logLifecycle(resourceType: "transferFunction",
                         action: "acquired",
                         estimatedBytes: ResourceMemoryEstimator.estimate(for: texture))
        }
        return texture
    }

    @MainActor
    func transferTexture(for function: VolumeTransferFunction,
                         device: any MTLDevice,
                         options: TransferFunctions.TextureOptions? = nil) -> (any MTLTexture)? {
        let texture = transferFunctionCache.texture(for: function,
                                                    device: device,
                                                    options: options)
        if let texture {
            logLifecycle(resourceType: "transferFunction",
                         action: "acquired",
                         estimatedBytes: ResourceMemoryEstimator.estimate(for: texture))
        }
        return texture
    }

    private func makeReferenceDataset(from descriptor: VolumeUploadDescriptor) -> VolumeDataset {
        VolumeDataset(data: Data(),
                      dimensions: descriptor.dimensions,
                      spacing: descriptor.spacing,
                      pixelFormat: .int16Signed,
                      intensityRange: descriptor.intensityRange,
                      orientation: descriptor.orientation,
                      recommendedWindow: descriptor.recommendedWindow)
    }


    private func logLifecycle(resourceType: String,
                              action: String,
                              estimatedBytes: Int) {
        guard featureFlags.contains(.diagnosticLogging) else {
            return
        }

        lifecycleLogger.info("resource=\(resourceType, privacy: .public) action=\(action, privacy: .public) estimatedBytes=\(estimatedBytes, privacy: .public)")
    }
}

private enum StreamUploadError: Error {
    case sliceSignednessMismatch(sliceIndex: Int, expected: VolumePixelFormat, actual: VolumePixelFormat)
}


private final class StreamContentFingerprintAccumulator: @unchecked Sendable {
    private static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211

    private let lock = NSLock()
    private var hash = fnvOffsetBasis

    var value: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return hash
    }

    func mix(slice: VolumeUploadSlice) {
        mix(integer: slice.index)
        mix(double: slice.slope)
        mix(double: slice.intercept)
        mix(integer: Int(slice.minClamp))
        mix(integer: Int(slice.maxClamp))
        mix(data: slice.data)
    }

    private func mix(data: Data) {
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            lock.lock()
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= Self.fnvPrime
            }
            lock.unlock()
        }
    }

    private func mix(integer value: Int) {
        var encoded = UInt64(bitPattern: Int64(value)).littleEndian
        mix(bytesOf: &encoded)
    }

    private func mix(double value: Double) {
        var encoded = value.bitPattern.littleEndian
        mix(bytesOf: &encoded)
    }

    private func mix(bytesOf value: inout UInt64) {
        withUnsafeBytes(of: &value) { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            lock.lock()
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= Self.fnvPrime
            }
            lock.unlock()
        }
    }
}

private struct HashedVolumeUploadSliceSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == VolumeUploadSlice {
    typealias Element = VolumeUploadSlice

    let base: Base
    let intensityRange: ClosedRange<Int32>
    let hasher: StreamContentFingerprintAccumulator

    func makeAsyncIterator() -> Iterator {
        Iterator(baseIterator: base.makeAsyncIterator(),
                 intensityRange: intensityRange,
                 hasher: hasher)
    }

    struct Iterator: AsyncIteratorProtocol {
        var baseIterator: Base.AsyncIterator
        let intensityRange: ClosedRange<Int32>
        let hasher: StreamContentFingerprintAccumulator

        mutating func next() async throws -> VolumeUploadSlice? {
            guard let slice = try await baseIterator.next() else {
                return nil
            }
            let uploadSlice = VolumeUploadSlice(index: slice.index,
                                                data: slice.data,
                                                slope: slice.slope,
                                                intercept: slice.intercept,
                                                minClamp: intensityRange.lowerBound,
                                                maxClamp: intensityRange.upperBound)
            hasher.mix(slice: uploadSlice)
            return uploadSlice
        }
    }
}

private struct HashedSliceDataUploadSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == SliceData {
    typealias Element = VolumeUploadSlice

    let base: Base
    let expectedPixelFormat: VolumePixelFormat
    let intensityRange: ClosedRange<Int32>
    let hasher: StreamContentFingerprintAccumulator

    func makeAsyncIterator() -> Iterator {
        Iterator(baseIterator: base.makeAsyncIterator(),
                 expectedPixelFormat: expectedPixelFormat,
                 intensityRange: intensityRange,
                 hasher: hasher)
    }

    struct Iterator: AsyncIteratorProtocol {
        var baseIterator: Base.AsyncIterator
        let expectedPixelFormat: VolumePixelFormat
        let intensityRange: ClosedRange<Int32>
        let hasher: StreamContentFingerprintAccumulator

        mutating func next() async throws -> VolumeUploadSlice? {
            guard let slice = try await baseIterator.next() else {
                return nil
            }

            let actualPixelFormat: VolumePixelFormat = slice.isSigned ? .int16Signed : .int16Unsigned
            guard actualPixelFormat == expectedPixelFormat else {
                throw StreamUploadError.sliceSignednessMismatch(sliceIndex: slice.index,
                                                               expected: expectedPixelFormat,
                                                               actual: actualPixelFormat)
            }

            let uploadSlice = VolumeUploadSlice(index: slice.index,
                                                data: slice.rawBytes,
                                                slope: slice.slope,
                                                intercept: slice.intercept,
                                                minClamp: intensityRange.lowerBound,
                                                maxClamp: intensityRange.upperBound)
            hasher.mix(slice: uploadSlice)
            return uploadSlice
        }
    }
}

private extension VolumePixelFormat {
    var hashKey: Int {
        switch self {
        case .int16Signed:
            return 0
        case .int16Unsigned:
            return 1
        }
    }
}

#if DEBUG

extension VolumeResourceManager {
    private var debugAccess: ResourceDebugAccess {
        ResourceDebugAccess(
            volumeTextureCount: { self.textureCache.count },
            transferTextureCount: { self.transferFunctionCache.textureCount },
            outputTextureCount: { self.textureLeasePool.debugTextureCount },
            memoryBreakdown: { self.memoryBreakdown() },
            outputPoolTextureCount: { self.textureLeasePool.textureCount },
            outputPoolInUseCount: { self.textureLeasePool.inUseCount },
            totalReferenceCount: { self.textureCache.values.reduce(0) { $0 + $1.referenceCount } },
            volumeTextureObjectIdentifier: { handle in
                guard let texture = self.texture(for: handle) else { return nil }
                return ObjectIdentifier(texture as AnyObject)
            },
            transferTextureLastAccessTime: { texture in
                self.transferFunctionCache.debugLastAccessTime(for: texture)
            },
            outputTextureIsInUse: { texture in
                self.textureLeasePool.debugIsInUse(texture)
            },
            outputTextureLeaseCount: { self.textureLeasePool.debugLeaseCount },
            outputTextureLeaseAcquiredCount: { self.textureLeasePool.debugLeaseAcquiredCount },
            outputTextureLeasePresentedCount: { self.textureLeasePool.debugLeasePresentedCount },
            outputTextureLeaseReleasedCount: { self.textureLeasePool.debugLeaseReleasedCount },
            outputTextureLeasePendingCount: { self.textureLeasePool.debugLeasePendingCount }
        )
    }

    var debugTextureCount: Int { debugAccess.volumeTextureCount }
    var debugTransferTextureCount: Int { debugAccess.transferTextureCount }
    var debugOutputTextureCount: Int { debugAccess.outputTextureCount }
    var debugMemoryBreakdown: ResourceMemoryBreakdown { debugAccess.memoryBreakdown }
    var debugOutputPoolTextureCount: Int { debugAccess.outputPoolTextureCount }
    var debugOutputPoolInUseCount: Int { debugAccess.outputPoolInUseCount }
    var debugTotalReferenceCount: Int { debugAccess.totalReferenceCount }

    func debugTextureObjectIdentifier(for handle: VolumeResourceHandle) -> ObjectIdentifier? {
        debugAccess.volumeTextureObjectIdentifier(for: handle)
    }

    func debugTransferTextureLastAccessTime(for texture: any MTLTexture) -> CFAbsoluteTime? {
        debugAccess.transferTextureLastAccessTime(for: texture)
    }

    func debugOutputTextureIsInUse(_ texture: any MTLTexture) -> Bool? {
        debugAccess.outputTextureIsInUse(texture)
    }

    var debugOutputTextureLeaseCount: Int { debugAccess.outputTextureLeaseCount }
    var debugOutputTextureLeaseAcquiredCount: Int { debugAccess.outputTextureLeaseAcquiredCount }
    var debugOutputTextureLeasePresentedCount: Int { debugAccess.outputTextureLeasePresentedCount }
    var debugOutputTextureLeaseReleasedCount: Int { debugAccess.outputTextureLeaseReleasedCount }
    var debugOutputTextureLeasePendingCount: Int { debugAccess.outputTextureLeasePendingCount }
}

#endif
