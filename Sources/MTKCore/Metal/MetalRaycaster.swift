//
//  MetalRaycaster.swift
//  MTK
//
//  Facade over the Metal pipelines backing volume rendering and MPR.
//
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
import Metal
import OSLog
import simd
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif

/// Facade over Metal rendering pipelines for volumetric ray casting.
///
/// `MetalRaycaster` manages Metal pipeline states, textures, and command buffers for
/// high-performance volume rendering. It provides a simplified interface for:
/// - Fragment-based volume rendering (SceneKit integration)
/// - Compute-based volume rendering (standalone rendering)
/// - Dataset texture management
/// - Empty space acceleration structure generation
///
/// ## Overview
///
/// The raycaster maintains separate pipeline caches for fragment and compute rendering:
/// - **Fragment pipelines**: Used by SceneKit materials (``VolumeCubeMaterial``, ``MPRPlaneMaterial``)
/// - **Compute pipelines**: Used by compute-based renderers (DVR, MIP, MinIP)
///
/// ## Pipeline Caching
///
/// Pipelines are cached by configuration to avoid recompilation:
/// - Fragment: Keyed by (color format, depth format, sample count)
/// - Compute: Keyed by rendering technique
///
/// Use ``resetCaches()`` to clear all cached pipelines.
///
/// ## Usage
///
/// ```swift
/// let device = MTLCreateSystemDefaultDevice()!
/// let raycaster = try MetalRaycaster(device: device)
///
/// // Load dataset
/// let resources = try raycaster.load(dataset: dataset)
///
/// // Create fragment pipeline for SceneKit
/// let fragmentPipeline = try raycaster.makeFragmentPipeline(
///     colorPixelFormat: .bgra8Unorm,
///     depthPixelFormat: .depth32Float
/// )
///
/// // Create compute pipeline for standalone rendering
/// let computePipeline = try raycaster.makeComputePipeline(for: .dvr)
/// ```
///
/// ## Topics
///
/// ### Creating a Raycaster
/// - ``init(device:commandQueue:library:)``
///
/// ### Dataset Management
/// - ``prepare(dataset:texture:)``
/// - ``prepare(dataset:texture:includeAccelerationStructure:)``
/// - ``load(dataset:)``
/// - ``load(dataset:includeAccelerationStructure:)``
/// - ``loadBuiltinDataset(for:)``
/// - ``loadBuiltinDataset(for:includeAccelerationStructure:)``
///
/// ### Pipeline Creation
/// - ``makeFragmentPipeline(colorPixelFormat:depthPixelFormat:sampleCount:label:)``
/// - ``makeComputePipeline(for:label:)``
///
/// ### Acceleration
/// - ``prepareAccelerationStructure(dataset:)``
/// - ``isMetalPerformanceShadersAvailable``
///
/// ### Utilities
/// - ``makeCommandBuffer(label:)``
/// - ``makeFallbackImage(dataset:slice:)``
/// - ``resetCaches()``
///
/// ### Supporting Types
/// - ``Technique``
/// - ``DatasetResources``
/// - ``Error``
public final class MetalRaycaster {
    /// Volume rendering techniques supported by compute pipelines.
    public enum Technique: CaseIterable {
        /// Direct Volume Rendering (front-to-back alpha compositing).
        case dvr

        /// Maximum Intensity Projection.
        case mip

        /// Minimum Intensity Projection.
        case minip
    }

    /// GPU resources for a loaded volume dataset.
    ///
    /// Bundles the dataset with its Metal textures, dimensions, spacing, and optional
    /// acceleration structure.
    public struct DatasetResources {
        /// The source volume dataset.
        public let dataset: VolumeDataset

        /// Metal 3D texture containing the volume data.
        public let texture: any MTLTexture

        /// Volume dimensions in voxels (width, height, depth).
        public let dimensions: SIMD3<Int32>

        /// Voxel spacing in world units (x, y, z).
        public let spacing: SIMD3<Float>

        /// Optional empty space acceleration texture (MPS min-max pyramid).
        public let accelerationTexture: (any MTLTexture)?
    }

    /// Errors that can occur during raycaster initialization or operation.
    public enum Error: Swift.Error {
        /// Metal shader library could not be loaded.
        case libraryUnavailable

        /// Requested Metal function is missing from the shader library.
        case pipelineUnavailable(function: String)

        /// Metal command queue creation failed.
        case commandQueueUnavailable

        /// Dataset texture creation or loading failed.
        case datasetUnavailable

        /// Transfer function texture creation failed.
        case transferFunctionUnavailable

        /// Device does not support required Metal features (e.g., 3D textures).
        case unsupportedDevice
    }

    private struct FragmentSignature: Hashable {
        var color: MTLPixelFormat
        var depth: MTLPixelFormat
        var sampleCount: Int
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let library: any MTLLibrary
    private let logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "MetalRaycaster")
    private var fragmentCache: [FragmentSignature: any MTLRenderPipelineState] = [:]
    private var computeCache: [Technique: any MTLComputePipelineState] = [:]

    /// The currently loaded dataset and its GPU resources.
    ///
    /// Updated by ``load(dataset:)`` and ``loadBuiltinDataset(for:)`` methods.
    public private(set) var currentDataset: DatasetResources?

#if canImport(MetalPerformanceShaders)
    private let mpsAvailable: Bool
#else
    private let mpsAvailable = false
#endif

    /// Creates a new Metal raycaster for volume rendering.
    ///
    /// Initializes Metal resources including device, command queue, and shader library.
    /// Validates device capabilities and ensures 3D texture support.
    ///
    /// - Parameters:
    ///   - device: Metal device for GPU operations.
    ///   - commandQueue: Optional command queue. If `nil`, creates a new queue from the device.
    ///   - library: Optional Metal shader library. If `nil`, attempts to load in this order:
    ///     1. `MTK.metallib` from Bundle.module
    ///     2. Device's default library
    ///     3. Default library from Bundle.module (iOS 13+)
    ///
    /// - Throws:
    ///   - ``Error/unsupportedDevice`` if the device does not support 3D textures.
    ///   - ``Error/commandQueueUnavailable`` if command queue creation fails.
    ///   - ``Error/libraryUnavailable`` if no shader library can be loaded.
    ///
    /// ## Device Requirements
    ///
    /// The raycaster requires 3D texture support:
    /// - **iOS/tvOS**: Apple GPU family 3+ (A11 Bionic and later)
    /// - **macOS**: Mac GPU family 2+ (Apple Silicon or modern discrete GPUs)
    ///
    /// ## Metal Performance Shaders
    ///
    /// MPS availability is detected automatically via `MPSSupportsMTLDevice()`.
    /// When available, MPS enables:
    /// - Accelerated histogram calculation (``VolumeHistogramCalculator``)
    /// - Empty space skipping acceleration (``prepareAccelerationStructure(dataset:)``)
    ///
    /// ## Usage
    ///
    /// ```swift
    /// guard let device = MTLCreateSystemDefaultDevice() else {
    ///     fatalError("Metal not available")
    /// }
    ///
    /// do {
    ///     let raycaster = try MetalRaycaster(device: device)
    ///     print("MPS available: \(raycaster.isMetalPerformanceShadersAvailable)")
    /// } catch {
    ///     print("Failed to create raycaster: \(error)")
    /// }
    /// ```
    public init(device: any MTLDevice,
                commandQueue: (any MTLCommandQueue)? = nil,
                library: (any MTLLibrary)? = nil) throws {
        var supports3DTextures = false
#if os(iOS) || os(tvOS)
        if #available(iOS 13.0, tvOS 13.0, *) {
            supports3DTextures = device.supportsFamily(.apple3) || device.supportsFamily(.apple4) || device.supportsFamily(.apple5)
        } else {
            supports3DTextures = true
        }
#elseif os(macOS)
        if #available(macOS 11.0, *) {
            supports3DTextures = device.supportsFamily(.mac2)
        } else {
            supports3DTextures = true
        }
#else
        supports3DTextures = true
#endif

        if #available(iOS 13.0, tvOS 13.0, macOS 11.0, *) {
            supports3DTextures = supports3DTextures || device.supportsFamily(.apple4) || device.supportsFamily(.mac2)
        }

        guard supports3DTextures else {
            throw Error.unsupportedDevice
        }

        guard let queue = commandQueue ?? device.makeCommandQueue() else {
            throw Error.commandQueueUnavailable
        }

        let resolvedLibrary: (any MTLLibrary)?
        if let library {
            resolvedLibrary = library
        } else if let url = Bundle.module.url(forResource: "MTK", withExtension: "metallib"),
                  let lib = try? device.makeLibrary(URL: url) {
            resolvedLibrary = lib
        } else if let defaultLibrary = device.makeDefaultLibrary() {
            resolvedLibrary = defaultLibrary
        } else if #available(iOS 13.0, tvOS 13.0, macOS 11.0, *),
                  let bundleLibrary = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            resolvedLibrary = bundleLibrary
        } else {
            resolvedLibrary = nil
        }

        guard let resolvedLibrary else {
            throw Error.libraryUnavailable
        }

        self.device = device
        self.commandQueue = queue
        self.library = resolvedLibrary
#if canImport(MetalPerformanceShaders)
        self.mpsAvailable = MPSSupportsMTLDevice(device)
#endif
    }

    /// Whether Metal Performance Shaders (MPS) is available on this device.
    ///
    /// When `true`, MPS-accelerated features are enabled:
    /// - ``VolumeHistogramCalculator`` uses MPS histogram kernel
    /// - ``prepareAccelerationStructure(dataset:)`` generates MPS min-max pyramids
    ///
    /// MPS is available on:
    /// - iOS 10+, tvOS 10+, macOS 10.13+ with supported GPUs
    /// - Apple Silicon Macs
    public var isMetalPerformanceShadersAvailable: Bool { mpsAvailable }

    /// Creates a fragment-based rendering pipeline for SceneKit integration.
    ///
    /// Fragment pipelines are used by ``VolumeCubeMaterial`` and ``MPRPlaneMaterial``
    /// for rendering volumes within SceneKit scenes. Pipelines are cached by their
    /// configuration signature (color/depth format, sample count) to avoid recompilation.
    ///
    /// - Parameters:
    ///   - colorPixelFormat: Pixel format for the color attachment (e.g., `.bgra8Unorm`).
    ///   - depthPixelFormat: Pixel format for the depth attachment. Use `.invalid` for no depth.
    ///   - sampleCount: Number of MSAA samples (1 = no MSAA).
    ///   - label: Optional debug label for the pipeline state.
    ///
    /// - Returns: A configured `MTLRenderPipelineState` ready for use with SceneKit.
    ///
    /// - Throws: ``Error/pipelineUnavailable(function:)`` if required shader functions
    ///   (`volume_vertex`, `volume_fragment`) are missing from the library.
    ///
    /// ## Blending Configuration
    ///
    /// The pipeline enables alpha blending with:
    /// - RGB: `sourceAlpha + (1 - sourceAlpha) * destination`
    /// - Alpha: `sourceAlpha + (1 - sourceAlpha) * destination`
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Create pipeline matching SceneKit's drawable configuration
    /// let pipeline = try raycaster.makeFragmentPipeline(
    ///     colorPixelFormat: .bgra8Unorm,
    ///     depthPixelFormat: .depth32Float,
    ///     sampleCount: 4,  // 4x MSAA
    ///     label: "Volume Fragment Pipeline"
    /// )
    /// ```
    public func makeFragmentPipeline(colorPixelFormat: MTLPixelFormat,
                                     depthPixelFormat: MTLPixelFormat = .invalid,
                                     sampleCount: Int = 1,
                                     label: String? = nil) throws -> any MTLRenderPipelineState {
        let signature = FragmentSignature(color: colorPixelFormat,
                                          depth: depthPixelFormat,
                                          sampleCount: sampleCount)
        if let cached = fragmentCache[signature] {
            return cached
        }

        guard let vertexFunction = library.makeFunction(name: "volume_vertex") else {
            throw Error.pipelineUnavailable(function: "volume_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "volume_fragment") else {
            throw Error.pipelineUnavailable(function: "volume_fragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label ?? "VolumeRenderingKit.Volume.Fragment"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        if depthPixelFormat != .invalid {
            descriptor.depthAttachmentPixelFormat = depthPixelFormat
        }
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        fragmentCache[signature] = pipeline
        return pipeline
    }

    /// Creates a compute-based rendering pipeline for standalone volume rendering.
    ///
    /// Compute pipelines are used by ``MetalVolumeRenderingAdapter`` and ``MetalMPRAdapter``
    /// for offscreen rendering without SceneKit. Pipelines are cached by rendering technique
    /// to avoid recompilation.
    ///
    /// - Parameters:
    ///   - technique: The rendering technique to use (DVR, MIP, or MinIP).
    ///   - label: Optional debug label for the pipeline state.
    ///
    /// - Returns: A configured `MTLComputePipelineState` ready for compute encoding.
    ///
    /// - Throws: ``Error/pipelineUnavailable(function:)`` if the required kernel function
    ///   is missing from the shader library.
    ///
    /// ## Kernel Mapping
    ///
    /// - ``Technique/dvr`` → `dvrKernel` (Direct Volume Rendering)
    /// - ``Technique/mip`` → `slabKernel` (Maximum Intensity Projection)
    /// - ``Technique/minip`` → `slabKernel` (Minimum Intensity Projection)
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Create DVR pipeline
    /// let dvrPipeline = try raycaster.makeComputePipeline(
    ///     for: .dvr,
    ///     label: "DVR Compute Pipeline"
    /// )
    ///
    /// // Create MIP pipeline
    /// let mipPipeline = try raycaster.makeComputePipeline(for: .mip)
    /// ```
    public func makeComputePipeline(for technique: Technique,
                                    label: String? = nil) throws -> any MTLComputePipelineState {
        if let cached = computeCache[technique] {
            return cached
        }

        let functionName: String
        switch technique {
        case .dvr:
            functionName = "dvrKernel"
        case .mip, .minip:
            functionName = "slabKernel"
        }

        guard let function = library.makeFunction(name: functionName) else {
            throw Error.pipelineUnavailable(function: functionName)
        }

        let pipeline = try device.makeComputePipelineState(function: function)
        computeCache[technique] = pipeline
        return pipeline
    }

    /// Prepares GPU texture resources for a volume dataset without acceleration structure.
    ///
    /// This method creates or registers a Metal 3D texture for the dataset and returns
    /// a ``DatasetResources`` bundle containing the texture, dimensions, spacing, and dataset.
    ///
    /// - Parameters:
    ///   - dataset: The volume dataset to prepare.
    ///   - texture: Optional pre-created 3D texture. If `nil`, a texture is generated automatically.
    ///
    /// - Returns: A ``DatasetResources`` bundle with `accelerationTexture` set to `nil`.
    ///
    /// - Throws: ``Error/datasetUnavailable`` if texture creation fails.
    ///
    /// ## Automatic Texture Creation
    ///
    /// When `texture` is `nil`, the method uses ``VolumeTextureFactory`` to create a Metal
    /// 3D texture from the dataset's pixel data. The texture format depends on ``VolumePixelFormat``:
    /// - `.int16Signed` → `.r16Sint`
    /// - `.int16Unsigned` → `.r16Uint`
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Automatic texture creation
    /// let resources = try raycaster.prepare(dataset: dataset)
    ///
    /// // Use existing texture
    /// let customTexture = device.makeTexture(descriptor: descriptor)!
    /// let resources = try raycaster.prepare(dataset: dataset, texture: customTexture)
    /// ```
    ///
    /// - SeeAlso: ``prepare(dataset:texture:includeAccelerationStructure:)`` for acceleration structure support.
    public func prepare(dataset: VolumeDataset,
                        texture: (any MTLTexture)? = nil) throws -> DatasetResources {
        try prepare(dataset: dataset,
                    texture: texture,
                    includeAccelerationStructure: false)
    }

    /// Prepares GPU texture resources for a volume dataset with optional acceleration structure.
    ///
    /// This is the most flexible preparation method, allowing control over both texture
    /// creation and empty space acceleration structure generation.
    ///
    /// - Parameters:
    ///   - dataset: The volume dataset to prepare.
    ///   - texture: Optional pre-created 3D texture. If `nil`, a texture is generated automatically.
    ///   - includeAccelerationStructure: Whether to generate an MPS min-max pyramid for empty space skipping.
    ///
    /// - Returns: A ``DatasetResources`` bundle with optional `accelerationTexture`.
    ///
    /// - Throws: ``Error/datasetUnavailable`` if texture creation fails.
    ///
    /// ## Acceleration Structure
    ///
    /// When `includeAccelerationStructure` is `true`:
    /// - Calls ``prepareAccelerationStructure(dataset:)`` to generate MPS min-max pyramid
    /// - Returns `nil` for `accelerationTexture` if MPS is unavailable
    /// - One-time cost: ~10-50ms depending on dataset size
    /// - Performance benefit: 30%+ speedup for sparse volumes (CT scans with large air regions)
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Prepare with acceleration for sparse datasets
    /// let resources = try raycaster.prepare(
    ///     dataset: dataset,
    ///     includeAccelerationStructure: true
    /// )
    ///
    /// if let accelTexture = resources.accelerationTexture {
    ///     print("Acceleration structure ready: \(accelTexture.width)x\(accelTexture.height)x\(accelTexture.depth)")
    /// }
    /// ```
    ///
    /// - SeeAlso: ``prepareAccelerationStructure(dataset:)`` for detailed acceleration structure documentation.
    public func prepare(dataset: VolumeDataset,
                        texture: (any MTLTexture)? = nil,
                        includeAccelerationStructure: Bool) throws -> DatasetResources {
        let factory = VolumeTextureFactory(dataset: dataset)
        guard let texture = texture ?? factory.generate(device: device) else {
            throw Error.datasetUnavailable
        }

        let accelerationTexture = includeAccelerationStructure
            ? prepareAccelerationStructure(dataset: dataset)
            : nil

        let resources = DatasetResources(
            dataset: dataset,
            texture: texture,
            dimensions: factory.dimension,
            spacing: factory.resolution,
            accelerationTexture: accelerationTexture
        )
        currentDataset = resources
        return resources
    }

    /// Loads a volume dataset and prepares GPU texture resources.
    ///
    /// Convenience method that calls ``prepare(dataset:texture:)`` with automatic
    /// texture creation and updates ``currentDataset``.
    ///
    /// - Parameter dataset: The volume dataset to load.
    ///
    /// - Returns: A ``DatasetResources`` bundle without acceleration structure.
    ///
    /// - Throws: ``Error/datasetUnavailable`` if texture creation fails.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let dicomLoader = DicomVolumeLoader(...)
    /// let dataset = try dicomLoader.loadSeries(at: url)
    ///
    /// let resources = try raycaster.load(dataset: dataset)
    /// print("Loaded \(resources.dimensions) volume")
    /// ```
    ///
    /// - SeeAlso: ``load(dataset:includeAccelerationStructure:)`` for acceleration structure support.
    @discardableResult
    public func load(dataset: VolumeDataset) throws -> DatasetResources {
        try prepare(dataset: dataset,
                    texture: nil,
                    includeAccelerationStructure: false)
    }

    /// Loads a volume dataset with optional acceleration structure generation.
    ///
    /// Convenience method that calls ``prepare(dataset:texture:includeAccelerationStructure:)``
    /// with automatic texture creation and updates ``currentDataset``.
    ///
    /// - Parameters:
    ///   - dataset: The volume dataset to load.
    ///   - includeAccelerationStructure: Whether to generate empty space acceleration.
    ///
    /// - Returns: A ``DatasetResources`` bundle with optional acceleration texture.
    ///
    /// - Throws: ``Error/datasetUnavailable`` if texture creation fails.
    ///
    /// ## Performance Impact
    ///
    /// Enabling acceleration structure adds ~10-50ms to load time but can improve
    /// rendering performance by 30%+ for sparse volumes (e.g., CT chest scans with
    /// large air regions).
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Load with acceleration for CT scans
    /// let resources = try raycaster.load(
    ///     dataset: ctDataset,
    ///     includeAccelerationStructure: true
    /// )
    ///
    /// // Load without acceleration for dense MR volumes
    /// let resources = try raycaster.load(
    ///     dataset: mrDataset,
    ///     includeAccelerationStructure: false
    /// )
    /// ```
    @discardableResult
    public func load(dataset: VolumeDataset,
                     includeAccelerationStructure: Bool) throws -> DatasetResources {
        try prepare(dataset: dataset,
                    texture: nil,
                    includeAccelerationStructure: includeAccelerationStructure)
    }

    /// Generates an MPS-accelerated empty space skipping structure for a dataset.
    ///
    /// Creates a hierarchical min-max pyramid texture that enables efficient ray marching
    /// by skipping transparent regions without sampling the transfer function at every step.
    ///
    /// - Parameter dataset: The source volume dataset.
    ///
    /// - Returns: An `MTLTexture` containing the acceleration structure, or `nil` if MPS
    ///   is unavailable or generation fails.
    ///
    /// ## How It Works
    ///
    /// The acceleration structure is a 3D mipmap pyramid in `rg16Float` format where:
    /// - **R channel**: Minimum intensity in the region
    /// - **G channel**: Maximum intensity in the region
    /// - **Mip levels**: Up to 8 levels (1→1/2→1/4→...→1/128)
    ///
    /// During ray marching, the shader queries the pyramid at the current step's mip level.
    /// If the transfer function opacity is zero for the entire intensity range `[min, max]`,
    /// the ray advances with 2× step size.
    ///
    /// ## Performance Characteristics
    ///
    /// - **Generation time**: ~10-50ms (one-time cost at dataset load)
    /// - **Memory overhead**: ~228% of source data size (rg16Float + pyramid levels)
    /// - **Speedup**: 30%+ for sparse volumes, minimal overhead for dense volumes
    ///
    /// ## MPS Availability
    ///
    /// Returns `nil` when MPS is unavailable:
    /// - macOS < 10.13
    /// - Non-Apple GPUs on macOS
    /// - iOS Simulator (Intel Macs)
    ///
    /// ## Usage
    ///
    /// ```swift
    /// if let accelTexture = raycaster.prepareAccelerationStructure(dataset: dataset) {
    ///     // Pass to compute kernel via argument buffer
    ///     encoder.setTexture(accelTexture, index: accelerationTextureIndex)
    /// } else {
    ///     print("MPS unavailable, using fallback ray marching")
    /// }
    /// ```
    ///
    /// - Note: The acceleration structure is automatically used by ``MetalVolumeRenderingAdapter``
    ///   when available. Manual integration is only needed for custom rendering pipelines.
    ///
    /// - SeeAlso: ``isMetalPerformanceShadersAvailable`` to check MPS availability before calling.
    public func prepareAccelerationStructure(dataset: VolumeDataset) -> (any MTLTexture)? {
#if canImport(MetalPerformanceShaders)
        guard mpsAvailable else {
            logger.debug("MPS unavailable, skipping acceleration structure generation")
            return nil
        }
        return MPSEmptySpaceAccelerator.generateTexture(device: device,
                                                        commandQueue: commandQueue,
                                                        library: library,
                                                        dataset: dataset,
                                                        logger: logger)
#else
        logger.debug("MetalPerformanceShaders not available on this platform")
        return nil
#endif
    }

    /// Loads a built-in synthetic volume dataset for testing and development.
    ///
    /// MTK includes procedurally generated test datasets for:
    /// - Sphere primitive
    /// - Cube primitive
    /// - Gradient patterns
    /// - Noise patterns
    ///
    /// - Parameter preset: The built-in dataset preset to load.
    ///
    /// - Returns: A ``DatasetResources`` bundle without acceleration structure.
    ///
    /// - Throws: ``Error/datasetUnavailable`` if texture creation fails.
    ///
    /// ## Available Presets
    ///
    /// See ``VolumeDatasetPreset`` for the complete list of built-in datasets.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Load sphere for testing ray marching
    /// let sphereResources = try raycaster.loadBuiltinDataset(for: .sphere)
    ///
    /// // Load gradient for transfer function testing
    /// let gradientResources = try raycaster.loadBuiltinDataset(for: .gradient)
    /// ```
    ///
    /// - SeeAlso: ``loadBuiltinDataset(for:includeAccelerationStructure:)`` for acceleration structure support.
    @discardableResult
    public func loadBuiltinDataset(for preset: VolumeDatasetPreset) throws -> DatasetResources {
        try loadBuiltinDataset(for: preset, includeAccelerationStructure: false)
    }

    /// Loads a built-in synthetic volume dataset with optional acceleration structure.
    ///
    /// Extended version of ``loadBuiltinDataset(for:)`` that supports acceleration structure
    /// generation for performance testing.
    ///
    /// - Parameters:
    ///   - preset: The built-in dataset preset to load.
    ///   - includeAccelerationStructure: Whether to generate empty space acceleration.
    ///
    /// - Returns: A ``DatasetResources`` bundle with optional acceleration texture.
    ///
    /// - Throws: ``Error/datasetUnavailable`` if texture creation fails.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Load sphere with acceleration for performance testing
    /// let resources = try raycaster.loadBuiltinDataset(
    ///     for: .sphere,
    ///     includeAccelerationStructure: true
    /// )
    ///
    /// // Measure rendering performance with/without acceleration
    /// let withAccel = benchmark { render(resources) }
    /// let withoutAccel = benchmark {
    ///     var res = resources
    ///     res.accelerationTexture = nil
    ///     render(res)
    /// }
    /// ```
    @discardableResult
    public func loadBuiltinDataset(for preset: VolumeDatasetPreset,
                                   includeAccelerationStructure: Bool) throws -> DatasetResources {
        let factory = VolumeTextureFactory(preset: preset)
        guard let texture = factory.generate(device: device) else {
            logger.error("Failed to create built-in dataset for preset: \(preset.rawValue)")
            throw Error.datasetUnavailable
        }

        let accelerationTexture = includeAccelerationStructure
            ? prepareAccelerationStructure(dataset: factory.dataset)
            : nil

        let resources = DatasetResources(
            dataset: factory.dataset,
            texture: texture,
            dimensions: factory.dimension,
            spacing: factory.resolution,
            accelerationTexture: accelerationTexture
        )
        currentDataset = resources
        return resources
    }

    /// Generates a CPU-based grayscale slice image for preview or fallback rendering.
    ///
    /// Creates a 2D image by extracting a single axial slice from the volume.
    /// Intensity values are normalized to the dataset's intensity range and mapped
    /// to 8-bit grayscale.
    ///
    /// - Parameters:
    ///   - dataset: The source volume dataset.
    ///   - index: The slice index (Z coordinate) to extract. If `nil`, uses the middle slice.
    ///
    /// - Returns: A `CGImage` containing the grayscale slice, or `nil` if image creation fails
    ///   or CoreGraphics is unavailable.
    ///
    /// ## Performance
    ///
    /// Fallback image generation is CPU-based and relatively slow:
    /// - 256×256 slice: ~1-2ms
    /// - 512×512 slice: ~5-10ms
    /// - 1024×1024 slice: ~20-40ms
    ///
    /// For interactive rendering, use GPU-accelerated ``makeFragmentPipeline(colorPixelFormat:depthPixelFormat:sampleCount:label:)``
    /// or ``makeComputePipeline(for:label:)`` instead.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Generate middle slice
    /// if let preview = raycaster.makeFallbackImage(dataset: dataset) {
    ///     imageView.image = UIImage(cgImage: preview)
    /// }
    ///
    /// // Generate specific slice
    /// if let slice = raycaster.makeFallbackImage(dataset: dataset, slice: 100) {
    ///     imageView.image = UIImage(cgImage: slice)
    /// }
    /// ```
    ///
    /// - Note: This method is primarily used for testing, debugging, and situations where
    ///   GPU rendering is unavailable.
    public func makeFallbackImage(dataset: VolumeDataset,
                                  slice index: Int? = nil) -> CGImage? {
#if canImport(CoreGraphics)
        let width = dataset.dimensions.width
        let height = dataset.dimensions.height
        let depth = dataset.dimensions.depth
        let sliceIndex = max(0, min(index ?? depth / 2, depth - 1))
        let voxelsPerSlice = width * height
        var pixels = [UInt8](repeating: 0, count: voxelsPerSlice)
        let minValue = dataset.intensityRange.lowerBound
        let maxValue = dataset.intensityRange.upperBound
        let span = max(maxValue - minValue, 1)

        let startOffset = sliceIndex * voxelsPerSlice

        return dataset.data.withUnsafeBytes { rawBuffer -> CGImage? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            switch dataset.pixelFormat {
            case .int16Signed:
                let typed = baseAddress.bindMemory(to: Int16.self, capacity: dataset.voxelCount)
                for voxel in 0..<voxelsPerSlice {
                    let value = Int32(typed[startOffset + voxel])
                    let normalized = Float(value - minValue) / Float(span)
                    let clamped = simd_clamp(normalized, 0, 1)
                    pixels[voxel] = UInt8(clamping: Int(clamped * 255))
                }
            case .int16Unsigned:
                let typed = baseAddress.bindMemory(to: UInt16.self, capacity: dataset.voxelCount)
                for voxel in 0..<voxelsPerSlice {
                    let value = Int32(typed[startOffset + voxel])
                    let normalized = Float(value - minValue) / Float(span)
                    let clamped = simd_clamp(normalized, 0, 1)
                    pixels[voxel] = UInt8(clamping: Int(clamped * 255))
                }
            }

            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            let colorSpace = CGColorSpaceCreateDeviceGray()
            return CGImage(width: width,
                           height: height,
                           bitsPerComponent: 8,
                           bitsPerPixel: 8,
                           bytesPerRow: width,
                           space: colorSpace,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: provider,
                           decode: nil,
                           shouldInterpolate: false,
                           intent: .defaultIntent)
        }
#else
        return nil
#endif
    }

    /// Creates a new Metal command buffer for encoding GPU work.
    ///
    /// Convenience method for creating command buffers from the raycaster's internal
    /// command queue with optional debug labeling.
    ///
    /// - Parameter label: Optional debug label for the command buffer. Defaults to
    ///   `"VolumeRenderingKit.CommandBuffer"`.
    ///
    /// - Returns: A new `MTLCommandBuffer`, or `nil` if command buffer creation fails.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// guard let commandBuffer = raycaster.makeCommandBuffer(label: "Volume Render Pass") else {
    ///     throw RenderError.commandBufferUnavailable
    /// }
    ///
    /// // Encode rendering work
    /// let encoder = commandBuffer.makeComputeCommandEncoder()
    /// encoder?.setComputePipelineState(pipeline)
    /// // ... encode commands ...
    /// encoder?.endEncoding()
    ///
    /// commandBuffer.commit()
    /// commandBuffer.waitUntilCompleted()
    /// ```
    ///
    /// - Note: Command buffers must be committed before work is executed. Use `commit()`
    ///   to submit to the GPU and optionally `waitUntilCompleted()` for synchronous execution.
    public func makeCommandBuffer(label: String? = nil) -> (any MTLCommandBuffer)? {
        let commandBuffer = commandQueue.makeCommandBuffer()
        commandBuffer?.label = label ?? "VolumeRenderingKit.CommandBuffer"
        return commandBuffer
    }

    /// Clears all cached pipeline states.
    ///
    /// Removes all cached fragment and compute pipelines, forcing recompilation on next use.
    /// Cache capacity is preserved to avoid memory churn.
    ///
    /// ## When to Call
    ///
    /// - After updating shader library or Metal functions
    /// - When switching between many different pipeline configurations
    /// - To free memory in low-memory situations
    /// - For testing pipeline compilation paths
    ///
    /// ## Performance Impact
    ///
    /// Clearing caches forces pipeline recompilation:
    /// - Fragment pipeline compilation: ~5-20ms
    /// - Compute pipeline compilation: ~10-30ms
    ///
    /// Pipelines are automatically re-cached on next use.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Clear caches after shader modification
    /// raycaster.resetCaches()
    ///
    /// // Next pipeline creation will recompile
    /// let pipeline = try raycaster.makeFragmentPipeline(
    ///     colorPixelFormat: .bgra8Unorm
    /// )
    /// ```
    public func resetCaches() {
        fragmentCache.removeAll(keepingCapacity: true)
        computeCache.removeAll(keepingCapacity: true)
    }
}
