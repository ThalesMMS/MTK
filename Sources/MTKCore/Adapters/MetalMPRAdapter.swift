//
//  MetalMPRAdapter.swift
//  MetalVolumetrics
//
//  Multi-planar reconstruction adapter backed exclusively by Metal compute.
//  Metal resource setup failures are surfaced explicitly during initialization.
//
//  Thales Matheus Mendonça Santos — February 2026

import Foundation
import Metal
import OSLog
import simd

/// Multi-planar reconstruction (MPR) adapter backed exclusively by Metal compute.
///
/// `MetalMPRAdapter` provides high-performance orthogonal and oblique slice extraction
/// from volumetric datasets. Metal device, command queue, shader library, and compute
/// pipeline failures are reported as explicit errors instead of being hidden behind
/// another backend.
///
/// ## Overview
///
/// The adapter implements the ``MPRReslicePort`` protocol, providing:
/// - Orthogonal slicing (axial, sagittal, coronal)
/// - Oblique multi-planar reconstruction
/// - Slab generation with multiple blend modes (maximum, minimum, average)
/// - Metal compute shader acceleration
///
/// ## Usage
///
/// ```swift
/// let device = MTLCreateSystemDefaultDevice()!
/// let adapter = try MetalMPRAdapter(device: device)
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
/// - ``init(device:commandQueue:library:debugOptions:)``
///
/// ### Slicing
/// - ``makeSlab(dataset:plane:thickness:steps:blend:)``
///
/// ### Configuration
/// - ``send(_:)``
///
/// ### Supporting Types
/// - ``InitializationError``
/// - ``Overrides``
/// - ``SliceSnapshot``
@preconcurrency
public actor MetalMPRAdapter: MPRReslicePort {
    /// Errors that can occur before the Metal compute adapter is available.
    public enum InitializationError: Error, Equatable {
        /// The supplied Metal device could not create a command queue.
        case commandQueueCreationFailed

        /// The supplied command queue belongs to a different Metal device.
        case commandQueueDeviceMismatch

        /// No usable shader library could be loaded for the supplied Metal device.
        case shaderLibraryUnavailable

        /// The supplied shader library belongs to a different Metal device.
        case shaderLibraryDeviceMismatch
    }

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
    private let gpuAdapter: MetalMPRComputeAdapter
    private let logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "MetalMPRAdapter")

    /// Creates a new Metal-backed MPR adapter.
    ///
    /// This initializer configures the adapter to use Metal compute shaders for
    /// high-performance slice generation. If the required Metal resources cannot be
    /// initialized, the initializer throws instead of silently selecting another backend.
    ///
    /// - Parameters:
    ///   - device: Metal device for GPU compute operations.
    ///   - commandQueue: Optional command queue. If `nil`, a new queue is created from the device.
    ///   - library: Optional Metal shader library. If `nil`, loads `MTK.metallib` or the default library.
    ///   - debugOptions: Debug configuration options for logging and validation.
    ///
    /// - Throws: ``InitializationError/commandQueueCreationFailed`` when a command queue cannot be
    ///   created, ``InitializationError/commandQueueDeviceMismatch`` when an injected command queue
    ///   belongs to another device, ``InitializationError/shaderLibraryUnavailable`` when no shader
    ///   library is available, or ``InitializationError/shaderLibraryDeviceMismatch`` when a resolved
    ///   shader library belongs to another device.
    ///
    /// ## Metal Initialization
    ///
    /// The adapter initializes a ``MetalMPRComputeAdapter`` with:
    /// - Feature flags evaluated from device capabilities
    /// - MPR-specific Metal compute kernels (`mprKernel`, `mprSlabKernel`)
    /// - Argument buffers for efficient parameter passing
    ///
    /// ## Usage
    ///
    /// ```swift
    /// guard let device = MTLCreateSystemDefaultDevice() else { return }
    /// let adapter = try MetalMPRAdapter(device: device)
    /// ```
    public init(device: any MTLDevice,
                commandQueue: (any MTLCommandQueue)? = nil,
                library: (any MTLLibrary)? = nil,
                debugOptions: VolumeRenderingDebugOptions = VolumeRenderingDebugOptions()) throws {
        let queue: any MTLCommandQueue
        if let commandQueue {
            guard commandQueue.device === device else {
                throw InitializationError.commandQueueDeviceMismatch
            }
            queue = commandQueue
        } else if let createdQueue = device.makeCommandQueue() {
            queue = createdQueue
        } else {
            throw InitializationError.commandQueueCreationFailed
        }

        let lib = library ?? ShaderLibraryLoader.makeDefaultLibrary(on: device) { message in
            Logger(subsystem: "com.mtk.volumerendering", category: "ShaderLoader").info("\(message)")
        }

        guard let lib else {
            throw InitializationError.shaderLibraryUnavailable
        }

        guard lib.device === device else {
            throw InitializationError.shaderLibraryDeviceMismatch
        }

        let featureFlags = FeatureFlags.evaluate(for: device)
        self.gpuAdapter = MetalMPRComputeAdapter(
            device: device,
            commandQueue: queue,
            library: lib,
            featureFlags: featureFlags,
            debugOptions: debugOptions
        )
        logger.info("MetalMPRAdapter initialized with Metal compute backend")
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
    /// - Throws: Errors from Metal operations such as texture creation, command buffer creation,
    ///   or kernel execution failure.
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
    /// Typical slice generation time: ~2-5ms for a 512×512 output, 5mm thickness, 10 steps.
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
    /// Generate an MPR slab image from a volume along the specified plane using the Metal GPU adapter.
    ///
    /// The effective `blend`, `thickness`, and `steps` are computed by applying any pending overrides (set via `send(_:)`) first, then falling back to the provided arguments; thickness and steps are sanitized before use. All pending overrides are cleared after computation.
    /// - Parameters:
    ///   - dataset: The volume dataset to sample.
    ///   - plane: The geometry of the reslice plane in world space.
    ///   - thickness: Requested slab thickness in voxels (used if no override is present).
    ///   - steps: Requested sampling steps across the slab (used if no override is present).
    ///   - blend: Requested blending mode for slab compositing (used if no override is present).
    /// - Returns: An `MPRSlice` containing the generated slab image and its intensity range.
    /// - Throws: Any error produced by the underlying GPU adapter (for example Metal texture, command queue, or kernel failures).
    public func makeSlab(dataset: VolumeDataset,
                         plane: MPRPlaneGeometry,
                         thickness: Int,
                         steps: Int,
                         blend: MPRBlendMode) async throws -> MPRSlice {
        let effectiveBlend = overrides.blend ?? blend
        let effectiveThickness = VolumetricMath.sanitizeThickness(overrides.slabThickness ?? thickness)
        let effectiveSteps = VolumetricMath.sanitizeSteps(overrides.slabSteps ?? steps)
        defer {
            overrides.blend = nil
            overrides.slabThickness = nil
            overrides.slabSteps = nil
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let slice = try await gpuAdapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: effectiveThickness,
            steps: effectiveSteps,
            blend: effectiveBlend
        )

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        logger.info("MPR slab generation completed via Metal path: \(String(format: "%.2f", duration * 1000))ms blend=\(effectiveBlend) thickness=\(effectiveThickness) steps=\(effectiveSteps)")

        let axis = Self.dominantAxis(for: plane)
        lastSnapshot = SliceSnapshot(axis: axis,
                                     intensityRange: slice.intensityRange,
                                     blend: effectiveBlend,
                                     thickness: effectiveThickness,
                                     steps: effectiveSteps)

        return slice
    }

    /// Sends an MPR command to update slice generation parameters.
    ///
    /// Commands set persistent overrides that apply to the next ``makeSlab(dataset:plane:thickness:steps:blend:)``
    /// call. Overrides are cleared after being applied.
    ///
    /// - Parameter command: The command to execute.
    ///
    /// - Throws: Errors from the Metal compute adapter during parameter validation or state updates.
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
    /// Sends a reslice command to the GPU compute adapter and records pending parameter overrides to apply on the next slab generation.
    ///
    /// The command is forwarded to the underlying GPU adapter; certain command variants update `overrides` so they take effect for the next `makeSlab(...)` call:
    /// - `.setBlend(mode)`: sets the pending blend mode.
    /// - `.setSlab(thickness, steps)`: sets the pending slab thickness and steps after sanitizing them.
    /// - Parameters:
    ///   - command: The reslice command to forward and apply as an override when applicable.
    /// - Throws: Any error propagated from the GPU adapter when sending the command.
    public func send(_ command: MPRResliceCommand) async throws {
        try await gpuAdapter.send(command)

        switch command {
        case .setBlend(let mode):
            overrides.blend = mode
        case .setSlab(let thickness, let steps):
            overrides.slabThickness = VolumetricMath.sanitizeThickness(thickness)
            overrides.slabSteps = VolumetricMath.sanitizeSteps(steps)
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
    public var debugGPUAvailable: Bool { true }
}

// MARK: - Helpers

private extension MetalMPRAdapter {
    /// Determines the dominant axis of the given plane's world normal.
    /// - Parameters:
    ///   - plane: The plane whose world-space normal is used to determine the dominant axis.
    /// - Returns: The `MPRPlaneAxis` corresponding to the component (`x`, `y`, or `z`) with the largest absolute value in the plane's world normal; returns `.z` if a mapping cannot be made.
    static func dominantAxis(for plane: MPRPlaneGeometry) -> MPRPlaneAxis {
        let normal = plane.normalWorld
        let components = [abs(normal.x), abs(normal.y), abs(normal.z)]
        let index = components.enumerated().max(by: { $0.element < $1.element })?.offset ?? 2
        return MPRPlaneAxis(rawValue: index) ?? .z
    }
}
