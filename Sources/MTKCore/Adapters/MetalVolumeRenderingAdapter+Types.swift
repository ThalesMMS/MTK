//
//  MetalVolumeRenderingAdapter+Types.swift
//  MTK
//
//  Supporting types for the Metal volume rendering adapter.
//
//  Thales Matheus Mendonça Santos — April 2026

import Foundation
import simd

/// Extended rendering state configuration for advanced volume rendering features.
///
/// This structure encapsulates all advanced rendering parameters including windowing,
/// lighting, tone curves, clipping, and adaptive sampling. It is used internally by
/// ``MetalVolumeRenderingAdapter`` to maintain rendering state across frames.
///
/// ## Topics
///
/// ### Windowing
/// - ``huWindow``
/// - ``shift``
/// - ``densityGate``
///
/// ### Lighting and Quality
/// - ``lightingEnabled``
/// - ``samplingStep``
/// - ``adaptiveEnabled``
/// - ``adaptiveThreshold``
/// - ``jitterAmount``
/// - ``earlyTerminationThreshold``
///
/// ### Transfer Functions
/// - ``channelIntensities``
/// - ``toneCurvePoints``
/// - ``toneCurvePresetKeys``
/// - ``toneCurveGains``
///
/// ### Clipping
/// - ``clipBounds``
/// - ``clipPlanePreset``
/// - ``clipPlaneOffset``
@preconcurrency
public struct ExtendedRenderingState: Sendable {
    /// HU (Hounsfield Unit) window for CT data visualization.
    /// When set, overrides the dataset's recommended window.
    var huWindow: ClosedRange<Int32>?

    /// Whether lighting calculations are enabled during rendering.
    var lightingEnabled: Bool = true

    /// Step size for ray marching, expressed as a fraction of the volume diagonal.
    var samplingStep: Float = 1.0 / 512.0

    /// Intensity shift applied to all voxel values before windowing.
    var shift: Float = 0

    /// Optional density gate that filters out voxels outside this intensity range.
    var densityGate: ClosedRange<Float>?

    /// Optional HU gate that filters out voxels outside this raw intensity range.
    var huGate: ClosedRange<Int32>?

    /// Whether adaptive sampling is enabled (adjusts step size based on gradient).
    var adaptiveEnabled: Bool = false

    /// Gradient threshold for adaptive sampling trigger.
    var adaptiveThreshold: Float = 0

    /// Amount of temporal jitter to reduce aliasing artifacts.
    var jitterAmount: Float = 0

    /// Accumulated opacity threshold for early ray termination.
    var earlyTerminationThreshold: Float = 0.95

    /// Per-channel intensity multipliers (RGBA).
    var channelIntensities: SIMD4<Float> = SIMD4<Float>(repeating: 1)

    /// Per-channel tone curve control points (channel index -> array of (input, output) pairs).
    var toneCurvePoints: [Int: [SIMD2<Float>]] = [:]

    /// Per-channel tone curve preset identifiers.
    var toneCurvePresetKeys: [Int: String] = [:]

    /// Per-channel tone curve gain values.
    var toneCurveGains: [Int: Float] = [:]

    /// 3D clip bounds in normalized volume space [0, 1].
    var clipBounds: ClipBoundsSnapshot = .default

    /// Active clip plane preset (0 = none, 1 = axial, 2 = sagittal, 3 = coronal).
    var clipPlanePreset: Int = 0

    /// Distance offset for the active clip plane.
    var clipPlaneOffset: Float = 0
}

extension MetalVolumeRenderingAdapter {
    /// Errors that can occur before the Metal compute adapter is available.
    public enum InitializationError: Error, Equatable, LocalizedError {
        /// No Metal device was available to create the adapter.
        case metalDeviceUnavailable

        /// The supplied Metal device could not create a command queue.
        case commandQueueCreationFailed

        /// The supplied command queue belongs to a different Metal device.
        case commandQueueDeviceMismatch

        /// No usable shader library could be loaded for the supplied Metal device.
        case shaderLibraryUnavailable

        /// The supplied shader library belongs to a different Metal device.
        case shaderLibraryDeviceMismatch

        /// The volume compute kernel was not present in the shader library.
        case computeFunctionNotFound

        /// The volume compute pipeline could not be created.
        case pipelineCreationFailed

        /// The camera uniforms buffer could not be allocated.
        case cameraBufferAllocationFailed

        public var errorDescription: String? {
            switch self {
            case .metalDeviceUnavailable:
                return "Metal device unavailable"
            case .commandQueueCreationFailed:
                return "Metal command queue creation failed"
            case .commandQueueDeviceMismatch:
                return "Metal command queue device mismatch"
            case .shaderLibraryUnavailable:
                return "Metal shader library unavailable"
            case .shaderLibraryDeviceMismatch:
                return "Metal shader library device mismatch"
            case .computeFunctionNotFound:
                return "Metal volume compute function not found"
            case .pipelineCreationFailed:
                return "Metal volume compute pipeline creation failed"
            case .cameraBufferAllocationFailed:
                return "Metal camera buffer allocation failed"
            }
        }

        public var failureReason: String? {
            switch self {
            case .metalDeviceUnavailable:
                return "The system did not provide a Metal device for volume rendering."
            case .commandQueueCreationFailed:
                return "The supplied Metal device returned nil when creating a command queue."
            case .commandQueueDeviceMismatch:
                return "The injected command queue was created from a different Metal device."
            case .shaderLibraryUnavailable:
                return "The required MTK.metallib was not bundled in MTKCore's Bundle.module resources or could not be loaded."
            case .shaderLibraryDeviceMismatch:
                return "The injected or resolved shader library was created from a different Metal device."
            case .computeFunctionNotFound:
                return "The shader library does not contain the volume_compute kernel."
            case .pipelineCreationFailed:
                return "Metal could not compile a compute pipeline for the volume_compute kernel."
            case .cameraBufferAllocationFailed:
                return "The supplied Metal device could not allocate the camera uniforms buffer."
            }
        }
    }

    /// Errors specific to the volume rendering adapter.
    public enum AdapterError: Error, Equatable, LocalizedError {
        /// The requested histogram bin count is invalid (must be > 0).
        case invalidHistogramBinCount

        /// No explicit window was provided and the dataset does not define a recommended window.
        case windowNotSpecified

        /// Transfer-function color control points must not be empty.
        case emptyColorPoints

        /// Transfer-function opacity control points must not be empty.
        case emptyAlphaPoints

        /// Camera axes produced a non-finite look-at matrix.
        case degenerateCameraMatrix

        /// Histogram calculation could not construct a dataset reader.
        case datasetReadFailed

        /// The requested extended adapter operation is not supported by this renderer.
        case notSupported

        /// Histogram data is not available from the extended adapter snapshot API.
        case histogramNotAvailable

        /// The requested extended adapter operation has not been implemented.
        case notImplemented

        public var errorDescription: String? {
            switch self {
            case .invalidHistogramBinCount:
                return "Invalid histogram bin count"
            case .windowNotSpecified:
                return "Window not specified"
            case .emptyColorPoints:
                return "Color control points are empty"
            case .emptyAlphaPoints:
                return "Alpha control points are empty"
            case .degenerateCameraMatrix:
                return "Degenerate camera matrix"
            case .datasetReadFailed:
                return "Dataset read failed"
            case .notSupported:
                return "Operation not supported"
            case .histogramNotAvailable:
                return "Histogram not available"
            case .notImplemented:
                return "Operation not implemented"
            }
        }

        public var failureReason: String? {
            switch self {
            case .invalidHistogramBinCount:
                return "Histogram bin count must be greater than zero."
            case .windowNotSpecified:
                return "The render request did not provide a window override and the dataset does not define a recommended window."
            case .emptyColorPoints:
                return "The transfer function must include at least one color control point."
            case .emptyAlphaPoints:
                return "The transfer function must include at least one opacity control point."
            case .degenerateCameraMatrix:
                return "The camera position, target, and up vector produced non-finite basis vectors."
            case .datasetReadFailed:
                return "The adapter could not construct a reader for the dataset's voxel buffer."
            case .notSupported:
                return "This operation is not supported by the Metal volume rendering adapter."
            case .histogramNotAvailable:
                return "The extended histogram snapshot API does not currently provide histogram data."
            case .notImplemented:
                return "This extended adapter operation has not been implemented."
            }
        }
    }

    /// Runtime errors produced by Metal volume rendering operations.
    public enum RenderingError: Error, Equatable, LocalizedError {
        /// Unable to create or access the dataset's Metal texture.
        case datasetTextureUnavailable

        /// Unable to create or access the transfer function texture.
        case transferTextureUnavailable

        /// Failed to encode Metal commands.
        case commandEncodingFailed

        /// Unable to create or access the output render texture.
        case outputTextureUnavailable

        /// Unable to create a CPU image from a rendered frame.
        case cgImageCreationFailed

        /// Metal reported an execution failure after the command buffer was committed.
        case commandBufferExecutionFailed(underlyingDescription: String)

        public static func == (lhs: RenderingError, rhs: RenderingError) -> Bool {
            switch (lhs, rhs) {
            case (.datasetTextureUnavailable, .datasetTextureUnavailable),
                 (.transferTextureUnavailable, .transferTextureUnavailable),
                 (.commandEncodingFailed, .commandEncodingFailed),
                 (.outputTextureUnavailable, .outputTextureUnavailable),
                 (.cgImageCreationFailed, .cgImageCreationFailed):
                return true
            case let (.commandBufferExecutionFailed(lhsDescription),
                      .commandBufferExecutionFailed(rhsDescription)):
                return lhsDescription == rhsDescription
            default:
                return false
            }
        }

        public var errorDescription: String? {
            switch self {
            case .datasetTextureUnavailable:
                return "Dataset texture unavailable"
            case .transferTextureUnavailable:
                return "Transfer function texture unavailable"
            case .commandEncodingFailed:
                return "Metal command encoding failed"
            case .outputTextureUnavailable:
                return "Output texture unavailable"
            case .cgImageCreationFailed:
                return "CGImage creation failed"
            case .commandBufferExecutionFailed:
                return "Metal command buffer execution failed"
            }
        }

        public var failureReason: String? {
            switch self {
            case .datasetTextureUnavailable:
                return "The adapter could not create or reuse a Metal texture for the dataset."
            case .transferTextureUnavailable:
                return "The adapter could not create or reuse a Metal texture for the transfer function."
            case .commandEncodingFailed:
                return "The adapter could not create a Metal command buffer or compute command encoder."
            case .outputTextureUnavailable:
                return "The adapter could not create or access the output Metal texture."
            case .cgImageCreationFailed:
                return "The rendered frame could not be converted to a CGImage for snapshot or export."
            case .commandBufferExecutionFailed(let underlyingDescription):
                return underlyingDescription
            }
        }
    }

    /// Rendering parameter overrides that take precedence over request values.
    ///
    /// Use ``send(_:)`` to set these overrides. They persist across render calls
    /// until explicitly changed or cleared. Optional values default to `nil`,
    /// meaning no override; lighting defaults to enabled.
    public struct Overrides {
        /// Override compositing mode for all render requests.
        public var compositing: VolumeRenderRequest.Compositing?

        /// Override sampling distance for all render requests.
        public var samplingDistance: Float?

        /// Override intensity window for all render requests.
        public var window: ClosedRange<Int32>?

        /// Override lighting enabled state. Lighting is applied by default unless explicitly disabled.
        public var lightingEnabled: Bool = true
    }

    /// Snapshot of the most recent successful render.
    ///
    /// Captures the dataset, metadata, and window used in the last ``renderFrame(using:)`` call.
    /// Useful for debugging and validating rendering state.
    public struct RenderSnapshot {
        /// The dataset that was rendered.
        public var dataset: VolumeDataset

        /// Metadata describing the render configuration.
        public var metadata: VolumeRenderFrame.Metadata

        /// The intensity window applied during rendering.
        public var window: ClosedRange<Int32>
    }
}
