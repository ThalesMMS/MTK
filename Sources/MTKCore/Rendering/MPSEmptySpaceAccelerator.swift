//
//  MPSEmptySpaceAccelerator.swift
//  MTK
//
//  Generates min-max mipmap acceleration structures for efficient empty space skipping
//  during volumetric ray marching. Uses Metal compute shaders to pre-compute hierarchical
//  minimum and maximum intensity values, enabling rapid detection and skipping of
//  transparent regions without expensive per-sample evaluation.
//
//  Thales Matheus Mendonca Santos — February 2026
//

import Foundation
import Metal
import OSLog

#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders

/// Generates hierarchical min-max mipmap acceleration structures for efficient
/// empty space skipping during volumetric ray marching.
///
/// This accelerator requires Metal Performance Shaders. Shared generation helpers
/// report explicit unavailability or failure when MPS support or required Metal
/// resources are absent.
///
/// The accelerator pre-computes minimum and maximum intensity values at multiple
/// resolution levels (up to 8 mip levels), creating a pyramid structure that enables
/// rapid detection and skipping of transparent regions without expensive per-sample
/// transfer function evaluation.
///
/// **Memory Overhead:** ~228% of source data size (rg16Float = 2x Int16 source, plus ~14% mip pyramid).
///
/// **Performance Characteristics:**
/// - 30%+ speedup for sparse volumes (CT chest, head scans with large air regions)
/// - Minimal overhead for dense volumes (MR, contrast-enhanced CT)
/// - One-time cost at dataset load, amortized over all subsequent renders
///
/// **Availability Contract:** Shared generation helpers report explicit success,
/// feature unavailability, or failure. Renderers decide whether to attach the
/// returned acceleration texture.
public final class MPSEmptySpaceAccelerator {
    /// Encapsulates a min-max mipmap pyramid texture and associated metadata
    /// for empty space skipping during ray marching.
    ///
    /// The acceleration structure stores minimum and maximum intensity values
    /// at each mip level in an `rg16Float` 3D texture (R=min, G=max).
    /// Higher mip levels cover progressively larger spatial regions (2x per level).
    ///
    /// **Usage Pattern:**
    /// ```swift
    /// switch MPSEmptySpaceAccelerator.create(device: device) {
    /// case .success(let accelerator):
    ///     let structure = try accelerator.generateAccelerationStructure(dataset: dataset)
    ///     // Pass structure.texture to ray marching shader
    /// case .unavailable(let reason):
    ///     print("Acceleration unavailable: \\(reason)")
    /// }
    /// ```
    public struct AccelerationStructure: Equatable {
        /// 3D texture storing min-max intensity pairs at multiple mip levels.
        /// Format: `rg16Float` (R=min, G=max).
        public let texture: any MTLTexture

        /// Number of mip levels in the pyramid (1-8 based on volume dimensions).
        /// Each level covers 2x spatial region of the previous level.
        public let mipLevels: Int

        /// Original intensity range from the source volume dataset,
        /// used for normalizing intensity queries.
        public let intensityRange: ClosedRange<Float>

        public init(texture: any MTLTexture, mipLevels: Int, intensityRange: ClosedRange<Float>) {
            self.texture = texture
            self.mipLevels = mipLevels
            self.intensityRange = intensityRange
        }

        /// Determines whether two `AccelerationStructure` values represent the same acceleration data.
        /// Compares texture identity, mip level count, and intensity range.
        /// - Returns: `true` if both structures reference the same texture (identity), have equal `mipLevels`, and equal `intensityRange`, `false` otherwise.
        public static func == (lhs: AccelerationStructure, rhs: AccelerationStructure) -> Bool {
            lhs.texture === rhs.texture &&
            lhs.mipLevels == rhs.mipLevels &&
            lhs.intensityRange == rhs.intensityRange
        }
    }

    /// Errors that can occur during acceleration structure generation.
    public enum AcceleratorError: Swift.Error, Equatable {
        /// The Metal device does not support Metal Performance Shaders.
        case unsupportedDevice

        /// Failed to create a command buffer from the command queue.
        case commandBufferUnavailable

        /// Failed to allocate or create a Metal texture.
        case textureCreationFailed

        /// Failed to create a blit command encoder for mipmap generation.
        case blitEncoderUnavailable

        /// Failed to create a compute command encoder for min-max calculation.
        case computeEncoderUnavailable

        /// Failed to create a Metal compute pipeline state.
        case pipelineCreationFailed

        /// The source texture is not a 3D texture type.
        case invalidSourceTexture

        /// The source texture pixel format is unsupported for acceleration generation.
        /// Supported formats are `.r16Sint` and `.r16Uint`.
        case unsupportedPixelFormat

        /// The provided intensity range is invalid for the source pixel format.
        /// For `.r16Uint`, the lower bound must be non-negative.
        case invalidIntensityRange
    }

    /// Reasons why shared acceleration generation can be unavailable.
    public enum UnavailabilityReason: Equatable {
        /// Metal Performance Shaders are not supported on the selected device.
        case mpsUnsupportedOnDevice

        /// No Metal command queue is available for accelerator setup.
        case commandQueueUnavailable

        /// Required Metal libraries or empty-space kernels could not be resolved.
        case libraryUnavailable

        /// Accelerator setup failed after capability and library checks succeeded.
        case acceleratorInitializationFailed
    }

    /// Explicit result for accelerator construction requests.
    public enum CreationResult {
        /// Accelerator construction succeeded and returned a configured accelerator instance.
        case success(MPSEmptySpaceAccelerator)

        /// Accelerator construction is unavailable for a typed, non-error reason.
        case unavailable(reason: UnavailabilityReason)
    }

    /// Explicit result for shared acceleration-structure generation requests.
    public enum GenerationResult {
        /// Acceleration generation succeeded and produced a min-max pyramid texture.
        case success(any MTLTexture)

        /// Acceleration generation is unavailable for a typed, non-error reason.
        case unavailable(reason: UnavailabilityReason)

        /// Acceleration generation attempted work and failed with an error.
        case failed(any Swift.Error)
    }

    /// Metal device used for texture allocation and compute operations.
    private let device: any MTLDevice

    /// Command queue for submitting GPU work to build acceleration structures.
    private let commandQueue: any MTLCommandQueue

    /// Metal shader library containing compute kernels.
    private let library: any MTLLibrary

    /// Compute pipeline for building the base mip level.
    private let basePipelineSigned: any MTLComputePipelineState
    private let basePipelineUnsigned: any MTLComputePipelineState

    /// Compute pipeline for downsampling mip levels.
    private let downsamplePipeline: any MTLComputePipelineState

    /// Logger for diagnostic messages during acceleration structure generation.
    private let logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "MPSEmptySpaceAccelerator")

    /// Creates an accelerator instance when MPS support and required Metal resources are available.
    ///
    /// Internal convenience retained for tests and same-module helpers. Public callers
    /// should use ``create(device:commandQueue:library:)`` to retain typed diagnostics.
    convenience init?(device: any MTLDevice,
                      commandQueue: (any MTLCommandQueue)? = nil,
                      library: (any MTLLibrary)? = nil) {
        guard MPSSupportsMTLDevice(device) else { return nil }
        guard let queue = commandQueue ?? device.makeCommandQueue() else { return nil }

        guard let resolvedResources = Self.resolveResources(device: device, preferred: library) else {
            return nil
        }

        self.init(device: device, commandQueue: queue, resolvedResources: resolvedResources)
    }

    private init(device: any MTLDevice,
                 commandQueue: any MTLCommandQueue,
                 resolvedResources: ResolvedResources) {
        self.device = device
        self.commandQueue = commandQueue
        self.library = resolvedResources.library
        self.basePipelineSigned = resolvedResources.baseSigned
        self.basePipelineUnsigned = resolvedResources.baseUnsigned
        self.downsamplePipeline = resolvedResources.downsample
    }

    /// Creates an accelerator with explicit availability diagnostics.
    ///
    /// - Parameters:
    ///   - device: Metal device to use for acceleration structure generation.
    ///   - commandQueue: Optional command queue. If `nil`, creates a new queue from the device.
    ///   - library: Optional Metal library. If `nil`, candidate libraries are resolved automatically.
    /// - Returns: A ``CreationResult`` that preserves whether setup succeeded or which prerequisite was unavailable.
    public static func create(device: any MTLDevice,
                              commandQueue: (any MTLCommandQueue)? = nil,
                              library: (any MTLLibrary)? = nil) -> CreationResult {
        guard MPSSupportsMTLDevice(device) else {
            return .unavailable(reason: .mpsUnsupportedOnDevice)
        }
        guard let queue = commandQueue ?? device.makeCommandQueue() else {
            return .unavailable(reason: .commandQueueUnavailable)
        }
        guard let resolvedFunctions = Self.resolveFunctions(device: device, preferred: library) else {
            return .unavailable(reason: .libraryUnavailable)
        }
        guard let resolvedResources = Self.resolveResources(device: device, resolvedFunctions: resolvedFunctions) else {
            return .unavailable(reason: .acceleratorInitializationFailed)
        }

        return .success(
            MPSEmptySpaceAccelerator(
                device: device,
                commandQueue: queue,
                resolvedResources: resolvedResources
            )
        )
    }

    /// Last-resort resolution path used when precompiled/default Metal libraries do not expose
    /// the empty-space compute kernels (for example, stale cached metallib artifacts).
    private static func makeRuntimeLibrary(device: any MTLDevice) -> (any MTLLibrary)? {
        let sourceURL = Bundle.module.url(forResource: "empty_space_compute", withExtension: "metal")
            ?? Bundle.module.url(forResource: "empty_space_compute", withExtension: "metal", subdirectory: "Shaders")
        guard let sourceURL,
              let source = try? String(contentsOf: sourceURL) else {
            return nil
        }

        let options = MTLCompileOptions()
        if #available(iOS 16.0, tvOS 16.0, macOS 13.0, *) {
            options.languageVersion = .version3_0
        }
        return try? device.makeLibrary(source: source, options: options)
    }

    /// Generates a min-max mipmap acceleration structure from a volume dataset.
    ///
    /// This convenience method creates a 3D texture from the dataset and then
    /// builds the hierarchical min-max pyramid. The resulting acceleration structure
    /// can be queried during ray marching to quickly skip transparent regions.
    ///
    /// - Parameter dataset: Volume dataset containing intensity data and metadata.
    ///
    /// - Returns: Acceleration structure with min-max mipmap pyramid and metadata.
    ///
    /// - Throws:
    ///   - `AcceleratorError.textureCreationFailed` if 3D texture allocation fails.
    ///   - `AcceleratorError.commandBufferUnavailable` if GPU command submission fails.
    /// Creates an acceleration structure (hierarchical min–max mipmap) from a volume dataset.
    /// - Parameters:
    ///   - dataset: The source volume data and associated metadata used to create a 3D Metal texture.
    /// - Returns: An `AccelerationStructure` containing the min/max mipmap texture, mip level count, and intensity range.
    /// - Throws: `AcceleratorError.textureCreationFailed` if converting the dataset to a Metal texture fails; rethrows any errors produced while building the acceleration structure from the texture.
    public func generateAccelerationStructure(dataset: VolumeDataset) throws -> AccelerationStructure {
        // Convert dataset to 3D Metal texture
        let factory = VolumeTextureFactory(dataset: dataset)
        guard let sourceTexture = factory.generate(device: device) else {
            throw AcceleratorError.textureCreationFailed
        }

        return try generateAccelerationStructure(from: sourceTexture, intensityRange: dataset.intensityRange)
    }

    /// Generates a min-max mipmap acceleration structure from an existing 3D texture.
    ///
    /// Builds a hierarchical pyramid where each mip level stores minimum and maximum
    /// intensity values for progressively larger spatial regions. The base mip level
    /// copies normalized per-voxel intensity to both min/max channels, and higher
    /// levels compute proper min-of-mins / max-of-maxes from 2x2x2 blocks.
    ///
    /// **Algorithm:**
    /// 1. Calculate optimal mip level count (1-8 based on max dimension)
    /// 2. Allocate `rg16Float` 3D texture for min-max storage
    /// 3. Build base mip level via compute shader (per-voxel normalization)
    /// 4. Downsample higher mip levels via compute shader (min/max of 2x2x2 blocks)
    /// 5. Submit GPU work and wait for completion
    ///
    /// - Parameters:
    ///   - sourceTexture: Source 3D texture containing intensity data.
    ///                    Must have `textureType == .type3D`.
    ///   - intensityRange: Original intensity range for normalization.
    ///
    /// - Returns: Acceleration structure with min-max mipmap pyramid and metadata.
    ///
    /// - Throws:
    ///   - `AcceleratorError.unsupportedPixelFormat` if the source texture format is not `.r16Sint` or `.r16Uint`.
    ///   - `AcceleratorError.invalidIntensityRange` if the source format is `.r16Uint` and `intensityRange.lowerBound` is negative.
    ///   - `AcceleratorError.invalidSourceTexture` if texture is not 3D type.
    ///   - `AcceleratorError.textureCreationFailed` if acceleration texture allocation fails.
    ///   - `AcceleratorError.commandBufferUnavailable` if command buffer creation fails.
    /// Create a hierarchical min–max mipmap acceleration structure from a 3D Metal texture.
    /// - Parameters:
    ///   - sourceTexture: The source 3D Metal texture containing voxel intensities.
    ///   - intensityRange: The original intensity bounds as a `ClosedRange<Int32>`; this range is converted to `Float` in the returned structure for shader compatibility.
    /// - Returns: An `AccelerationStructure` that encapsulates the generated rg16Float 3D min–max pyramid (R = min, G = max), the number of mip levels, and the intensity range expressed as `Float`.
    /// - Throws: `AcceleratorError.unsupportedPixelFormat` when `sourceTexture.pixelFormat` is not `.r16Sint` or `.r16Uint`; `AcceleratorError.invalidIntensityRange` when `.r16Uint` is paired with a negative lower bound; `AcceleratorError.invalidSourceTexture` if `sourceTexture` is not a 3D texture. May propagate other `AcceleratorError` cases raised during texture allocation or pyramid construction (for example `textureCreationFailed`, `commandBufferUnavailable`, `blitEncoderUnavailable`, `computeEncoderUnavailable`, or `pipelineCreationFailed`).
    public func generateAccelerationStructure(
        from sourceTexture: any MTLTexture,
        intensityRange: ClosedRange<Int32>
    ) throws -> AccelerationStructure {
        let sourcePixelFormat = sourceTexture.pixelFormat
        guard sourcePixelFormat == .r16Sint || sourcePixelFormat == .r16Uint else {
            throw AcceleratorError.unsupportedPixelFormat
        }
        if sourcePixelFormat == .r16Uint, intensityRange.lowerBound < 0 {
            throw AcceleratorError.invalidIntensityRange
        }

        guard sourceTexture.textureType == .type3D else {
            throw AcceleratorError.invalidSourceTexture
        }

        let basePipeline = sourcePixelFormat == .r16Uint ? basePipelineUnsigned : basePipelineSigned

        // Calculate optimal mip level count (capped at 8 for performance/memory balance)
        let mipLevels = calculateMipLevels(for: sourceTexture)

        // Allocate rg16Float 3D texture for min-max pyramid
        let accelerationTexture = try createAccelerationTexture(
            width: sourceTexture.width,
            height: sourceTexture.height,
            depth: sourceTexture.depth,
            mipLevels: mipLevels
        )

        // Build multi-resolution min-max pyramid
        try buildMinMaxPyramid(
            source: sourceTexture,
            destination: accelerationTexture,
            mipLevels: mipLevels,
            intensityRange: intensityRange,
            basePipeline: basePipeline
        )

        // Convert intensity range to Float for shader compatibility
        let floatRange = Float(intensityRange.lowerBound)...Float(intensityRange.upperBound)
        return AccelerationStructure(
            texture: accelerationTexture,
            mipLevels: mipLevels,
            intensityRange: floatRange
        )
    }
}

// MARK: - Private Implementation

private extension MPSEmptySpaceAccelerator {
    struct ResolvedFunctions {
        let library: any MTLLibrary
        let baseSigned: any MTLFunction
        let baseUnsigned: any MTLFunction
        let downsample: any MTLFunction
    }

    struct ResolvedResources {
        let library: any MTLLibrary
        let baseSigned: any MTLComputePipelineState
        let baseUnsigned: any MTLComputePipelineState
        let downsample: any MTLComputePipelineState
    }

    /// Builds an ordered list of candidate Metal libraries to resolve the empty-space compute kernels.
    ///
    /// The returned list prefers the caller-provided library first (if supplied) and then includes bundled, default, bundle-scoped, and runtime-compiled libraries as available.
    /// - Parameters:
    ///   - library: An optional caller-provided `MTLLibrary` to try first.
    /// - Returns: An ordered array of `MTLLibrary` candidates to attempt when resolving compute kernel functions.
    static func candidateLibraries(
        device: any MTLDevice,
        preferred library: (any MTLLibrary)? = nil
    ) -> [any MTLLibrary] {
        var candidates: [any MTLLibrary] = []
        if let library {
            // Prefer the caller-provided library, but keep alternate candidates in
            // case it does not expose the empty-space kernels.
            candidates.append(library)
        }
        if let url = Bundle.module.url(forResource: "MTK", withExtension: "metallib"),
           let bundledLibrary = try? device.makeLibrary(URL: url) {
            candidates.append(bundledLibrary)
        }
        if let defaultLibrary = device.makeDefaultLibrary() {
            candidates.append(defaultLibrary)
        }
        if #available(iOS 13.0, tvOS 13.0, macOS 11.0, *),
           let bundleLibrary = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            candidates.append(bundleLibrary)
        }
        if let runtimeLibrary = Self.makeRuntimeLibrary(device: device) {
            candidates.append(runtimeLibrary)
        }
        return candidates
    }

    /// Finds a Metal library that provides all required compute kernels and returns those functions grouped as `ResolvedFunctions`.
    /// - Parameters:
    ///   - device: The Metal device used to probe candidate libraries.
    ///   - library: An optional preferred `MTLLibrary` to try first when searching for the kernels.
    /// - Returns: A `ResolvedFunctions` instance containing `computeMinMaxBase`, `computeMinMaxBaseUnsigned`, and `computeMinMaxDownsample` if a library with all three functions is found, `nil` otherwise.
    static func resolveFunctions(
        device: any MTLDevice,
        preferred library: (any MTLLibrary)? = nil
    ) -> ResolvedFunctions? {
        for candidate in candidateLibraries(device: device, preferred: library) {
            guard let baseSigned = candidate.makeFunction(name: "computeMinMaxBase"),
                  let baseUnsigned = candidate.makeFunction(name: "computeMinMaxBaseUnsigned"),
                  let downsample = candidate.makeFunction(name: "computeMinMaxDownsample") else {
                continue
            }
            return ResolvedFunctions(
                library: candidate,
                baseSigned: baseSigned,
                baseUnsigned: baseUnsigned,
                downsample: downsample
            )
        }
        return nil
    }

    /// Resolves the accelerator's compute kernel functions and constructs their `MTLComputePipelineState` objects.
    /// - Parameters:
    ///   - device: The `MTLDevice` used to create pipeline states.
    ///   - library: An optional preferred `MTLLibrary` to search first for the required kernel functions.
    /// - Returns: A `ResolvedResources` instance containing the chosen library and the three compute pipeline states when all kernels and pipelines are successfully resolved and created; `nil` if any required function or pipeline state cannot be resolved or constructed.
    static func resolveResources(
        device: any MTLDevice,
        resolvedFunctions: ResolvedFunctions
    ) -> ResolvedResources? {
        guard let baseSignedPSO = try? device.makeComputePipelineState(function: resolvedFunctions.baseSigned),
              let baseUnsignedPSO = try? device.makeComputePipelineState(function: resolvedFunctions.baseUnsigned),
              let downsamplePSO = try? device.makeComputePipelineState(function: resolvedFunctions.downsample) else {
            return nil
        }

        return ResolvedResources(
            library: resolvedFunctions.library,
            baseSigned: baseSignedPSO,
            baseUnsigned: baseUnsignedPSO,
            downsample: downsamplePSO
        )
    }

    /// Resolves the accelerator's compute kernel functions and constructs their `MTLComputePipelineState` objects.
    /// - Parameters:
    ///   - device: The `MTLDevice` used to create pipeline states.
    ///   - library: An optional preferred `MTLLibrary` to search first for the required kernel functions.
    /// - Returns: A `ResolvedResources` instance containing the chosen library and the three compute pipeline states when all kernels and pipelines are successfully resolved and created; `nil` if any required function or pipeline state cannot be resolved or constructed.
    static func resolveResources(
        device: any MTLDevice,
        preferred library: (any MTLLibrary)? = nil
    ) -> ResolvedResources? {
        guard let resolvedFunctions = resolveFunctions(device: device, preferred: library) else {
            return nil
        }

        return resolveResources(device: device, resolvedFunctions: resolvedFunctions)
    }

    /// Calculates the optimal number of mip levels for the acceleration structure.
    ///
    /// Determines the maximum mip level count based on the largest texture dimension,
    /// capped at 8 levels for performance and memory balance. Each mip level covers
    /// 2x the spatial region of the previous level.
    ///
    /// - Parameter texture: Source 3D texture whose `width`, `height`, and `depth` determine mip count.
    /// - Returns: Mip level count in range [1, 8].
    func calculateMipLevels(for texture: any MTLTexture) -> Int {
        let maxDimension = max(texture.width, texture.height, texture.depth)
        guard maxDimension > 0 else {
            return 1
        }
        // log2(maxDimension) gives the theoretical max levels, +1 includes the base level
        let levels = Int(floor(log2(Double(maxDimension)))) + 1
        // Cap at 8 mip levels to balance memory overhead vs. acceleration benefit
        return max(1, min(levels, 8))
    }

    /// Allocates a 3D texture for storing the min-max mipmap pyramid.
    ///
    /// Creates an `rg16Float` 3D texture with the specified dimensions and mip level count.
    /// The texture uses `.private` storage mode for GPU-only access and includes usage flags
    /// for both compute shaders (write) and fragment shaders (read).
    ///
    /// **Format:** `rg16Float` - R channel stores minimum intensity, G channel stores maximum.
    ///
    /// - Parameters:
    ///   - width: Texture width (matches source volume X dimension).
    ///   - height: Texture height (matches source volume Y dimension).
    ///   - depth: Texture depth (matches source volume Z dimension).
    ///   - mipLevels: Number of mip levels to allocate (1-8).
    ///
    /// - Returns: Allocated 3D texture ready for min-max pyramid generation.
    ///
    /// Create a GPU-only 3D texture configured to store the hierarchical min–max mipmap pyramid.
    /// 
    /// The texture uses `rg16Float` where the R channel stores the minimum and the G channel stores the maximum intensity for each voxel. It is configured for shader read/write access and is placed in private storage for GPU-only usage.
    /// - Parameters:
    ///   - width: Width of the base level in voxels.
    ///   - height: Height of the base level in voxels.
    ///   - depth: Depth of the base level in voxels.
    ///   - mipLevels: Number of mip levels to allocate (base level + downsampled levels).
    /// - Returns: A 3D `MTLTexture` configured for the min–max pyramid.
    /// - Throws: `AcceleratorError.textureCreationFailed` if the texture could not be created.
    func createAccelerationTexture(
        width: Int,
        height: Int,
        depth: Int,
        mipLevels: Int
    ) throws -> any MTLTexture {
        // StorageModePolicy.md: ESS acceleration textures are GPU-only intermediates.
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rg16Float  // R=min, G=max intensity
        descriptor.width = width
        descriptor.height = height
        descriptor.depth = depth
        descriptor.mipmapLevelCount = mipLevels
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private  // GPU-only, no CPU access needed

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            logger.error("Failed to create acceleration structure texture (\(width)x\(height)x\(depth), \(mipLevels) mips)")
            throw AcceleratorError.textureCreationFailed
        }

        texture.label = "MPSEmptySpaceAccelerator.MinMaxPyramid"
        return texture
    }

    /// Builds the complete min-max mipmap pyramid by generating all mip levels.
    ///
    /// **Algorithm:**
    /// 1. Generate base mip level (level 0) using compute shader on source volume
    /// 2. Generate higher mip levels (1 through N-1) via compute shader downsampling
    /// 3. Submit all GPU work in a single command buffer
    /// 4. Wait synchronously for completion and check for errors
    ///
    /// Each mip level stores minimum intensity in R channel and maximum intensity in G channel,
    /// enabling hierarchical empty space queries during ray marching.
    ///
    /// - Parameters:
    ///   - source: Source 3D texture containing original intensity data.
    ///   - destination: Target 3D texture for min-max pyramid (allocated with mip levels).
    ///   - mipLevels: Number of mip levels to generate (1-8).
    ///   - intensityRange: Dataset intensity range for normalization.
    ///
    /// - Throws:
    ///   - `AcceleratorError.commandBufferUnavailable` if command buffer creation fails.
    ///   - `AcceleratorError.computeEncoderUnavailable` if compute encoder creation fails.
    /// Builds a hierarchical min–max mipmap pyramid in `destination` from `source`.
    /// - Parameters:
    ///   - source: The source 3D texture containing raw voxel intensities (level 0 input).
    ///   - destination: A 3D texture allocated to hold the min–max pyramid across mip levels (rg16Float); must have `mipLevels` allocated.
    ///   - mipLevels: Number of mip levels to generate (including level 0).
    ///   - intensityRange: Intensity normalization range passed to the base-level compute kernel.
    ///   - basePipeline: Base-level compute pipeline selected from the source texture pixel format.
    /// - Throws: `AcceleratorError.commandBufferUnavailable` if a command buffer cannot be created; forwards any errors produced by the compute encoders or by GPU execution if the command buffer completes with an error.
    func buildMinMaxPyramid(
        source: any MTLTexture,
        destination: any MTLTexture,
        mipLevels: Int,
        intensityRange: ClosedRange<Int32>,
        basePipeline: any MTLComputePipelineState
    ) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw AcceleratorError.commandBufferUnavailable
        }
        commandBuffer.label = "MPSEmptySpaceAccelerator.BuildPyramid"

        // Build base mip level (level 0) using compute shader
        try buildBaseMipLevel(
            source: source,
            destination: destination,
            intensityRange: intensityRange,
            basePipeline: basePipeline,
            commandBuffer: commandBuffer
        )

        // Build higher mip levels (1 through N-1) via compute downsampling
        for level in 1..<mipLevels {
            try buildDownsampledMipLevel(
                destination: destination,
                sourceLevel: level - 1,
                targetLevel: level,
                commandBuffer: commandBuffer
            )
        }

        // Execute all GPU work synchronously
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Check for GPU errors during execution
        if let error = commandBuffer.error {
            logger.error("Acceleration structure build failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Builds the base mip level (level 0) of the min-max pyramid.
    ///
    /// Dispatches the `computeMinMaxBase` kernel which reads each voxel from the source
    /// 3D texture, normalizes its intensity to [0, 1], and writes it to both the R (min)
    /// and G (max) channels of the destination texture. At the base level, each voxel's
    /// min and max are identical.
    ///
    /// - Parameters:
    ///   - source: Source 3D texture containing original intensity data.
    ///   - destination: Destination texture for min-max values at mip level 0.
    ///   - intensityRange: Dataset intensity range for normalization.
    ///   - commandBuffer: Command buffer to encode GPU work into.
    ///
    /// Encodes a compute pass that generates the base (level 0) min–max mipmap from a source 3D texture into the destination texture.
    /// - Parameters:
    ///   - source: The source 3D texture containing original voxel intensities.
    ///   - destination: The destination 3D texture that will receive the computed min/max values for the base mip level.
    ///   - intensityRange: The inclusive integer range (min and max) of source intensities used by the compute kernel.
    ///   - basePipeline: Base-level compute pipeline selected from the source texture pixel format.
    ///   - commandBuffer: The command buffer to which the compute commands are encoded.
    /// - Throws: `AcceleratorError.computeEncoderUnavailable` if a compute encoder cannot be created.
    func buildBaseMipLevel(
        source: any MTLTexture,
        destination: any MTLTexture,
        intensityRange: ClosedRange<Int32>,
        basePipeline: any MTLComputePipelineState,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw AcceleratorError.computeEncoderUnavailable
        }
        computeEncoder.label = "MPSEmptySpaceAccelerator.BaseMip"

        computeEncoder.setComputePipelineState(basePipeline)
        computeEncoder.setTexture(source, index: 0)
        computeEncoder.setTexture(destination, index: 1)

        var dataMin = Int32(intensityRange.lowerBound)
        var dataMax = Int32(intensityRange.upperBound)
        computeEncoder.setBytes(&dataMin, length: MemoryLayout<Int32>.size, index: 0)
        computeEncoder.setBytes(&dataMax, length: MemoryLayout<Int32>.size, index: 1)

        let threadgroupSize = optimalThreadgroupSize(for: basePipeline, dimensions: source)
        let threadgroups = MTLSize(
            width: (source.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (source.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: (source.depth + threadgroupSize.depth - 1) / threadgroupSize.depth
        )

        computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
    }

    /// Generates a downsampled mip level using a compute shader.
    ///
    /// Creates texture views targeting specific mip levels of the acceleration texture,
    /// then dispatches the `computeMinMaxDownsample` kernel which reads 2x2x2 blocks
    /// from the source level and computes min-of-mins (R) and max-of-maxes (G) for
    /// the target level.
    ///
    /// - Parameters:
    ///   - destination: Texture containing the min-max pyramid being built.
    ///   - sourceLevel: Source mip level index to read from.
    ///   - targetLevel: Target mip level index to write to.
    ///   - commandBuffer: Command buffer to encode compute operations into.
    ///
    /// - Throws:
    ///   - `AcceleratorError.textureCreationFailed` if mip-level texture views cannot be created.
    /// Generate the downsampled min-max mip level for `targetLevel` by reading from `sourceLevel` within the given 3D destination texture.
    /// - Parameters:
    ///   - destination: A 3D rg16Float texture that holds the min-max pyramid; the function creates level-specific texture views into this texture.
    ///   - sourceLevel: The existing mip level index to read min/max values from.
    ///   - targetLevel: The mip level index to write the downsampled min/max results into.
    ///   - commandBuffer: The command buffer used to encode and dispatch the compute kernel.
    /// - Throws:
    ///   - `AcceleratorError.textureCreationFailed` if per-level texture views cannot be created.
    ///   - `AcceleratorError.computeEncoderUnavailable` if a compute command encoder cannot be obtained from the command buffer.
    func buildDownsampledMipLevel(
        destination: any MTLTexture,
        sourceLevel: Int,
        targetLevel: Int,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        // Create texture views targeting specific mip levels
        guard let sourceView = destination.makeTextureView(
            pixelFormat: .rg16Float,
            textureType: .type3D,
            levels: sourceLevel..<(sourceLevel + 1),
            slices: 0..<1
        ) else {
            throw AcceleratorError.textureCreationFailed
        }

        guard let destView = destination.makeTextureView(
            pixelFormat: .rg16Float,
            textureType: .type3D,
            levels: targetLevel..<(targetLevel + 1),
            slices: 0..<1
        ) else {
            throw AcceleratorError.textureCreationFailed
        }

        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw AcceleratorError.computeEncoderUnavailable
        }
        computeEncoder.label = "MPSEmptySpaceAccelerator.MipLevel\(targetLevel)"

        computeEncoder.setComputePipelineState(downsamplePipeline)
        computeEncoder.setTexture(sourceView, index: 0)
        computeEncoder.setTexture(destView, index: 1)

        // Destination dimensions at this mip level
        let dstWidth = destView.width
        let dstHeight = destView.height
        let dstDepth = destView.depth

        let threadgroupSize = optimalThreadgroupSize(for: downsamplePipeline, dimensions: destView)
        let threadgroups = MTLSize(
            width: (dstWidth + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (dstHeight + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: (dstDepth + threadgroupSize.depth - 1) / threadgroupSize.depth
        )

        computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
    }

    /// Selects a cubic threadgroup size appropriate for 3D dispatch, constrained by the pipeline's maximum threads per threadgroup.
    /// - Parameters:
    ///   - pipeline: The compute pipeline whose `maxTotalThreadsPerThreadgroup` limits the returned size.
    ///   - texture: The 3D texture whose dispatch will use the threadgroup size (only used to indicate 3D use-case).
    /// - Returns: An `MTLSize` with equal `width`, `height`, and `depth` for threadgroup dimensions, not exceeding the pipeline's thread limit.
    func optimalThreadgroupSize(
        for pipeline: any MTLComputePipelineState,
        dimensions texture: any MTLTexture
    ) -> MTLSize {
        let maxThreads = pipeline.maxTotalThreadsPerThreadgroup
        // Use 4x4x4 = 64 threads as default, reasonable for 3D dispatch
        let side = min(4, Int(cbrt(Double(maxThreads))))
        return MTLSize(width: side, height: side, depth: side)
    }
}

// MARK: - Memory Overhead Calculation

public extension MPSEmptySpaceAccelerator.AccelerationStructure {
    /// Calculates the total memory footprint of the acceleration structure in bytes.
    ///
    /// Sums the size of all mip levels in the min-max pyramid. Each pixel stores
    /// two 16-bit float values (min and max intensity), totaling 4 bytes per voxel.
    ///
    /// **Formula:** For each mip level L, size = (width/2^L) × (height/2^L) × (depth/2^L) × 4 bytes
    ///
    /// **Typical overhead:** ~228% of a single-channel Int16 source due to geometric series convergence:
    /// - Base level: ~2x Int16 source (rg16Float stores two 16-bit channels)
    /// - All mip levels: 1 + 1/8 + 1/64 + ... ≈ 1.14x base level size
    ///   (total ≈ 1.14 × 2.0 = 2.28x the Int16 source)
    ///
    /// - Returns: Total memory footprint in bytes across all mip levels.
    var memoryFootprint: Int {
        let bytesPerPixel = 4  // rg16Float = 2 channels × 2 bytes/channel
        var totalBytes = 0

        // Sum memory for each mip level
        for level in 0..<mipLevels {
            let divisor = 1 << level  // 2^level
            let w = max(1, texture.width / divisor)
            let h = max(1, texture.height / divisor)
            let d = max(1, texture.depth / divisor)
            totalBytes += w * h * d * bytesPerPixel
        }

        return totalBytes
    }

    /// Calculates the memory overhead as a ratio relative to the source dataset size.
    ///
    /// Divides the acceleration structure's memory footprint by the source dataset's
    /// data size to produce a relative overhead ratio.
    ///
    /// **Example:** A return value of 0.15 indicates the acceleration structure uses
    /// 15% additional memory compared to the source volume.
    ///
    /// - Parameter dataset: Source volume dataset to compare against.
    /// Computes the memory overhead of the acceleration structure relative to a volume dataset.
    /// - Parameter dataset: The reference volume dataset; its raw byte count (`dataset.data.count`) is used for comparison.
    /// Computes the accelerator's memory overhead relative to a dataset.
    /// - Parameter dataset: The dataset whose `data.count` (byte count) is used as the baseline.
    /// - Returns: The ratio of `memoryFootprint` to `dataset.data.count`; returns `0.0` if `dataset.data.count` is zero.
    func memoryOverhead(relativeTo dataset: VolumeDataset) -> Double {
        let datasetBytes = dataset.data.count
        guard datasetBytes > 0 else { return 0.0 }
        return Double(memoryFootprint) / Double(datasetBytes)
    }
}
// MARK: - Shared Convenience API

public extension MPSEmptySpaceAccelerator {
    /// Shared helper used by multiple renderers to generate an acceleration structure texture.
    /// Centralizes the MPS-availability checks, logging, and error handling.
    ///
    /// Generates an empty-space acceleration texture (min-max mipmap pyramid)
    /// for a volume dataset and returns an explicit result describing success,
    /// feature unavailability, or a generation failure.
    /// - Returns: A `GenerationResult` describing the outcome:
    ///   - `.success(texture)`: the generated acceleration `MTLTexture`.
    ///   - `.unavailable(reason:)`: generation was not attempted due to device/library/initialization constraints.
    ///   - `.failed(error)`: generation was attempted but failed with the provided error.
    static func generateTexture(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        library: (any MTLLibrary)? = nil,
        dataset: VolumeDataset,
        logger: Logger
    ) -> GenerationResult {
        let accelerator: MPSEmptySpaceAccelerator
        switch Self.create(device: device, commandQueue: commandQueue, library: library) {
        case .success(let created):
            accelerator = created
        case .unavailable(let reason):
            switch reason {
            case .mpsUnsupportedOnDevice:
                logger.debug("MPS not supported on device '\(device.name)'; empty-space acceleration feature unavailable")
            case .commandQueueUnavailable:
                logger.error("Failed to resolve a Metal command queue while configuring the MPS accelerator on device '\(device.name)'")
            case .libraryUnavailable:
                logger.error("Required empty-space acceleration Metal library or kernels are unavailable on device '\(device.name)'")
            case .acceleratorInitializationFailed:
                logger.error("MPS accelerator initialization failed on device '\(device.name)' despite MPS support; unable to resolve command queue, shader library, or empty-space compute pipelines")
            }
            return .unavailable(reason: reason)
        }

        do {
            let structure = try accelerator.generateAccelerationStructure(dataset: dataset)
            let overhead = structure.memoryOverhead(relativeTo: dataset)
            logger.info("Generated acceleration structure: \(structure.mipLevels) mip levels, \(String(format: "%.1f%%", overhead * 100)) memory overhead")
            return .success(structure.texture)
        } catch {
            logger.error("Failed to generate acceleration structure: \(error.localizedDescription)")
            return .failed(error)
        }
    }
}
#endif
