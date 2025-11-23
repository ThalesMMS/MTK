//
//  BackendResolver.swift
//  MTK - MTKCore
//
//  Provides runtime resolution of the volumetric rendering backend based on
//  Metal availability and user preferences. This component encapsulates the logic
//  for determining which rendering backend can be safely used on the current system,
//  with support for persisting user preferences via UserDefaults.
//
//  Note: This struct focuses on Metal runtime availability checking. The actual
//  backend enumeration (metalPerformanceShaders vs sceneKit) is defined in
//  MTKUI/VolumetricSceneController.swift to avoid circular dependencies.
//
//  Extracted from: Isis DICOM Viewer/Presentation/ViewModels/Viewer/VolumetricSessionState.swift
//  Thales Matheus Mendonça Santos - November 2025
//

import Foundation

/// Represents errors that can occur during Metal backend resolution
public enum BackendResolutionError: LocalizedError, Equatable {
    case metalUnavailable
    case noBackendAvailable

    public var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "Metal runtime is not available on this system. Enable a Metal-capable device to use the Metal backend."
        case .noBackendAvailable:
            return "No volumetric backend is available on this system."
        }
    }

    public var failureReason: String? {
        switch self {
        case .metalUnavailable:
            return "The GPU does not support the required Metal runtime capabilities."
        case .noBackendAvailable:
            return "Neither Metal nor any fallback backend could be initialized."
        }
    }
}

/// Resolves Metal backend availability at runtime.
///
/// BackendResolver checks Metal runtime availability and persists the resolution
/// to UserDefaults for future sessions. This component is used by higher-level
/// backend selection logic to determine which rendering implementation should be used.
///
/// Usage:
/// ```swift
/// let resolver = BackendResolver(defaults: UserDefaults.standard)
/// if try resolver.isMetalAvailable() {
///     // Use Metal-based rendering
/// }
/// ```
///
/// For testing:
/// ```swift
/// let resolver = BackendResolver(defaults: nil)
/// let available = try resolver.isMetalAvailable()
/// ```
public struct BackendResolver {
    /// The UserDefaults instance where backend preferences are stored.
    /// If nil, no preference persistence occurs.
    public let defaults: UserDefaults?

    /// Creates a new BackendResolver.
    ///
    /// - Parameter defaults: Optional UserDefaults instance for persisting preferences.
    ///   If nil, the resolver will not persist the resolution result.
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
    }

    /// Checks whether the Metal backend is available on this system.
    ///
    /// This method uses the MetalRuntimeGuard to determine if the GPU supports
    /// the features required by the Metal volumetric rendering stack.
    /// The result can optionally be persisted to UserDefaults.
    ///
    /// - Returns: true if Metal runtime is available and meets all requirements
    /// - Throws: BackendResolutionError.metalUnavailable if Metal is unavailable
    public func checkMetalAvailability() throws -> Bool {
        guard Self.isMetalBackendAvailable() else {
            throw BackendResolutionError.metalUnavailable
        }

        // Persist the Metal availability check result
        if let defaults = defaults {
            defaults.set(true, forKey: Self.metalAvailabilityKey)
        }

        return true
    }

    /// Checks whether the Metal backend is available on this system (non-throwing).
    ///
    /// Returns the availability status without raising an error.
    /// This is useful for conditional logic that doesn't require error handling.
    ///
    /// - Returns: true if Metal runtime is available, false otherwise
    public func isMetalAvailable() -> Bool {
        Self.isMetalBackendAvailable()
    }

    /// Checks whether the Metal backend is available on this system.
    ///
    /// This method uses conditional compilation to check Metal availability through
    /// the MetalRuntimeAvailability bridge, which internally uses MetalRuntimeGuard.
    ///
    /// - Returns: true if Metal runtime is available and meets minimum requirements, false otherwise
    private static func isMetalBackendAvailable() -> Bool {
        return MetalRuntimeAvailability.isAvailable()
    }

    /// The UserDefaults key for storing the Metal availability check result
    public static let metalAvailabilityKey = "volumetric.metalAvailable"

    /// The UserDefaults key for storing the preferred backend preference
    /// This key is used by higher-level selection logic
    public static let preferredBackendKey = "volumetric.preferredBackend"
}

// MARK: - Static Helper Methods

public extension BackendResolver {
    /// Convenience static method to check Metal availability with default UserDefaults.
    ///
    /// - Parameter defaults: UserDefaults instance to use. Defaults to UserDefaults.standard
    /// - Returns: true if Metal is available
    /// - Throws: BackendResolutionError.metalUnavailable if Metal is not available
    static func checkConfiguredMetalAvailability(
        defaults: UserDefaults = .standard
    ) throws -> Bool {
        try BackendResolver(defaults: defaults).checkMetalAvailability()
    }

    /// Convenience static method to check Metal availability without side effects.
    ///
    /// Useful for non-throwing checks that don't persist results.
    ///
    /// - Returns: true if Metal is available
    static func isMetalAvailable() -> Bool {
        BackendResolver(defaults: nil).isMetalAvailable()
    }
}
