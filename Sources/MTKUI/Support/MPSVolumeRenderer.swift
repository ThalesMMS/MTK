#if canImport(MetalPerformanceShaders)
import Foundation
import Metal
import simd
@_spi(Internal) import MTKCore

/// MTKUI-local placeholder retained only to keep the UI target compiling after
/// the alternate MPS renderer was removed from MTKCore.
///
/// This type does not provide a rendering implementation. Initialization and
/// rendering APIs throw ``RendererUnavailableError/notAvailable`` so the UI
/// layer must handle the missing renderer explicitly while preserving source
/// compatibility for optional MPS UI hooks.
final class MPSVolumeRenderer {
    struct Ray: Equatable {
        let origin: SIMD3<Float>
        let direction: SIMD3<Float>
    }

    struct RayCastingSample: Equatable {
        let ray: Ray
        let entryDistance: Float
        let exitDistance: Float
    }

    struct HistogramResult: Equatable {
        let bins: [Float]
        let intensityRange: ClosedRange<Float>
    }

    init(device: any MTLDevice, commandQueue: any MTLCommandQueue) throws {
        throw RendererUnavailableError.notAvailable
    }

    /// Applies a Gaussian blur to the provided volume dataset and returns a texture containing the filtered result.
    /// - Parameters:
    ///   - dataset: The source volume dataset to be filtered.
    ///   - sigma: The standard deviation of the Gaussian kernel, in voxels.
    /// - Returns: A Metal texture containing the Gaussian-filtered volume data.
    /// - Throws: `RendererUnavailableError.notAvailable` if the renderer is unavailable.
    func applyGaussianFilter(dataset: VolumeDataset, sigma: Float) throws -> any MTLTexture {
        throw RendererUnavailableError.notAvailable
    }

    /// Performs a ray cast against the dataset's axis-aligned bounding box, producing entry and exit distances for each input ray.
    /// - Parameters:
    ///   - dataset: The volume dataset whose bounding box will be tested.
    ///   - rays: An array of rays (origin and direction) to intersect with the bounding box.
    /// - Returns: An array of `RayCastingSample` values corresponding to each input ray, containing the ray and its entry and exit distances into the bounding box.
    /// - Throws: `RendererUnavailableError.notAvailable` when the MPS-based renderer is not available.
    func performBoundingBoxRayCast(dataset: VolumeDataset,
                                   rays: [Ray]) throws -> [RayCastingSample] {
        throw RendererUnavailableError.notAvailable
    }

    enum RendererUnavailableError: Error {
        case notAvailable
    }
}
#endif
