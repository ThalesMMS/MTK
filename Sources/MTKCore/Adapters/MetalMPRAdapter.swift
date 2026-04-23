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
/// let frame = try await adapter.makeTextureFrame(
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
/// - ``makeTextureFrame(dataset:plane:thickness:steps:blend:)``
/// - ``makeSlabTexture(dataset:volumeTexture:plane:thickness:steps:blend:)``
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
    public enum InitializationError: Error, Equatable, LocalizedError {
        /// The supplied Metal device could not create a command queue.
        case commandQueueCreationFailed

        /// The supplied command queue belongs to a different Metal device.
        case commandQueueDeviceMismatch

        /// No usable shader library could be loaded for the supplied Metal device.
        case shaderLibraryUnavailable

        /// The supplied shader library belongs to a different Metal device.
        case shaderLibraryDeviceMismatch

        public var errorDescription: String? {
            switch self {
            case .commandQueueCreationFailed:
                return "Metal command queue creation failed"
            case .commandQueueDeviceMismatch:
                return "Metal command queue device mismatch"
            case .shaderLibraryUnavailable:
                return "Metal shader library unavailable"
            case .shaderLibraryDeviceMismatch:
                return "Metal shader library device mismatch"
            }
        }

        public var failureReason: String? {
            switch self {
            case .commandQueueCreationFailed:
                return "The supplied Metal device returned nil when creating a command queue."
            case .commandQueueDeviceMismatch:
                return "The injected command queue was created from a different Metal device."
            case .shaderLibraryUnavailable:
                return "The required MTK.metallib was not bundled in MTKCore's Bundle.module resources or could not be loaded."
            case .shaderLibraryDeviceMismatch:
                return "The injected or resolved shader library was created from a different Metal device."
            }
        }
    }

    /// Parameter overrides for MPR slice generation.
    ///
    /// Overrides set via ``send(_:)`` persist until the next texture frame generation
    /// call, where they are applied and then cleared.
    public struct Overrides: Equatable {
        /// Override blend mode for the next slab generation.
        var blend: MPRBlendMode?

        /// Override slab thickness for the next slab generation.
        var slabThickness: Int?

        /// Override number of sampling steps for the next slab generation.
        var slabSteps: Int?
    }

    /// Snapshot of the most recent slice generation.
    ///
    /// Captures parameters and results from the last texture frame generation call.
    /// Useful for debugging and validating MPR state.
    public struct SliceSnapshot: Equatable {
        /// The dominant anatomical axis of the slice (axial, sagittal, or coronal).
        var axis: MPRPlaneAxis

        /// Actual intensity range found in the generated slice.
        var intensityRange: ClosedRange<Int32>

        /// Blend mode used for slab generation.
        var blend: MPRBlendMode

        /// Slab thickness resolved along the plane normal using dataset spacing.
        var thickness: Int

        /// Number of sampling steps used.
        var steps: Int
    }

    private var overrides = Overrides()
    private var lastSnapshot: SliceSnapshot?
    let gpuAdapter: MetalMPRComputeAdapter
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
    ///   - library: Optional Metal shader library. If `nil`, loads `MTK.metallib` from `Bundle.module`.
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

        let lib: any MTLLibrary
        if let library {
            lib = library
        } else {
            do {
                lib = try ShaderLibraryLoader.loadLibrary(for: device)
            } catch is ShaderLibraryLoader.LoaderError {
                throw InitializationError.shaderLibraryUnavailable
            } catch {
                throw InitializationError.shaderLibraryUnavailable
            }
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

    public func makeTextureFrame(dataset: VolumeDataset,
                                 plane: MPRPlaneGeometry,
                                 thickness: Int,
                                 steps: Int,
                                 blend: MPRBlendMode) async throws -> MPRTextureFrame {
        let effectiveBlend = overrides.blend ?? blend
        let effectiveThickness = VolumetricMath.sanitizeThickness(overrides.slabThickness ?? thickness)
        let effectiveSteps = VolumetricMath.sanitizeSteps(overrides.slabSteps ?? steps)
        defer {
            overrides.blend = nil
            overrides.slabThickness = nil
            overrides.slabSteps = nil
        }

        let frame = try await gpuAdapter.makeTextureFrame(
            dataset: dataset,
            plane: plane,
            thickness: effectiveThickness,
            steps: effectiveSteps,
            blend: effectiveBlend
        )

        let axis = Self.dominantAxis(for: plane)
        lastSnapshot = SliceSnapshot(axis: axis,
                                     intensityRange: frame.intensityRange,
                                     blend: effectiveBlend,
                                     thickness: effectiveThickness,
                                     steps: effectiveSteps)

        return frame
    }

    public func makeTextureFrame(dataset: VolumeDataset,
                                 volumeTexture: any MTLTexture,
                                 plane: MPRPlaneGeometry,
                                 thickness: Int,
                                 steps: Int,
                                 blend: MPRBlendMode,
                                 viewportID: ViewportID? = nil) async throws -> MPRTextureFrame {
        try await makeSlabTexture(dataset: dataset,
                                  volumeTexture: volumeTexture,
                                  plane: plane,
                                  thickness: thickness,
                                  steps: steps,
                                  blend: blend,
                                  viewportID: viewportID)
    }

    public func makeSlabTexture(dataset: VolumeDataset,
                                volumeTexture: any MTLTexture,
                                plane: MPRPlaneGeometry,
                                thickness: Int,
                                steps: Int,
                                blend: MPRBlendMode) async throws -> MPRTextureFrame {
        try await makeSlabTexture(dataset: dataset,
                                  volumeTexture: volumeTexture,
                                  plane: plane,
                                  thickness: thickness,
                                  steps: steps,
                                  blend: blend,
                                  viewportID: nil)
    }

    public func makeSlabTexture(dataset: VolumeDataset,
                                volumeTexture: any MTLTexture,
                                plane: MPRPlaneGeometry,
                                thickness: Int,
                                steps: Int,
                                blend: MPRBlendMode,
                                viewportID: ViewportID?) async throws -> MPRTextureFrame {
        let effectiveBlend = overrides.blend ?? blend
        let effectiveThickness = VolumetricMath.sanitizeThickness(overrides.slabThickness ?? thickness)
        let effectiveSteps = VolumetricMath.sanitizeSteps(overrides.slabSteps ?? steps)
        defer {
            overrides.blend = nil
            overrides.slabThickness = nil
            overrides.slabSteps = nil
        }

        let frame = try await gpuAdapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: effectiveThickness,
            steps: effectiveSteps,
            blend: effectiveBlend,
            viewportID: viewportID
        )

        let axis = Self.dominantAxis(for: plane)
        lastSnapshot = SliceSnapshot(axis: axis,
                                     intensityRange: frame.intensityRange,
                                     blend: effectiveBlend,
                                     thickness: effectiveThickness,
                                     steps: effectiveSteps)

        return frame
    }

    /// Sends an MPR command to update slice generation parameters.
    ///
    /// Commands set persistent overrides that apply to the next texture frame generation
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
    /// // Next texture frame call will use maximum blend
    /// let frame = try await adapter.makeTextureFrame(
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
    /// Sends a reslice command to the GPU compute adapter and records pending parameter overrides to apply on the next frame generation.
    ///
    /// The command is forwarded to the underlying GPU adapter; certain command variants update `overrides` so they take effect for the next frame generation call:
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
