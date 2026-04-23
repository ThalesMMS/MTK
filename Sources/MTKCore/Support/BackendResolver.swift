//
//  BackendResolver.swift
//  MTK - MTKCore
//
//  Provides runtime verification for the Metal requirement used by volumetric
//  rendering. This component encapsulates the checks that decide whether the
//  current system satisfies the Metal rendering contract, with support for
//  persisting the check result via UserDefaults.
//
//  Note: This struct focuses on Metal runtime availability checking. Related
//  rendering-mode types live in MTKUI/VolumeViewportController.swift to avoid
//  circular dependencies.
//
//  Extracted from: Isis DICOM Viewer/Presentation/ViewModels/Viewer/VolumetricSessionState.swift
//  Thales Matheus Mendonça Santos - November 2025
//

import Foundation

/// Represents requirement failures encountered while verifying the Metal rendering contract.
public enum BackendResolutionError: LocalizedError, Equatable {
    /// The host does not satisfy the required Metal runtime capabilities.
    case metalUnavailable
    /// Metal runtime capability checks passed, but Metal rendering initialization still failed.
    case noBackendAvailable

    public var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "Metal runtime is not available on this system. Use a Metal-capable device for volumetric rendering."
        case .noBackendAvailable:
            return "Metal initialization failed for volumetric rendering."
        }
    }

    public var failureReason: String? {
        switch self {
        case .metalUnavailable:
            return "The GPU does not support the required Metal runtime capabilities."
        case .noBackendAvailable:
            return "Metal initialization failed after runtime availability was checked."
        }
    }
}

/// Verifies the Metal runtime requirement for the volumetric rendering path.
///
/// `BackendResolver` checks the Metal runtime requirement and can persist the
/// result to `UserDefaults` for future sessions. Higher-level UI code should use
/// this check to surface an explicit unsupported-capability state before creating
/// Metal rendering controllers.
///
/// Throwing requirement check:
/// ```swift
/// let resolver = BackendResolver(defaults: UserDefaults.standard)
/// try resolver.checkMetalAvailability()
/// // Initialize Metal-based rendering.
/// ```
///
/// Non-throwing status check:
/// ```swift
/// let resolver = BackendResolver(defaults: nil)
/// let available = resolver.isMetalAvailable()
/// ```
public struct BackendResolver {
    /// The UserDefaults instance where Metal requirement check results are stored.
    /// If nil, no preference persistence occurs.
    public let defaults: UserDefaults?

    /// Creates a new Metal requirement resolver.
    ///
    /// - Parameter defaults: Optional UserDefaults instance for persisting preferences.
    ///   If nil, the resolver will not persist the check result.
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
    }

    /// Checks whether this system satisfies the Metal rendering requirement.
    ///
    /// This method uses the MetalRuntimeGuard to determine if the GPU supports
    /// the features required by the Metal volumetric rendering stack.
    /// A successful result can optionally be persisted to UserDefaults.
    ///
    /// - Returns: true if the Metal runtime satisfies all requirements.
    /// - Throws: BackendResolutionError.metalUnavailable if the requirement is not satisfied.
    public func checkMetalAvailability() throws -> Bool {
        guard Self.isMetalBackendAvailable() else {
            throw BackendResolutionError.metalUnavailable
        }

        // Persist the Metal requirement check result.
        if let defaults = defaults {
            defaults.set(true, forKey: Self.metalAvailabilityKey)
        }

        return true
    }

    /// Checks whether this system satisfies the Metal rendering requirement (non-throwing).
    ///
    /// Returns the requirement status without raising an error. This is useful
    /// for UI gating that presents an unsupported-capability state.
    ///
    /// - Returns: true if Metal runtime is available, false otherwise
    public func isMetalAvailable() -> Bool {
        Self.isMetalBackendAvailable()
    }

    /// Checks whether this system satisfies the Metal rendering requirement.
    ///
    /// This method uses conditional compilation to check Metal availability through
    /// the MetalRuntimeAvailability bridge, which internally uses MetalRuntimeGuard.
    ///
    /// - Returns: true if the Metal runtime satisfies required capabilities, false otherwise.
    private static func isMetalBackendAvailable() -> Bool {
        return MetalRuntimeAvailability.isAvailable()
    }

    /// The UserDefaults key for storing the Metal requirement check result.
    public static let metalAvailabilityKey = "volumetric.metalAvailable"

    /// Legacy UserDefaults key retained for compatibility with existing preference storage.
    public static let preferredBackendKey = "volumetric.preferredBackend"
}

// MARK: - Static Helper Methods

public extension BackendResolver {
    /// Convenience static method to enforce Metal availability with default UserDefaults.
    ///
    /// - Parameter defaults: UserDefaults instance to use. Defaults to UserDefaults.standard
    /// - Returns: true if the Metal runtime satisfies required capabilities.
    /// - Throws: BackendResolutionError.metalUnavailable if the requirement is not satisfied.
    static func checkConfiguredMetalAvailability(
        defaults: UserDefaults = .standard
    ) throws -> Bool {
        try BackendResolver(defaults: defaults).checkMetalAvailability()
    }

    /// Convenience static method to inspect Metal availability without side effects.
    ///
    /// Useful for non-throwing requirement checks that don't persist results.
    ///
    /// - Returns: true if the Metal runtime satisfies required capabilities.
    static func isMetalAvailable() -> Bool {
        BackendResolver(defaults: nil).isMetalAvailable()
    }
}
