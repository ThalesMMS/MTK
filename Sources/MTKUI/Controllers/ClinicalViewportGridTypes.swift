//
//  ClinicalViewportGridTypes.swift
//  MTKUI
//
//  Shared clinical viewport grid types.
//

import Foundation
import MTKCore

extension WindowLevelShift {
    init(range: ClosedRange<Int32>) {
        let lower = Double(range.lowerBound)
        let upper = Double(range.upperBound)
        self.init(window: max(upper - lower, 1), level: (lower + upper) / 2)
    }

    var range: ClosedRange<Int32> {
        let lowerDouble = (level - window / 2).rounded()
        let upperDouble = (level + window / 2).rounded()
        let lower = Self.clampedInt32(lowerDouble)
        let upper = Self.clampedInt32(upperDouble)
        return min(lower, upper)...max(lower, upper)
    }

    private static func clampedInt32(_ value: Double) -> Int32 {
        guard value.isFinite else {
            return value.sign == .minus ? Int32.min : Int32.max
        }
        let int32Min = Double(Int32.min)
        let int32Max = Double(Int32.max)
        return Int32(min(max(value, int32Min), int32Max))
    }
}

public enum ClinicalVolumeViewportMode: String, CaseIterable, Sendable {
    case dvr
    case mip
    case minip
    case aip

    var viewportType: ViewportType {
        switch self {
        case .dvr:
            return .volume3D
        case .mip:
            return .projection(mode: .mip)
        case .minip:
            return .projection(mode: .minip)
        case .aip:
            return .projection(mode: .aip)
        }
    }

    var displayName: String {
        switch self {
        case .dvr:
            return "3D"
        case .mip:
            return "MIP"
        case .minip:
            return "MinIP"
        case .aip:
            return "AIP"
        }
    }

    var compositing: VolumeRenderRequest.Compositing {
        switch self {
        case .dvr:
            return .frontToBack
        case .mip:
            return .maximumIntensity
        case .minip:
            return .minimumIntensity
        case .aip:
            return .averageIntensity
        }
    }
}

public struct ClinicalViewportTimingSnapshot: Equatable, Sendable {
    public var renderTime: CFAbsoluteTime?
    public var presentationTime: CFAbsoluteTime?
    public var uploadTime: CFAbsoluteTime?

    public init(renderTime: CFAbsoluteTime? = nil,
                presentationTime: CFAbsoluteTime? = nil,
                uploadTime: CFAbsoluteTime? = nil) {
        self.renderTime = renderTime
        self.presentationTime = presentationTime
        self.uploadTime = uploadTime
    }
}

public struct ClinicalSlabConfiguration: Equatable, Sendable {
    public var thickness: Int
    public var steps: Int

    public init(thickness: Int = 3, steps: Int? = nil) {
        let resolvedThickness = Self.snapToOddVoxelCount(max(1, thickness))
        let doubledThickness = resolvedThickness > Int.max / 2 ? Int.max : resolvedThickness * 2
        let defaultSteps = max(doubledThickness, 6)
        self.thickness = resolvedThickness
        self.steps = Self.snapToOddVoxelCount(max(1, steps ?? defaultSteps))
    }

    /// Adjusts an integer to produce a positive, odd voxel count.
    /// - Parameter value: The input voxel count to normalize.
    /// - Returns: An odd integer greater than zero. If `value` is less than or equal to zero returns `1`; if `value` is even returns the nearest odd integer (decrementing when `value == Int.max` to avoid overflow); otherwise returns `value` unchanged.
    private static func snapToOddVoxelCount(_ value: Int) -> Int {
        guard value > 0 else { return 1 }
        if value % 2 == 0 {
            return value == Int.max ? value - 1 : value + 1
        }
        return value
    }
}

public enum ClinicalViewportGridControllerError: Error, Equatable, LocalizedError {
    case metalUnavailable
    case noDatasetApplied
    case viewportSurfaceNotFound

    public var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "Metal device unavailable"
        case .noDatasetApplied:
            return "No dataset is loaded in the clinical viewport grid"
        case .viewportSurfaceNotFound:
            return "Viewport surface not found"
        }
    }
}

public struct ClinicalViewportDebugSnapshot: Equatable, Sendable, Identifiable {
    public let viewportID: ViewportID
    public let viewportName: String
    public var viewportType: String
    public var renderMode: String
    public var datasetHandle: String?
    public var volumeTextureLabel: String?
    public var outputTextureLabel: String?
    public var lastPassExecuted: String?
    public var presentationStatus: String
    public var lastError: String?
    public var lastRenderRequestTime: CFAbsoluteTime?
    public var lastRenderCompletionTime: CFAbsoluteTime?
    public var lastPresentationTime: CFAbsoluteTime?

    public var id: ViewportID { viewportID }

    public init(viewportID: ViewportID,
                viewportName: String,
                viewportType: String,
                renderMode: String,
                datasetHandle: String? = nil,
                volumeTextureLabel: String? = nil,
                outputTextureLabel: String? = nil,
                lastPassExecuted: String? = nil,
                presentationStatus: String = "idle",
                lastError: String? = nil,
                lastRenderRequestTime: CFAbsoluteTime? = nil,
                lastRenderCompletionTime: CFAbsoluteTime? = nil,
                lastPresentationTime: CFAbsoluteTime? = nil) {
        self.viewportID = viewportID
        self.viewportName = viewportName
        self.viewportType = viewportType
        self.renderMode = renderMode
        self.datasetHandle = datasetHandle
        self.volumeTextureLabel = volumeTextureLabel
        self.outputTextureLabel = outputTextureLabel
        self.lastPassExecuted = lastPassExecuted
        self.presentationStatus = presentationStatus
        self.lastError = lastError
        self.lastRenderRequestTime = lastRenderRequestTime
        self.lastRenderCompletionTime = lastRenderCompletionTime
        self.lastPresentationTime = lastPresentationTime
    }
}

public struct MPRLabels: Equatable, Sendable {
    public var leading: String
    public var trailing: String
    public var top: String
    public var bottom: String

    public init(leading: String, trailing: String, top: String, bottom: String) {
        self.leading = leading
        self.trailing = trailing
        self.top = top
        self.bottom = bottom
    }

    public init(_ labels: (leading: String, trailing: String, top: String, bottom: String)) {
        self.init(leading: labels.leading,
                  trailing: labels.trailing,
                  top: labels.top,
                  bottom: labels.bottom)
    }
}

@available(*, deprecated, message: "Use MPRDisplayTransform instead.")
public struct ClinicalMPRDisplayContract: Equatable, Sendable {
    public let flipHorizontal: Bool
    public let flipVertical: Bool
    public let labels: MPRLabels

    public init(flipHorizontal: Bool,
                flipVertical: Bool,
                labels: MPRLabels) {
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.labels = labels
    }

    public init(flipHorizontal: Bool,
                flipVertical: Bool,
                labels: (leading: String, trailing: String, top: String, bottom: String)) {
        self.init(flipHorizontal: flipHorizontal,
                  flipVertical: flipVertical,
                  labels: MPRLabels(labels))
    }

    public init(_ transform: MPRDisplayTransform) {
        self.init(flipHorizontal: transform.presentationFlipHorizontal,
                  flipVertical: transform.presentationFlipVertical,
                  labels: MPRLabels(transform.labels))
    }

    /// Creates a ClinicalMPRDisplayContract using the clinical default MPR display transform for the specified axis.
    /// - Parameter axis: The imaging axis (axial, coronal, sagittal) used to derive the default transform.
    /// - Returns: A ClinicalMPRDisplayContract configured with the clinical default transform for the given axis.
    public static func `default`(for axis: MTKCore.Axis) -> ClinicalMPRDisplayContract {
        ClinicalMPRDisplayContract(defaultClinicalMPRDisplayTransform(for: axis))
    }

    /// Compare two `ClinicalMPRDisplayContract` values for equality.
    /// - Returns: `true` if both contracts have identical `flipHorizontal`, `flipVertical`, and all label strings (`leading`, `trailing`, `top`, `bottom`); `false` otherwise.
    public static func == (lhs: ClinicalMPRDisplayContract, rhs: ClinicalMPRDisplayContract) -> Bool {
        lhs.flipHorizontal == rhs.flipHorizontal &&
        lhs.flipVertical == rhs.flipVertical &&
        lhs.labels == rhs.labels
    }
}

extension ViewportType {
    var debugName: String {
        switch self {
        case .volume3D:
            return "volume3D"
        case .mpr(let axis):
            return "mpr(\(axis.debugName))"
        case .projection(let mode):
            return "projection(\(mode.debugName))"
        }
    }
}

extension ProjectionMode {
    var debugName: String {
        switch self {
        case .mip:
            return "mip"
        case .minip:
            return "minip"
        case .aip:
            return "aip"
        }
    }
}

extension MTKCore.Axis {
    var debugName: String {
        switch self {
        case .axial:
            return "axial"
        case .coronal:
            return "coronal"
        case .sagittal:
            return "sagittal"
        }
    }
}

/// Creates a default MPR display transform for the given axis using the clinical fallback plane geometry and axis mapping.
/// - Parameter axis: The imaging axis (`.axial`, `.coronal`, or `.sagittal`) to build the transform for.
/// - Returns: An `MPRDisplayTransform` configured for the specified axis using clinical fallback geometry and plane axis mapping.
func defaultClinicalMPRDisplayTransform(for axis: MTKCore.Axis) -> MPRDisplayTransform {
    MPRDisplayTransformFactory.makeTransform(for: clinicalFallbackPlaneGeometry(for: axis),
                                            axis: clinicalPlaneAxis(for: axis))
}

/// Maps an `MTKCore.Axis` to the corresponding `MPRPlaneAxis` used for clinical MPR transforms.
/// - Parameters:
///   - axis: The imaging axis (`.axial`, `.coronal`, or `.sagittal`).
/// - Returns: The matching `MPRPlaneAxis` — `.z` for `.axial`, `.y` for `.coronal`, and `.x` for `.sagittal`.
func clinicalPlaneAxis(for axis: MTKCore.Axis) -> MPRPlaneAxis {
    switch axis {
    case .axial:
        return .z
    case .coronal:
        return .y
    case .sagittal:
        return .x
    }
}

/// Produce a canonical MPRPlaneGeometry for the given MTKCore.Axis.
/// - Parameter axis: The axis to map.
/// - Returns: An `MPRPlaneGeometry` using `.canonical(axis:)` with `.z` for `.axial`, `.y` for `.coronal`, and `.x` for `.sagittal`.
func clinicalFallbackPlaneGeometry(for axis: MTKCore.Axis) -> MPRPlaneGeometry {
    switch axis {
    case .axial:
        return .canonical(axis: .z)
    case .coronal:
        return .canonical(axis: .y)
    case .sagittal:
        return .canonical(axis: .x)
    }
}
