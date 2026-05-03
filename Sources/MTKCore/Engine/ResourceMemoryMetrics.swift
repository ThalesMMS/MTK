import Foundation
import Metal

/// Internal helper that aggregates GPU resource memory and metadata for diagnostics.
///
/// This is intentionally best-effort and is designed to avoid adding synchronization
/// on the render hot path.
internal struct ResourceMemoryMetrics {
    internal struct Snapshot {
        internal var breakdown: ResourceMemoryBreakdown
        internal var uploadPeakMemoryBytes: Int?
        internal var volumeTextureCount: Int
        internal var transferTextureCount: Int
        internal var outputTexturePoolSize: Int
        internal var resources: [VolumeResourceHandle.Metadata]

        internal var estimatedMemoryBytes: Int { breakdown.total }

        internal func asGPUResourceMetrics() -> GPUResourceMetrics {
            GPUResourceMetrics(
                estimatedMemoryBytes: estimatedMemoryBytes,
                volumeTextureCount: volumeTextureCount,
                transferTextureCount: transferTextureCount,
                outputTexturePoolSize: outputTexturePoolSize,
                uploadPeakMemoryBytes: uploadPeakMemoryBytes,
                breakdown: breakdown,
                resources: resources
            )
        }
    }

    internal func snapshot(volumeTextures: some Collection<VolumeResourceManager.CachedResource>,
                           transferFunctionCache: TransferFunctionCache,
                           textureLeasePool: TextureLeasePool) -> Snapshot {
        let breakdown = ResourceMemoryBreakdown(
            volumeTextures: volumeTextures.reduce(0) { $0 + $1.estimatedBytes },
            transferTextures: transferFunctionCache.estimatedBytes,
            outputTextures: textureLeasePool.estimatedBytes
        )

        let uploadPeakMemoryBytes = volumeTextures.compactMap(\.peakMemoryBytes).max()

        return Snapshot(
            breakdown: breakdown,
            uploadPeakMemoryBytes: uploadPeakMemoryBytes,
            volumeTextureCount: volumeTextures.count,
            transferTextureCount: transferFunctionCache.textureCount,
            outputTexturePoolSize: textureLeasePool.textureCount,
            resources: volumeTextures.map(\.metadata) +
                transferFunctionCache.metadata +
                textureLeasePool.metadata
        )
    }
}
