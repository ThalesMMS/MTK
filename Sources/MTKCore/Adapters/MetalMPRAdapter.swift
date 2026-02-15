//
//  MetalMPRAdapter.swift
//  MetalVolumetrics
//
//  Multi-planar reconstruction adapter with GPU acceleration and CPU fallback.
//  Leverages Metal compute shaders for high-performance slab generation when
//  available, while maintaining a robust CPU reference implementation for
//  compatibility and testing.
//
//  Thales Matheus Mendonça Santos — February 2026

import Foundation
import Metal
import OSLog
import simd

/// Multi-planar reconstruction (MPR) adapter with GPU acceleration and CPU fallback.
///
/// `MetalMPRAdapter` provides high-performance orthogonal and oblique slice extraction
/// from volumetric datasets. It automatically selects between GPU-accelerated Metal
/// compute shaders and CPU-based reference implementation depending on device
/// capabilities and configuration.
///
/// ## Overview
///
/// The adapter implements the ``MPRReslicePort`` protocol, providing:
/// - Orthogonal slicing (axial, sagittal, coronal)
/// - Oblique multi-planar reconstruction
/// - Slab generation with multiple blend modes (maximum, minimum, average)
/// - GPU acceleration via Metal compute shaders
/// - Automatic CPU fallback for compatibility
///
/// ## GPU vs CPU Performance
///
/// Typical slab generation times (512×512 slice, 5mm thickness, 10 steps):
/// - GPU: ~2-5ms
/// - CPU: ~50-150ms
///
/// ## Usage
///
/// ```swift
/// // Basic CPU-only adapter
/// let adapter = MetalMPRAdapter()
///
/// // GPU-accelerated adapter
/// let device = MTLCreateSystemDefaultDevice()!
/// let gpuAdapter = MetalMPRAdapter(device: device)
///
/// // Generate axial slice
/// let plane = MPRPlaneGeometry.axial(
///     at: dataset.dimensions.depth / 2,
///     dataset: dataset
/// )
///
/// let slice = try await adapter.makeSlab(
///     dataset: dataset,
///     plane: plane,
///     thickness: 5,
///     steps: 10,
///     blend: .maximum
/// )
/// ```
///
/// ## Topics
///
/// ### Creating an Adapter
/// - ``init()``
/// - ``init(device:commandQueue:library:debugOptions:)``
///
/// ### Slicing
/// - ``makeSlab(dataset:plane:thickness:steps:blend:)``
///
/// ### Configuration
/// - ``send(_:)``
/// - ``setForceCPU(_:)``
///
/// ### Supporting Types
/// - ``Overrides``
/// - ``SliceSnapshot``
@preconcurrency
public actor MetalMPRAdapter: MPRReslicePort {
    /// Parameter overrides for MPR slice generation.
    ///
    /// Overrides set via ``send(_:)`` persist until the next ``makeSlab(dataset:plane:thickness:steps:blend:)``
    /// call, where they are applied and then cleared.
    public struct Overrides: Equatable {
        /// Override blend mode for the next slab generation.
        var blend: MPRBlendMode?

        /// Override slab thickness (in voxels) for the next slab generation.
        var slabThickness: Int?

        /// Override number of sampling steps for the next slab generation.
        var slabSteps: Int?
    }

    /// Snapshot of the most recent slice generation.
    ///
    /// Captures parameters and results from the last ``makeSlab(dataset:plane:thickness:steps:blend:)`` call.
    /// Useful for debugging and validating MPR state.
    public struct SliceSnapshot: Equatable {
        /// The dominant anatomical axis of the slice (axial, sagittal, or coronal).
        var axis: MPRPlaneAxis

        /// Actual intensity range found in the generated slice.
        var intensityRange: ClosedRange<Int32>

        /// Blend mode used for slab generation.
        var blend: MPRBlendMode

        /// Slab thickness in voxels.
        var thickness: Int

        /// Number of sampling steps used.
        var steps: Int
    }

    private var overrides = Overrides()
    private var lastSnapshot: SliceSnapshot?

    // GPU acceleration
    private var gpuAdapter: MetalMPRComputeAdapter?
    private var forceCPU: Bool = false
    private let logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "MetalMPRAdapter")

    /// Creates a new MPR adapter with CPU-only rendering.
    ///
    /// This initializer creates an adapter that uses the CPU reference implementation
    /// for all slice generation. To enable GPU acceleration, use
    /// ``init(device:commandQueue:library:debugOptions:)`` instead.
    public init() {}

    /// Creates a new MPR adapter with GPU acceleration.
    ///
    /// This initializer configures the adapter to use Metal compute shaders for high-performance
    /// slice generation. If Metal resources cannot be initialized, the adapter automatically
    /// falls back to CPU rendering.
    ///
    /// - Parameters:
    ///   - device: Metal device for GPU compute operations.
    ///   - commandQueue: Optional command queue. If `nil`, a new queue is created from the device.
    ///   - library: Optional Metal shader library. If `nil`, loads `MTK.metallib` or the default library.
    ///   - debugOptions: Debug configuration options for logging and validation.
    ///
    /// ## GPU Initialization
    ///
    /// The adapter initializes a ``MetalMPRComputeAdapter`` with:
    /// - Feature flags evaluated from device capabilities
    /// - MPR-specific Metal compute kernels (`mprKernel`, `mprSlabKernel`)
    /// - Argument buffers for efficient parameter passing
    ///
    /// ## Fallback Behavior
    ///
    /// If GPU initialization fails (e.g., command queue or library unavailable),
    /// the adapter logs a warning and falls back to CPU rendering for all operations.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// guard let device = MTLCreateSystemDefaultDevice() else {
    ///     // No GPU available, use init() for CPU-only
    ///     return MetalMPRAdapter()
    /// }
    ///
    /// let adapter = MetalMPRAdapter(device: device)
    /// ```
    public init(device: any MTLDevice,
                commandQueue: (any MTLCommandQueue)? = nil,
                library: (any MTLLibrary)? = nil,
                debugOptions: VolumeRenderingDebugOptions = VolumeRenderingDebugOptions()) {
        let queue = commandQueue ?? device.makeCommandQueue()
        let lib = library ?? ShaderLibraryLoader.makeDefaultLibrary(on: device) { message in
            Logger(subsystem: "com.mtk.volumerendering", category: "ShaderLoader").info("\(message)")
        }

        if let queue = queue, let lib = lib {
            let featureFlags = FeatureFlags.evaluate(for: device)
            self.gpuAdapter = MetalMPRComputeAdapter(
                device: device,
                commandQueue: queue,
                library: lib,
                featureFlags: featureFlags,
                debugOptions: debugOptions
            )
            logger.info("MetalMPRAdapter initialized with GPU acceleration")
        } else {
            logger.warning("MetalMPRAdapter: Failed to initialize GPU adapter, using CPU fallback")
        }
    }

    /// Generates a 2D slice or slab from a volumetric dataset.
    ///
    /// This is the primary MPR method. It extracts a 2D cross-section from a 3D volume
    /// along an arbitrary plane, optionally averaging/blending multiple parallel slices
    /// for reduced noise (slab mode).
    ///
    /// - Parameters:
    ///   - dataset: The source volumetric dataset.
    ///   - plane: Geometry defining the slice plane's position and orientation in volume space.
    ///   - thickness: Slab thickness in voxels. Use 0 or 1 for a single slice.
    ///   - steps: Number of parallel slices to sample within the slab thickness. Use 1 for single slice.
    ///   - blend: Blending mode for combining multiple slab samples (maximum, minimum, average, single).
    ///
    /// - Returns: An ``MPRSlice`` containing the extracted 2D image data and metadata.
    ///
    /// - Throws: Errors from GPU operations (e.g., texture creation failure, kernel execution errors).
    ///   CPU fallback does not throw errors but may return empty slices if geometry is invalid.
    ///
    /// ## Rendering Path Selection
    ///
    /// The adapter attempts GPU rendering first when:
    /// - GPU adapter is initialized (via ``init(device:commandQueue:library:debugOptions:)``)
    /// - CPU rendering is not forced (via ``setForceCPU(_:)``)
    ///
    /// If GPU rendering fails, the adapter automatically falls back to CPU rendering and logs
    /// the error and fallback time.
    ///
    /// ## Parameter Overrides
    ///
    /// Overrides set via ``send(_:)`` are applied in this order:
    /// 1. Blend mode (override → parameter)
    /// 2. Thickness (override → parameter, then sanitized to ≥0)
    /// 3. Steps (override → parameter, then sanitized to ≥1)
    ///
    /// Overrides are cleared after each call.
    ///
    /// ## Performance
    ///
    /// Typical slice generation times (512×512 output, 5mm thickness, 10 steps):
    /// - GPU: ~2-5ms
    /// - CPU: ~50-150ms (depends on CPU cores and dataset size)
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Single axial slice at Z = 128
    /// let plane = MPRPlaneGeometry.axial(at: 128, dataset: dataset)
    /// let slice = try await adapter.makeSlab(
    ///     dataset: dataset,
    ///     plane: plane,
    ///     thickness: 1,
    ///     steps: 1,
    ///     blend: .single
    /// )
    ///
    /// // 10mm slab with MIP (maximum intensity projection)
    /// let slabPlane = MPRPlaneGeometry.axial(at: 128, dataset: dataset)
    /// let slab = try await adapter.makeSlab(
    ///     dataset: dataset,
    ///     plane: slabPlane,
    ///     thickness: 10,
    ///     steps: 20,
    ///     blend: .maximum
    /// )
    /// ```
    public func makeSlab(dataset: VolumeDataset,
                         plane: MPRPlaneGeometry,
                         thickness: Int,
                         steps: Int,
                         blend: MPRBlendMode) async throws -> MPRSlice {
        let effectiveBlend = overrides.blend ?? blend
        let effectiveThickness = VolumetricMath.sanitizeThickness(overrides.slabThickness ?? thickness)
        let effectiveSteps = VolumetricMath.sanitizeSteps(overrides.slabSteps ?? steps)

        // Try GPU path first if available and not forced to CPU
        if shouldUseGPU(for: dataset) {
            let startTime = CFAbsoluteTimeGetCurrent()
            do {
                let slice = try await gpuAdapter!.makeSlab(
                    dataset: dataset,
                    plane: plane,
                    thickness: effectiveThickness,
                    steps: effectiveSteps,
                    blend: effectiveBlend
                )

                let duration = CFAbsoluteTimeGetCurrent() - startTime
                logger.info("MPR slab generation completed via GPU path: \(String(format: "%.2f", duration * 1000))ms blend=\(effectiveBlend) thickness=\(effectiveThickness) steps=\(effectiveSteps)")

                let axis = Self.dominantAxis(for: plane)
                lastSnapshot = SliceSnapshot(axis: axis,
                                             intensityRange: slice.intensityRange,
                                             blend: effectiveBlend,
                                             thickness: effectiveThickness,
                                             steps: effectiveSteps)

                overrides.blend = nil
                overrides.slabThickness = nil
                overrides.slabSteps = nil

                return slice
            } catch {
                let duration = CFAbsoluteTimeGetCurrent() - startTime
                logger.warning("GPU slab generation failed after \(String(format: "%.2f", duration * 1000))ms: \(error.localizedDescription), falling back to CPU")
            }
        }

        // CPU fallback path
        let startTime = CFAbsoluteTimeGetCurrent()
        let slice = try await makeSlabOnCPU(
            dataset: dataset,
            plane: plane,
            thickness: effectiveThickness,
            steps: effectiveSteps,
            blend: effectiveBlend
        )

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        logger.info("MPR slab generation completed via CPU path: \(String(format: "%.2f", duration * 1000))ms blend=\(effectiveBlend) thickness=\(effectiveThickness) steps=\(effectiveSteps)")

        let axis = Self.dominantAxis(for: plane)
        lastSnapshot = SliceSnapshot(axis: axis,
                                     intensityRange: slice.intensityRange,
                                     blend: effectiveBlend,
                                     thickness: effectiveThickness,
                                     steps: effectiveSteps)

        overrides.blend = nil
        overrides.slabThickness = nil
        overrides.slabSteps = nil

        return slice
    }

    /// Sends an MPR command to update slice generation parameters.
    ///
    /// Commands set persistent overrides that apply to the next ``makeSlab(dataset:plane:thickness:steps:blend:)``
    /// call. Overrides are cleared after being applied.
    ///
    /// - Parameter command: The command to execute.
    ///
    /// - Throws: Commands are forwarded to the GPU adapter if available, which may throw
    ///   errors during parameter validation or state updates.
    ///
    /// ## Available Commands
    ///
    /// - ``MPRResliceCommand/setBlend(_:)`` - Override blend mode for next slab
    /// - ``MPRResliceCommand/setSlab(_:_:)`` - Override slab thickness and steps for next slab
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Change blend mode to maximum intensity
    /// try await adapter.send(.setBlend(.maximum))
    ///
    /// // Next makeSlab call will use maximum blend
    /// let slice = try await adapter.makeSlab(
    ///     dataset: dataset,
    ///     plane: plane,
    ///     thickness: 5,
    ///     steps: 10,
    ///     blend: .average  // Overridden to .maximum
    /// )
    ///
    /// // Override slab parameters
    /// try await adapter.send(.setSlab(thickness: 10, steps: 20))
    /// ```
    public func send(_ command: MPRResliceCommand) async throws {
        // Forward to GPU adapter if available
        if let adapter = gpuAdapter {
            try await adapter.send(command)
        }

        // Also update local overrides for CPU fallback
        switch command {
        case .setBlend(let mode):
            overrides.blend = mode
        case .setSlab(let thickness, let steps):
            overrides.slabThickness = VolumetricMath.sanitizeThickness(thickness)
            overrides.slabSteps = VolumetricMath.sanitizeSteps(steps)
        }
    }

    /// Forces CPU rendering path for testing or compatibility.
    ///
    /// When enabled, all ``makeSlab(dataset:plane:thickness:steps:blend:)`` calls use the
    /// CPU reference implementation, even if GPU acceleration is available.
    ///
    /// - Parameter force: Whether to force CPU rendering.
    ///
    /// ## Use Cases
    ///
    /// - **Testing**: Validate CPU and GPU paths produce identical results
    /// - **Compatibility**: Work around GPU driver bugs or unsupported features
    /// - **Profiling**: Measure CPU vs GPU performance
    /// - **Debugging**: Isolate GPU-specific issues
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Enable CPU-only rendering
    /// adapter.setForceCPU(true)
    ///
    /// // All subsequent makeSlab calls use CPU
    /// let slice = try await adapter.makeSlab(...)
    ///
    /// // Re-enable GPU acceleration
    /// adapter.setForceCPU(false)
    /// ```
    public func setForceCPU(_ force: Bool) {
        forceCPU = force
        if force {
            logger.info("Forcing CPU rendering path")
        } else if gpuAdapter != nil {
            logger.info("GPU rendering path enabled")
        }
    }
}

// MARK: - Testing SPI

extension MetalMPRAdapter {
    @_spi(Testing)
    public var debugOverrides: Overrides { overrides }

    @_spi(Testing)
    public var debugLastSnapshot: SliceSnapshot? { lastSnapshot }

    @_spi(Testing)
    public var debugGPUAvailable: Bool { gpuAdapter != nil }

    @_spi(Testing)
    public var debugForceCPU: Bool { forceCPU }
}

// MARK: - GPU/CPU Path Selection

private extension MetalMPRAdapter {
    /// Determines whether to use GPU compute path based on availability and configuration
    func shouldUseGPU(for dataset: VolumeDataset) -> Bool {
        guard !forceCPU else { return false }
        guard gpuAdapter != nil else { return false }
        return true
    }

    /// CPU-based slab generation (reference implementation)
    func makeSlabOnCPU(dataset: VolumeDataset,
                       plane: MPRPlaneGeometry,
                       thickness: Int,
                       steps: Int,
                       blend: MPRBlendMode) async throws -> MPRSlice {
        try await Task.detached(priority: .userInitiated) {
            dataset.data.withUnsafeBytes { buffer -> MPRSlice in
                guard let reader = VolumeDataReader(dataset: dataset, buffer: buffer) else {
                    return Self.emptySlice(dataset: dataset)
                }

                let (width, height) = Self.sliceDimensions(for: plane)
                let bytesPerPixel = dataset.pixelFormat.bytesPerVoxel
                var pixels = Data(count: width * height * bytesPerPixel)

                let normal = Self.normalVector(for: plane, dataset: dataset)
                let offsets = Self.sampleOffsets(thickness: thickness, steps: steps)

                pixels.withUnsafeMutableBytes { rawBuffer in
                    switch dataset.pixelFormat {
                    case .int16Signed:
                        let pointer = rawBuffer.bindMemory(to: Int16.self)
                        Self.populateSlice(into: pointer,
                                           width: width,
                                           height: height,
                                           reader: reader,
                                           plane: plane,
                                           normal: normal,
                                           offsets: offsets,
                                           blend: blend,
                                           intensityRange: dataset.intensityRange)
                    case .int16Unsigned:
                        let pointer = rawBuffer.bindMemory(to: UInt16.self)
                        Self.populateSlice(into: pointer,
                                           width: width,
                                           height: height,
                                           reader: reader,
                                           plane: plane,
                                           normal: normal,
                                           offsets: offsets,
                                           blend: blend,
                                           intensityRange: dataset.intensityRange)
                    }
                }

                let pixelSpacing = Self.pixelSpacing(for: plane,
                                                     width: width,
                                                     height: height,
                                                     dataset: dataset)
                let intensityRange = Self.intensityRange(in: pixels, pixelFormat: dataset.pixelFormat)
                    ?? dataset.intensityRange

                return MPRSlice(pixels: pixels,
                                width: width,
                                height: height,
                                bytesPerRow: width * bytesPerPixel,
                                pixelFormat: dataset.pixelFormat,
                                intensityRange: intensityRange,
                                pixelSpacing: pixelSpacing)
            }
        }.value
    }
}

// MARK: - Helpers

private extension MetalMPRAdapter {
    static func dominantAxis(for plane: MPRPlaneGeometry) -> MPRPlaneAxis {
        let normal = plane.normalWorld
        let components = [abs(normal.x), abs(normal.y), abs(normal.z)]
        let index = components.enumerated().max(by: { $0.element < $1.element })?.offset ?? 2
        return MPRPlaneAxis(rawValue: index) ?? .z
    }

    static func sliceDimensions(for plane: MPRPlaneGeometry) -> (width: Int, height: Int) {
        let width = max(1, Int(round(simd_length(plane.axisUVoxel))))
        let height = max(1, Int(round(simd_length(plane.axisVVoxel))))
        return (width, height)
    }

    static func normalVector(for plane: MPRPlaneGeometry, dataset: VolumeDataset) -> SIMD3<Float> {
        let cross = simd_cross(plane.axisUVoxel, plane.axisVVoxel)
        let length = simd_length(cross)
        if length > Float.ulpOfOne {
            return cross / length
        }

        let voxelToWorld = voxelToWorldMatrix(for: dataset)
        let worldToVoxel = simd_inverse(voxelToWorld)
        let worldNormal = plane.normalWorld
        let transformed = transformDirection(worldToVoxel, worldNormal)
        let transformedLength = simd_length(transformed)
        if transformedLength > Float.ulpOfOne {
            return transformed / transformedLength
        }
        return SIMD3<Float>(0, 0, 1)
    }

    static func sampleOffsets(thickness: Int, steps: Int) -> [Float] {
        let sanitizedSteps = max(1, steps)
        if sanitizedSteps == 1 { return [0] }

        let span = Float(max(0, thickness))
        if span == 0 {
            return Array(repeating: 0, count: sanitizedSteps)
        }

        let start = -span / 2
        let stepSize = span / Float(sanitizedSteps - 1)
        return (0..<sanitizedSteps).map { start + Float($0) * stepSize }
    }

    static func pixelSpacing(for plane: MPRPlaneGeometry,
                             width: Int,
                             height: Int,
                             dataset: VolumeDataset) -> SIMD2<Float>? {
        let uLength = simd_length(plane.axisUWorld)
        let vLength = simd_length(plane.axisVWorld)
        let spacingU = width > 1 ? uLength / Float(width - 1) : Float(dataset.spacing.x)
        let spacingV = height > 1 ? vLength / Float(height - 1) : Float(dataset.spacing.y)
        return SIMD2<Float>(spacingU, spacingV)
    }

    static func voxelToWorldMatrix(for dataset: VolumeDataset) -> simd_float4x4 {
        let orientation = dataset.orientation
        let spacing = dataset.spacing

        let row = orientation.row
        let column = orientation.column
        let normal = safeNormalize(simd_cross(row, column), fallback: SIMD3<Float>(0, 0, 1))

        let spacingX = Float(spacing.x)
        let spacingY = Float(spacing.y)
        let spacingZ = Float(spacing.z)

        return simd_float4x4(columns: (
            SIMD4<Float>(row.x * spacingX, row.y * spacingX, row.z * spacingX, 0),
            SIMD4<Float>(column.x * spacingY, column.y * spacingY, column.z * spacingY, 0),
            SIMD4<Float>(normal.x * spacingZ, normal.y * spacingZ, normal.z * spacingZ, 0),
            SIMD4<Float>(orientation.origin.x, orientation.origin.y, orientation.origin.z, 1)
        ))
    }

    static func transformDirection(_ matrix: simd_float4x4, _ direction: SIMD3<Float>) -> SIMD3<Float> {
        let vector = matrix * SIMD4<Float>(direction, 0)
        return SIMD3<Float>(vector.x, vector.y, vector.z)
    }

    static func safeNormalize(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        if length <= Float.ulpOfOne {
            return fallback
        }
        return vector / length
    }

    static func emptySlice(dataset: VolumeDataset) -> MPRSlice {
        MPRSlice(pixels: Data(),
                 width: 0,
                 height: 0,
                 bytesPerRow: 0,
                 pixelFormat: dataset.pixelFormat,
                 intensityRange: dataset.intensityRange,
                 pixelSpacing: nil)
    }

    static func populateSlice(into buffer: UnsafeMutableBufferPointer<Int16>,
                              width: Int,
                              height: Int,
                              reader: VolumeDataReader,
                              plane: MPRPlaneGeometry,
                              normal: SIMD3<Float>,
                              offsets: [Float],
                              blend: MPRBlendMode,
                              intensityRange: ClosedRange<Int32>) {
        guard let baseAddress = buffer.baseAddress else { return }
        let uVector = plane.axisUVoxel
        let vVector = plane.axisVVoxel
        let origin = plane.originVoxel
        let lower = Float(intensityRange.lowerBound)
        let upper = Float(intensityRange.upperBound)

        let uDenominator = max(1, width - 1)
        let vDenominator = max(1, height - 1)

        for v in 0..<height {
            let vRatio = height > 1 ? Float(v) / Float(vDenominator) : 0
            for u in 0..<width {
                let uRatio = width > 1 ? Float(u) / Float(uDenominator) : 0
                let basePoint = origin + uVector * uRatio + vVector * vRatio
                let intensity = sampleIntensity(reader: reader,
                                                basePoint: basePoint,
                                                normal: normal,
                                                offsets: offsets,
                                                blend: blend,
                                                intensityRange: intensityRange)
                let clamped = min(max(intensity, lower), upper)
                baseAddress[v * width + u] = Int16(clamping: Int(round(clamped)))
            }
        }
    }

    static func populateSlice(into buffer: UnsafeMutableBufferPointer<UInt16>,
                              width: Int,
                              height: Int,
                              reader: VolumeDataReader,
                              plane: MPRPlaneGeometry,
                              normal: SIMD3<Float>,
                              offsets: [Float],
                              blend: MPRBlendMode,
                              intensityRange: ClosedRange<Int32>) {
        guard let baseAddress = buffer.baseAddress else { return }
        let uVector = plane.axisUVoxel
        let vVector = plane.axisVVoxel
        let origin = plane.originVoxel
        let lower = Float(intensityRange.lowerBound)
        let upper = Float(intensityRange.upperBound)

        let uDenominator = max(1, width - 1)
        let vDenominator = max(1, height - 1)

        for v in 0..<height {
            let vRatio = height > 1 ? Float(v) / Float(vDenominator) : 0
            for u in 0..<width {
                let uRatio = width > 1 ? Float(u) / Float(uDenominator) : 0
                let basePoint = origin + uVector * uRatio + vVector * vRatio
                let intensity = sampleIntensity(reader: reader,
                                                basePoint: basePoint,
                                                normal: normal,
                                                offsets: offsets,
                                                blend: blend,
                                                intensityRange: intensityRange)
                let clamped = min(max(intensity, lower), upper)
                baseAddress[v * width + u] = UInt16(clamping: Int(round(clamped)))
            }
        }
    }

    static func sampleIntensity(reader: VolumeDataReader,
                                basePoint: SIMD3<Float>,
                                normal: SIMD3<Float>,
                                offsets: [Float],
                                blend: MPRBlendMode,
                                intensityRange: ClosedRange<Int32>) -> Float {
        let defaultValue = Float(intensityRange.lowerBound)

        switch blend {
        case .single:
            guard !offsets.isEmpty else { return defaultValue }
            let middleIndex = offsets.count / 2
            let position = basePoint + normal * offsets[middleIndex]
            return reader.intensity(at: position)
        case .maximum:
            var hasSample = false
            var maxSample = defaultValue
            for offset in offsets {
                let position = basePoint + normal * offset
                let intensity = reader.intensity(at: position)
                if !hasSample || intensity > maxSample {
                    maxSample = intensity
                    hasSample = true
                }
            }
            return hasSample ? maxSample : defaultValue
        case .minimum:
            var hasSample = false
            var minSample = Float(intensityRange.upperBound)
            for offset in offsets {
                let position = basePoint + normal * offset
                let intensity = reader.intensity(at: position)
                if !hasSample || intensity < minSample {
                    minSample = intensity
                    hasSample = true
                }
            }
            return hasSample ? minSample : defaultValue
        case .average:
            var total: Float = 0
            var count: Float = 0
            for offset in offsets {
                let position = basePoint + normal * offset
                total += reader.intensity(at: position)
                count += 1
            }
            return count > 0 ? total / count : defaultValue
        @unknown default:
            guard !offsets.isEmpty else { return defaultValue }
            let middleIndex = offsets.count / 2
            let position = basePoint + normal * offsets[middleIndex]
            return reader.intensity(at: position)
        }
    }

    static func intensityRange(in pixels: Data, pixelFormat: VolumePixelFormat) -> ClosedRange<Int32>? {
        guard !pixels.isEmpty else { return nil }

        return pixels.withUnsafeBytes { rawBuffer -> ClosedRange<Int32>? in
            switch pixelFormat {
            case .int16Signed:
                let count = rawBuffer.count / MemoryLayout<Int16>.size
                guard count > 0 else { return nil }
                var minValue = Int32(Int16.max)
                var maxValue = Int32(Int16.min)
                let pointer = rawBuffer.bindMemory(to: Int16.self)
                for index in 0..<count {
                    let value = Int32(pointer[index])
                    minValue = min(minValue, value)
                    maxValue = max(maxValue, value)
                }
                return minValue...maxValue
            case .int16Unsigned:
                let count = rawBuffer.count / MemoryLayout<UInt16>.size
                guard count > 0 else { return nil }
                var minValue = Int32.max
                var maxValue = Int32.min
                let pointer = rawBuffer.bindMemory(to: UInt16.self)
                for index in 0..<count {
                    let value = Int32(pointer[index])
                    minValue = min(minValue, value)
                    maxValue = max(maxValue, value)
                }
                return minValue...maxValue
            }
        }
    }
}
